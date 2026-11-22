import XCTest
import AFSpikeCore
@testable import AstroFieldKit

final class NikonSessionTests: XCTestCase {
    func testSessionCloseNotifiesOnceAndLeavesCapabilities() {
        let camera = NikonCamera()
        camera.finishSessionOpen(CameraStatus(state: .connected, model: "Z 7_2",
                                              capabilities: [.liveView, .stillCapture]))
        var reasons: [String] = []
        camera.onSessionLost = { reasons.append($0) }

        let icc = ICCCamera()
        camera.camera(icc, didCloseSessionWithError: NSError(domain: "test", code: 1))
        // The browser may report removal in addition to the closed session.
        camera.cameraWasRemoved(icc)

        XCTAssertEqual(reasons.count, 1, "session loss must be reported once per session")
        XCTAssertFalse(camera.status.state.isConnected)
        XCTAssertTrue(camera.status.capabilities.contains(.liveView),
                      "capabilities are kept so the reconnect can reuse them")
        XCTAssertTrue(camera.status.notes.first?.contains("ICC 会话断开") == true)
    }

    func testIntentionalCloseIsSuppressed() async {
        let camera = NikonCamera()
        camera.finishSessionOpen(CameraStatus(state: .connected, model: "Z 7_2",
                                              capabilities: [.liveView]))
        var reasons: [String] = []
        camera.onSessionLost = { reasons.append($0) }
        await camera.disconnect()
        let icc = ICCCamera()
        camera.camera(icc, didCloseSessionWithError: nil)
        XCTAssertTrue(reasons.isEmpty)
        XCTAssertFalse(camera.status.state.isConnected)
    }
}
