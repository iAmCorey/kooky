import Network
import XCTest
@testable import KookyKit

final class RemoteNetworkRecoveryMonitorTests: XCTestCase {
    func testOnlyUnavailableToSatisfiedTransitionIsRecovery() {
        XCTAssertFalse(RemoteNetworkRecoveryMonitor.isRecovery(
            previous: nil,
            current: .satisfied
        ))
        XCTAssertFalse(RemoteNetworkRecoveryMonitor.isRecovery(
            previous: .satisfied,
            current: .satisfied
        ))
        XCTAssertFalse(RemoteNetworkRecoveryMonitor.isRecovery(
            previous: .unsatisfied,
            current: .requiresConnection
        ))
        XCTAssertTrue(RemoteNetworkRecoveryMonitor.isRecovery(
            previous: .unsatisfied,
            current: .satisfied
        ))
        XCTAssertTrue(RemoteNetworkRecoveryMonitor.isRecovery(
            previous: .requiresConnection,
            current: .satisfied
        ))
    }
}
