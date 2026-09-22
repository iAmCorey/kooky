import Darwin
import Foundation
import XCTest
@testable import KookyKit

@MainActor
final class SurfaceTeardownCoordinatorTests: XCTestCase {
    func testProcessTerminationStartsBeforeFreeQueueAdmission() {
        let recorder = TeardownRecorder()
        let freeStarted = DispatchSemaphore(value: 0)
        let allowFree = DispatchSemaphore(value: 0)
        let coordinator = SurfaceTeardownCoordinator(
            maxConcurrentFrees: 2,
            requestTermination: { recorder.recordRequest($0) },
            freeSurface: {
                recorder.recordFree($0)
                freeStarted.signal()
                allowFree.wait()
            }
        )

        coordinator.enqueue(surfaceBits: 1, foregroundProcessGroup: nil, retainedHostBits: nil)
        coordinator.enqueue(surfaceBits: 2, foregroundProcessGroup: nil, retainedHostBits: nil)
        XCTAssertEqual(freeStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(freeStarted.wait(timeout: .now() + 2), .success)

        coordinator.enqueue(surfaceBits: 3, foregroundProcessGroup: nil, retainedHostBits: nil)
        XCTAssertEqual(recorder.requests, [1, 2, 3])
        XCTAssertEqual(
            freeStarted.wait(timeout: .now() + 0.1),
            .timedOut,
            "the third native free should wait for a bounded worker slot"
        )

        let drained = expectation(description: "all frees drained")
        coordinator.whenDrained { drained.fulfill() }
        allowFree.signal()
        allowFree.signal()
        XCTAssertEqual(freeStarted.wait(timeout: .now() + 2), .success)
        allowFree.signal()
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(Set(recorder.frees), Set([1, 2, 3]))
        XCTAssertTrue(coordinator.isDrained)
    }

    func testRetainedHostReleasesBeforeDrainWaiter() {
        let recorder = TeardownRecorder()
        let drained = expectation(description: "drained")
        let coordinator = SurfaceTeardownCoordinator(
            requestTermination: { recorder.recordRequest($0) },
            freeSurface: { recorder.recordFree($0) },
            releaseHost: { recorder.recordHostRelease($0) }
        )

        coordinator.enqueue(surfaceBits: 7, foregroundProcessGroup: nil, retainedHostBits: 99)
        coordinator.whenDrained {
            XCTAssertEqual(recorder.hostReleases, [99])
            drained.fulfill()
        }

        wait(for: [drained], timeout: 2)
        XCTAssertEqual(recorder.requests, [7])
        XCTAssertEqual(recorder.frees, [7])
    }

    func testNativeTeardownStartsAfterForegroundProcessGroupTermination() {
        let recorder = TeardownRecorder()
        let foregroundFinished = LockedBox<(@Sendable () -> Void)?>(nil)
        let nativeFreeStarted = DispatchSemaphore(value: 0)
        let drained = expectation(description: "drained")
        let coordinator = SurfaceTeardownCoordinator(
            requestTermination: { recorder.recordRequest($0) },
            freeSurface: {
                recorder.recordFree($0)
                nativeFreeStarted.signal()
            },
            beginForegroundTermination: { processGroup, completion in
                recorder.recordForegroundRequest(processGroup)
                foregroundFinished.value = completion
            }
        )

        coordinator.enqueue(surfaceBits: 8, foregroundProcessGroup: 77, retainedHostBits: nil)
        XCTAssertEqual(recorder.requests, [])
        XCTAssertEqual(recorder.foregroundRequests, [77])
        XCTAssertFalse(coordinator.isDrained)
        XCTAssertEqual(
            nativeFreeStarted.wait(timeout: .now() + 0.1),
            .timedOut,
            "native teardown must wait for graceful foreground termination"
        )

        coordinator.whenDrained { drained.fulfill() }
        foregroundFinished.value?()
        XCTAssertEqual(nativeFreeStarted.wait(timeout: .now() + 2), .success)
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(recorder.requests, [8])
        XCTAssertEqual(recorder.frees, [8])
        XCTAssertTrue(coordinator.isDrained)
    }

    func testForegroundShutdownStartsWhileNativeFreeWorkersAreBusy() {
        let recorder = TeardownRecorder()
        let freeStarted = DispatchSemaphore(value: 0)
        let allowFree = DispatchSemaphore(value: 0)
        let foregroundFinished = LockedBox<(@Sendable () -> Void)?>(nil)
        let coordinator = SurfaceTeardownCoordinator(
            maxConcurrentFrees: 1,
            requestTermination: { recorder.recordRequest($0) },
            freeSurface: { _ in
                freeStarted.signal()
                allowFree.wait()
            },
            beginForegroundTermination: { processGroup, completion in
                recorder.recordForegroundRequest(processGroup)
                foregroundFinished.value = completion
            }
        )

        coordinator.enqueue(surfaceBits: 1, foregroundProcessGroup: nil, retainedHostBits: nil)
        XCTAssertEqual(freeStarted.wait(timeout: .now() + 2), .success)
        coordinator.enqueue(surfaceBits: 2, foregroundProcessGroup: 77, retainedHostBits: nil)
        XCTAssertEqual(recorder.foregroundRequests, [77])
        XCTAssertEqual(recorder.requests, [1])
        foregroundFinished.value?()
        XCTAssertEqual(recorder.requests, [1, 2])

        let drained = expectation(description: "drained")
        coordinator.whenDrained { drained.fulfill() }
        allowFree.signal()
        allowFree.signal()
        wait(for: [drained], timeout: 3)
    }

    func testRealChildFinishesCleanupAfterLauncherExitsBeforeNativeTeardown() throws {
        let job = try ForegroundJob(script: #"""
        trap '/bin/sleep 0.3; printf done > "$1/cleaned"; exit 0' HUP
        printf '%s' "$$" > "$1/ready"
        while :; do /bin/sleep 1; done
        """#)
        defer { job.stop() }
        let cleaned = job.directory.appendingPathComponent("cleaned")
        let cleanupBeforeNative = LockedBox(false)
        let drained = expectation(description: "graceful shutdown")
        let coordinator = SurfaceTeardownCoordinator(
            requestTermination: { _ in
                cleanupBeforeNative.value = FileManager.default.fileExists(atPath: cleaned.path)
            },
            freeSurface: { _ in },
            beginForegroundTermination: { ForegroundProcessGroupTerminator.begin($0, completion: $1) }
        )

        coordinator.enqueue(surfaceBits: 1, foregroundProcessGroup: job.group, retainedHostBits: nil)
        XCTAssertEqual(job.launcherReaped.wait(timeout: .now() + 2), .success)
        coordinator.whenDrained { drained.fulfill() }
        wait(for: [drained], timeout: 4)

        XCTAssertTrue(cleanupBeforeNative.value, "the agent's cleanup must survive its bash launcher's exit")
        XCTAssertFalse(job.groupExists, "all foreground processes must be gone before native teardown")
        XCTAssertTrue(coordinator.isDrained)
    }

    func testRealChildIgnoringSignalsIsKilledBeforeDrainCompletes() throws {
        let job = try ForegroundJob(script: #"""
        trap '' HUP TERM
        printf '%s' "$$" > "$1/ready"
        while :; do /bin/sleep 1; done
        """#)
        defer { job.stop() }
        let drained = expectation(description: "forced shutdown")
        let coordinator = SurfaceTeardownCoordinator(
            requestTermination: { _ in },
            freeSurface: { _ in },
            beginForegroundTermination: {
                ForegroundProcessGroupTerminator.begin(
                    $0, sighupGrace: .milliseconds(300), sigkillGrace: .seconds(1), completion: $1
                )
            }
        )

        coordinator.enqueue(surfaceBits: 1, foregroundProcessGroup: job.group, retainedHostBits: nil)
        XCTAssertEqual(job.launcherReaped.wait(timeout: .now() + 2), .success)
        coordinator.whenDrained { drained.fulfill() }
        wait(for: [drained], timeout: 3)

        XCTAssertFalse(job.groupExists, "an exited launcher must not strand a signal-ignoring descendant")
        XCTAssertTrue(coordinator.isDrained)
    }

    func testInvalidOrOwnProcessGroupCompletesWithoutSignalling() {
        for group in [0, 1, -1, getpgrp()] as [pid_t] {
            let completed = LockedBox(false)
            ForegroundProcessGroupTerminator.begin(group) { completed.value = true }
            XCTAssertTrue(completed.value)
        }
    }
}

/// A real bash launcher and child in their own process group. Reap only our
/// direct child; the terminator must still wait for (or kill) its descendants.
private final class ForegroundJob {
    let directory: URL
    let group: pid_t
    let launcherReaped = DispatchGroup()
    private var stopped = false

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = [
            "/bin/bash", "-c",
            #"exec >/dev/null 2>&1; /bin/bash -c "$1" job "$2"; status=$?; exit "$status""#,
            "launcher", script, directory.path,
        ].map { (value: String) in strdup(value) } + [nil]
        let environment = ["PATH=/usr/bin:/bin", "LC_ALL=C"].map { (value: String) in strdup(value) } + [nil]
        defer {
            for value in arguments + environment { free(value) }
        }
        var pid: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/bash", nil, &attributes, argv.baseAddress!, env.baseAddress!)
            }
        }
        group = pid
        guard result == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
        let child = pid
        let reaped = launcherReaped
        reaped.enter()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1, errno == EINTR {}
            reaped.leave()
        }
        let ready = directory.appendingPathComponent("ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard ContinuousClock.now < deadline else {
                stop()
                throw NSError(domain: "ForegroundJob", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "foreground child did not become ready",
                ])
            }
            usleep(10_000)
        }
    }

    var groupExists: Bool { killpg(group, 0) == 0 || errno == EPERM }

    func stop() {
        guard !stopped, group > 1, group != getpgrp() else { return }
        stopped = true
        _ = killpg(group, SIGKILL)
        _ = launcherReaped.wait(timeout: .now() + 2)
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}

private final class TeardownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [UInt] = []
    private var storedFrees: [UInt] = []
    private var storedHostReleases: [UInt] = []
    private var storedForegroundRequests: [pid_t] = []

    var requests: [UInt] { locked { storedRequests } }
    var frees: [UInt] { locked { storedFrees } }
    var hostReleases: [UInt] { locked { storedHostReleases } }
    var foregroundRequests: [pid_t] { locked { storedForegroundRequests } }

    func recordRequest(_ bits: UInt) { locked { storedRequests.append(bits) } }
    func recordFree(_ bits: UInt) { locked { storedFrees.append(bits) } }
    func recordHostRelease(_ bits: UInt) { locked { storedHostReleases.append(bits) } }
    func recordForegroundRequest(_ processGroup: pid_t) { locked { storedForegroundRequests.append(processGroup) } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) { storedValue = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
