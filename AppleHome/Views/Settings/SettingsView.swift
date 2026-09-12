import SwiftUI
import HomeKit

private enum SettingsRoute: Hashable { case api, homeKit, activity }

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var path: [SettingsRoute] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField(text: $model.settings.homeName, prompt: Text(model.homeName)) {
                        Text("Home name")
                    }
                    .foregroundStyle(.white)
                } header: {
                    Text("Home")
                }

                Section {
                    Toggle(isOn: $model.settings.demoEnabled) {
                        SettingsRow(symbol: "sparkles", color: Theme.mint, title: Text("Demo lights"),
                                    detail: Text("Try the app without hardware"))
                    }
                    .tint(Theme.amber)

                    NavigationLink(value: SettingsRoute.api) {
                        SettingsRow(symbol: "network", color: Theme.cyan, title: Text("Light server (API)"),
                                    detail: Text(model.settings.api.isEnabled
                                                 ? (model.settings.api.mode == .simpleSwitch ? "On · one device" : "On")
                                                 : "Off"))
                    }

                    NavigationLink(value: SettingsRoute.homeKit) {
                        SettingsRow(symbol: "homekit", color: Theme.amber, title: Text("Apple Home"),
                                    detail: Text(model.settings.homeKitEnabled ? "On" : "Off"))
                    }
                } header: {
                    Text("Connections")
                }

                Section {
                    NavigationLink(value: SettingsRoute.activity) {
                        SettingsRow(symbol: "clock.arrow.circlepath", color: Theme.cyan, title: Text("Activity"),
                                    detail: Text("\(model.log.entries.count) events"))
                    }
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        SettingsRow(symbol: "globe", color: Theme.mint, title: Text("Language"),
                                    detail: Text("Thai or English"))
                    }
                } footer: {
                    Text("AppleHome follows your iPhone language. To choose Thai or English just for this app, open Settings › AppleHome › Language.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle(Text("Settings"))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .api: APISettingsView()
                case .homeKit: HomeKitSettingsView()
                case .activity: ActivityLogView()
                }
            }
        }
        #if DEBUG
        .onAppear {
            // Screenshot helper: `-openSettings api` launch argument.
            switch UserDefaults.standard.string(forKey: "openSettings") {
            case "api": path = [.api]
            case "homeKit": path = [.homeKit]
            case "activity": path = [.activity]
            default: break
            }
        }
        #endif
    }
}

struct SettingsRow: View {
    let symbol: String
    let color: Color
    let title: Text
    var detail: Text?

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                title.foregroundStyle(.white)
                detail?.font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - API

struct APISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var baseURL = ""
    @State private var token = ""
    @State private var testing = false
    @State private var testResult: Result<Int, Error>?

