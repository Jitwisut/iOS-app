import Foundation
import Network
import Observation
import os

/// Whether the device currently has a usable internet path, and a hook that fires each time
/// it comes back. Only runs while the process is alive: iOS never wakes a suspended app just
/// because the network returned, so callers also retry on launch and on returning to the
/// foreground.
@Observable
final class NetworkMonitor {
    /// nil until the first path update arrives (a few milliseconds after launch).
    private(set) var isOnline: Bool?
    /// Called on the main actor whenever the path becomes satisfied, including the first time.
    var onReconnect: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "Jitwisut.AppleHome.network"))
        #if DEBUG
        installDebugOverride()
        #endif
    }

    private func update(online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        guard online, wasOnline != true else { return }
        let pending = waiters
        waiters = [:]
        pending.values.forEach { $0.resume(returning: true) }
        onReconnect?()
    }

    /// Suspends until the network is back or `timeout` passes; returns whether it came back.
    func waitUntilOnline(timeout: Duration) async -> Bool {
        if isOnline == true { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                waiter.resume(returning: false)
            }
        }
    }

    #if DEBUG
    /// The Simulator shares the Mac's network, so connectivity can't really be dropped there.
    /// `xcrun simctl spawn <device> notifyutil -p Jitwisut.AppleHome.debug.offline` (or
    /// `.online`) drives the exact same path a real loss and recovery would.
    private func installDebugOverride() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let monitor = Unmanaged<NetworkMonitor>.fromOpaque(observer).takeUnretainedValue()
            let online = (name.rawValue as String).hasSuffix(".online")
            Task { @MainActor in
                geofenceLog.info("debug network override: \(online ? "online" : "offline", privacy: .public)")
                monitor.update(online: online)
            }
        }
        for suffix in ["offline", "online"] {
            CFNotificationCenterAddObserver(center, observer, callback,
                                            "Jitwisut.AppleHome.debug.\(suffix)" as CFString,
                                            nil, .deliverImmediately)
        }
    }
    #endif
}
