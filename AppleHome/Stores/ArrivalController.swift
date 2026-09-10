import SwiftUI
import CoreLocation
import Observation
import UserNotifications

/// Turns geofence transitions into light actions, and keeps the zone (CLMonitor) and the
/// Apple Home automation in step with the user's arrival settings.
@Observable
final class ArrivalController {
    private static let key = "arrival.v1"

    var settings: ArrivalSettings {
        didSet {
            guard settings != oldValue else { return }
            Persisted.save(settings, key: Self.key)
            scheduleSync()
        }
    }

    let location: LocationService
    private let store: HomeStore
    private let homeKit: HomeKitManager
    private let log: ActivityLog
    private var syncTask: Task<Void, Never>?
    private var lastRun: [ZoneTransition: Date] = [:]
    /// Ignore GPS jitter around the edge of the zone.
    private let cooldown: TimeInterval = 180

    init(location: LocationService, store: HomeStore, homeKit: HomeKitManager, log: ActivityLog) {
        self.location = location
        self.store = store
        self.homeKit = homeKit
        self.log = log
        settings = Persisted.load(ArrivalSettings.self, key: Self.key) ?? ArrivalSettings()
        location.onTransition = { [weak self] transition in
            Task { await self?.handle(transition) }
        }
    }

    func start() async {
        await location.activateMonitor()
        await applyZone()
    }

    // MARK: Derived

    var distanceToHome: CLLocationDistance? {
        guard let home = settings.home, let here = location.location else { return nil }
        return here.distance(from: home.location)
    }

    var isHome: Bool? {
        if let distanceToHome { return distanceToHome <= settings.radius }
        return location.isInsideZone
    }

    var selectedLightCount: Int {
        settings.lightIDs.isEmpty ? store.lights.count : settings.lightIDs.count
    }

    // MARK: Sync

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await applyZone()
            await syncHomeKit()
        }
    }

    func syncHomeKit() async {
        guard homeKit.isActive, homeKit.home != nil else { return }
        await homeKit.syncArrivalAutomation(settings)
    }

    private func applyZone() async {
        if settings.isEnabled, let home = settings.home {
            await location.setZone(center: home, radius: settings.radius)
        } else {
            await location.clearZone()
        }
    }

    // MARK: Actions

    func runTest(_ transition: ZoneTransition) async {
        await handle(transition, isTest: true)
    }

    private func handle(_ transition: ZoneTransition, isTest: Bool = false) async {
        guard settings.isEnabled || isTest else { return }
        if !isTest, let last = lastRun[transition], Date().timeIntervalSince(last) < cooldown { return }
        lastRun[transition] = Date()

        // A background relaunch only gets a few seconds; ask for a little more.
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "arrival")
        defer { UIApplication.shared.endBackgroundTask(taskID) }

        switch transition {
        case .entered:
            if settings.onlyAfterDark, let home = settings.home, !Sun.isDark(coordinate: home) {
                log.add(.skipped, String(localized: "Arrived home during daylight. Lights left as they were."))
                return
            }
            let result = await store.runAutomation(isOn: true, lightIDs: settings.lightIDs, includeHomeKit: isTest)
            report(kind: isTest ? .test : .arrived, result: result,
                   title: String(localized: "Welcome home"),
                   message: String(localized: "Turned on \(result.done) lights"))

        case .exited:
            guard settings.onLeave == .turnOff else { return }
            let result = await store.runAutomation(isOn: false, lightIDs: settings.lightIDs, includeHomeKit: isTest)
            report(kind: isTest ? .test : .left, result: result,
                   title: String(localized: "You left home"),
                   message: String(localized: "Turned off \(result.done) lights"))
        }
    }

    private func report(kind: ActivityEntry.Kind, result: (done: Int, failed: Int), title: String, message: String) {
        if result.failed > 0 {
            log.add(.error, String(localized: "\(message), \(result.failed) failed"))
        } else {
            log.add(kind, message)
        }
        guard settings.notify, kind != .test else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
