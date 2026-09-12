import Foundation

/// Runs shortcuts from the user's own Shortcuts app by name.
///
/// iOS has no public API for a third-party app to list or read a user's shortcuts —
/// the Shortcuts app is the only place that list exists. So this app can only run a
/// shortcut whose exact name the user has typed in (copied from the Shortcuts app),
/// via Shortcuts' own `x-callback-url` scheme. The callback comes back into this app
/// through the `applehome://shortcut-result` URL registered in Info.plist, which
/// `RootView` picks up with `.onOpenURL`.
enum ShortcutsService {
    /// Opens the Shortcuts app itself, e.g. so the user can copy a shortcut's name.
    static let appURL = URL(string: "shortcuts://")!

    /// Builds the URL that runs `name` and reports back to this app when it finishes.
    static func runURL(named name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "x-success", value: "applehome://shortcut-result?status=success&name=\(trimmed)"),
            URLQueryItem(name: "x-error", value: "applehome://shortcut-result?status=error&name=\(trimmed)"),
            URLQueryItem(name: "x-cancel", value: "applehome://shortcut-result?status=cancelled&name=\(trimmed)"),
        ]
        return components.url
    }

    struct CallbackResult {
        enum Status: String { case success, error, cancelled }
        var name: String
        var status: Status
    }

    /// Parses a callback from Shortcuts; `nil` if `url` isn't one of ours.
    static func parseCallback(_ url: URL) -> CallbackResult? {
        guard url.scheme == "applehome", url.host == "shortcut-result" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let statusRaw = items.first(where: { $0.name == "status" })?.value,
              let status = CallbackResult.Status(rawValue: statusRaw) else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? ""
        return CallbackResult(name: name, status: status)
    }
}
