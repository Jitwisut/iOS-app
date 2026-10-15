import AppIntents
import WidgetKit

// The widget intents take plain light ids (picked through `LightOptions`) rather than an
// AppEntity: an entity parameter arrived empty here, so a toggle built on it silently did
// nothing.

/// Which light a Control Center toggle or Home Screen widget switches. Left empty, it
/// uses the first light — the only one in a simple-switch or MQTT setup.
struct SelectLightIntent: WidgetConfigurationIntent, ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a Light"
    static let description = IntentDescription("The light this control switches.")
    /// Only meant for configuring a widget, not as an action in Shortcuts.
    static let isDiscoverable = false

    @Parameter(title: "Light", optionsProvider: LightOptions())
    var lightID: String?

    init() {}

    /// Both configuration protocols supply a default `perform()`, so one has to be spelled out.
    func perform() async throws -> some IntentResult { .result() }

    /// The configured light if it still exists, else the first one, else the fixed device.
    func resolve(in lights: [CachedLight]) -> CachedLight {
        lights.first { $0.id == lightID } ?? lights.first ?? .fallback
    }
}

/// The action behind the Control Center toggle and the widget's power button.
struct SwitchLightIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn a Light On or Off"
    static let isDiscoverable = false

    @Parameter(title: "Light")
    var lightID: String

    @Parameter(title: "On")
    var value: Bool

    init() {}

    init(lightID: String, value: Bool? = nil) {
        self.lightID = lightID
        if let value { self.value = value }
    }

    func perform() async throws -> some IntentResult {
        try await LightRemote.setPower(value, id: lightID)
        return .result()
    }
}
