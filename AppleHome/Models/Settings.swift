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

enum APIMode: String, Codable, CaseIterable, Sendable {
    /// A server that lists many lights (see API.md).
    case restServer
    /// One device with fixed on/off endpoints, e.g. an ESP32 relay.
    case simpleSwitch
    /// One device switched by publishing to an MQTT broker (e.g. HiveMQ Cloud),
    /// rather than calling HTTP endpoints directly.
    case mqttSwitch
}

struct APIConfiguration: Codable, Equatable, Sendable {
    var isEnabled = false
    var baseURL = ""
    var mode: APIMode = .restServer
    /// Simple-switch settings. Paths are stored without a leading slash.
    var keyHeader = "X-API-Key"
    var onPath = "api/on"
    var offPath = "api/off"
    var statusPath = "api/status"
    var deviceName = ""
    var deviceRoom = ""
    /// MQTT-switch settings. The password lives in the keychain, like the API key.
    var mqttHost = ""
    var mqttPort = 8883
    var mqttUsername = ""
    var commandTopic = ""
    var stateTopic = ""
    var availabilityTopic = ""

    init() {}

    /// Hand-written so settings saved by an older build still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        mode = try c.decodeIfPresent(APIMode.self, forKey: .mode) ?? .restServer
        keyHeader = try c.decodeIfPresent(String.self, forKey: .keyHeader) ?? "X-API-Key"
        onPath = try c.decodeIfPresent(String.self, forKey: .onPath) ?? "api/on"
        offPath = try c.decodeIfPresent(String.self, forKey: .offPath) ?? "api/off"
        statusPath = try c.decodeIfPresent(String.self, forKey: .statusPath) ?? "api/status"
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        deviceRoom = try c.decodeIfPresent(String.self, forKey: .deviceRoom) ?? ""
        mqttHost = try c.decodeIfPresent(String.self, forKey: .mqttHost) ?? ""
        mqttPort = try c.decodeIfPresent(Int.self, forKey: .mqttPort) ?? 8883
        mqttUsername = try c.decodeIfPresent(String.self, forKey: .mqttUsername) ?? ""
        commandTopic = try c.decodeIfPresent(String.self, forKey: .commandTopic) ?? ""
        stateTopic = try c.decodeIfPresent(String.self, forKey: .stateTopic) ?? ""
        availabilityTopic = try c.decodeIfPresent(String.self, forKey: .availabilityTopic) ?? ""
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var homeName = ""
    var demoEnabled = true
    var api = APIConfiguration()
    var homeKitEnabled = false
    var homeKitHomeID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homeName = try c.decodeIfPresent(String.self, forKey: .homeName) ?? ""
        demoEnabled = try c.decodeIfPresent(Bool.self, forKey: .demoEnabled) ?? true
        api = try c.decodeIfPresent(APIConfiguration.self, forKey: .api) ?? APIConfiguration()
        homeKitEnabled = try c.decodeIfPresent(Bool.self, forKey: .homeKitEnabled) ?? false
        homeKitHomeID = try c.decodeIfPresent(String.self, forKey: .homeKitHomeID)
    }
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
