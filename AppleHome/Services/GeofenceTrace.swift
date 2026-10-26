import Foundation
import os

/// A short history of launches and geofence decisions, kept on the device. Background
/// relaunches happen with nobody watching the console, so this is what shows afterwards
/// whether iOS woke the app at all, what it reported, and what the app did about it.
/// Read it back with `devicectl device copy from … --source Library/Preferences`.
enum GeofenceTrace {
    private static let key = "geofence.trace"
    private static let limit = 300
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func add(_ line: String) {
        geofenceLog.info("\(line, privacy: .public)")
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append("\(formatter.string(from: .now)) \(line)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        UserDefaults.standard.set(lines, forKey: key)
    }
}
