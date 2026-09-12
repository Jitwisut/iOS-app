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
    /// Shortcuts (from Settings › Shortcuts) to run on arrival, in addition to switching
    /// lights. Best-effort: iOS only lets the app hand off to Shortcuts while AppleHome
    /// is in the foreground, so this can silently do nothing on a background arrival.
    var arrivalShortcutIDs: Set<UUID> = []

    static let radiusRange: ClosedRange<Double> = 100...2000

    init() {}

    /// Hand-written so settings saved by an older build still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        home = try c.decodeIfPresent(Coordinate.self, forKey: .home)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 300
        lightIDs = try c.decodeIfPresent(Set<String>.self, forKey: .lightIDs) ?? []
        onLeave = try c.decodeIfPresent(LeaveAction.self, forKey: .onLeave) ?? .turnOff
        onlyAfterDark = try c.decodeIfPresent(Bool.self, forKey: .onlyAfterDark) ?? false
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        arrivalShortcutIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .arrivalShortcutIDs) ?? []
    }
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

/// A shortcut from the user's own Shortcuts app, run by name. iOS gives third-party
/// apps no way to list or introspect a user's shortcuts, so this is just a name the
/// user copied over — see `ShortcutsService`.
struct ShortcutItem: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
}

struct AppSettings: Codable, Equatable, Sendable {
    var homeName = ""
    var demoEnabled = true
    var api = APIConfiguration()
    var homeKitEnabled = false
    var homeKitHomeID: String?
    var shortcuts: [ShortcutItem] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homeName = try c.decodeIfPresent(String.self, forKey: .homeName) ?? ""
        demoEnabled = try c.decodeIfPresent(Bool.self, forKey: .demoEnabled) ?? true
        api = try c.decodeIfPresent(APIConfiguration.self, forKey: .api) ?? APIConfiguration()
        homeKitEnabled = try c.decodeIfPresent(Bool.self, forKey: .homeKitEnabled) ?? false
        homeKitHomeID = try c.decodeIfPresent(String.self, forKey: .homeKitHomeID)
        shortcuts = try c.decodeIfPresent([ShortcutItem].self, forKey: .shortcuts) ?? []
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
