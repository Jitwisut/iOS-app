import Foundation
import Security

/// Talks to a user-supplied light server in one of two shapes:
///
/// - `.restServer`: many lights (see API.md at the repo root)
/// - `.simpleSwitch`: one device with fixed on/off endpoints, e.g. an ESP32 relay:
///   `POST {base}/api/on`, `POST {base}/api/off`, `GET {base}/api/status` -> `{"on": true}`,
///   authenticated with a custom header such as `X-API-Key`.
///
/// REST contract:
///
///     GET   {base}/lights          -> [LightDTO]  or  { "lights": [LightDTO] }
///     PATCH {base}/lights/{id}     body { "on": Bool?, "brightness": 0-100? } -> LightDTO
///
/// Optional `Authorization: Bearer <token>` header.
final class APILightProvider: LightProvider {
    let source = LightSource.api
    var configuration: APIConfiguration
    private let session: URLSession

    init(configuration: APIConfiguration) {
        self.configuration = configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    struct LightDTO: Codable {
        var id: String
        var name: String
        var room: String?
        var on: Bool
        var brightness: Int?
        var type: String?
    }

    private struct Envelope: Codable { var lights: [LightDTO] }

    /// The single light id used in simple-switch mode.
    static let switchID = "device"

    func loadLights() async throws -> [Light] {
        guard configuration.mode == .restServer else { return [try await loadSwitch()] }
        let data = try await send("lights", method: "GET")
        let decoder = JSONDecoder()
        let dtos: [LightDTO]
        if let list = try? decoder.decode([LightDTO].self, from: data) {
            dtos = list
        } else if let env = try? decoder.decode(Envelope.self, from: data) {
            dtos = env.lights
        } else {
            throw APIError.decoding
        }
        return dtos.map { dto in
            Light(
                remoteID: dto.id,
                source: .api,
                name: dto.name,
                room: dto.room ?? String(localized: "Other"),
                kind: dto.type.flatMap(LightKind.init(rawValue:)) ?? LightKind.guess(from: dto.name),
                isOn: dto.on,
                brightness: Double(dto.brightness ?? (dto.on ? 100 : 0)) / 100,
                supportsBrightness: dto.brightness != nil
            )
        }
    }

    private func loadSwitch() async throws -> Light {
        let data = try await sendRetrying(configuration.statusPath, method: "GET")
        guard let isOn = Self.parseOnState(data) else { throw APIError.decoding }
        return Light(
            remoteID: Self.switchID,
            source: .api,
            name: configuration.deviceName.isEmpty ? String(localized: "Light") : configuration.deviceName,
            room: configuration.deviceRoom.isEmpty ? String(localized: "Home") : configuration.deviceRoom,
            kind: .bulb,
            isOn: isOn,
            // No dimming on this device: full brightness keeps the card, bar and 3D glow honest.
            brightness: 1,
            supportsBrightness: false
        )
    }

    func setPower(_ isOn: Bool, remoteID: String) async throws {
        guard configuration.mode == .restServer else {
            _ = try await sendRetrying(isOn ? configuration.onPath : configuration.offPath, method: "POST")
            return
        }
        _ = try await send("lights/\(escaped(remoteID))", method: "PATCH", body: ["on": isOn])
    }

    func setBrightness(_ value: Double, remoteID: String) async throws {
        guard configuration.mode == .restServer else {
            try await setPower(value > 0, remoteID: remoteID)
            return
        }
        let percent = Int((value * 100).rounded())
        _ = try await send("lights/\(escaped(remoteID))", method: "PATCH", body: ["on": percent > 0, "brightness": percent])
    }

    /// `{"on": true}`, and the common variants, without ever guessing a state.
    static func parseOnState(_ data: Data) -> Bool? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["on", "state", "power", "status"] {
            switch object[key] {
            case let value as Bool: return value
            case let value as NSNumber: return value.boolValue
            case let value as String: return ["on", "true", "1"].contains(value.lowercased())
            default: continue
            }
        }
        return nil
    }

    /// The ESP often drops the first connection after idling, and a background arrival
    /// only gets one chance, so retry a network failure once.
    private func sendRetrying(_ path: String, method: String) async throws -> Data {
        do {
            return try await send(path, method: method)
        } catch APIError.network {
            try? await Task.sleep(for: .seconds(1))
            return try await send(path, method: method)
        }
    }

    /// Used by the settings screen: returns how many lights the server reports.
    func testConnection() async throws -> Int {
        try await loadLights().count
    }

    private func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    private func send(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var base = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw APIError.notConfigured }
        while base.hasSuffix("/") { base.removeLast() }
        // A double slash is a 404 on small embedded servers, not a redirect.
        let route = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: route.isEmpty ? base : "\(base)/\(route)"),
              url.scheme?.hasPrefix("http") == true else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = Keychain.apiToken, !token.isEmpty {
            switch configuration.mode {
            case .restServer:
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .simpleSwitch:
                let header = configuration.keyHeader.isEmpty ? "X-API-Key" : configuration.keyHeader
                request.setValue(token, forHTTPHeaderField: header)
            }
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.network("") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw APIError.unauthorized
        default: throw APIError.http(http.statusCode)
        }
    }
}

enum APIError: LocalizedError {
    case notConfigured, invalidURL, unauthorized, decoding
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "Add your server URL in Settings first.")
        case .invalidURL: String(localized: "The server URL isn't valid. It should start with http:// or https://")
        case .unauthorized: String(localized: "The server rejected the token.")
        case .decoding: String(localized: "The server replied in an unexpected format.")
        case .http(let code): String(localized: "The server returned error \(code).")
        case .network(let message): String(localized: "Can't reach the server. \(message)")
        }
    }
}

/// Minimal Keychain wrapper for the API token.
enum Keychain {
    private static let service = "Jitwisut.AppleHome"
    private static let tokenAccount = "api-token"

    static var apiToken: String? {
        get { read(tokenAccount) }
        set { write(newValue, account: tokenAccount) }
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Readable after first unlock so background arrival events can still call the API.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
