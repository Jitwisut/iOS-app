import Foundation

enum LightSource: String, Codable, CaseIterable, Sendable {
    case demo, api, homeKit

    var displayName: String {
        switch self {
        case .demo: String(localized: "Demo")
        case .api: String(localized: "API")
        case .homeKit: String(localized: "Apple Home")
        }
    }

    var symbol: String {
        switch self {
        case .demo: "sparkles"
        case .api: "network"
        case .homeKit: "homekit"
        }
    }
}

enum LightKind: String, Codable, Sendable {
    case bulb, ceiling, floorLamp, tableLamp, strip, outdoor

    var symbol: String {
        switch self {
        case .bulb: "lightbulb"
        case .ceiling: "lamp.ceiling"
        case .floorLamp: "lamp.floor"
        case .tableLamp: "lamp.table"
        case .strip: "light.strip.2"
        case .outdoor: "light.cylindrical.ceiling"
        }
    }

    /// Best-effort guess from a device name (English or Thai).
    static func guess(from name: String) -> LightKind {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has("strip", "led", "ไฟเส้น") { return .strip }
        if has("floor", "ตั้งพื้น") { return .floorLamp }
        if has("desk", "table", "bedside", "โต๊ะ", "หัวเตียง") { return .tableLamp }
        if has("ceiling", "pendant", "เพดาน", "ห้อย") { return .ceiling }
        if has("porch", "garden", "outdoor", "gate", "หน้าบ้าน", "สวน", "ประตู") { return .outdoor }
        return .bulb
    }
}

struct Light: Identifiable, Hashable, Codable, Sendable {
    /// Globally unique: "<source>:<remoteID>". Lets automations reference lights across launches.
    var id: String { Light.makeID(source: source, remoteID: remoteID) }
    var remoteID: String
    var source: LightSource
    var name: String
    var room: String
    var kind: LightKind
    var isOn: Bool
    /// 0...1
    var brightness: Double
    var supportsBrightness: Bool = true
    var isReachable: Bool = true

    static func makeID(source: LightSource, remoteID: String) -> String { "\(source.rawValue):\(remoteID)" }

    static func parse(id: String) -> (source: LightSource, remoteID: String)? {
        guard let sep = id.firstIndex(of: ":"), let source = LightSource(rawValue: String(id[..<sep])) else { return nil }
        return (source, String(id[id.index(after: sep)...]))
    }

    var percent: Int { Int((brightness * 100).rounded()) }
}

/// Aggregate lighting state of one room, used by the 3D house.
struct RoomGlow: Equatable {
    var name: String
    var total: Int
    var onCount: Int
    /// 0...1 — how brightly the room should glow.
    var level: Double
}
