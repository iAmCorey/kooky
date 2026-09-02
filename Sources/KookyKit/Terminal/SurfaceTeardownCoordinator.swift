import Darwin
import Foundation
import GhosttyKit

/// Starts process shutdown synchronously, then moves the blocking native free
/// off the main actor. The native request retires the surface from app routing,
/// so no surface API may be called after `enqueue`.
final class SurfaceTeardownCoordinator: @unchecked Sendable {
    typealias NativeAction = @Sendable (UInt) -> Void
    typealias BeginForegroundTermination = @Sendable (pid_t, @escaping @Sendable () -> Void) -> Void
    typealias HostRelease = @MainActor @Sendable (UInt) -> Void
    typealias DrainWaiter = @MainActor @Sendable () -> Void

    static let shared = SurfaceTeardownCoordinator(
        requestTermination: { bits in
            guard let surface = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            ghostty_surface_request_process_termination(surface)
        },
        freeSurface: { bits in
            guard let surface = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            ghostty_surface_free(surface)
        },
        beginForegroundTermination: ForegroundProcessGroupTerminator.begin,
        releaseHost: { bits in
            guard let pointer = UnsafeRawPointer(bitPattern: bits) else { return }
            Unmanaged<GhosttySurfaceView>.fromOpaque(pointer).release()
        }
    )

    private let lock = NSLock()
    private let freeQueue: OperationQueue
    private let requestTermination: NativeAction
    private let freeSurface: NativeAction
    private let beginForegroundTermination: BeginForegroundTermination
    private let releaseHost: HostRelease
    private var pending: [UUID: Pending] = [:]
    private var drainWaiters: [DrainWaiter] = []

    init(
        maxConcurrentFrees: Int = 2,
        requestTermination: @escaping NativeAction,
        freeSurface: @escaping NativeAction,
        beginForegroundTermination: @escaping BeginForegroundTermination = { _, completion in completion() },
        releaseHost: @escaping HostRelease = { _ in }
    ) {
        let queue = OperationQueue()
        queue.name = "kooky.surface-teardown"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, maxConcurrentFrees)
        freeQueue = queue
        self.requestTermination = requestTermination
        self.freeSurface = freeSurface
        self.beginForegroundTermination = beginForegroundTermination
        self.releaseHost = releaseHost
    }

    /// `retainedHostBits` is a +1 `Unmanaged` retain released on the main actor
    /// after native teardown, keeping already-dispatched callbacks' userdata
    /// alive until `ghostty_surface_free` has joined every owned thread.
    func enqueue(surfaceBits: UInt, foregroundProcessGroup: pid_t?, retainedHostBits: UInt?) {
        let id = UUID()
        var components: Set<Component> = [.nativeFree]
        if foregroundProcessGroup != nil { components.insert(.foregroundProcessGroup) }
        lock.lock()
        pending[id] = Pending(components: components, retainedHostBits: retainedHostBits)
        lock.unlock()

        let startNativeTeardown: @Sendable () -> Void = { [self] in
            requestTermination(surfaceBits)
            freeQueue.addOperation { [self] in
                freeSurface(surfaceBits)
                finish(id: id, component: .nativeFree)
            }
        }

        // Keep the PTY and IO thread alive while the foreground program gets
        // the terminal's normal SIGHUP notification and performs cleanup.
        // Native teardown stops that IO thread, so it must start only after
        // the foreground process group exits or the grace period escalates.
        if let foregroundProcessGroup {
            beginForegroundTermination(foregroundProcessGroup) { [self] in
                startNativeTeardown()
                finish(id: id, component: .foregroundProcessGroup)
            }
        } else {
            startNativeTeardown()
        }
    }

    var isDrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty
    }

    func whenDrained(_ waiter: @escaping DrainWaiter) {
        lock.lock()
        if pending.isEmpty {
            lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { waiter() }
            }
            return
        }
        drainWaiters.append(waiter)
        lock.unlock()
    }

    private func finish(id: UUID, component: Component) {
        lock.lock()
        guard var entry = pending[id], entry.components.remove(component) != nil else {
            lock.unlock()
            return
        }
        guard entry.components.isEmpty else {
            pending[id] = entry
            lock.unlock()
            return
        }
        pending.removeValue(forKey: id)
        let waiters: [DrainWaiter]
        if pending.isEmpty {
            waiters = drainWaiters
            drainWaiters.removeAll()
        } else {
            waiters = []
        }
        lock.unlock()

        guard entry.retainedHostBits != nil || !waiters.isEmpty else { return }
        DispatchQueue.main.async { [releaseHost] in
            MainActor.assumeIsolated {
                if let retainedHostBits = entry.retainedHostBits { releaseHost(retainedHostBits) }
                for waiter in waiters { waiter() }
            }
        }
    }

    private enum Component: Hashable {
        case nativeFree
        case foregroundProcessGroup
    }

    private struct Pending {
        var components: Set<Component>
        let retainedHostBits: UInt?
    }
}

private enum ForegroundProcessGroupTerminator {
    private static let pollInterval = Duration.milliseconds(50)
    private static let sighupGrace = Duration.seconds(12)
    private static let sigkillGrace = Duration.seconds(3)

    static func begin(_ processGroup: pid_t, completion: @escaping @Sendable () -> Void) {
        guard processGroup > 1, processGroup != getpgrp() else {
            completion()
            return
        }

        if killpg(processGroup, SIGHUP) != 0, errno == ESRCH {
            completion()
            return
        }

        Task.detached(priority: .utility) {
            if await waitUntilLeaderGone(processGroup, timeout: sighupGrace) {
                // The process-group leader is the foreground job's root
                // process (the bash launcher for Kooky's agent tabs). Its exit
                // marks the owning command as done; descendants it spawned
                // (for example MCP servers) must not keep Kooky waiting.
                _ = killpg(processGroup, SIGTERM)
                completion()
                return
            }
            _ = killpg(processGroup, SIGKILL)
            _ = await waitUntilGone(processGroup, timeout: sigkillGrace)
            completion()
        }
    }

    private static func waitUntilLeaderGone(_ processGroup: pid_t, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while processExists(processGroup) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    private static func waitUntilGone(_ processGroup: pid_t, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while processGroupExists(processGroup) {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    private static func processExists(_ process: pid_t) -> Bool {
        if kill(process, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        if killpg(processGroup, 0) == 0 { return true }
        return errno == EPERM
    }
}
