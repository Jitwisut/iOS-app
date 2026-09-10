import Foundation

/// A backend that can list and control lights. HomeStore talks to every enabled provider
/// through this protocol, so the UI never cares where a light comes from.
protocol LightProvider: AnyObject {
    var source: LightSource { get }
    func loadLights() async throws -> [Light]
    func setPower(_ isOn: Bool, remoteID: String) async throws
    func setBrightness(_ value: Double, remoteID: String) async throws
}

final class DemoLightProvider: LightProvider {
    let source = LightSource.demo
    private var lights: [Light]

    init() {
        let living = String(localized: "Living Room")
        let kitchen = String(localized: "Kitchen")
        let bedroom = String(localized: "Bedroom")
        let porch = String(localized: "Porch")
        func make(_ id: String, _ name: String, _ room: String, _ kind: LightKind, _ on: Bool, _ b: Double) -> Light {
            Light(remoteID: id, source: .demo, name: name, room: room, kind: kind, isOn: on, brightness: b)
        }
        lights = [
            make("living-ceiling", String(localized: "Ceiling Light"), living, .ceiling, true, 0.8),
            make("living-floor", String(localized: "Floor Lamp"), living, .floorLamp, false, 0.6),
            make("kitchen-pendant", String(localized: "Pendant"), kitchen, .ceiling, false, 1.0),
            make("kitchen-strip", String(localized: "Cabinet Strip"), kitchen, .strip, true, 0.45),
            make("bed-bedside", String(localized: "Bedside Lamp"), bedroom, .tableLamp, false, 0.35),
            make("bed-ceiling", String(localized: "Bedroom Ceiling"), bedroom, .ceiling, false, 0.7),
            make("porch-light", String(localized: "Porch Light"), porch, .outdoor, false, 1.0),
        ]
    }

    func loadLights() async throws -> [Light] {
        try await Task.sleep(for: .milliseconds(250))
        return lights
    }

    func setPower(_ isOn: Bool, remoteID: String) async throws {
        try await Task.sleep(for: .milliseconds(120))
        guard let i = lights.firstIndex(where: { $0.remoteID == remoteID }) else { return }
        lights[i].isOn = isOn
    }

    func setBrightness(_ value: Double, remoteID: String) async throws {
        try await Task.sleep(for: .milliseconds(120))
        guard let i = lights.firstIndex(where: { $0.remoteID == remoteID }) else { return }
        lights[i].brightness = value
        lights[i].isOn = value > 0
    }
}
