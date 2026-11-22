import XCTest
@testable import AstroFieldKit

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultSchedule() {
        let policy = ReconnectPolicy.default
        XCTAssertEqual(policy.maxAttempts, 5)
        XCTAssertEqual(policy.delay(beforeAttempt: 1), 1)
        XCTAssertEqual(policy.delay(beforeAttempt: 2), 2)
        XCTAssertEqual(policy.delay(beforeAttempt: 3), 5)
        XCTAssertEqual(policy.delay(beforeAttempt: 4), 5)
        XCTAssertEqual(policy.delay(beforeAttempt: 5), 5)
        XCTAssertNil(policy.delay(beforeAttempt: 0))
        XCTAssertNil(policy.delay(beforeAttempt: 6))
    }

    func testNegativeDelaysAreDropped() {
        let policy = ReconnectPolicy(delays: [-1, 0, 3])
        XCTAssertEqual(policy.delays, [0, 3])
        XCTAssertEqual(policy.maxAttempts, 2)
    }

    func testReconnectingAndRecoveredStates() {
        let reconnecting = CameraState.reconnecting(attempt: 2, maxAttempts: 5)
        XCTAssertFalse(reconnecting.isConnected)
        XCTAssertTrue(reconnecting.isReconnecting)
        XCTAssertEqual(reconnecting.displayText, "重连中 2/5")

        let recovered = CameraState.recovered
        XCTAssertTrue(recovered.isConnected)
        XCTAssertFalse(recovered.isReconnecting)
        XCTAssertEqual(recovered.displayText, "已恢复")
    }
}
