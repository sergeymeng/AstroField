import XCTest
@testable import AstroFieldKit

final class SmokeTests: XCTestCase {
    func testPlanSummary() {
        var plan = CapturePlan()
        plan.start = .delay(seconds: 10)
        plan.exposureSeconds = 15
        plan.interval = .fixedStart(seconds: 20)
        plan.end = .count(3)
        XCTAssertTrue(plan.summary.contains("10 秒后开始"))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let times = ScheduleCalculator.theoreticalStartTimes(plan: plan, now: start)
        XCTAssertEqual(times.count, 3)
        XCTAssertEqual(times[1].timeIntervalSince(times[0]), 20, accuracy: 0.001)
    }
}
