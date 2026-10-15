import AppIntents

/// Siri phrases and the app's tiles in Shortcuts and Spotlight. Thai phrases live in
/// AppShortcuts.xcstrings; every phrase has to name the app.
struct AppleHomeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnLightsIntent(),
            phrases: [
                "Turn on the lights in \(.applicationName)",
                "Lights on in \(.applicationName)",
            ],
            shortTitle: "Lights On",
            systemImageName: "lightbulb.fill"
        )
        AppShortcut(
            intent: TurnOffLightsIntent(),
            phrases: [
                "Turn off the lights in \(.applicationName)",
                "Lights off in \(.applicationName)",
            ],
            shortTitle: "Lights Off",
            systemImageName: "lightbulb.slash"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
