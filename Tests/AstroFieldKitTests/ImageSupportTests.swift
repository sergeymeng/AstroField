import XCTest
import CoreGraphics
@testable import AstroFieldKit

final class ImageSupportTests: XCTestCase {
    private func starImage(width: Int, height: Int,
                           stars: [(x: Double, y: Double, flux: Double, sigma: Double)],
                           background: Float = 1000, noise: Double = 2,
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
        for i in pixels.indices { pixels[i] = min(65535, max(0, pixels[i] + Float(rng.gaussian() * noise))) }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    func testStarDetectionAndFWHM() {
        let image = starImage(width: 300, height: 200, stars: [
            (60, 50, 6000, 2.0), (150, 70, 8000, 2.0), (230, 40, 5000, 2.0),
            (80, 140, 7000, 2.0), (180, 150, 9000, 2.0), (250, 120, 4000, 2.0)
        ])
        let stars = StarDetector.detect(in: image)
        XCTAssertGreaterThanOrEqual(stars.count, 5)
        let measurement = StarDetector.measure(in: image)
        XCTAssertEqual(measurement.medianFWHM, 2.3548 * 2.0, accuracy: 0.8)
        XCTAssertGreaterThan(measurement.starCount, 4)
    }

    func testDetectorSeparatesSaturation() {
        let image = starImage(width: 200, height: 150, stars: [
            (50, 50, 200000, 2.0), (120, 80, 5000, 2.0), (160, 120, 6000, 2.0)
        ], noise: 1)
        let stars = StarDetector.detect(in: image)
        XCTAssertTrue(stars.contains { $0.saturated })
        let measurement = StarDetector.measure(in: image)
        XCTAssertGreaterThanOrEqual(measurement.starCount, 1)
        XCTAssertLessThanOrEqual(measurement.starCount, stars.count)
    }

    func testLumaDisplayAndRange() {
        let image = starImage(width: 120, height: 80, stars: [(60, 40, 9000, 2)])
        let range = image.autoRange()
        XCTAssertLessThan(range.low, range.high)
        let preview = image.displayImage()
        XCTAssertEqual(preview?.width, 120)
        XCTAssertEqual(preview?.height, 80)
        let downsample = image.downsampled(maxWidth: 60)
        XCTAssertEqual(downsample.width, 60)
        XCTAssertEqual(downsample.height, 40)
        let crop = image.cropped(x: 10, y: 10, width: 40, height: 30)
        XCTAssertEqual(crop?.width, 40)
        XCTAssertNil(image.cropped(x: 100, y: 0, width: 40, height: 30))
    }

    func testLiveStackerAlignsTranslation() {
        let stars: [(x: Double, y: Double, flux: Double, sigma: Double)] = [
            (60, 60, 9000, 1.8), (160, 80, 12000, 1.8), (260, 60, 8000, 1.8),
            (90, 180, 7000, 1.8), (200, 200, 11000, 1.8), (300, 150, 9000, 1.8),
            (140, 120, 6000, 1.8), (280, 220, 5000, 1.8)
        ]
        let reference = starImage(width: 340, height: 260, stars: stars, noise: 1, seed: 3)
        let shiftedStars = stars.map { (x: $0.x + 7, y: $0.y - 4, flux: $0.flux, sigma: $0.sigma) }
        let shifted = starImage(width: 340, height: 260, stars: shiftedStars, noise: 1, seed: 4)

        let stacker = LiveStacker(reference: reference, maxWidth: 340)
        let update = stacker.add(shifted)
        XCTAssertTrue(update.accepted, update.reason ?? "")
        XCTAssertLessThanOrEqual(abs((update.shift?.dx ?? 0) - 7), 2)
        XCTAssertLessThanOrEqual(abs((update.shift?.dy ?? 0) + 4), 2)
        XCTAssertEqual(update.acceptedCount, 2)
        XCTAssertGreaterThan(update.coverage, 0.9)
        XCTAssertNotNil(update.preview)

        let empty = starImage(width: 340, height: 260, stars: [], noise: 1, seed: 5)
        let rejected = stacker.add(empty)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.rejectedCount, 1)
    }


    func testFrameAnalyzerFastMetrics() {
        let image = starImage(width: 320, height: 240, stars: [
            (60, 50, 6000, 2.0), (150, 70, 8000, 2.0), (230, 40, 5000, 2.0),
            (80, 160, 7000, 2.0), (200, 180, 9000, 2.0)
        ])
        let metrics = FrameAnalyzer.metrics(image)
        XCTAssertGreaterThanOrEqual(metrics.starCount, 4)
        XCTAssertEqual(metrics.medianFWHM, 2.3548 * 2.0, accuracy: 1.0)
        XCTAssertEqual(metrics.background, 1000, accuracy: 30)
        XCTAssertLessThan(metrics.saturatedFraction, 0.01)
    }

    func testFastMeasurementMatchesDetector() {
        let image = starImage(width: 300, height: 220, stars: [
            (60, 50, 6000, 2.0), (150, 80, 8000, 2.2), (230, 60, 5000, 1.9),
            (90, 160, 7000, 2.1), (210, 170, 9000, 2.0)
        ])
        let slow = StarDetector.measure(in: image)
        let fast = StarDetector.measureFast(in: image)
        XCTAssertGreaterThanOrEqual(fast.starCount, 3)
        XCTAssertEqual(fast.medianFWHM, slow.medianFWHM, accuracy: 1.2)
    }

    func testMaxPoolPreservesStars() {
        var pixels = [Float](repeating: 100, count: 120 * 80)
        pixels[40 * 120 + 30] = 50000
        let image = LumaImage(width: 120, height: 80, pixels: pixels)
        let pooled = image.downsampledMax(maxWidth: 20)
        XCTAssertEqual(pooled.width, 20)
        XCTAssertEqual(pooled.pixels.max() ?? 0, 50000)
        let averaged = image.downsampled(maxWidth: 20)
        XCTAssertLessThan(averaged.pixels.max() ?? 0, 50000)
    }

