import Foundation

enum RemoteControlSupervisorState: Equatable, Sendable {
    case idle
    case waitingForRuntime
    case connected(since: Date)
    case degraded(since: Date, reason: RemoteDegradationReason)
    case authenticationRequired(since: Date, message: String?)
    case stopped
}

protocol RemoteControlSupervising: AnyObject, Sendable {
    func start()
    func retryNow()
    func moshDidExit()
    func stop(cleanup: Bool)
}

/// Owns short-lived SSH subscribers and reconnect policy. It never decides
/// that a remote Agent ended and never runs cleanup: network silence only
/// affects control freshness.
final class RemoteControlSupervisor: RemoteControlSupervising, @unchecked Sendable {
    typealias ChannelFactory = @Sendable (
        @escaping RemoteControlChannel.EventHandler
    ) -> any RemoteControlChannelRunning
    typealias StateHandler = @Sendable (RemoteControlSupervisorState) -> Void
    typealias FrameHandler = @Sendable (RemoteRuntimeFrame) -> Void

    static let backoffSeconds: [TimeInterval] = [0.5, 1, 2, 5, 10, 30, 60]

    private let runtimeToken: UUID
    private let channelFactory: ChannelFactory
    private let stateHandler: StateHandler
    private let frameHandler: FrameHandler
    private let queue = DispatchQueue(label: "kooky.remote-control-supervisor", qos: .utility)
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    private let cleanupAction: (@Sendable () -> Void)?

    private var channel: (any RemoteControlChannelRunning)?
    private var channelGeneration: UInt64 = 0
    private var retryWork: DispatchWorkItem?
    private var state: RemoteControlSupervisorState = .idle
    private var retryIndex = 0
    private var protocolViolations: [Date] = []
    private var stopped = false

    init(
        runtimeToken: UUID,
        channelFactory: @escaping ChannelFactory,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = {
            $0 * Double.random(in: 0.8...1.2)
        },
        cleanupAction: (@Sendable () -> Void)? = nil,
        stateHandler: @escaping StateHandler,
        frameHandler: @escaping FrameHandler
    ) {
        self.runtimeToken = runtimeToken
        self.channelFactory = channelFactory
        self.jitter = jitter
        self.cleanupAction = cleanupAction
        self.stateHandler = stateHandler
        self.frameHandler = frameHandler
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.transition(to: .waitingForRuntime)
            self.openChannel()
        }
    }

    func retryNow() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.retryWork?.cancel()
            self.retryWork = nil
            self.invalidateChannel()
            self.transition(to: .waitingForRuntime)
            self.openChannel()
        }
    }

    /// Called only for a real local mosh-client exit, never for TCP silence.
    func moshDidExit() {
        stop(cleanup: true)
    }

    func stop(cleanup: Bool = false) {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.retryWork?.cancel()
            self.retryWork = nil
            self.invalidateChannel()
            self.transition(to: .stopped)
            if cleanup { self.cleanupAction?() }
        }
    }

    static func backoff(at attempt: Int, jitterFactor: Double) -> TimeInterval {
        let index = min(max(0, attempt), backoffSeconds.count - 1)
        return backoffSeconds[index] * min(1.2, max(0.8, jitterFactor))
    }

    private func openChannel() {
        guard !stopped, channel == nil else { return }
        channelGeneration &+= 1
        let generation = channelGeneration
        channel = channelFactory { [weak self] event in
            self?.queue.async { [weak self] in
                guard let self, generation == self.channelGeneration else {
                    return
                }
                self.handle(event)
            }
        }
        channel?.start()
    }

    private func invalidateChannel() {
        channelGeneration &+= 1
        let previous = channel
        channel = nil
        previous?.stop()
    }

    private func handle(_ event: RemoteControlChannelEvent) {
        guard !stopped else { return }
        switch event {
        case .frame(let frame):
            handle(frame)
        case .protocolViolation:
            let now = Date()
            protocolViolations.append(now)
            protocolViolations.removeAll { now.timeIntervalSince($0) > 10 }
            if protocolViolations.count >= 3 {
                invalidateChannel()
                transition(to: .degraded(since: now, reason: .protocolIncompatible))
                scheduleRetry()
            }
        case .exited(let exit):
            channel = nil
            guard exit.kind != .cancelled else { return }
            if case .connected(let since) = state,
               Date().timeIntervalSince(since) >= 30 {
                retryIndex = 0
            }
            if exit.kind == .authenticationRequired {
                retryWork?.cancel()
                retryWork = nil
                transition(to: .authenticationRequired(
                    since: Date(),
                    message: exit.message
                ))
                return
            }
            let reason: RemoteDegradationReason = exit.kind == .runtimeUnavailable
                ? .controlUnavailable
                : .controlDisconnected
            transition(to: .degraded(since: Date(), reason: reason))
            scheduleRetry()
        }
    }

    private func handle(_ frame: RemoteRuntimeFrame) {
        switch frame {
        case .ready(let token):
            guard token == runtimeToken else {
                invalidateChannel()
                transition(to: .degraded(since: Date(), reason: .controlDisconnected))
                scheduleRetry()
                return
            }
        case .snapshot, .event:
            let now = Date()
            if case .connected(let since) = state,
               now.timeIntervalSince(since) >= 30 {
                retryIndex = 0
            }
            if !state.isConnected {
                protocolViolations.removeAll()
                transition(to: .connected(since: now))
            }
            frameHandler(frame)
        case .error:
            frameHandler(frame)
        }
    }

    private func scheduleRetry() {
        guard !stopped, retryWork == nil else { return }
        let base = Self.backoffSeconds[min(retryIndex, Self.backoffSeconds.count - 1)]
        retryIndex = min(retryIndex + 1, Self.backoffSeconds.count - 1)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.retryWork = nil
            self.transition(to: .waitingForRuntime)
            self.openChannel()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + max(0, jitter(base)), execute: work)
    }

    private func transition(to next: RemoteControlSupervisorState) {
        guard state != next else { return }
        state = next
        stateHandler(next)
    }
}

private extension RemoteControlSupervisorState {
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
