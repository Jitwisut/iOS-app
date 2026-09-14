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

    func setZone(center: Coordinate, radius: Double) async {
        await activateMonitor()
        guard let monitor else { return }
        if backgroundSession == nil { backgroundSession = CLServiceSession(authorization: .always) }
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
        currentZone = (center, radius)
        manager.startMonitoringSignificantLocationChanges()
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
        case .satisfied: handle(inside: true)
        case .unsatisfied: handle(inside: false)
        default: return
        }
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
            self.handle(inside: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.classicRegionID else { return }
        Task { @MainActor in
            geofenceLog.info("classic region: exited")
            self.handle(inside: false)
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
            geofenceLog.info("significant location change: \(inside ? "inside" : "outside", privacy: .public)")
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
