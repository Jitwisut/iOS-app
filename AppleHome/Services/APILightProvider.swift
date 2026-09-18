import Foundation
import Security
import CocoaMQTT

/// Talks to a user-supplied light server in one of three shapes:
///
/// - `.restServer`: many lights (see API.md at the repo root)
/// - `.simpleSwitch`: one device with fixed on/off endpoints, e.g. an ESP32 relay:
///   `POST {base}/api/on`, `POST {base}/api/off`, `GET {base}/api/status` -> `{"on": true}`,
///   authenticated with a custom header such as `X-API-Key`.
/// - `.mqttSwitch`: one device switched by publishing "ON"/"OFF" to an MQTT broker
///   (e.g. HiveMQ Cloud over TLS) instead of calling HTTP endpoints. See the MQTT
///   section below.
///
/// REST contract:
///
///     GET   {base}/lights          -> [LightDTO]  or  { "lights": [LightDTO] }
///     PATCH {base}/lights/{id}     body { "on": Bool?, "brightness": 0-100? } -> LightDTO
///
/// Optional `Authorization: Bearer <token>` header.
final class APILightProvider: NSObject, LightProvider {
    let source = LightSource.api
    var configuration: APIConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            // A live MQTT session is only worth keeping if it still points at the same
            // broker/account; anything else (including leaving MQTT mode) tears it down
            // so the next call reconnects with the current settings.
            if configuration.mode != .mqttSwitch || mqttIdentity(configuration) != mqttIdentity(oldValue) {
                disconnectMQTT()
            }
        }
    }
    private let session: URLSession

    init(configuration: APIConfiguration) {
        self.configuration = configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        super.init()
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

    /// The single light id used in simple-switch and MQTT-switch mode.
    static let switchID = "device"

    var directTargets: [String] {
        [.simpleSwitch, .mqttSwitch].contains(configuration.mode) ? [Self.switchID] : []
    }

    func loadLights() async throws -> [Light] {
        switch configuration.mode {
        case .simpleSwitch: return [try await loadSwitch()]
        case .mqttSwitch: return [try await loadMQTTSwitch()]
        case .restServer: break
        }
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

    // MARK: - MQTT

    /// One MQTT client per provider instance, reused across calls while it stays connected.
    /// State/availability are retained broker messages, so `directTargets` lets an arrival
    /// publish the command straight away instead of waiting on a status readback first.
    private let mqttClientID = "AppleHome-\(UUID().uuidString.prefix(8))"
    private var mqttClient: CocoaMQTT?
    private var mqttHasSubscribed = false
    private var mqttLastOnState: Bool?
    private let mqttLock = NSLock()
    private var mqttConnectWaiters: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var mqttPublishWaiters: [UInt16: (Result<Void, Error>) -> Void] = [:]
    private var mqttStateWaiters: [UUID: (Bool?) -> Void] = [:]

    /// What identifies "the same broker session" across a settings edit. The password
    /// lives in the keychain, not here, so a password-only change is handled by
    /// `testConnection()` forcing a fresh connection instead.
    private func mqttIdentity(_ c: APIConfiguration) -> String {
        "\(c.mqttHost)|\(c.mqttPort)|\(c.mqttUsername)"
    }

    private func loadMQTTSwitch() async throws -> Light {
        let isOn = try await mqttCurrentState()
        return Light(
            remoteID: Self.switchID,
            source: .api,
            name: configuration.deviceName.isEmpty ? String(localized: "Light") : configuration.deviceName,
            room: configuration.deviceRoom.isEmpty ? String(localized: "Home") : configuration.deviceRoom,
            kind: .bulb,
            isOn: isOn,
            brightness: 1,
            supportsBrightness: false
        )
    }

    /// A CocoaMQTT client can go on reporting `.connected` for a socket the OS has actually
    /// already torn down — iOS suspends the connection while the app is backgrounded, with no
    /// callback telling the client it happened, so `mqttEnsureConnected()`'s "already
    /// connected" shortcut can wave through a dead session. That surfaced as "can't connect"
    /// errors that only cleared on a full force-quit, since nothing here ever discarded the
    /// stale client. One retry through a hard `disconnectMQTT()` — a fresh client, fresh
    /// socket — self-heals it instead, the same way `sendRetrying` does for the HTTP path.
    private func mqttSetPower(_ isOn: Bool) async throws {
        do {
            try await mqttSetPowerOnce(isOn)
        } catch {
            disconnectMQTT()
            try await mqttSetPowerOnce(isOn)
        }
    }

    private func mqttSetPowerOnce(_ isOn: Bool) async throws {
        try await mqttEnsureConnected()
        let topic = configuration.commandTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { throw APIError.notConfigured }
        guard let client = mqttClient else { throw APIError.network("MQTT client isn't connected.") }

        let id = client.publish(topic, withString: isOn ? "ON" : "OFF", qos: .qos1, retained: false)
        guard id >= 0 else { throw APIError.network("The MQTT publish queue is full.") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            registerMQTTPublishWaiter(id: UInt16(id), timeout: 8) { cont.resume(with: $0) }
        }
    }

    /// See the retry note on `mqttSetPower` above — same stale-connection failure mode.
    private func mqttCurrentState(timeout: TimeInterval = 6) async throws -> Bool {
        do {
            return try await mqttCurrentStateOnce(timeout: timeout)
        } catch {
            disconnectMQTT()
            return try await mqttCurrentStateOnce(timeout: timeout)
        }
    }

    private func mqttCurrentStateOnce(timeout: TimeInterval) async throws -> Bool {
        try await mqttEnsureConnected()
        mqttSubscribeIfNeeded()

        mqttLock.lock()
        let cached = mqttLastOnState
        mqttLock.unlock()
        if let cached { return cached }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            let waiterID = UUID()
            var resumed = false
            let resume: (Bool?) -> Void = { value in
                guard !resumed else { return }
                resumed = true
                if let value { cont.resume(returning: value) }
                else { cont.resume(throwing: APIError.network("No response from the device")) }
            }
            mqttLock.lock()
            mqttStateWaiters[waiterID] = resume
            mqttLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.mqttLock.lock()
                self?.mqttStateWaiters.removeValue(forKey: waiterID)
                self?.mqttLock.unlock()
                resume(nil)
            }
        }
    }

    /// Subscribes once per live connection; retained messages arrive right after SUBACK.
    private func mqttSubscribeIfNeeded() {
        mqttLock.lock()
        defer { mqttLock.unlock() }
        guard !mqttHasSubscribed, let client = mqttClient else { return }
        var topics: [(String, CocoaMQTTQoS)] = []
        let state = configuration.stateTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let availability = configuration.availabilityTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !state.isEmpty { topics.append((state, .qos1)) }
        if !availability.isEmpty { topics.append((availability, .qos1)) }
        guard !topics.isEmpty else { return }
        mqttHasSubscribed = true
        client.subscribe(topics)
    }

    private func registerMQTTPublishWaiter(id: UInt16, timeout: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        mqttLock.lock()
        var resumed = false
        mqttPublishWaiters[id] = { result in
            guard !resumed else { return }
            resumed = true
            completion(result)
        }
        mqttLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.mqttLock.lock()
            let waiter = self.mqttPublishWaiters.removeValue(forKey: id)
            self.mqttLock.unlock()
            waiter?(.failure(APIError.network("The MQTT publish timed out.")))
        }
    }

    /// Reuses a connected client, waits out one already connecting, or opens a new one —
    /// then blocks until CONNACK (or a timeout) so callers never publish on a dead socket.
    private func mqttEnsureConnected() async throws {
        guard configuration.mode == .mqttSwitch else { throw APIError.notConfigured }
        let host = configuration.mqttHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw APIError.notConfigured }

        if let client = mqttClient, client.connState == .connected { return }

        mqttLock.lock()
        let shouldConnect: Bool
        let client: CocoaMQTT
        if let existing = mqttClient, existing.connState == .connecting {
            client = existing
            shouldConnect = false
        } else {
            client = makeMQTTClient(host: host)
            mqttClient = client
            mqttHasSubscribed = false
            mqttLastOnState = nil
            shouldConnect = true
        }
        mqttLock.unlock()

        if shouldConnect {
            guard client.connect(timeout: 8) else { throw APIError.network("Couldn't start the MQTT connection.") }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let waiterID = UUID()
            var resumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            mqttLock.lock()
            mqttConnectWaiters[waiterID] = resume
            mqttLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                self.mqttLock.lock()
                let stillPending = self.mqttConnectWaiters.removeValue(forKey: waiterID) != nil
                self.mqttLock.unlock()
                if stillPending { resume(.failure(APIError.network("The MQTT connection timed out."))) }
            }
        }
    }

    private func makeMQTTClient(host: String) -> CocoaMQTT {
        let client = CocoaMQTT(clientID: mqttClientID, host: host, port: UInt16(clamping: configuration.mqttPort))
        client.username = configuration.mqttUsername.isEmpty ? nil : configuration.mqttUsername
        client.password = Keychain.mqttPassword
        client.enableSSL = true
        client.cleanSession = true
        client.keepAlive = 30
        client.autoReconnect = false
        client.delegate = self
        return client
    }

    /// Called when the app backgrounds. iOS can suspend the MQTT socket without ever telling
    /// CocoaMQTT it happened, so the safest thing on the way out is to drop it ourselves —
    /// the next call reconnects from scratch (the same path a cold launch already takes)
    /// instead of risking a resume that finds a connection which merely *looks* alive.
    func handleAppBackgrounded() {
        guard configuration.mode == .mqttSwitch else { return }
        disconnectMQTT()
    }

    private func disconnectMQTT() {
        mqttLock.lock()
        let client = mqttClient
        mqttClient = nil
        mqttHasSubscribed = false
        mqttLastOnState = nil
        let connectWaiters = mqttConnectWaiters; mqttConnectWaiters = [:]
        let publishWaiters = mqttPublishWaiters; mqttPublishWaiters = [:]
        mqttLock.unlock()
        client?.disconnect()
        let error = APIError.network("MQTT disconnected")
        connectWaiters.values.forEach { $0(.failure(error)) }
        publishWaiters.values.forEach { $0(.failure(error)) }
    }

    /// "ON"/"1"/"TRUE" and "OFF"/"0"/"FALSE", case-insensitively — matches the ESP firmware.
    static func parseMQTTBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "ON", "1", "TRUE": return true
        case "OFF", "0", "FALSE": return false
        default: return nil
        }
    }

    func setPower(_ isOn: Bool, remoteID: String) async throws {
        switch configuration.mode {
        case .simpleSwitch:
            _ = try await sendRetrying(isOn ? configuration.onPath : configuration.offPath, method: "POST")
        case .mqttSwitch:
            try await mqttSetPower(isOn)
        case .restServer:
            _ = try await send("lights/\(escaped(remoteID))", method: "PATCH", body: ["on": isOn])
        }
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
        // A fresh connection so a just-edited host/username/password is what gets tried,
        // even though only a keychain write (not `configuration`) changed for the password.
        if configuration.mode == .mqttSwitch { disconnectMQTT() }
        return try await loadLights().count
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
            case .mqttSwitch:
                break // MQTT never goes through this HTTP path.
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

extension APILightProvider: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        mqttLock.lock()
        let waiters = mqttConnectWaiters; mqttConnectWaiters = [:]
        mqttLock.unlock()
        let result: Result<Void, Error> = ack == .accept
            ? .success(())
            : .failure(APIError.network("MQTT: \(ack.description)"))
        waiters.values.forEach { $0(result) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}

    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        mqttLock.lock()
        let waiter = mqttPublishWaiters.removeValue(forKey: id)
        mqttLock.unlock()
        waiter?(.success(()))
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        guard message.topic == configuration.stateTopic,
              let isOn = Self.parseMQTTBool(message.string ?? "") else { return }
        mqttLock.lock()
        mqttLastOnState = isOn
        let waiters = mqttStateWaiters; mqttStateWaiters = [:]
        mqttLock.unlock()
        waiters.values.forEach { $0(isOn) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        mqttLock.lock()
        guard mqtt === mqttClient else { mqttLock.unlock(); return }
        mqttClient = nil
        mqttHasSubscribed = false
        let connectWaiters = mqttConnectWaiters; mqttConnectWaiters = [:]
        let publishWaiters = mqttPublishWaiters; mqttPublishWaiters = [:]
        mqttLock.unlock()
        let error = APIError.network(err?.localizedDescription ?? "MQTT disconnected")
        connectWaiters.values.forEach { $0(.failure(error)) }
        publishWaiters.values.forEach { $0(.failure(error)) }
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

/// Minimal Keychain wrapper for the API token and MQTT password.
enum Keychain {
    private static let service = "Jitwisut.AppleHome"
    private static let tokenAccount = "api-token"
    private static let mqttPasswordAccount = "mqtt-password"

    static var apiToken: String? {
        get { read(tokenAccount) }
        set { write(newValue, account: tokenAccount) }
    }

    static var mqttPassword: String? {
        get { read(mqttPasswordAccount) }
        set { write(newValue, account: mqttPasswordAccount) }
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
