import XCTest
@testable import KookyKit

final class RemoteControlChannelTests: XCTestCase {
    private final class FakeChannel: RemoteControlChannelRunning, @unchecked Sendable {
        let handler: RemoteControlChannel.EventHandler
        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)

        init(handler: @escaping RemoteControlChannel.EventHandler) {
            self.handler = handler
        }

        func start() { started.signal() }
        func stop() { stopped.signal() }
        func emit(_ event: RemoteControlChannelEvent) { handler(event) }
    }

    private final class Recorder<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        let changed = DispatchSemaphore(value: 0)

        func append(_ value: Value) {
            lock.lock()
            storage.append(value)
            lock.unlock()
            changed.signal()
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testArgumentsAreNonInteractiveMultiplexedAndKeepValuesAsTokens() {
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let configuration = RemoteControlChannelConfiguration(
            destination: "user@host.example",
            runtimeToken: token,
            sshPort: 2222,
            identityFile: "/tmp/key with spaces"
        )

        let arguments = RemoteControlChannel.arguments(for: configuration)

        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("ConnectTimeout=10"))
        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("user@host.example"))
        XCTAssertTrue(arguments.contains("/tmp/key with spaces"))
        XCTAssertEqual(arguments[arguments.count - 3], "--")
        XCTAssertFalse(arguments.contains { $0.contains("user@host.example;") })
        XCTAssertTrue(arguments.last?.contains(token.uuidString.lowercased()) == true)
    }

    func testSystemOpenSSHAcceptsGeneratedArgumentContract() throws {
        let configuration = RemoteControlChannelConfiguration(
            destination: "localhost",
            runtimeToken: UUID(),
            sshPort: 2_222,
            identityFile: "/tmp/key with spaces"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + RemoteControlChannel.arguments(for: configuration)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let rendered = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(rendered.contains("hostname localhost"))
        XCTAssertTrue(rendered.contains("port 2222"))
        XCTAssertTrue(rendered.contains("batchmode yes"))
        XCTAssertTrue(rendered.contains("controlmaster auto"))
    }

    func testExitClassificationSeparatesAuthNetworkRuntimeAndCancellation() {
        XCTAssertEqual(
            RemoteControlChannel.classifyExit(
                status: 255,
                stderr: "Permission denied (publickey,password).",
                wasCancelled: false
            ).kind,
            .authenticationRequired
        )
        XCTAssertEqual(
            RemoteControlChannel.classifyExit(
                status: 255,
                stderr: "ssh: connect to host x: Network is unreachable",
                wasCancelled: false
            ).kind,
            .networkUnavailable
        )
        XCTAssertEqual(
            RemoteControlChannel.classifyExit(
                status: 75,
                stderr: "",
                wasCancelled: false
            ).kind,
            .runtimeUnavailable
        )
        XCTAssertEqual(
            RemoteControlChannel.classifyExit(
                status: 15,
                stderr: "ignored",
                wasCancelled: true
            ).kind,
            .cancelled
        )
    }

    func testDiagnosticsStripControlCharactersAndStayBoundedByChannel() {
        let exit = RemoteControlChannel.classifyExit(
            status: 1,
            stderr: "bad\u{001B}[31m\r\nmessage\u{0000}",
            wasCancelled: false
        )
        XCTAssertEqual(exit.kind, .exited)
        XCTAssertEqual(exit.message, "bad[31m\r\nmessage")
    }

    func testBackoffClampsAttemptAndJitter() {
        XCTAssertEqual(RemoteControlSupervisor.backoff(at: 0, jitterFactor: 1), 0.5)
        XCTAssertEqual(RemoteControlSupervisor.backoff(at: 3, jitterFactor: 1), 5)
        XCTAssertEqual(RemoteControlSupervisor.backoff(at: 99, jitterFactor: 2), 72)
        XCTAssertEqual(RemoteControlSupervisor.backoff(at: -1, jitterFactor: 0), 0.4)
    }

    func testLaunchFailureMarkersRoundTripWithoutAcceptingArbitraryTitles() {
        XCTAssertEqual(
            RemoteLaunchFailureMarker.parse(
                RemoteLaunchFailureMarker.title(for: .executableMissing("mosh"))
            ),
            .executableMissing("mosh")
        )
        XCTAssertEqual(
            RemoteLaunchFailureMarker.parse(
                RemoteLaunchFailureMarker.title(
                    for: .processExited(code: 42, message: "not transported")
                )
            ),
            .processExited(code: 42, message: nil)
        )
        XCTAssertNil(RemoteLaunchFailureMarker.parse("kooky-agent:codex:running"))
    }

    func testSessionExitMarkerRoundTripsWithoutAcceptingArbitraryTitles() {
        XCTAssertEqual(
            RemoteSessionExitMarker.parse(RemoteSessionExitMarker.title(exitCode: 130)),
            130
        )
        XCTAssertTrue(RemoteSessionExitMarker.isMarker(RemoteSessionExitMarker.title(exitCode: 0)))
        XCTAssertNil(RemoteSessionExitMarker.parse("kooky-agent:codex:running"))
        XCTAssertNil(RemoteSessionExitMarker.parse(
            RemoteLaunchFailureMarker.title(for: .processExited(code: 1, message: nil))
        ))
        XCTAssertFalse(RemoteLaunchFailureMarker.isMarker(RemoteSessionExitMarker.title(exitCode: 1)))
    }

    func testSupervisorConnectsDegradesAndPreservesFrameDelivery() throws {
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let states = Recorder<RemoteControlSupervisorState>()
        let frames = Recorder<RemoteRuntimeFrame>()
        let channels = Recorder<FakeChannel>()
        let supervisor = RemoteControlSupervisor(
            runtimeToken: token,
            channelFactory: { handler in
                let created = FakeChannel(handler: handler)
                channels.append(created)
                return created
            },
            jitter: { _ in 60 },
            stateHandler: states.append,
            frameHandler: frames.append
        )

        supervisor.start()
        XCTAssertEqual(states.changed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(channels.changed.wait(timeout: .now() + 1), .success)
        let startedChannel = try XCTUnwrap(channels.values.last)
        XCTAssertEqual(startedChannel.started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(states.values.first, .waitingForRuntime)

        let snapshot = RemoteRuntimeSnapshot(
            sequence: 7,
            agent: "codex",
            activity: .running,
            cwd: "/srv/app",
            cwdTruncated: false,
            exitCode: nil,
            durationMilliseconds: nil
        )
        startedChannel.emit(.frame(.ready(token: token)))
        startedChannel.emit(.frame(.snapshot(snapshot)))
        XCTAssertEqual(states.changed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(frames.changed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(states.values.contains {
            if case .connected = $0 { return true }
            return false
        })
        XCTAssertEqual(frames.values.last, .snapshot(snapshot))

        startedChannel.emit(.exited(RemoteControlExit(
            kind: .networkUnavailable,
            status: 255,
            message: "network unreachable"
        )))
        XCTAssertEqual(states.changed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(states.values.contains {
            if case .degraded(_, .controlDisconnected) = $0 { return true }
            return false
        })
        supervisor.stop()
    }

    func testSupervisorParksAuthenticationAndCleanupOnlyRunsOnExplicitStop() throws {
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let states = Recorder<RemoteControlSupervisorState>()
        let cleanup = DispatchSemaphore(value: 0)
        let channels = Recorder<FakeChannel>()
        let supervisor = RemoteControlSupervisor(
            runtimeToken: token,
            channelFactory: { handler in
                let created = FakeChannel(handler: handler)
                channels.append(created)
                return created
            },
            jitter: { _ in 60 },
            cleanupAction: { cleanup.signal() },
            stateHandler: states.append,
            frameHandler: { _ in }
        )
        supervisor.start()
        XCTAssertEqual(states.changed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(channels.changed.wait(timeout: .now() + 1), .success)
        let startedChannel = try XCTUnwrap(channels.values.last)
        XCTAssertEqual(startedChannel.started.wait(timeout: .now() + 1), .success)

        startedChannel.emit(.exited(RemoteControlExit(
            kind: .authenticationRequired,
            status: 255,
            message: "permission denied"
        )))
        XCTAssertEqual(states.changed.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(states.values.contains {
            if case .authenticationRequired = $0 { return true }
            return false
        })
        XCTAssertEqual(cleanup.wait(timeout: .now() + 0.05), .timedOut)

        supervisor.stop(cleanup: true)
        XCTAssertEqual(cleanup.wait(timeout: .now() + 1), .success)
    }

    func testLateExitFromReplacedChannelCannotClearCurrentChannel() throws {
        let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let states = Recorder<RemoteControlSupervisorState>()
        let frames = Recorder<RemoteRuntimeFrame>()
        let channels = Recorder<FakeChannel>()
        let supervisor = RemoteControlSupervisor(
            runtimeToken: token,
            channelFactory: { handler in
                let created = FakeChannel(handler: handler)
                channels.append(created)
                return created
            },
            jitter: { _ in 60 },
            stateHandler: states.append,
            frameHandler: frames.append
        )
        supervisor.start()
        XCTAssertEqual(channels.changed.wait(timeout: .now() + 1), .success)
        let old = try XCTUnwrap(channels.values.first)
        XCTAssertEqual(old.started.wait(timeout: .now() + 1), .success)

        supervisor.retryNow()
        XCTAssertEqual(channels.changed.wait(timeout: .now() + 1), .success)
        let current = try XCTUnwrap(channels.values.last)
        XCTAssertFalse(old === current)
        XCTAssertEqual(current.started.wait(timeout: .now() + 1), .success)

        old.emit(.exited(RemoteControlExit(
            kind: .cancelled,
            status: 15,
            message: nil
        )))
        let snapshot = RemoteRuntimeSnapshot(
            sequence: 1,
            agent: "codex",
            activity: .running,
            cwd: "/srv",
            cwdTruncated: false,
            exitCode: nil,
            durationMilliseconds: nil
        )
        current.emit(.frame(.ready(token: token)))
        current.emit(.frame(.snapshot(snapshot)))

        XCTAssertEqual(frames.changed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(frames.values.last, .snapshot(snapshot))
        XCTAssertTrue(states.values.contains {
            if case .connected = $0 { return true }
            return false
        })
        supervisor.stop()
    }
}
