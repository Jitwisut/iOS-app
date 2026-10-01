import SwiftUI
import CoreLocation
import Observation
import UserNotifications
import os

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
    private let network: NetworkMonitor
    private var syncTask: Task<Void, Never>?
    /// Set by AppModel; looks up the current name for a saved shortcut id, since arrival
    /// settings only store the id (the name can change without breaking the reference).
    var resolveShortcut: ((UUID) -> ShortcutItem?)?
    /// Ignore GPS jitter around the edge of the zone. Persisted, because background
    /// arrivals usually run in a freshly relaunched process.
    private let cooldown: TimeInterval = 180
    private static let lastRunKey = "arrival.lastRun"

    /// A light action that didn't get through (typically: no internet at the moment it ran),
    /// kept so it can be retried once things work again. Persisted, because the retry usually
    /// happens in a later process — the next launch, return to the foreground, or location
    /// wake-up — rather than the one that failed.
    private struct PendingAutomation: Codable {
        var transition: ZoneTransition.RawValue
        var date: Date
    }
    private static let pendingKey = "arrival.pending"
    /// Past this, switching the lights would be a surprise rather than the thing you wanted.
    private static let pendingLifetime: TimeInterval = 60 * 60
    /// How long a failed background run keeps the app awake waiting for the network, which
    /// covers the common "forgot to turn data on, turned it on right away" case.
    private static let reconnectGrace: Duration = .seconds(25)
    @MainActor private var isRetrying = false

    init(location: LocationService, store: HomeStore, homeKit: HomeKitManager, log: ActivityLog, network: NetworkMonitor) {
        self.location = location
        self.store = store
        self.homeKit = homeKit
        self.log = log
        self.network = network
        settings = Persisted.load(ArrivalSettings.self, key: Self.key) ?? ArrivalSettings()
        location.onTransition = { [weak self] transition in
            Task { await self?.handle(transition) }
        }
        network.onReconnect = { [weak self] in
            Task { await self?.retryPending() }
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
        geofenceLog.info("applyZone enabled=\(self.settings.isEnabled) hasHome=\(self.settings.home != nil) r=\(self.settings.radius)")
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
        let runKey = "\(Self.lastRunKey).\(transition.rawValue)"
        if !isTest, let last = UserDefaults.standard.object(forKey: runKey) as? Date,
           Date().timeIntervalSince(last) < cooldown { return }
        // A newer arrival/departure supersedes anything still waiting to be retried.
        if !isTest { Self.clearPending() }

        // A background relaunch only gets a few seconds; ask for a little more.
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "arrival")
        defer { UIApplication.shared.endBackgroundTask(taskID) }

        switch transition {
        case .entered:
            if settings.onlyAfterDark, let home = settings.home, !Sun.isDark(coordinate: home) {
                if !isTest { Self.markRan(transition) }
                log.add(.skipped, String(localized: "Arrived home during daylight. Lights left as they were."))
                return
            }
            let result = await store.runAutomation(isOn: true, lightIDs: settings.lightIDs, includeHomeKit: isTest)
            report(result, turningOn: true, isTest: isTest)
            await runShortcuts()
            if !isTest { await afterRun(result, transition: transition) }

        case .exited:
            guard settings.onLeave == .turnOff else { return }
            let result = await store.runAutomation(isOn: false, lightIDs: settings.lightIDs, includeHomeKit: isTest)
            report(result, turningOn: false, isTest: isTest)
            if !isTest { await afterRun(result, transition: transition) }
        }
    }

    // MARK: Retry after a failure

    /// Something didn't switch, or nothing could be reached at all.
    private static func needsRetry(_ result: AutomationResult) -> Bool {
        result.failed > 0 || (result.done == 0 && result.leftToHomeKit == 0)
    }

    /// Starts the jitter cooldown — but only once the lights really switched. A failed attempt
    /// changed nothing, so it mustn't block the next one: GPS bouncing in → out → in at the
    /// zone's edge while offline would otherwise leave you home with the lights still off.
    private static func markRan(_ transition: ZoneTransition) {
        UserDefaults.standard.set(Date(), forKey: "\(lastRunKey).\(transition.rawValue)")
    }

    private func afterRun(_ result: AutomationResult, transition: ZoneTransition) async {
        if Self.needsRetry(result) {
            await keepForRetry(transition)
        } else {
            Self.markRan(transition)
        }
    }

    private static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    private func keepForRetry(_ transition: ZoneTransition) async {
        Persisted.save(PendingAutomation(transition: transition.rawValue, date: .now), key: Self.pendingKey)
        geofenceLog.info("kept \(transition.rawValue, privacy: .public) for retry, online=\(String(describing: self.network.isOnline), privacy: .public)")
        // Still inside handle()'s background task: if we're offline, hold on briefly in case
        // the connection comes straight back. A suspended app can't hear about it later.
        guard network.isOnline == false else { return }
        if await network.waitUntilOnline(timeout: Self.reconnectGrace) {
            await retryPending()
        }
    }

    /// Re-runs a light action that failed earlier, if it's still wanted: not too old, the
    /// feature still on, and you're still on the same side of the zone — retrying "arrived"
    /// after you've already left again would be exactly wrong.
    @MainActor
    func retryPending() async {
        guard !isRetrying,
              let pending = Persisted.load(PendingAutomation.self, key: Self.pendingKey) else { return }
        guard Date().timeIntervalSince(pending.date) < Self.pendingLifetime,
              settings.isEnabled,
              let transition = ZoneTransition(rawValue: pending.transition) else {
            Self.clearPending()
            return
        }
        let turningOn = transition == .entered
        let stillApplies = turningOn
            ? location.isInsideZone == true
            : location.isInsideZone == false && settings.onLeave == .turnOff
        guard stillApplies else {
            geofenceLog.info("dropping pending \(pending.transition, privacy: .public): no longer applies")
            Self.clearPending()
            return
        }
        // Known offline: keep it for the reconnect callback instead of burning a timeout.
        guard network.isOnline != false else { return }

        isRetrying = true
        defer { isRetrying = false }
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "arrival-retry")
        defer { UIApplication.shared.endBackgroundTask(taskID) }

        geofenceLog.info("retrying pending \(pending.transition, privacy: .public)")
        let result = await store.runAutomation(isOn: turningOn, lightIDs: settings.lightIDs, includeHomeKit: false)
        guard !Self.needsRetry(result) else {
            geofenceLog.info("retry still failing: \(result.done) done, \(result.failed) failed")
            return
        }
        Self.clearPending()
        Self.markRan(transition)
        let message = turningOn
            ? String(localized: "Retried: turned on \(result.done) lights")
            : String(localized: "Retried: turned off \(result.done) lights")
        geofenceLog.info("retry succeeded: \(result.done) done")
        log.add(turningOn ? .arrived : .left, message)
        guard settings.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = turningOn ? String(localized: "Welcome home") : String(localized: "You left home")
        content.body = message
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func report(_ result: AutomationResult, turningOn: Bool, isTest: Bool) {
        geofenceLog.info("automation on=\(turningOn): \(result.done) done, \(result.failed) failed, \(result.leftToHomeKit) via Apple Home")
        var kind: ActivityEntry.Kind = isTest ? .test : (turningOn ? .arrived : .left)
        var title = turningOn ? String(localized: "Welcome home") : String(localized: "You left home")
        var message: String
        var shouldNotify = settings.notify && !isTest

        if result.done == 0 && result.failed == 0 {
            if result.leftToHomeKit > 0 {
                // Nothing for the app to do; the hub runs the Apple Home automation.
                message = String(localized: "Apple Home is switching \(result.leftToHomeKit) lights")
                shouldNotify = false
            } else {
                kind = .error
                title = String(localized: "Lights didn't respond")
                message = String(localized: "No lights could be reached. Check your light server.")
            }
        } else {
            message = turningOn
                ? String(localized: "Turned on \(result.done) lights")
                : String(localized: "Turned off \(result.done) lights")
            if result.failed > 0 {
                kind = .error
                message = String(localized: "\(message), \(result.failed) failed")
            }
        }

        if !isTest, Self.needsRetry(result) {
            if network.isOnline == false {
                title = String(localized: "No internet")
                message = String(localized: "Lights will switch once you're back online. Open AppleHome to retry now.")
            } else {
                message = String(localized: "\(message) Will retry automatically.")
            }
        }

        log.add(kind, message)
        guard shouldNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Best-effort: `UIApplication.open` only succeeds while AppleHome is the foreground
    /// app, so a background arrival often can't hand off to Shortcuts at all. A successful
    /// hand-off is logged only once Shortcuts calls back (see AppModel.handleShortcutCallback);
    /// here we only log the cases where the hand-off itself never happened.
    private func runShortcuts() async {
        guard !settings.arrivalShortcutIDs.isEmpty else { return }
        for id in settings.arrivalShortcutIDs {
            guard let item = resolveShortcut?(id), let url = ShortcutsService.runURL(named: item.name) else { continue }
            let opened = await UIApplication.shared.open(url)
            if !opened {
                geofenceLog.error("shortcut '\(item.name, privacy: .public)': couldn't open (app likely backgrounded)")
                log.add(.error, String(localized: "Couldn't start “\(item.name)”"))
            }
        }
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
