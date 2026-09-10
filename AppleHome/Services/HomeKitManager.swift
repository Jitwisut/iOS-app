import Foundation
import HomeKit
import CoreLocation
import Observation

enum HomeKitAutomationStatus: Equatable {
    case idle
    case syncing
    case synced(Date)
    /// Automation saved, but nothing in the home can run it while you're away.
    case noHub
    case failed(String)
}

/// Controls HomeKit lightbulbs and mirrors the arrival settings into Apple Home as
/// location-triggered automations. HomeKit won't let apps drive accessories from the
/// background, so the home hub (Apple TV / HomePod) must run these triggers for us.
@Observable
final class HomeKitManager: NSObject, LightProvider {
    let source = LightSource.homeKit

    private var manager: HMHomeManager?
    private(set) var homes: [HMHome] = []
    private(set) var isReady = false
    private(set) var authorization: HMHomeManagerAuthorizationStatus = []
    private(set) var automationStatus: HomeKitAutomationStatus = .idle
    var selectedHomeID: String?
    /// Called whenever homes or accessories change so the store can reload.
    var onChange: (() -> Void)?

    private static let automationPrefix = "AppleHome · "
    private static let arriveName = automationPrefix + "Arrive"
    private static let leaveName = automationPrefix + "Leave"

    var isActive: Bool { manager != nil }

    var home: HMHome? {
        if let id = selectedHomeID, let match = homes.first(where: { $0.uniqueIdentifier.uuidString == id }) {
            return match
        }
        return homes.first
    }

    var hubState: HMHomeHubState { home?.homeHubState ?? .notAvailable }

    /// Creating HMHomeManager shows the HomeKit permission prompt, so only do it once the user opts in.
    func activate() {
        guard manager == nil else { return }
        let m = HMHomeManager()
        m.delegate = self
        manager = m
    }

    func deactivate() {
        manager?.delegate = nil
        manager = nil
        homes = []
        isReady = false
        automationStatus = .idle
    }

    fileprivate func refreshHomes() {
        guard let manager else { return }
        homes = manager.homes
        authorization = manager.authorizationStatus
        isReady = true
        onChange?()
    }

    // MARK: LightProvider

    func loadLights() async throws -> [Light] {
        guard let home else { return [] }
        var result: [Light] = []
        for accessory in home.accessories {
            for service in accessory.services where service.serviceType == HMServiceTypeLightbulb {
                guard let power = service.characteristic(HMCharacteristicTypePowerState) else { continue }
                let brightness = service.characteristic(HMCharacteristicTypeBrightness)
                if accessory.isReachable {
                    try? await power.readValue()
                    if let brightness { try? await brightness.readValue() }
                }
                let name = service.name.isEmpty ? accessory.name : service.name
                result.append(Light(
                    remoteID: service.uniqueIdentifier.uuidString,
                    source: .homeKit,
                    name: name,
                    room: accessory.room?.name ?? home.roomForEntireHome().name,
                    kind: .guess(from: name),
                    isOn: (power.value as? NSNumber)?.boolValue ?? false,
                    brightness: ((brightness?.value as? NSNumber)?.doubleValue ?? 100) / 100,
                    supportsBrightness: brightness != nil,
                    isReachable: accessory.isReachable
                ))
            }
        }
        return result
    }

    func setPower(_ isOn: Bool, remoteID: String) async throws {
        guard let power = lightService(remoteID)?.characteristic(HMCharacteristicTypePowerState) else { return }
        try await power.writeValue(isOn)
    }

    func setBrightness(_ value: Double, remoteID: String) async throws {
        guard let service = lightService(remoteID) else { return }
        if let brightness = service.characteristic(HMCharacteristicTypeBrightness) {
            try await brightness.writeValue(Int((value * 100).rounded()))
        }
        try await service.characteristic(HMCharacteristicTypePowerState)?.writeValue(value > 0)
    }

    private func lightService(_ remoteID: String) -> HMService? {
        home?.accessories.lazy.flatMap(\.services).first { $0.uniqueIdentifier.uuidString == remoteID }
    }

    // MARK: Arrival automation

    func syncArrivalAutomation(_ settings: ArrivalSettings) async {
        guard let home else {
            automationStatus = .idle
            return
        }
        automationStatus = .syncing
        do {
            try await removeOurAutomations(from: home)

            let wanted = settings.lightIDs.compactMap(Light.parse).filter { $0.source == .homeKit }.map(\.remoteID)
            let services = home.accessories.flatMap(\.services).filter { service in
                service.serviceType == HMServiceTypeLightbulb
                    && (settings.lightIDs.isEmpty || wanted.contains(service.uniqueIdentifier.uuidString))
            }
            guard settings.isEnabled, let center = settings.home, !services.isEmpty else {
                automationStatus = .idle
                return
            }

            try await addLocationTrigger(
                to: home, name: Self.arriveName, center: center, radius: settings.radius,
                onEntry: true, powerOn: true, services: services, afterDark: settings.onlyAfterDark
            )
            if settings.onLeave == .turnOff {
                try await addLocationTrigger(
                    to: home, name: Self.leaveName, center: center, radius: settings.radius,
                    onEntry: false, powerOn: false, services: services, afterDark: false
                )
            }
            automationStatus = home.homeHubState == .connected ? .synced(Date()) : .noHub
        } catch {
            automationStatus = .failed(error.localizedDescription)
        }
    }

    private func removeOurAutomations(from home: HMHome) async throws {
        for trigger in home.triggers where trigger.name.hasPrefix(Self.automationPrefix) {
            try await home.removeTrigger(trigger)
        }
        for actionSet in home.actionSets where actionSet.name.hasPrefix(Self.automationPrefix) {
            try await home.removeActionSet(actionSet)
        }
    }

    private func addLocationTrigger(
        to home: HMHome, name: String, center: Coordinate, radius: Double,
        onEntry: Bool, powerOn: Bool, services: [HMService], afterDark: Bool
    ) async throws {
        let region = CLCircularRegion(center: center.clCoordinate, radius: radius, identifier: name)
        region.notifyOnEntry = onEntry
        region.notifyOnExit = !onEntry

        let actionSet = try await home.addActionSet(named: name)
        for service in services {
            guard let power = service.characteristic(HMCharacteristicTypePowerState) else { continue }
            try await actionSet.addAction(HMCharacteristicWriteAction(characteristic: power, targetValue: NSNumber(value: powerOn)))
        }

        var predicate: NSPredicate?
        if afterDark {
            let sunset = HMSignificantTimeEvent(significantEvent: .sunset, offset: nil)
            let sunrise = HMSignificantTimeEvent(significantEvent: .sunrise, offset: nil)
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                HMEventTrigger.predicateForEvaluatingTriggerOccurring(afterSignificantEvent: sunset),
                HMEventTrigger.predicateForEvaluatingTriggerOccurring(beforeSignificantEvent: sunrise),
            ])
        }

        let trigger = HMEventTrigger(name: name, events: [HMLocationEvent(region: region)], predicate: predicate)
        try await home.addTrigger(trigger)
        try await trigger.addActionSet(actionSet)
        try await trigger.enable(true)
    }
}

extension HomeKitManager: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.refreshHomes() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in self.refreshHomes() }
    }
}

private extension HMService {
    func characteristic(_ type: String) -> HMCharacteristic? {
        characteristics.first { $0.characteristicType == type }
    }
}
