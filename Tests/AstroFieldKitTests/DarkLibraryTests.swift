import XCTest
@testable import AstroFieldKit

final class DarkLibraryTests: XCTestCase {
    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldDarks-\(UUID().uuidString)", isDirectory: true)
    }

    private func constantImage(width: Int, height: Int, value: Float) -> LumaImage {
        LumaImage(width: width, height: height,
                  pixels: [Float](repeating: value, count: width * height))
    }

    private func buildDark(values: [Float], width: Int, height: Int,
                           settings: ExposureSettings,
                           createdAt: Date = Date(),
                           source: ImageSource = .simulator) throws -> MasterDark {
        let accumulator = DarkAccumulator()
        for value in values {
            try accumulator.add(constantImage(width: width, height: height, value: value),
                                settings: settings)
        }
        return try XCTUnwrap(accumulator.build(settings: settings,
                                               createdAt: createdAt,
                                               source: source))
    }

    // MARK: - Accumulator

    func testDarkAccumulatorAveragesFrames() throws {
        let accumulator = DarkAccumulator()
        let settings = ExposureSettings(iso: 800, exposureSeconds: 4, aperture: 2.8)
        let width = 40
        let height = 30
        for value: Float in [10, 20, 60] {
            var pixels = [Float](repeating: value, count: width * height)
            pixels[17] = 5000
            try accumulator.add(LumaImage(width: width, height: height, pixels: pixels),
                                settings: settings)
        }
        XCTAssertEqual(accumulator.frameCount, 3)
        XCTAssertEqual(accumulator.frameWidth, width)
        XCTAssertEqual(accumulator.frameHeight, height)
        XCTAssertEqual(accumulator.recordedSettings, settings)

        let master = try XCTUnwrap(accumulator.build(settings: settings))
        XCTAssertEqual(master.meta.frameCount, 3)
        XCTAssertEqual(master.meta.width, width)
        XCTAssertEqual(master.meta.height, height)
        XCTAssertEqual(master.meta.iso, 800)
        XCTAssertEqual(master.meta.exposureSeconds, 4, accuracy: 1e-9)
        XCTAssertEqual(master.meta.source, .simulator)
        XCTAssertEqual(master.pixels[0], 30, accuracy: 1e-5)          // (10 + 20 + 60) / 3
        XCTAssertEqual(master.pixels[17], 5000, accuracy: 1e-5)       // fixed hot pixel
        let expectedMean = (30 * Float(width * height - 1) + 5000) / Float(width * height)
        XCTAssertEqual(master.meta.meanLevel, expectedMean, accuracy: 0.01)
        XCTAssertEqual(master.meta.hotPixelCount, 1)
    }

    func testDarkAccumulatorRejectsMismatchesAndEmptyBuild() throws {
        let accumulator = DarkAccumulator()
        let settings = ExposureSettings(iso: 800, exposureSeconds: 1, aperture: 2.8)
        XCTAssertNil(accumulator.build(settings: settings))
        XCTAssertEqual(accumulator.frameCount, 0)
        XCTAssertNil(accumulator.frameWidth)
        XCTAssertNil(accumulator.recordedSettings)

        try accumulator.add(constantImage(width: 20, height: 10, value: 1), settings: settings)
        XCTAssertThrowsError(try accumulator.add(constantImage(width: 10, height: 10, value: 1))) { error in
            guard case DarkLibraryError.frameSizeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try accumulator.add(constantImage(width: 20, height: 10, value: 2),
                                                 settings: ExposureSettings(iso: 1600,
                                                                            exposureSeconds: 1))) { error in
            guard case DarkLibraryError.settingsMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(accumulator.frameCount, 1)
        // Building with settings other than the recorded ones is refused.
        XCTAssertNil(accumulator.build(settings: ExposureSettings(iso: 1600, exposureSeconds: 1)))
        XCTAssertNotNil(accumulator.build(settings: settings))
    }

    // MARK: - Library

    func testDarkLibraryRoundTripMatchAndDelete() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DarkLibrary(directory: directory)
        XCTAssertTrue(library.all().isEmpty)

        let settings = ExposureSettings(iso: 1600, exposureSeconds: 10, aperture: 2.8)
        let built = try buildDark(values: [100, 120], width: 60, height: 40,
                                  settings: settings,
                                  createdAt: Date(timeIntervalSince1970: 1_000))
        let saved = try library.save(built)
        XCTAssertEqual(saved.fileName, "\(saved.id.uuidString).darkbin")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(saved.fileName).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("index.json").path))
        XCTAssertEqual(library.all(), [saved])

        // Matching: ISO must be exact, exposure within 10 %, source must agree.
        XCTAssertEqual(library.match(iso: 1600, exposureSeconds: 10, source: .simulator,
                                     width: 60, height: 40)?.id, saved.id)
        XCTAssertEqual(library.match(iso: 1600, exposureSeconds: 11,
                                     source: .simulator)?.id, saved.id)
        XCTAssertNil(library.match(iso: 3200, exposureSeconds: 10, source: .simulator))
        XCTAssertNil(library.match(iso: 1600, exposureSeconds: 8, source: .simulator))
        XCTAssertNil(library.match(iso: 1600, exposureSeconds: 12.5, source: .simulator))
        XCTAssertNil(library.match(iso: 1600, exposureSeconds: 10, source: .nikon))
        XCTAssertNil(library.match(iso: 1600, exposureSeconds: 10, source: .playback))

        let loaded = try XCTUnwrap(library.load(id: saved.id))
        XCTAssertEqual(loaded.meta.id, saved.id)
        XCTAssertEqual(loaded.meta.hotPixelCount, saved.hotPixelCount)
        XCTAssertEqual(loaded.pixels.count, 60 * 40)
        XCTAssertEqual(loaded.pixels[0], 110, accuracy: 0.001)

        XCTAssertTrue(library.delete(id: saved.id))
        XCTAssertTrue(library.all().isEmpty)
        XCTAssertNil(library.load(id: saved.id))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(saved.fileName).path))
        XCTAssertFalse(library.delete(id: saved.id))
    }

    func testDarkLibrarySortsNewestFirstAndPrefersSameSize() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DarkLibrary(directory: directory)
        let settings = ExposureSettings(iso: 800, exposureSeconds: 5)
        let older = try buildDark(values: [10], width: 40, height: 20, settings: settings,
                                  createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = try buildDark(values: [20], width: 40, height: 20, settings: settings,
                                  createdAt: Date(timeIntervalSince1970: 2_000))
        let small = try buildDark(values: [30], width: 20, height: 10, settings: settings,
                                  createdAt: Date(timeIntervalSince1970: 3_000))
        try library.save(older)
        try library.save(newer)
        try library.save(small)

        XCTAssertEqual(library.all().map(\.id),
                       [small.meta.id, newer.meta.id, older.meta.id])
        // A same-size master beats a newer one that would need resampling.
        XCTAssertEqual(library.match(iso: 800, exposureSeconds: 5, source: .simulator,
                                     width: 40, height: 20)?.id, newer.meta.id)
        // Without a size the newest compatible master wins.
        XCTAssertEqual(library.match(iso: 800, exposureSeconds: 5,
                                     source: .simulator)?.id, small.meta.id)
        // Sorting is stable across calls.
        XCTAssertEqual(library.all(), library.all())
    }

    func testDarkLibraryCreatesDirectoryOnDemand() throws {
        let root = temporaryDirectory()
        let directory = root.appendingPathComponent("nested/Darks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DarkLibrary(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        try FileManager.default.removeItem(at: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let settings = ExposureSettings(iso: 400, exposureSeconds: 1)
        let dark = try buildDark(values: [3], width: 8, height: 6, settings: settings)
        let saved = try library.save(dark)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(saved.fileName).path))
    }

    func testDarkLibraryRejectsCorruptIndex() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DarkLibrary(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexURL = directory.appendingPathComponent("index.json")
        let garbage = Data("not a dark index".utf8)
        try garbage.write(to: indexURL)

        let settings = ExposureSettings(iso: 800, exposureSeconds: 2)
        let dark = try buildDark(values: [5], width: 20, height: 10, settings: settings)
        XCTAssertThrowsError(try library.save(dark)) { error in
            guard case DarkLibraryError.indexCorrupted = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        // The corrupt index is preserved instead of being replaced by an empty one.
        XCTAssertEqual(try Data(contentsOf: indexURL), garbage)
        XCTAssertTrue(library.all().isEmpty)
        XCTAssertNil(library.match(iso: 800, exposureSeconds: 2, source: .simulator))
    }

    func testDarkLibraryLoadRejectsTruncatedFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DarkLibrary(directory: directory)
        let settings = ExposureSettings(iso: 800, exposureSeconds: 1)
        let dark = try buildDark(values: [5], width: 10, height: 8, settings: settings)
        let saved = try library.save(dark)
        let fileURL = directory.appendingPathComponent(saved.fileName)
        let full = try Data(contentsOf: fileURL)
        XCTAssertGreaterThan(full.count, 20)
        try full.prefix(20).write(to: fileURL)
        XCTAssertNil(library.load(id: saved.id))
        XCTAssertNil(library.load(meta: saved))
    }

    func testDegenerateDecodedDarkIsMarkedUnusableAndNotMatched() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldDark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = DarkLibrary(directory: dir)
        let settings = ExposureSettings(iso: 800, exposureSeconds: 1, aperture: 2.8)
        // Core Image NEF decode of a dark frame can collapse to two levels:
        // most pixels clipped to zero, a quarter at a high plateau.
        var pixels = [Float](repeating: 0, count: 100 * 60)
        for y in 0..<15 {
            for x in 0..<100 { pixels[y * 100 + x] = 30_000 }
        }
        let frame = LumaImage(width: 100, height: 60, pixels: pixels)
        let accumulator = DarkAccumulator()
        try accumulator.add(frame, settings: settings)
        let master = try XCTUnwrap(accumulator.build(settings: settings, source: .nikon))
        XCTAssertFalse(master.meta.isUsable)
        _ = try library.save(master)
        XCTAssertNil(library.match(iso: 800, exposureSeconds: 1, source: .nikon))
        XCTAssertEqual(library.all().first?.isUsable, false)
    }

    func testDarkLibraryConcurrentLoads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = DarkLibrary(directory: directory)
        let settings = ExposureSettings(iso: 400, exposureSeconds: 3)
        let saved = try library.save(try buildDark(values: [7, 8], width: 32, height: 24,
                                                   settings: settings))
        let counter = TestCounter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let dark = library.load(id: saved.id)
            if dark == nil || dark?.pixels.count != 32 * 24 {
                counter.increment()
            }
        }
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: - Subtraction

    func testDarkSubtractionClampsAndResamples() {
        let frame = constantImage(width: 8, height: 6, value: 500)
        let sameSizeMeta = MasterDarkMeta(exposureSeconds: 1, iso: 800, frameCount: 3,
                                          width: 8, height: 6, meanLevel: 700)
        let sameSize = MasterDark(meta: sameSizeMeta,
                                  pixels: [Float](repeating: 700, count: 8 * 6))
        let clamped = DarkSubtraction.subtract(sameSize, from: frame)
        XCTAssertEqual(clamped.width, 8)
        XCTAssertEqual(clamped.height, 6)
        XCTAssertEqual(clamped.pixels, [Float](repeating: 0, count: 8 * 6))

        // A larger master is resampled to the exact frame size.
        let largerMeta = MasterDarkMeta(exposureSeconds: 1, iso: 800, frameCount: 3,
                                        width: 16, height: 12, meanLevel: 300)
        let larger = MasterDark(meta: largerMeta,
                                pixels: [Float](repeating: 300, count: 16 * 12))
        let adapted = DarkSubtraction.subtract(larger, from: frame)
        XCTAssertEqual(adapted.width, 8)
        XCTAssertEqual(adapted.height, 6)
        XCTAssertEqual(adapted.pixels, [Float](repeating: 200, count: 8 * 6))

        // An inconsistent master leaves the frame untouched.
        let brokenMeta = MasterDarkMeta(exposureSeconds: 1, iso: 800, frameCount: 3,
                                        width: 8, height: 6)
        let broken = MasterDark(meta: brokenMeta, pixels: [])
        XCTAssertEqual(DarkSubtraction.subtract(broken, from: frame).pixels, frame.pixels)
    }

    // MARK: - Simulator

    func testCoveredSimulatorFramesShareHotPixelsAndHaveNoStars() {
        var scene = SimulatorScene()
        scene.width = 600
        scene.height = 400
        scene.starCount = 40
        scene.seed = 4242
        scene.condition = .brightSky
        let settings = ExposureSettings(iso: 800, exposureSeconds: 2, aperture: 2.8)
        let normal = SimulatorSky(scene: scene).render(settings: settings, focusSigma: 1.2,
                                                       timeSeconds: 0, width: 600, height: 400,
                                                       seedOffset: 1, isLive: false)

        var coveredScene = scene
        coveredScene.lensCovered = true
        let coveredSky = SimulatorSky(scene: coveredScene)
        let covered = coveredSky.render(settings: settings, focusSigma: 1.2, timeSeconds: 37,
                                        width: 600, height: 400, seedOffset: 99, isLive: false)
        let repeated = coveredSky.render(settings: settings, focusSigma: 1.2, timeSeconds: 37,
                                         width: 600, height: 400, seedOffset: 99, isLive: false)
        XCTAssertEqual(covered.pixels, repeated.pixels)
        XCTAssertEqual(StarDetector.measure(in: covered).starCount, 0)

        // brightSky lighting is ignored while the lens cap is on: only bias remains.
        let coveredMedian = covered.median()
        XCTAssertEqual(Double(coveredMedian), scene.biasADU, accuracy: 60)
        XCTAssertLessThan(coveredMedian, 1000)

        // Hot pixels are a fixed pattern: same sites in normal and covered frames,
        // independent of seedOffset and time.
        let hot = scene.hotPixels(width: 600, height: 400)
        XCTAssertEqual(hot.count, scene.configuredHotPixels)
        XCTAssertEqual(scene.hotPixels(width: 600, height: 400), hot)
        XCTAssertEqual(coveredScene.hotPixels(width: 600, height: 400), hot)
        let hottest = hot.max { $0.scale < $1.scale }!
        let index = hottest.y * 600 + hottest.x
        XCTAssertGreaterThan(normal.pixels[index], normal.median() + 1000)
        XCTAssertGreaterThan(covered.pixels[index], coveredMedian + 1000)

        // Positions are sensor-relative, so a half-size render keeps them.
        let half = scene.hotPixels(width: 300, height: 200)
        XCTAssertEqual(half.count, hot.count)
        for (small, full) in zip(half, hot) {
            XCTAssertLessThanOrEqual(abs(small.x * 2 - full.x), 1)
            XCTAssertLessThanOrEqual(abs(small.y * 2 - full.y), 1)
            XCTAssertEqual(small.scale, full.scale, accuracy: 1e-9)
        }
    }

    func testObstructionCoversHotPixelsInCoveredFrames() throws {
        var scene = SimulatorScene()
        scene.width = 500
        scene.height = 320
        scene.configuredHotPixels = 120
        scene.lensCovered = true
        scene.condition = .obstruction
        let settings = ExposureSettings(iso: 800, exposureSeconds: 4, aperture: 2.8)
        let image = SimulatorSky(scene: scene).render(settings: settings, focusSigma: 1.2,
                                                      timeSeconds: 0, width: 500, height: 320,
                                                      seedOffset: 5, isLive: false)
        let hot = scene.hotPixels(width: 500, height: 320)
        XCTAssertEqual(hot.count, 120)

        let x1 = Int(0.38 * 500)
        let y0 = Int(0.55 * 320)
        let blocked = hot.filter { $0.x < x1 && $0.y >= y0 }
        XCTAssertFalse(blocked.isEmpty)
        for pixel in blocked {
            // The obstruction mask zeroes the signal, but read noise is added
            // afterwards, so compare against the hot-pixel level, not exact 0.
            XCTAssertLessThan(image.pixels[pixel.y * 500 + pixel.x],
                              image.median() + 500)
        }
        let visible = try XCTUnwrap(hot.first { !($0.x < x1 && $0.y >= y0) })
        XCTAssertGreaterThan(image.pixels[visible.y * 500 + visible.x], image.median() + 500)
    }

    func testSimulatedDarkSubtractionReducesBackgroundAndHotPixels() async throws {
        var scene = SimulatorScene()
        scene.width = 1000
        scene.height = 666
        scene.starCount = 60
        scene.seed = 77
        let camera = SimulatorCamera(scene: scene)
        camera.simulateTiming = false
        camera.fixedSimulationTime = 0
        try await camera.connect()
        let settings = ExposureSettings(iso: 800, exposureSeconds: 4, aperture: 2.8)
        try await camera.apply(settings)

        let normalRecord = try await camera.capture(sequence: 1)
        let normalFrame = try XCTUnwrap(normalRecord.analysisLuma)
        XCTAssertGreaterThan(StarDetector.measure(in: normalFrame).starCount, 3)

        camera.setLensCovered(true)
        let accumulator = DarkAccumulator()
        var darkFrames: [LumaImage] = []
        for sequence in 2...4 {
            let record = try await camera.capture(sequence: sequence)
            let luma = try XCTUnwrap(record.analysisLuma)
            darkFrames.append(luma)
            try accumulator.add(luma, settings: record.settings)
        }
        camera.setLensCovered(false)
        for dark in darkFrames {
            XCTAssertEqual(StarDetector.measure(in: dark).starCount, 0)
        }

        let master = try XCTUnwrap(accumulator.build(settings: settings, source: .simulator))
        XCTAssertEqual(master.meta.frameCount, 3)
        XCTAssertEqual(master.meta.hotPixelCount, scene.configuredHotPixels)

        let corrected = DarkSubtraction.subtract(master, from: normalFrame)
        XCTAssertEqual(corrected.width, normalFrame.width)
        XCTAssertEqual(corrected.height, normalFrame.height)
        let before = normalFrame.median()
        let after = corrected.median()
        // The master removes the bias/dark-current level; the sky background stays.
        XCTAssertGreaterThanOrEqual(Double(before - after), 250)

        let hot = scene.hotPixels(width: 1000, height: 666)
        let hottest = try XCTUnwrap(hot.max { $0.scale < $1.scale })
        let index = hottest.y * 1000 + hottest.x
        XCTAssertGreaterThanOrEqual(Double(normalFrame.pixels[index]
                                           - corrected.pixels[index]), 3000)

        // The same fixed pattern is present in normal and covered frames.
        for pixel in hot {
            let idx = pixel.y * 1000 + pixel.x
            XCTAssertGreaterThan(normalFrame.pixels[idx], before + 2000)
            XCTAssertGreaterThan(darkFrames[0].pixels[idx], darkFrames[0].median() + 2000)
        }
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
