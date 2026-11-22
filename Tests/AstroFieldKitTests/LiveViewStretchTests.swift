import XCTest
import CoreGraphics
import ImageIO
@testable import AstroFieldKit

final class LiveViewStretchTests: XCTestCase {
    /// Builds an 8-bit grayscale image with a noisy background and Gaussian stars.
    private func syntheticFrame(width: Int = 320, height: Int = 240,
                                background: Double = 20,
                                noiseSigma: Double = 2,
                                stars: [(x: Double, y: Double, peak: Double, sigma: Double)] = [])
        -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var rng = SeededRandom(seed: 7)
        for y in 0..<height {
            for x in 0..<width {
                var value = background + noiseSigma * rng.gaussian()
                for star in stars {
                    let dx = Double(x) - star.x
                    let dy = Double(y) - star.y
                    let r2 = dx * dx + dy * dy
                    value += star.peak * exp(-r2 / (2 * star.sigma * star.sigma))
                }
                pixels[y * width + x] = UInt8(min(255, max(0, value.rounded())))
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func pixels(of image: CGImage) -> [Float]? {
        LumaImage.from(cgImage: image)?.pixels
    }

    func testDarkFrameBackgroundGoesBlackAndStarsStayVisible() throws {
        let starX = 160.0, starY = 120.0
        let frame = try XCTUnwrap(syntheticFrame(stars: [(starX, starY, 90, 1.2)]))
        let result = try XCTUnwrap(LiveViewStretch.stretch(frame, settings: .default))
        let out = try XCTUnwrap(pixels(of: result.image))
        XCTAssertEqual(out.count, 320 * 240)

        var background: [Float] = []
        for y in 10..<50 {
            for x in 10..<60 { background.append(out[y * 320 + x]) }
        }
        background.sort()
        // LumaImage.from re-expands the 8-bit display frame into 16-bit values.
        let backgroundMedian = background[background.count / 2] / 257
        XCTAssertLessThan(backgroundMedian, 12, "median background should map near black")

        let starPixel = out[120 * 320 + 160] / 257
        XCTAssertGreaterThan(starPixel, backgroundMedian + 60,
                             "star core should stand far above the stretched background")

        XCTAssertEqual(result.stats.median, 20, accuracy: 3)
        XCTAssertGreaterThan(result.stats.sigma, 0.5)
        XCTAssertGreaterThan(result.stats.high, result.stats.low)
    }

    func testDisabledReturnsNoDisplayImage() throws {
        let frame = try XCTUnwrap(syntheticFrame(stars: [(100, 100, 80, 1.0)]))
        var settings = LiveViewStretchSettings.default
        settings.enabled = false
        XCTAssertNil(LiveViewStretch.stretch(frame, settings: settings))
    }

    func testHigherGainRaisesStarContrast() throws {
        let frame = try XCTUnwrap(syntheticFrame(stars: [(160, 120, 25, 1.2)]))
        var highGain = LiveViewStretchSettings.default
        highGain.gainSigma = 8      // more aggressive stretch
        var lowGain = LiveViewStretchSettings.default
        lowGain.gainSigma = 40      // more headroom
        let highOut = try XCTUnwrap(LiveViewStretch.stretch(frame, settings: highGain))
        let lowOut = try XCTUnwrap(LiveViewStretch.stretch(frame, settings: lowGain))
        let high = try XCTUnwrap(pixels(of: highOut.image))
        let low = try XCTUnwrap(pixels(of: lowOut.image))
        let index = 120 * 320 + 160
        XCTAssertGreaterThan(high[index] - high[10 * 320 + 10],
                             low[index] - low[10 * 320 + 10],
                             "higher display gain should increase star contrast")
    }

    func testStretchDoesNotMutateMeasurementFrame() throws {
        let frame = try XCTUnwrap(syntheticFrame(stars: [(120, 90, 80, 1.0)]))
        let before = try XCTUnwrap(pixels(of: frame))
        _ = LiveViewStretch.stretch(frame, settings: .default)
        let after = try XCTUnwrap(pixels(of: frame))
        XCTAssertEqual(before, after)
    }

    func testStretchKeeps1024x680FrameUnderBudget() throws {
        let frame = try XCTUnwrap(syntheticFrame(width: 1024, height: 680,
                                                 stars: [(500, 340, 80, 1.2)]))
        // Warm up once, then measure. The display path targets 15 fps on Nikon;
        // the stretch alone must stay well inside one 66 ms frame.
        _ = LiveViewStretch.stretch(frame, settings: .default)
        let start = Date()
        let iterations = 5
        for _ in 0..<iterations {
            XCTAssertNotNil(LiveViewStretch.stretch(frame, settings: .default))
        }
        let average = Date().timeIntervalSince(start) / Double(iterations)
        #if DEBUG
        // Debug builds run the pixel loops unoptimized; the app ships release.
        let budget = 0.090
        #else
        let budget = 0.040
        #endif
        XCTAssertLessThan(average, budget,
                          "stretch averaged \(Int(average * 1000)) ms per 1024x680 frame")
    }

    /// Local hardware sample from the Z7 II LiveView run. Skipped when the
    /// machine does not have logs/hw-z7ii (the logs are not committed).
    func testRealNikonLiveViewFrameBudget() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent("logs/hw-z7ii/icclv/icc_000213.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no local Nikon LiveView sample")
        }
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(ImageLoader.cgImage(fromJPEG: data))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 680)
        _ = LiveViewStretch.stretch(image, settings: .default)
        let start = Date()
        let iterations = 5
        for _ in 0..<iterations {
            XCTAssertNotNil(LiveViewStretch.stretch(image, settings: .default))
        }
        let average = Date().timeIntervalSince(start) / Double(iterations)
        #if DEBUG
        let budget = 0.090
        #else
        let budget = 0.040
        #endif
        XCTAssertLessThan(average, budget,
                          "real JPEG stretch averaged \(Int(average * 1000)) ms")
    }

    /// Diagnostic: ASTROFIELD_STRETCH_OUT=/tmp/out.png writes the stretched
    /// hardware sample for visual inspection. Skipped by default.
    func testWriteStretchPreviewWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["ASTROFIELD_STRETCH_OUT"] else {
            throw XCTSkip("ASTROFIELD_STRETCH_OUT not set")
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent("logs/hw-z7ii/icclv/icc_000213.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no local Nikon LiveView sample")
        }
        let image = try XCTUnwrap(ImageLoader.cgImage(fromJPEG: Data(contentsOf: url)))
        let result = try XCTUnwrap(LiveViewStretch.stretch(image, settings: .default))
        let outputURL = URL(fileURLWithPath: output)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            outputURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, result.image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
