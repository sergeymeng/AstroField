import XCTest
@testable import AstroFieldKit

final class SessionStackerTests: XCTestCase {
    private func starImage(width: Int, height: Int,
                           stars: [(x: Double, y: Double, flux: Double, sigma: Double)],
                           background: Float = 1_000, noise: Double = 2,
                           seed: UInt64 = 5) -> LumaImage {
        var pixels = [Float](repeating: background, count: width * height)
        for star in stars {
            let radius = Int(ceil(5 * star.sigma))
            let x0 = max(0, Int(star.x) - radius), x1 = min(width - 1, Int(star.x) + radius)
            let y0 = max(0, Int(star.y) - radius), y1 = min(height - 1, Int(star.y) + radius)
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - star.x
                    let dy = Double(y) - star.y
                    let v = star.flux * exp(-(dx * dx + dy * dy) / (2 * star.sigma * star.sigma))
                    pixels[y * width + x] += Float(v)
                }
            }
        }
        var rng = SeededRandom(seed: seed)
        for i in pixels.indices {
            pixels[i] = min(65535, max(0, pixels[i] + Float(rng.gaussian() * noise)))
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    func testStackAcceptsShiftedFramesAndRejectsStarless() {
        let stars: [(x: Double, y: Double, flux: Double, sigma: Double)] = [
            (60, 60, 9_000, 1.8), (160, 80, 12_000, 1.8), (260, 60, 8_000, 1.8),
            (90, 180, 7_000, 1.8), (200, 200, 11_000, 1.8), (300, 150, 9_000, 1.8),
            (140, 120, 6_000, 1.8), (280, 220, 5_000, 1.8)
        ]
        let reference = starImage(width: 340, height: 260, stars: stars, noise: 1, seed: 3)
        let shifted = starImage(width: 340, height: 260,
                                stars: stars.map { ($0.x + 7, $0.y - 4, $0.flux, $0.sigma) },
                                noise: 1, seed: 4)
        let starless = starImage(width: 340, height: 260, stars: [], noise: 1, seed: 5)

        let stacker = SessionStacker(maxWidth: 340)
        XCTAssertTrue(stacker.add(reference))
        XCTAssertTrue(stacker.add(shifted))
        XCTAssertFalse(stacker.add(starless))
        guard let result = stacker.result() else {
            return XCTFail("expected a stack result")
        }
        XCTAssertEqual(result.summary.total, 3)
        XCTAssertEqual(result.summary.accepted, 2)
        XCTAssertEqual(result.summary.rejected, 1)
        XCTAssertGreaterThan(result.summary.coverage, 0.9)
        XCTAssertTrue(result.summary.reasonText.contains(L10n.text("星点不足，未参与叠加")),
                      result.summary.reasonText)
        XCTAssertEqual(result.image.width, 340)
        XCTAssertEqual(result.image.height, 260)
    }

    func testResultIsNilBeforeReference() {
        let stacker = SessionStacker(maxWidth: 200)
        XCTAssertNil(stacker.result())
        XCTAssertFalse(stacker.hasReference)
    }
}
