import XCTest
import AFSpikeCore
@testable import AstroFieldKit

final class AutoExposureTests: XCTestCase {
    private func makeCamera(scene: SimulatorScene) async throws -> SimulatorCamera {
        let camera = SimulatorCamera(scene: scene)
        camera.simulateTiming = false
        camera.fixedSimulationTime = 0
        try await camera.connect()
        return camera
    }

    private func probe(_ camera: SimulatorCamera)
        -> @Sendable (ExposureSettings) async throws -> AutoExposureSample {
        { settings in
            try await camera.apply(settings)
            let record = try await camera.capture(sequence: -1)
            guard let luma = record.analysisLuma else {
                throw CameraError.captureFailed("no luma")
            }
            return AutoExposureSample(settings: settings,
                                      metrics: FrameAnalyzer.metrics(luma))
        }
    }

    func testTrailingLimitMatchesNPF() {
        XCTAssertEqual(AutoExposureMath.trailingLimitSeconds(
            focalLengthMM: 35, aperture: 2.8, pixelPitchMicrons: 4.35),
            6.53, accuracy: 0.06)
        XCTAssertEqual(AutoExposureMath.trailingLimitSeconds(
            focalLengthMM: 200, aperture: 2.8, pixelPitchMicrons: 4.35),
            1.14, accuracy: 0.03)
        XCTAssertEqual(AutoExposureMath.trailingLimitSeconds(
            focalLengthMM: 14, aperture: 1.8, pixelPitchMicrons: 4.35),
            13.82, accuracy: 0.1)
    }

    func testDarkSceneRaisesISOToTargetBackground() async throws {
        var scene = SimulatorScene()
        scene.width = 600
        scene.height = 400
        scene.starCount = 40
        scene.seed = 11
        let camera = try await makeCamera(scene: scene)
        let runner = AutoExposureRunner()
        let result = await runner.run(
            initial: ExposureSettings(iso: 1600, exposureSeconds: 8, aperture: 2.8),
            focalLengthMM: 35,
            probe: probe(camera))
        XCTAssertTrue(result.status.isRecommended, result.status.displayText)
        let target = 65_535 * 0.12
        let background = result.samples.last?.metrics.background ?? 0
        XCTAssertEqual(background, target, accuracy: target * 0.45)
        XCTAssertGreaterThanOrEqual(result.samples.count, 2)
        XCTAssertGreaterThan(result.settings.iso, 1600)
    }

    func testTrailingShortensShutter() async throws {
        // Deterministic probe: every frame reports heavy trailing and a
        // background inside the target band. The runner must halve the shutter
        // until its retry budget is spent.
        let probe: @Sendable (ExposureSettings) async throws -> AutoExposureSample = { settings in
            AutoExposureSample(settings: settings,
                               metrics: FrameMetrics(starCount: 40,
                                                     background: 8_000,
                                                     noise: 50,
                                                     medianFWHM: 3,
                                                     medianEccentricity: 0.6,
                                                     saturatedFraction: 0))
        }
        let runner = AutoExposureRunner()
        let result = await runner.run(
            initial: ExposureSettings(iso: 1600, exposureSeconds: 8, aperture: 2.8),
            focalLengthMM: 35,
            probe: probe)
        XCTAssertGreaterThanOrEqual(result.samples.count, 2)
        XCTAssertLessThan(result.settings.exposureSeconds, 2)
        XCTAssertFalse(result.status.isRecommended)
        XCTAssertTrue(result.status.displayText.contains("偏心"),
                      result.status.displayText)
    }

    func testStarlessSceneIsUnconfirmed() async throws {
        var scene = SimulatorScene()
        scene.width = 500
        scene.height = 340
        scene.starCount = 0
        scene.condition = .noStars
        let camera = try await makeCamera(scene: scene)
        let runner = AutoExposureRunner()
        let result = await runner.run(
            initial: ExposureSettings(iso: 1600, exposureSeconds: 4, aperture: 2.8),
            focalLengthMM: 35,
            probe: probe(camera))
        XCTAssertFalse(result.status.isRecommended)
        XCTAssertTrue(result.status.displayText.contains("星点不足"),
                      result.status.displayText)
    }

    func testDecodeSuspectStopsImmediately() async throws {
        let probe: @Sendable (ExposureSettings) async throws -> AutoExposureSample = { settings in
            AutoExposureSample(settings: settings,
                               metrics: FrameMetrics(starCount: 300, background: 0,
                                                     noise: 0, medianFWHM: 18,
                                                     medianEccentricity: 0.9,
                                                     saturatedFraction: 0))
        }
        let result = await AutoExposureRunner().run(
            initial: ExposureSettings(iso: 1600, exposureSeconds: 8, aperture: 2.8),
            focalLengthMM: 35,
            probe: probe)
        XCTAssertFalse(result.status.isRecommended)
        XCTAssertTrue(result.status.displayText.contains("解码异常"),
                      result.status.displayText)
        XCTAssertEqual(result.samples.count, 1)
    }

    func testISORangeIsRespected() async throws {
        var scene = SimulatorScene()
        scene.width = 500
        scene.height = 340
        scene.starCount = 30
        scene.seed = 13
        let camera = try await makeCamera(scene: scene)
        var config = AutoExposureConfig()
        config.isoRange = 400...1600
        let runner = AutoExposureRunner(config: config)
        let result = await runner.run(
            initial: ExposureSettings(iso: 800, exposureSeconds: 8, aperture: 2.8),
            focalLengthMM: 35,
            probe: probe(camera))
        XCTAssertLessThanOrEqual(result.settings.iso, 1600)
        XCTAssertGreaterThanOrEqual(result.settings.iso, 400)
        // Too dark for the allowed ISO range: must not claim success.
        XCTAssertFalse(result.status.isRecommended)
    }
}
