import XCTest
import AFSpikeCore
@testable import AstroFieldKit

final class QualityEngineTests: XCTestCase {
    private func metrics(fwhm: Double, stars: Int = 30, background: Double = 1000) -> FrameMetrics {
        FrameMetrics(starCount: stars, background: background, noise: 20,
                     medianFWHM: fwhm, medianEccentricity: 0.1,
                     saturatedFraction: 0)
    }

    func testBaselineThenAccepts() {
        var engine = QualityEngine()
        let first = engine.observe(metrics(fwhm: 3.0))
        XCTAssertEqual(first.verdict, .accepted)
        XCTAssertEqual(first.action, .none)
        let second = engine.observe(metrics(fwhm: 3.1))
        XCTAssertEqual(second.verdict, .accepted)
    }

    func testBackgroundChangeIsNotRefocusEvidence() {
        var engine = QualityEngine()
        _ = engine.observe(metrics(fwhm: 3.0))
        let result = engine.observe(metrics(fwhm: 4.5, background: 2200))
        if case .warning(let text) = result.verdict {
            XCTAssertTrue(text.contains("背景"))
        } else {
            XCTFail("expected background warning")
        }
        if case .notice = result.action {} else { XCTFail("expected notice, not refocus") }
    }

    func testLargeFWHMTriggersLimitedRefocus() {
        var engine = QualityEngine()
        engine.maxRefocusSuggestions = 2
        _ = engine.observe(metrics(fwhm: 3.0))
        let first = engine.observe(metrics(fwhm: 5.0))
        if case .suggestRefocus = first.action {} else { XCTFail("expected refocus suggestion") }
        let second = engine.observe(metrics(fwhm: 5.0))
        if case .suggestRefocus = second.action {} else { XCTFail("expected second suggestion") }
        let third = engine.observe(metrics(fwhm: 5.0))
        if case .notice = third.action {} else { XCTFail("expected limit notice") }
    }

    func testFewStarsIsUnmeasured() {
        var engine = QualityEngine()
        let result = engine.observe(metrics(fwhm: 3.0, stars: 2))
        if case .unmeasured = result.verdict {} else { XCTFail("expected unmeasured") }
        XCTAssertEqual(result.action, .none)
        XCTAssertNil(engine.baseline)
    }

    func testMildIncreaseIsNotice() {
        var engine = QualityEngine()
        _ = engine.observe(metrics(fwhm: 3.0))
        let result = engine.observe(metrics(fwhm: 3.9))
        if case .warning = result.verdict {} else { XCTFail("expected warning") }
        if case .notice = result.action {} else { XCTFail("expected notice") }
    }
}
