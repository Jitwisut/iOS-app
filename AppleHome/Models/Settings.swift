import Foundation
import CoreLocation

struct Coordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum LeaveAction: String, Codable, CaseIterable, Sendable {
    case turnOff, nothing
}

struct ArrivalSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var home: Coordinate?
    /// Meters
    var radius: Double = 300
    /// Empty means "all lights".
    var lightIDs: Set<String> = []
    var onLeave: LeaveAction = .turnOff
    var onlyAfterDark = false
    var notify = true

    static let radiusRange: ClosedRange<Double> = 100...2000
}

struct APIConfiguration: Codable, Equatable, Sendable {
    var isEnabled = false
    var baseURL = ""
}

struct AppSettings: Codable, Equatable, Sendable {
    var homeName = ""
    var demoEnabled = true
    var api = APIConfiguration()
    var homeKitEnabled = false
    var homeKitHomeID: String?
}

/// Tiny Codable-over-UserDefaults persistence.
enum Persisted {
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
