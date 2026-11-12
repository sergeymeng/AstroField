import XCTest
@testable import AstroFieldKit

final class FocusSearcherTests: XCTestCase {
    final class CurveProbe: FocusProbe, @unchecked Sendable {
        var position: Double = 0
        let best: Double
        let slopeBelow: Double
        let slopeAbove: Double
        var seed: UInt64 = 11
        private let lock = NSLock()

        init(best: Double, slopeBelow: Double = 0.012, slopeAbove: Double = 0.020) {
            self.best = best
            self.slopeBelow = slopeBelow
            self.slopeAbove = slopeAbove
        }

        func move(signedSteps: Int) async throws {
            lock.lock()
            position += Double(signedSteps)
            lock.unlock()
        }

        func measure() async throws -> FocusMeasurement {
            lock.lock()
            let pos = position
            seed &+= 1
            var rng = SeededRandom(seed: seed)
            lock.unlock()
            let delta = pos - best
            let slope = delta < 0 ? slopeBelow : slopeAbove
            let fwhm = 2.0 + abs(delta) * slope + abs(rng.gaussian()) * 0.008
            return FocusMeasurement(medianFWHM: fwhm, starCount: 24, medianEccentricity: 0.12)
        }
    }

    func testFindsKnownFocusToTheRight() async {
        let probe = CurveProbe(best: 120)
        let searcher = FocusSearcher()
        let result = await searcher.run(probe: probe, config: .init())
        XCTAssertEqual(result.status, .confirmed)
        let position = result.bestRelativeSteps ?? 0
        XCTAssertEqual(position, 120, accuracy: 14)
        XCTAssertGreaterThan(result.samples.count, 6)
        XCTAssertGreaterThan(result.confidence, 0.2)
    }

    func testFindsKnownFocusToTheLeft() async {
        let probe = CurveProbe(best: -150)
        let searcher = FocusSearcher()
        let result = await searcher.run(probe: probe, config: .init())
        XCTAssertEqual(result.status, .confirmed)
        let position = result.bestRelativeSteps ?? 0
        XCTAssertEqual(position, -150, accuracy: 18)
    }

    func testNoStarsIsUnconfirmed() async {
        let probe = ClosureFocusProbe(
            measure: { FocusMeasurement(medianFWHM: 0, starCount: 0, medianEccentricity: 0) },
            move: { _ in })
        let result = await FocusSearcher().run(probe: probe)
        XCTAssertEqual(result.status, .unconfirmed)
        XCTAssertTrue(result.message.contains("星点不足"))
    }

    func testCancellation() async {
        let counter = CallCounter()
        let probe = CurveProbe(best: 300)
        let result = await FocusSearcher().run(
            probe: probe,
            config: .init(),
            shouldCancel: { counter.bump() > 3 })
        XCTAssertEqual(result.status, .cancelled)
    }

    func testFlatCurveIsNotConfirmed() async {
        let probe = ClosureFocusProbe(
            measure: { FocusMeasurement(medianFWHM: 3.0, starCount: 30, medianEccentricity: 0.1) },
            move: { _ in })
        let result = await FocusSearcher().run(probe: probe, config: .init())
        XCTAssertEqual(result.status, .unconfirmed)
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
