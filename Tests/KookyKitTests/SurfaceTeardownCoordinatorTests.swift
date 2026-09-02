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
