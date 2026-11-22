import XCTest
@testable import AstroFieldKit

final class PSFFitTests: XCTestCase {
    /// Pixel-integrated Gaussian star field: each pixel holds the integral of
    /// the PSF over its area, matching what a sensor actually records.
    private func integratedStarField(width: Int, height: Int,
                                     stars: [(x: Double, y: Double, flux: Double)],
                                     sigma: Double,
                                     background: Float = 1_000,
                                     noise: Double = 2,
                                     seed: UInt64 = 7) -> LumaImage {
        var pixels = [Float](repeating: background, count: width * height)
        let inv = 1.0 / (sqrt(2.0) * sigma)
        for star in stars {
            let radius = Int(ceil(5 * sigma)) + 1
            let x0 = max(0, Int(star.x) - radius), x1 = min(width - 1, Int(star.x) + radius)
            let y0 = max(0, Int(star.y) - radius), y1 = min(height - 1, Int(star.y) + radius)
            if x0 > x1 || y0 > y1 { continue }
            for y in y0...y1 {
                let iy = 0.5 * (erf((Double(y) + 0.5 - star.y) * inv)
                                - erf((Double(y) - 0.5 - star.y) * inv))
                for x in x0...x1 {
                    let ix = 0.5 * (erf((Double(x) + 0.5 - star.x) * inv)
                                    - erf((Double(x) - 0.5 - star.x) * inv))
                    pixels[y * width + x] += Float(star.flux * ix * iy)
                }
            }
        }
        var rng = SeededRandom(seed: seed)
        for i in pixels.indices {
            pixels[i] = min(65535, max(0, pixels[i] + Float(rng.gaussian() * noise)))
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    func testPixelIntegratedFitBeatsMomentsOnUndersampledStars() {
        let sigma = 1.0
        let expected = 2.3548 * sigma
        let stars: [(x: Double, y: Double, flux: Double)] = [
            (40, 40, 20_000), (120, 50, 24_000), (200, 42, 18_000),
            (60, 120, 22_000), (150, 130, 26_000), (230, 120, 20_000),
            (90, 190, 24_000), (190, 200, 18_000)
        ]
        let image = integratedStarField(width: 300, height: 240, stars: stars, sigma: sigma)
        let detected = StarDetector.detect(in: image).filter { !$0.saturated }
        XCTAssertGreaterThanOrEqual(detected.count, 6)
        let momentMedian = median(detected.map { $0.fwhm })
        let measured = StarDetector.measure(in: image)
        XCTAssertGreaterThanOrEqual(measured.starCount, 6)
        let fitMedian = measured.medianFWHM
        let momentError = abs(momentMedian - expected)
        let fitError = abs(fitMedian - expected)
        print("sigma", sigma, "expected", expected,
              "moments", momentMedian, "fit", fitMedian)
        XCTAssertLessThan(fitError, momentError,
                          "pixel-integrated fit should beat second moments")
        XCTAssertEqual(fitMedian, expected, accuracy: 0.25)
    }

    func testPixelIntegratedFitOnWellSampledStars() {
        let sigma = 2.5
        let expected = 2.3548 * sigma
        let stars: [(x: Double, y: Double, flux: Double)] = [
            (50, 50, 60_000), (140, 60, 70_000), (220, 55, 55_000),
            (80, 150, 65_000), (180, 160, 75_000)
        ]
        let image = integratedStarField(width: 300, height: 240, stars: stars,
                                        sigma: sigma, noise: 3)
        let measured = StarDetector.measure(in: image)
        XCTAssertEqual(measured.medianFWHM, expected, accuracy: 0.2)
    }
}
