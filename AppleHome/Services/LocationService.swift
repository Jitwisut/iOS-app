import Foundation
import CoreLocation
import Observation
import os

let geofenceLog = Logger(subsystem: "Jitwisut.AppleHome", category: "geofence")

enum ZoneTransition: String, Sendable {
    case entered, exited
}

/// Location permission, a foreground live position (for the distance readout), and the
/// background geofence. The CLMonitor event stream is started from the app model, not a
/// view, because iOS relaunches the app in the background — with no UI — to deliver it.
@Observable
final class LocationService: NSObject {
    private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus
    private(set) var location: CLLocation?

    private var monitor: CLMonitor?
    /// Since iOS 18, background monitor events only arrive while an Always session is held.
    private var backgroundSession: CLServiceSession?
    private var eventsTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private static let monitorName = "AppleHomeArrival"
    private static let conditionID = "home"
    private static let insideKey = "zone.lastInside"
    /// The old CLLocationManager.startMonitoring(for:) region API, run alongside CLMonitor.
    /// Apple documents *this specific API* as the one exception that keeps working after the
    /// user force-quits the app — CLMonitor is newer and that guarantee isn't documented for
    /// it, so this is defense in depth, not a replacement. Both report through the same
    /// `handle(state:)`, which already collapses duplicate transitions from either source.
    private static let classicRegionID = "AppleHomeArrivalClassic"
    /// The zone currently configured, kept so significant-location-change updates (below) can
    /// independently recompute inside/outside — a real GPS fix, not iOS's own confidence
    /// heuristic for a geofence boundary.
    private var currentZone: (center: Coordinate, radius: Double)?
    /// When a geofence (either monitor) last reported a state. A position fix taken before
    /// this can't overrule it — see didUpdateLocations.
    private var lastZoneEventDate: Date?
    private static let maxFixAge: TimeInterval = 30

    /// Only real transitions (outside → inside, inside → outside) are reported, never the
    /// first "you are already inside" determination after setting the zone up.
    var onTransition: ((ZoneTransition) -> Void)?

    /// Last known zone state, persisted so a background relaunch can tell arrival from noise.
    private(set) var isInsideZone: Bool? {
        didSet {
            if let isInsideZone { UserDefaults.standard.set(isInsideZone, forKey: Self.insideKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.insideKey) }
        }
    }

    override init() {
        authorization = manager.authorizationStatus
        isInsideZone = UserDefaults.standard.object(forKey: Self.insideKey) as? Bool
        super.init()
        manager.delegate = self
    }

