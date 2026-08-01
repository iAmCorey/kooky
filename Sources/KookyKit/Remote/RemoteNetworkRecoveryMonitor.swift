@preconcurrency import Network
import Foundation

/// Emits only a real unavailable-to-available transition. `NWPathMonitor`
/// reports its initial path immediately after `start`; treating that initial
/// report as a recovery would tear down freshly-created control channels on
/// every application launch.
final class RemoteNetworkRecoveryMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(
        label: "kooky.remote-network-recovery",
        qos: .utility
    )
    private let lock = NSLock()
    private let onRecovery: @Sendable () -> Void
    private var previousStatus: NWPath.Status?

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        onRecovery: @escaping @Sendable () -> Void
    ) {
        self.monitor = monitor
        self.onRecovery = onRecovery
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.receive(path.status)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private func receive(_ status: NWPath.Status) {
        lock.lock()
        let previous = previousStatus
        previousStatus = status
        lock.unlock()

        guard Self.isRecovery(previous: previous, current: status) else {
            return
        }
        onRecovery()
    }

    static func isRecovery(
        previous: NWPath.Status?,
        current: NWPath.Status
    ) -> Bool {
        previous != nil
            && previous != .satisfied
            && current == .satisfied
    }
}
