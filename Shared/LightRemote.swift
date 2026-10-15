import Foundation
import WidgetKit

/// A light as the widgets last saw it, kept in the app group so a widget or Control Center
/// toggle can still draw something sensible while the device is slow or offline.
struct CachedLight: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var room: String
    var isOn: Bool

    /// The single on/off device, used before any light has been loaded — which is also
    /// exactly the light a simple-switch or MQTT setup has.
    static var fallback: CachedLight {
        CachedLight(id: Light.makeID(source: .api, remoteID: APILightProvider.switchID),
                    name: String(localized: "Light"), room: "", isOn: false)
    }
}

enum LightCache {
    private static let key = "widget.lights.v1"

    static var lights: [CachedLight] {
        Persisted.load([CachedLight].self, key: key, in: AppGroup.defaults) ?? []
    }

    /// Replaces the list with the API lights from a fresh load.
    static func remember(_ lights: [Light]) {
        let cached = lights.filter { $0.source == .api }.map {
            CachedLight(id: $0.id, name: $0.name, room: $0.room, isOn: $0.isOn)
        }
        store(cached)
    }

    static func remember(isOn: Bool, id: String) {
        var cached = lights
        guard let index = cached.firstIndex(where: { $0.id == id }) else { return }
        cached[index].isOn = isOn
        store(cached)
    }

    private static func store(_ cached: [CachedLight]) {
        guard cached != lights else { return }
        Persisted.save(cached, key: key, in: AppGroup.defaults)
        // Both are cheap no-ops when nothing is installed, and keep a toggle made in the
        // app from leaving Control Center or the Home Screen showing the old state.
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

extension Notification.Name {
    /// Posted after an App Intent switched a light, so a running app can reload its list.
    static let lightsChangedOutsideApp = Notification.Name("AppleHome.lightsChangedOutsideApp")
}

/// Switches API lights using only the shared settings and keychain, with none of the app's
/// object graph. App Intents can run in the app or in the widget extension, so everything
/// they do goes through here.
///
/// Only API lights are offered: HomeKit refuses to control accessories from the background
/// or an extension, and demo lights only exist inside the app's own process.
enum LightRemote {
    enum Failure: LocalizedError {
        case notSetUp, unknownLight

        var errorDescription: String? {
            switch self {
            case .notSetUp: String(localized: "Set up a light server in AppleHome first.")
            case .unknownLight: String(localized: "That light isn't available anymore.")
            }
        }
    }

    /// A Control Center toggle has to answer quickly, so a slow device falls back to the cache.
    private static let readDeadline: Duration = .seconds(4)

    static var isSetUp: Bool { AppGroup.settings.api.isEnabled }

    /// Fresh from the server when it answers in time, otherwise the last known list.
    static func lights() async -> [CachedLight] {
        guard let provider = makeProvider() else { return [] }
        defer { provider.close() }
        if let loaded = await withDeadline(readDeadline, { try await provider.loadLights() }) {
            LightCache.remember(loaded)
        }
        return LightCache.lights
    }

    static func setPower(_ isOn: Bool, id: String) async throws {
        guard let provider = makeProvider() else { throw Failure.notSetUp }
        defer { provider.close() }
        guard let target = Light.parse(id: id), target.source == .api else { throw Failure.unknownLight }
        try await provider.setPower(isOn, remoteID: target.remoteID)
        LightCache.remember(isOn: isOn, id: id)
        NotificationCenter.default.post(name: .lightsChangedOutsideApp, object: nil)
    }

    /// Every API light, or the one fixed device when listing it fails — a sleepy ESP
    /// shouldn't stop "turn off the lights" from at least sending the command.
    @discardableResult
    static func setAll(_ isOn: Bool) async throws -> Int {
        guard let provider = makeProvider() else { throw Failure.notSetUp }
        defer { provider.close() }
        var ids = provider.directTargets
        if ids.isEmpty {
            let loaded = await withDeadline(readDeadline, { try await provider.loadLights() })
            ids = loaded?.map(\.remoteID) ?? LightCache.lights.compactMap { Light.parse(id: $0.id)?.remoteID }
        }
        guard !ids.isEmpty else { throw Failure.unknownLight }
        var firstError: Error?
        var done = 0
        for remoteID in ids {
            do {
                try await provider.setPower(isOn, remoteID: remoteID)
                LightCache.remember(isOn: isOn, id: Light.makeID(source: .api, remoteID: remoteID))
                done += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        NotificationCenter.default.post(name: .lightsChangedOutsideApp, object: nil)
        if done == 0, let firstError { throw firstError }
        return done
    }

    private static func makeProvider() -> APILightProvider? {
        let settings = AppGroup.settings
        guard settings.api.isEnabled else { return nil }
        return APILightProvider(configuration: settings.api)
    }

    /// The work's result, or nil if it failed or didn't finish in time. The provider's own
    /// MQTT waits aren't cancellable, so a late result is simply dropped.
    private static func withDeadline<T>(_ deadline: Duration, _ work: @escaping () async throws -> T) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let value = try? await work()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Lets only the first of two racing tasks resume a continuation.
private nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
