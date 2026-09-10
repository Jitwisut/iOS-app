import Foundation
import Observation

struct ActivityEntry: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case arrived, left, test, skipped, error

        var symbol: String {
            switch self {
            case .arrived: "house.fill"
            case .left: "figure.walk.departure"
            case .test: "wand.and.stars"
            case .skipped: "moon.zzz.fill"
            case .error: "exclamationmark.triangle.fill"
            }
        }
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var message: String
}

@Observable
final class ActivityLog {
    private static let key = "activity.v1"
    private(set) var entries: [ActivityEntry]

    init() {
        entries = Persisted.load([ActivityEntry].self, key: Self.key) ?? []
    }

    func add(_ kind: ActivityEntry.Kind, _ message: String) {
        entries.insert(ActivityEntry(kind: kind, message: message), at: 0)
        if entries.count > 60 { entries.removeLast(entries.count - 60) }
        Persisted.save(entries, key: Self.key)
    }

    func clear() {
        entries = []
        Persisted.save(entries, key: Self.key)
    }
}