    var canMonitorInBackground: Bool { authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func requestPermission() {
        switch authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    // MARK: Foreground position

    func startLiveUpdates() {
        guard liveTask == nil, authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return }
        liveTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self, !Task.isCancelled else { break }
                    if let loc = update.location { self.location = loc }
                }
            } catch {}
        }
    }

    func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
    }

    // MARK: Geofence

    /// Must run at launch (including background relaunches) so pending events get delivered.
    func activateMonitor() async {
        guard monitor == nil else { return }
        geofenceLog.info("creating monitor")
        let m = await CLMonitor(Self.monitorName)
        monitor = m
        geofenceLog.info("monitor ready, auth=\(String(describing: self.authorization), privacy: .public)")
        eventsTask = Task { [weak self] in
            do {
                for try await event in await m.events {
                    geofenceLog.info("monitor event \(event.identifier, privacy: .public) state=\(String(describing: event.state), privacy: .public)")
                    self?.handle(state: event.state)
                }
            } catch {}
        }
    }

    /// The synchronous part of setting the zone up, called first thing at launch — before any
    /// `await` — so a background relaunch holds its Always session and knows the zone by the
    /// time the location events that woke it start arriving. A significant-change fix that
    /// landed before `currentZone` was set used to be silently dropped.
    func prepare(center: Coordinate, radius: Double) {
        if backgroundSession == nil { backgroundSession = CLServiceSession(authorization: .always) }
        currentZone = (center, radius)
    }

    func setZone(center: Coordinate, radius: Double) async {
        prepare(center: center, radius: radius)
        await activateMonitor()
        guard let monitor else { return }

        // setZone() runs on every launch, including the background relaunch iOS does to
        // deliver an arrival — and when the app was swiped away, that relaunch is the *only*
        // chance to act on it. Removing and re-adding the same geofence here threw away the
        // very event that woke the app (and a freshly re-added region never reports "entered"
        // for a place you're already standing in), so an unchanged zone is left exactly as
        // iOS has it. Instead, ask the classic region where we are now: if the arrival event
        // itself got lost, its state still turns into the missed transition through
        // handle(inside:), which compares it against the persisted isInsideZone. (Not
        // CLMonitor's record.lastEvent — at launch that's still the old state, and feeding it
        // in reported a false departure right after a real arrival.)
        if await isAlreadyMonitoring(center: center, radius: radius, monitor: monitor) {
            geofenceLog.info("zone unchanged, keeping existing monitoring")
            requestClassicState()
            manager.startMonitoringSignificantLocationChanges()
            return
        }

        await monitor.remove(Self.conditionID)

        // If we already know where we are, seed the state through the same dedup path a real
        // geofence event uses. The very first time (isInsideZone still nil) that silently
        // seeds without firing, so turning the feature on while standing at home doesn't
        // count as an "arrival" — but editing an already-configured home location or radius
        // later, in a way that flips whether you're now inside or outside, *does* fire the
        // matching transition. Dragging home away from where you're standing should turn the
        // lights off, the same as actually walking away would.
        //
        // setZone() runs on every launch, including a background relaunch, and a fresh
        // process almost never has `location` populated yet — foreground live updates haven't
        // started, and CLMonitor/region/significant-change events haven't arrived yet either.
        // This used to fall into an `else` that wiped isInsideZone to nil right here, which
        // erased the one piece of state a later relaunch needs to tell a real transition from
        // noise (see the property's own doc comment) — on a typical outing the app is
        // relaunched several times before iOS is confident enough to report "exited", and each
        // relaunch was quietly discarding the "you were inside" memory the eventual real event
        // needed to compare against, so departures got silently swallowed far more often than
        // arrivals. Now a stale value is left alone rather than erased; it only ever moves
        // forward from an actual position fix or a real monitoring event.
        var assumed: CLMonitor.Event.State = .unknown
        if let location {
            let inside = location.distance(from: center.location) <= radius
            assumed = inside ? .satisfied : .unsatisfied
            handle(inside: inside)
        }
        geofenceLog.info("zone set r=\(radius) assumed=\(String(describing: assumed), privacy: .public)")
        let condition = CLMonitor.CircularGeographicCondition(center: center.clCoordinate, radius: radius)
        await monitor.add(condition, identifier: Self.conditionID, assuming: assumed)

        applyClassicRegion(center: center, radius: radius)
        requestClassicState()
        manager.startMonitoringSignificantLocationChanges()
    }

    /// Both geofences are already registered for exactly this center and radius.
    private func isAlreadyMonitoring(center: Coordinate, radius: Double, monitor: CLMonitor) async -> Bool {
        func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            abs(a.latitude - b.latitude) < 1e-6 && abs(a.longitude - b.longitude) < 1e-6
        }
        guard let record = await monitor.record(for: Self.conditionID),
              let condition = record.condition as? CLMonitor.CircularGeographicCondition,
              same(condition.center, center.clCoordinate),
              abs(condition.radius - radius) < 0.5 else { return false }
        let classicRadius = min(radius, manager.maximumRegionMonitoringDistance)
        return manager.monitoredRegions.contains { region in
            guard region.identifier == Self.classicRegionID, let circle = region as? CLCircularRegion else { return false }
            return same(circle.center, center.clCoordinate) && abs(circle.radius - classicRadius) < 0.5
        }
    }

    /// Answered by `locationManager(_:didDetermineState:for:)`.
    private func requestClassicState() {
        for region in manager.monitoredRegions where region.identifier == Self.classicRegionID {
            manager.requestState(for: region)
        }
    }

    func clearZone() async {
        await monitor?.remove(Self.conditionID)
        backgroundSession?.invalidate()
        backgroundSession = nil
        isInsideZone = nil
        removeClassicRegion()
        currentZone = nil
        manager.stopMonitoringSignificantLocationChanges()
    }

    private func applyClassicRegion(center: Coordinate, radius: Double) {
        removeClassicRegion()
        let clamped = min(radius, manager.maximumRegionMonitoringDistance)
        let region = CLCircularRegion(center: center.clCoordinate, radius: clamped, identifier: Self.classicRegionID)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func removeClassicRegion() {
        for region in manager.monitoredRegions where region.identifier == Self.classicRegionID {
            manager.stopMonitoring(for: region)
        }
    }

    private func handle(state: CLMonitor.Event.State) {
        switch state {
        case .satisfied: handleGeofence(inside: true)
        case .unsatisfied: handleGeofence(inside: false)
        default: return
        }
    }

    /// A state reported by either geofence, as opposed to a raw position fix. Only a report
    /// that changes the state moves `lastZoneEventDate`: the launch-time "still inside" reply
    /// to requestClassicState() mustn't shut out the fresh fix of a departure the geofence
    /// itself hasn't confirmed yet.
    private func handleGeofence(inside: Bool) {
        if isInsideZone != inside { lastZoneEventDate = .now }
        handle(inside: inside)
    }

    /// Shared by both monitoring paths (CLMonitor and the classic region API below), so a
    /// transition reported by either — or both, in whichever order they happen to arrive —
    /// is only ever acted on once.
    private func handle(inside: Bool) {
        let previous = isInsideZone
        isInsideZone = inside
        guard let previous, previous != inside else { return }
        geofenceLog.info("transition \(inside ? "entered" : "exited", privacy: .public)")
        onTransition?(inside ? .entered : .exited)
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.startLiveUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.classicRegionID else { return }
        Task { @MainActor in
            geofenceLog.info("classic region: entered")
            self.handleGeofence(inside: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.classicRegionID else { return }
        Task { @MainActor in
            geofenceLog.info("classic region: exited")
            self.handleGeofence(inside: false)
        }
    }

    /// The answer to requestClassicState(), plus a copy of every boundary crossing (which
    /// handle(inside:) collapses with the didEnter/didExit it duplicates).
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == Self.classicRegionID, state != .unknown else { return }
        let inside = state == .inside
        Task { @MainActor in
            geofenceLog.info("classic region state: \(inside ? "inside" : "outside", privacy: .public)")
            self.handleGeofence(inside: inside)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == Self.classicRegionID else { return }
        geofenceLog.error("classic region monitoring failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Fires only for significant-location-change monitoring here (nothing else in this app
    /// calls startUpdatingLocation). A real fix arrives roughly every ~500m of movement or on
    /// a cell tower handoff — infrequent, but it's ground truth from an actual GPS reading,
    /// not iOS's own (evidently sometimes over-cautious) confidence heuristic for confirming
    /// a geofence exit. This is what catches a real departure the boundary check missed.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        Task { @MainActor in
            self.location = newest
            guard let zone = self.currentZone else { return }
            let inside = newest.distance(from: zone.center.location) <= zone.radius
            let age = -newest.timestamp.timeIntervalSinceNow
            geofenceLog.info("significant location change: \(inside ? "inside" : "outside", privacy: .public) age=\(Int(age))s acc=\(Int(newest.horizontalAccuracy))m")
            // Starting significant-change monitoring at launch first hands back iOS's cached
            // last position, which can be from before the trip home. On a background relaunch
            // for an arrival that stale "outside" landed right after the real "entered" and
            // switched the lights straight back off, so only a fix that's both recent and
            // newer than the last geofence state gets a say.
            if age > Self.maxFixAge { return }
            if let lastZoneEventDate = self.lastZoneEventDate, newest.timestamp < lastZoneEventDate { return }
            self.handle(inside: inside)
        }
    }
}

/// Solar elevation, so "only after dark" works offline for API lights.
enum Sun {
    /// True when the sun is below the horizon (including refraction) at `coordinate`.
    static func isDark(at date: Date = .now, coordinate: Coordinate) -> Bool {
        elevation(at: date, coordinate: coordinate) < -0.833
    }

    static func elevation(at date: Date, coordinate: Coordinate) -> Double {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let meanLongitude = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let gmstHours = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24)
        let hourAngle = (gmstHours * 15 + coordinate.longitude) * rad - rightAscension
        let lat = coordinate.latitude * rad
        return asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)) / rad
    }
}
