import SwiftUI
import Observation
import HomeKit
import os

enum AppTab: Hashable {
    case home, arrival, settings
}

/// Composition root. Created once in the App struct, which also runs on background
/// relaunches, so the geofence starts listening before any view exists.
@Observable
final class AppModel {
    private static let key = "settings.v1"

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            Persisted.save(settings, key: Self.key)
            apply(previous: oldValue)
        }
    }
    var selectedTab: AppTab = .home

    let log = ActivityLog()
    let location = LocationService()
    let homeKit = HomeKitManager()
    let api: APILightProvider
    let store: HomeStore
    let arrival: ArrivalController

    init() {
        let settings = Persisted.load(AppSettings.self, key: Self.key) ?? AppSettings()
        self.settings = settings
        api = APILightProvider(configuration: settings.api)
        store = HomeStore(providers: [DemoLightProvider(), api, homeKit], enabledSources: Self.sources(for: settings))
        arrival = ArrivalController(location: location, store: store, homeKit: homeKit, log: log)

        homeKit.selectedHomeID = settings.homeKitHomeID
        homeKit.onChange = { [weak self] in
            guard let self else { return }
            Task {
                await self.store.refresh()
                await self.arrival.syncHomeKit()
            }
        }
        if settings.homeKitEnabled { homeKit.activate() }

        #if DEBUG
        // Testing helpers, never compiled into a release build. JSON is passed base64-encoded
        // because UserDefaults silently drops launch arguments that start with "{".
        //   -seedAPIKey <key>            writes the keychain, which `defaults` can't reach
        //   -seedSettings <base64 json>  replaces the stored app settings
        //   -seedArrival  <base64 json>  replaces the stored arrival settings
        func seededJSON(_ key: String) -> Data? {
            guard let encoded = UserDefaults.standard.string(forKey: key) else { return nil }
            return Data(base64Encoded: encoded)
        }
        if let seeded = UserDefaults.standard.string(forKey: "seedAPIKey"), !seeded.isEmpty {
            Keychain.apiToken = seeded
        }
        if let data = seededJSON("seedSettings"), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        }
        if let data = seededJSON("seedArrival"), let decoded = try? JSONDecoder().decode(ArrivalSettings.self, from: data) {
            arrival.settings = decoded
        }
        geofenceLog.info("settings loaded: demo=\(self.settings.demoEnabled), api=\(self.settings.api.isEnabled), mode=\(self.settings.api.mode.rawValue, privacy: .public), base=\(self.settings.api.baseURL, privacy: .public)")
        #endif

        Task {
            await arrival.start()
            await store.refresh()
        }
    }

    var homeName: String {
        if !settings.homeName.isEmpty { return settings.homeName }
        if settings.homeKitEnabled, let name = homeKit.home?.name { return name }
        return String(localized: "My Home")
    }

    private static func sources(for settings: AppSettings) -> Set<LightSource> {
        var result = Set<LightSource>()
        if settings.demoEnabled { result.insert(.demo) }
        if settings.api.isEnabled { result.insert(.api) }
        if settings.homeKitEnabled { result.insert(.homeKit) }
        return result
    }

    private func apply(previous: AppSettings) {
        api.configuration = settings.api
        homeKit.selectedHomeID = settings.homeKitHomeID
        store.enabledSources = Self.sources(for: settings)

        if settings.homeKitEnabled != previous.homeKitEnabled {
            settings.homeKitEnabled ? homeKit.activate() : homeKit.deactivate()
        }
        let lightsChanged = Self.sources(for: settings) != Self.sources(for: previous)
            || settings.api != previous.api
            || settings.homeKitHomeID != previous.homeKitHomeID
        if lightsChanged {
            Task {
                await store.refresh()
                if settings.homeKitHomeID != previous.homeKitHomeID { await arrival.syncHomeKit() }
            }
        }
    }
}
