import Foundation
import CoreLocation
import Observation
import os

let geofenceLog = Logger(subsystem: "Jitwisut.AppleHome", category: "geofence")

enum ZoneTransition: Sendable {
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
        let m = await CLMonitor(Self.monitorName)
        monitor = m
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

        // If we already know where we are, seed the state so setting the zone up while
        // standing at home doesn't count as an "arrival".
        var assumed: CLMonitor.Event.State = .unknown
        if let location {
            let inside = location.distance(from: center.location) <= radius
            assumed = inside ? .satisfied : .unsatisfied
            isInsideZone = inside
        } else {
            isInsideZone = nil
        }
        geofenceLog.info("zone set r=\(radius) assumed=\(String(describing: assumed), privacy: .public)")
        let condition = CLMonitor.CircularGeographicCondition(center: center.clCoordinate, radius: radius)
        await monitor.add(condition, identifier: Self.conditionID, assuming: assumed)
    }

    func clearZone() async {
        await monitor?.remove(Self.conditionID)
        backgroundSession?.invalidate()
        backgroundSession = nil
        isInsideZone = nil
    }

    private func handle(state: CLMonitor.Event.State) {
        let inside: Bool
        switch state {
        case .satisfied: inside = true
        case .unsatisfied: inside = false
        default: return
        }
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