    var body: some View {
        @Bindable var model = model
        let isSimple = model.settings.api.mode == .simpleSwitch
        Form {
            Section {
                Toggle("Use light server", isOn: $model.settings.api.isEnabled)
                    .tint(Theme.amber)
                Picker("Kind", selection: $model.settings.api.mode) {
                    Text("One on/off device").tag(APIMode.simpleSwitch)
                    Text("Server with many lights").tag(APIMode.restServer)
                }
            } footer: {
                Text(isSimple
                     ? "For a single device with fixed on/off endpoints, such as an ESP32 relay on your Wi-Fi."
                     : "For a server that lists several lights and supports brightness. See API.md in the project.")
            }

            Section {
                TextField(text: $baseURL, prompt: Text(verbatim: isSimple ? "http://192.168.1.46" : "https://home.example.com/api")) {
                    Text("Address")
                }
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)

                SecureField(text: $token, prompt: Text(isSimple ? "API key" : "Bearer token (optional)")) {
                    Text(isSimple ? "API key" : "Token")
                }
                .textInputAutocapitalization(.never)
                .onSubmit(save)
            } header: {
                Text("Server")
            } footer: {
                if isSimple {
                    Text("The key is sent in the \(model.settings.api.keyHeader) header, and is stored in the iPhone keychain.")
                }
            }

            if isSimple {
                Section {
                    TextField(text: $model.settings.api.deviceName, prompt: Text("Light")) {
                        Text("Light name")
                    }
                    TextField(text: $model.settings.api.deviceRoom, prompt: Text("Home")) {
                        Text("Room")
                    }
                } header: {
                    Text("Shown in the app")
                }

                Section {
                    LabeledContent("Header") {
                        TextField(text: $model.settings.api.keyHeader, prompt: Text(verbatim: "X-API-Key")) { Text("Header") }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Turn on") {
                        TextField(text: $model.settings.api.onPath, prompt: Text(verbatim: "api/on")) { Text("On path") }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Turn off") {
                        TextField(text: $model.settings.api.offPath, prompt: Text(verbatim: "api/off")) { Text("Off path") }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Status") {
                        TextField(text: $model.settings.api.statusPath, prompt: Text(verbatim: "api/status")) { Text("Status path") }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Endpoints")
                } footer: {
                    Text("POST for on and off, GET for status, which should reply { \"on\": true }.")
                }
            }

            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || baseURL.isEmpty)

                if let testResult {
                    switch testResult {
                    case .success(let count):
                        Label {
                            Text(isSimple ? String(localized: "Connected to the device") : String(localized: "Connected · found \(count) lights"))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                        }
                    case .failure(let error):
                        Label {
                            Text(error.localizedDescription)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                        }
                    }
                }
            } footer: {
                Text("On a home Wi-Fi address, iOS asks for local network permission the first time.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground(glow: 0.15, accent: Theme.cyan))
        .navigationTitle(Text("Light server"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            baseURL = model.settings.api.baseURL
            token = Keychain.apiToken ?? ""
        }
        .onDisappear(perform: save)
    }

    private func save() {
        Keychain.apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.api.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func test() {
        save()
        testing = true
        testResult = nil
        Task {
            do {
                testResult = .success(try await model.api.testConnection())
            } catch {
                testResult = .failure(error)
            }
            testing = false
        }
    }
}

// MARK: - HomeKit

struct HomeKitSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let homeKit = model.homeKit
        Form {
            Section {
                Toggle("Use Apple Home", isOn: $model.settings.homeKitEnabled)
                    .tint(Theme.amber)
            } footer: {
                Text("Control the lights you've added to Apple's Home app. Arrival automations are saved into Apple Home and run by your home hub.")
            }

            if model.settings.homeKitEnabled {
                Section {
                    if !homeKit.isReady {
                        HStack { Text("Connecting…"); Spacer(); ProgressView() }
                    } else if homeKit.homes.isEmpty {
                        Text("No homes found. Create one in the Home app, then come back.")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Picker("Home", selection: Binding(
                            get: { homeKit.home?.uniqueIdentifier.uuidString ?? "" },
                            set: { model.settings.homeKitHomeID = $0 }
                        )) {
                            ForEach(homeKit.homes, id: \.uniqueIdentifier) { home in
                                Text(home.name).tag(home.uniqueIdentifier.uuidString)
                            }
                        }
                        LabeledContent("Lights") {
                            Text("\(model.store.lights.count(where: { $0.source == .homeKit }))")
                        }
                        LabeledContent("Home hub") {
                            Text(hubText).foregroundStyle(homeKit.hubState == .connected ? Theme.mint : Theme.amber)
                        }
                    }
                } header: {
                    Text("Status")
                } footer: {
                    if homeKit.isReady && homeKit.hubState != .connected {
                        Text("Without a home hub (Apple TV or HomePod), Apple Home can't run the arrival automation while you're away.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground(glow: 0.15))
        .navigationTitle(Text("Apple Home"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hubText: String {
        switch model.homeKit.hubState {
        case .connected: String(localized: "Connected")
        case .disconnected: String(localized: "Disconnected")
        default: String(localized: "Not found")
        }
    }
}

// MARK: - Activity

struct ActivityLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.log.entries.isEmpty {
                Text("Nothing yet. Arrivals, departures and tests will show up here.")
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(model.log.entries) { entry in
                ActivityRow(entry: entry)
                    .listRowInsets(EdgeInsets())
            }
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground(glow: 0.1, accent: Theme.cyan))
        .navigationTitle(Text("Activity"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.log.entries.isEmpty {
                Button("Clear", role: .destructive) { model.log.clear() }
            }
        }
    }
}
