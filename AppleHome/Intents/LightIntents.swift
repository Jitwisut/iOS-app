import AppIntents

/// Switches one light. The light is picked by id through `LightOptions` (see there for why
/// it isn't an AppEntity).
struct SetLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn a Light On or Off"
    static let description = IntentDescription("Switches one light from your light server.")

    @Parameter(title: "Light", optionsProvider: LightOptions())
    var lightID: String

    @Parameter(title: "On", displayName: Bool.IntentDisplayName(true: "On", false: "Off"))
    var value: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$lightID) \(\.$value)")
    }

    func perform() async throws -> some IntentResult {
        try await LightRemote.setPower(value, id: lightID)
        return .result()
    }
}

struct TurnOnLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On the Lights"
    static let description = IntentDescription("Turns on every light from your light server.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LightRemote.setAll(true)
        return .result(dialog: "Lights are on.")
    }
}

struct TurnOffLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off the Lights"
    static let description = IntentDescription("Turns off every light from your light server.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LightRemote.setAll(false)
        return .result(dialog: "Lights are off.")
    }
}
