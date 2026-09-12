import SwiftUI
import Observation

struct AutomationResult {
    var done = 0
    var failed = 0
    /// Lights the Apple Home automation switches instead of the app.
    var leftToHomeKit = 0
}

/// Every light from every enabled provider, with optimistic control.
@Observable
final class HomeStore {
    private(set) var lights: [Light] = []
    private(set) var isLoading = false
    var errorMessage: String?
    var selectedRoom: String?
    var enabledSources: Set<LightSource>

    private var providers: [LightSource: LightProvider] = [:]
    private var brightnessTasks: [String: Task<Void, Never>] = [:]

    init(providers: [LightProvider], enabledSources: Set<LightSource>) {
        self.enabledSources = enabledSources
        for provider in providers { self.providers[provider.source] = provider }
    }

    // MARK: Derived state

    var rooms: [String] {
        var seen = Set<String>()
        return lights.map(\.room).filter { seen.insert($0).inserted }
    }

    var visibleLights: [Light] {
        guard let selectedRoom else { return lights }
        return lights.filter { $0.room == selectedRoom }
    }

    var onCount: Int { lights.count(where: \.isOn) }

    func onCount(in room: String) -> Int { lights.count { $0.room == room && $0.isOn } }

    var roomGlows: [RoomGlow] {
        rooms.map { room in
            let inRoom = lights.filter { $0.room == room }
            let on = inRoom.filter(\.isOn)
            let level = on.isEmpty ? 0 : min(1, on.map { max($0.brightness, 0.25) }.reduce(0, +) / Double(max(inRoom.count, 1)) * 1.4)
            return RoomGlow(name: room, total: inRoom.count, onCount: on.count, level: level)
        }
    }

    /// 0...1, drives the ambient glow behind the house.
    var ambientGlow: Double {
        guard !lights.isEmpty else { return 0 }
        return lights.filter(\.isOn).map(\.brightness).reduce(0, +) / Double(lights.count)
    }

    func light(_ id: String) -> Light? { lights.first { $0.id == id } }

    // MARK: Loading

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        var loaded: [Light] = []
        var failures: [String] = []
        for source in LightSource.allCases where enabledSources.contains(source) {
            guard let provider = providers[source] else { continue }
            do {
                loaded += try await provider.loadLights()
            } catch {
                failures.append("\(source.displayName): \(error.localizedDescription)")
            }
        }
        withAnimation(.softSpring) {
            lights = loaded
            if let selectedRoom, !rooms.contains(selectedRoom) { self.selectedRoom = nil }
        }
        errorMessage = failures.first
    }

    // MARK: Control

    func toggle(_ light: Light) {
        Task { await setPower(!light.isOn, id: light.id) }
    }

    func setPower(_ isOn: Bool, id: String) async {
        guard let light = light(id), let provider = providers[light.source] else { return }
        let previous = light
        mutate(id) { $0.isOn = isOn; if isOn && $0.brightness < 0.05 { $0.brightness = 1 } }
        do {
            try await provider.setPower(isOn, remoteID: light.remoteID)
        } catch {
            mutate(id) { $0 = previous }
            errorMessage = error.localizedDescription
        }
    }

    func setAll(_ isOn: Bool, room: String? = nil) {
        let targets = lights.filter { ($0.room == room || room == nil) && $0.isOn != isOn }
        for light in targets {
            Task { await setPower(isOn, id: light.id) }
        }
    }

    /// Updates the UI immediately; the network write is debounced while the user drags.
    func setBrightness(_ value: Double, id: String) {
        guard let light = light(id), let provider = providers[light.source] else { return }
        let clamped = min(max(value, 0), 1)
        mutate(id, animated: false) { $0.brightness = clamped; $0.isOn = clamped > 0.005 }
        brightnessTasks[id]?.cancel()
        brightnessTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try await provider.setBrightness(clamped, remoteID: light.remoteID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs an arrival/departure action. HomeKit lights are skipped unless `includeHomeKit`,
    /// because the home hub runs those from the Apple Home automation.
    func runAutomation(isOn: Bool, lightIDs: Set<String>, includeHomeKit: Bool) async -> AutomationResult {
        var candidates: [(source: LightSource, remoteID: String)]
        let selectedSources: Set<LightSource>
        if lightIDs.isEmpty {
            if lights.isEmpty { await refresh() }
            candidates = lights.map { ($0.source, $0.remoteID) }
            selectedSources = enabledSources
        } else {
            candidates = lightIDs.compactMap(Light.parse)
            selectedSources = Set(candidates.map(\.source))
        }
        candidates = candidates.filter { enabledSources.contains($0.source) }

        // A provider that always addresses the same device needs no list, so an arrival
        // still works when the status read failed — which is common on sleepy hardware.
        for source in enabledSources where selectedSources.contains(source) {
            guard let direct = providers[source]?.directTargets, !direct.isEmpty else { continue }
            candidates.removeAll { $0.source == source }
            candidates += direct.map { (source, $0) }
        }

        var result = AutomationResult()
        for target in candidates {
            if target.source == .homeKit && !includeHomeKit {
                result.leftToHomeKit += 1
                continue
            }
            guard let provider = providers[target.source] else { continue }
            do {
                try await provider.setPower(isOn, remoteID: target.remoteID)
                mutate(Light.makeID(source: target.source, remoteID: target.remoteID)) { $0.isOn = isOn }
                result.done += 1
            } catch {
                result.failed += 1
            }
        }
        return result
    }

    private func mutate(_ id: String, animated: Bool = true, _ change: (inout Light) -> Void) {
        guard let index = lights.firstIndex(where: { $0.id == id }) else { return }
        if animated {
            withAnimation(.snappySpring) { change(&lights[index]) }
        } else {
            change(&lights[index])
        }
    }
}
