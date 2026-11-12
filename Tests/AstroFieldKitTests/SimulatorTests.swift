import XCTest
@testable import AstroFieldKit

final class SimulatorTests: XCTestCase {
    func testRenderIsDeterministic() {
        var scene = SimulatorScene()
        scene.width = 400
        scene.height = 267
        scene.starCount = 20
        scene.seed = 99
        let sky = SimulatorSky(scene: scene)
        let settings = ExposureSettings(iso: 1600, exposureSeconds: 2, aperture: 2.8)
        let a = sky.render(settings: settings, focusSigma: 1.4, timeSeconds: 0,
                           width: 400, height: 267, seedOffset: 3, isLive: false)
        let b = sky.render(settings: settings, focusSigma: 1.4, timeSeconds: 0,
                           width: 400, height: 267, seedOffset: 3, isLive: false)
        XCTAssertEqual(a.pixels, b.pixels)
    }

    func testDefocusIncreasesMeasuredFWHM() {
        var scene = SimulatorScene()
        scene.width = 900
        scene.height = 600
        scene.starCount = 40
        scene.seed = 7
        let sky = SimulatorSky(scene: scene)
        let settings = ExposureSettings(iso: 800, exposureSeconds: 2, aperture: 2.8)
        let sharp = sky.render(settings: settings, focusSigma: 1.2, timeSeconds: 0,
                               width: 900, height: 600, seedOffset: 1, isLive: false)
        let soft = sky.render(settings: settings, focusSigma: 4.5, timeSeconds: 0,
                              width: 900, height: 600, seedOffset: 1, isLive: false)
        let sharpM = StarDetector.measure(in: sharp)
        let softM = StarDetector.measure(in: soft)
        XCTAssertGreaterThan(sharpM.starCount, 3)
        XCTAssertGreaterThan(softM.starCount, 3)
        XCTAssertLessThan(sharpM.medianFWHM, softM.medianFWHM * 0.75)
    }

    func testConditions() {
        var scene = SimulatorScene()
        scene.width = 400
        scene.height = 267
        scene.starCount = 30
        let settings = ExposureSettings(iso: 800, exposureSeconds: 2, aperture: 2.8)

        scene.condition = .noStars
        let empty = SimulatorSky(scene: scene).render(settings: settings, focusSigma: 1.2,
                                                      timeSeconds: 0, width: 400, height: 267,
                                                      seedOffset: 2, isLive: false)
        XCTAssertLessThanOrEqual(StarDetector.measure(in: empty).starCount, 1)

        scene.condition = .obstruction
        let blocked = SimulatorSky(scene: scene).render(settings: settings, focusSigma: 1.2,
                                                        timeSeconds: 0, width: 400, height: 267,
                                                        seedOffset: 2, isLive: false)
        XCTAssertLessThan(StarDetector.measure(in: blocked).starCount, 30)
    }

    func testExposureRaisesBackground() {
        var scene = SimulatorScene()
        scene.width = 200
        scene.height = 140
        scene.starCount = 3
        let sky = SimulatorSky(scene: scene)
        let short = sky.render(settings: ExposureSettings(iso: 800, exposureSeconds: 1, aperture: 2.8),
                               focusSigma: 1.2, timeSeconds: 0, width: 200, height: 140,
                               seedOffset: 4, isLive: false)
        let long = sky.render(settings: ExposureSettings(iso: 800, exposureSeconds: 8, aperture: 2.8),
                              focusSigma: 1.2, timeSeconds: 0, width: 200, height: 140,
                              seedOffset: 4, isLive: false)
        XCTAssertGreaterThan(long.median(), short.median() * 2)
    }

    func testSimulatorCameraCaptureAndFocus() async throws {
        var scene = SimulatorScene()
        scene.width = 500
        scene.height = 333
        scene.starCount = 25
        let camera = SimulatorCamera(scene: scene)
        camera.simulateTiming = false
        try await camera.connect()
        try await camera.apply(ExposureSettings(iso: 800, exposureSeconds: 1, aperture: 2.8))
        let record = try await camera.capture(sequence: 1)
        XCTAssertEqual(record.source, .simulator)
        XCTAssertNotNil(record.preview)
        XCTAssertEqual(record.width, 500)
        XCTAssertEqual(record.height, 333)

        let before = camera.focusPosition
        try await camera.focusDrive(direction: .one, steps: 10)
        XCTAssertNotEqual(camera.focusPosition, before)

        try await camera.startLiveView()
        let preview = try await camera.livePreview()
        XCTAssertNotNil(preview)
        XCTAssertTrue(preview?.isSimulated ?? false)
        await camera.stopLiveView()
    }
}