    func testMeteorDetectorFindsStreak() {
        var pixels = [Float](repeating: 1000, count: 400 * 300)
        for x in 40...300 {
            let y = 60 + Int(Double(x - 40) * 40.0 / 260.0)
            for dy in -1...1 {
                let index = (y + dy) * 400 + x
                if index >= 0 && index < pixels.count { pixels[index] = 12000 }
            }
        }
        var rng = SeededRandom(seed: 9)
        for i in pixels.indices { pixels[i] += Float(rng.gaussian() * 2) }
        let image = LumaImage(width: 400, height: 300, pixels: pixels)
        let candidates = MeteorDetector.detect(in: image, minLength: 60)
        XCTAssertGreaterThanOrEqual(candidates.count, 1)
        XCTAssertGreaterThan(candidates[0].aspect, 3)
        XCTAssertGreaterThan(candidates[0].length, 100)
    }

    func testMeteorDetectorIgnoresStars() {
        let image = starImage(width: 320, height: 240, stars: [
            (60, 50, 6000, 2.0), (150, 70, 8000, 2.0), (230, 40, 5000, 2.0),
            (80, 160, 7000, 2.0), (200, 180, 9000, 2.0)
        ])
        let candidates = MeteorDetector.detect(in: image)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testLensProfileStoreRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldLens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LensProfileStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)
        let trial = TrialRecord(label: "f/2.8", exposureSeconds: 10, aperture: 2.8,
                                medianFWHM: 2.4, starCount: 40,
                                saturatedFraction: 0.001, eccentricity: 0.12)
        let entries = store.add(lensName: "SIM 35mm", cameraModel: "Simulator",
                                iso: 1600, note: "test", trials: [trial])
        XCTAssertEqual(entries.count, 1)
        let loaded = store.load()
        XCTAssertEqual(loaded.first?.lensName, "SIM 35mm")
        XCTAssertEqual(loaded.first?.trials.first?.medianFWHM, 2.4)
    }

    func testStarTrailAccumulatorMaxBlendAndGaps() {
        var first = [Float](repeating: 100, count: 100 * 80)
        first[20 * 100 + 30] = 50000
        var second = [Float](repeating: 100, count: 100 * 80)
        second[50 * 100 + 70] = 60000
        let imageA = LumaImage(width: 100, height: 80, pixels: first)
        let imageB = LumaImage(width: 100, height: 80, pixels: second)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let stacker = StarTrailStacker(reference: imageA,
                                       referenceExposure: 1,
                                       referenceTimestamp: t0,
                                       maxWidth: 100)
        stacker.gapTolerance = 1.0
        let update = stacker.add(imageB, exposureSeconds: 2, timestamp: t0.addingTimeInterval(5))
        XCTAssertTrue(update.accepted)
        XCTAssertEqual(update.frames, 2)
        XCTAssertEqual(update.totalExposure, 3, accuracy: 0.001)
        XCTAssertEqual(update.gapCount, 1)
        XCTAssertEqual(update.maxGap, 5, accuracy: 0.001)
        let current = stacker.current()
        XCTAssertEqual(current?.pixels[20 * 100 + 30], 50000)
        XCTAssertEqual(current?.pixels[50 * 100 + 70], 60000)
    }

    func testStarTrailRejectsSizeMismatch() {
        let image = starImage(width: 80, height: 60, stars: [])
        let other = LumaImage(width: 40, height: 30,
                              pixels: [Float](repeating: 0, count: 1200))
        let stacker = StarTrailStacker(reference: image, maxWidth: 80)
        let update = stacker.add(other, exposureSeconds: 1)
        XCTAssertFalse(update.accepted)
        XCTAssertEqual(update.rejected, 1)
    }

    func testPresetStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldPreset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PresetStore(directory: dir)
        XCTAssertTrue(store.load().isEmpty)

        var plan = CapturePlan()
        plan.iso = 3200
        plan.end = .count(25)
        let presets = store.upsert(name: "银河 25 张", plan: plan)
        XCTAssertEqual(presets.count, 1)
        store.saveLastPlan(plan)

        XCTAssertEqual(store.load().first?.name, "银河 25 张")
        XCTAssertEqual(store.lastPlan()?.iso, 3200)
        XCTAssertEqual(store.lastPlan()?.end, .count(25))

        let remaining = store.delete(id: presets[0].id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNotNil(store.lastPlan())
    }

    func testPlaybackSamplesAndLoader() async throws {
        let playback = PlaybackCamera()
        playback.simulateTiming = false
        try await playback.connect()
        XCTAssertTrue(playback.status.capabilities.contains(.stillCapture))
        let record = try await playback.capture(sequence: 0)
        guard let url = record.fileURL else {
            return XCTFail("playback should return a file URL")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(record.width, 1600)
        XCTAssertEqual(record.height, 1067)

        let luma = ImageLoader.luma(url: url, maxWidth: 400)
        XCTAssertNotNil(luma)
        XCTAssertEqual(luma?.width, 400)
        XCTAssertNotNil(ImageLoader.preview(url: url, maxWidth: 400))
        await playback.disconnect()
    }

    func testPlaybackRefusesLensActions() async throws {
        let playback = PlaybackCamera()
        playback.simulateTiming = false
        try await playback.connect()
        do {
            try await playback.focusDrive(direction: .one, steps: 5)
            XCTFail("playback must not claim focus support")
        } catch {
            XCTAssertTrue(error is CameraError)
        }
    }
}
