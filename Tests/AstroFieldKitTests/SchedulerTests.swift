import XCTest
@testable import AstroFieldKit

final class SchedulerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testPlanSummary() {
        var plan = CapturePlan()
        plan.start = .delay(seconds: 10)
        plan.exposureSeconds = 15
        plan.interval = .fixedStart(seconds: 20)
        plan.end = .count(3)
        XCTAssertTrue(plan.summary.contains("10 秒后开始"))
        XCTAssertTrue(plan.summary.contains("拍满 3 张"))
    }

    func testFixedStartTheory() {
        // 10 秒后开始，每 20 秒开始一张，每张 15 秒 → 第 10、30、50 秒。
        var plan = CapturePlan()
        plan.start = .delay(seconds: 10)
        plan.exposureSeconds = 15
        plan.interval = .fixedStart(seconds: 20)
        plan.end = .count(3)
        let times = ScheduleCalculator.theoreticalStartTimes(plan: plan, now: base)
            .map { $0.timeIntervalSince(base) }
        XCTAssertEqual(times, [10, 30, 50])

        // The exposure ends at 25/45/65; starts stay on the fixed grid.
        XCTAssertTrue(plan.intervalText.contains("固定间隔"))
    }

    func testAfterExposureTheory() {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 15
        plan.interval = .afterExposure(seconds: 5)
        plan.end = .count(4)
        let times = ScheduleCalculator.theoreticalStartTimes(plan: plan, now: base)
            .map { $0.timeIntervalSince(base) }
        XCTAssertEqual(times, [0, 20, 40, 60])
    }

    func testDurationEnd() {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 10
        plan.interval = .afterExposure(seconds: 5)
        plan.end = .duration(seconds: 45)
        let times = ScheduleCalculator.theoreticalStartTimes(plan: plan, now: base)
            .map { $0.timeIntervalSince(base) }
        XCTAssertEqual(times, [0, 15, 30])
    }

    func testPreflightWarnsWhenIntervalTooShort() {
        var plan = CapturePlan()
        plan.exposureSeconds = 15
        plan.interval = .fixedStart(seconds: 12)
        let issues = ScheduleCalculator.preflight(plan: plan)
        XCTAssertTrue(issues.contains { $0.contains("固定间隔") })
    }

    func testExposureRampInterpolation() {
        let linear = ExposureRamp(startSeconds: 1, endSeconds: 5, curve: .linear)
        XCTAssertEqual(linear.exposure(at: 0), 1, accuracy: 0.001)
        XCTAssertEqual(linear.exposure(at: 0.5), 3, accuracy: 0.001)
        XCTAssertEqual(linear.exposure(at: 1), 5, accuracy: 0.001)

        let geometric = ExposureRamp(startSeconds: 1, endSeconds: 16, curve: .geometric)
        XCTAssertEqual(geometric.exposure(at: 0.5), 4, accuracy: 0.001)

        var plan = CapturePlan()
        plan.exposureSeconds = 2
        plan.ramp = ExposureRamp(startSeconds: 1, endSeconds: 3, curve: .linear)
        let first = plan.settingsForFrame(index: 0, totalFrames: 3, elapsed: 0, duration: nil)
        let middle = plan.settingsForFrame(index: 1, totalFrames: 3, elapsed: 0, duration: nil)
        let last = plan.settingsForFrame(index: 2, totalFrames: 3, elapsed: 0, duration: nil)
        XCTAssertEqual(first.exposureSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(middle.exposureSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(last.exposureSeconds, 3, accuracy: 0.001)
    }

    func testCountdownExpectedEnd() {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 10
        plan.interval = .fixedStart(seconds: 20)
        plan.end = .count(3)
        let end = ScheduleCalculator.expectedEnd(plan: plan, now: base)
        XCTAssertEqual(end?.timeIntervalSince(base) ?? -1, 50, accuracy: 0.01)
    }
}

final class SequenceRunnerTests: XCTestCase {
    final class FakeCamera: CameraDevice, @unchecked Sendable {
        let id = UUID()
        let kind: CameraKind = .simulator
        var displayName = "Fake"
        var status = CameraStatus(state: .connected, model: "Fake")
        var onStatusChange: ((CameraStatus) -> Void)?
        var applyCount = 0
        var appliedSettings: [ExposureSettings] = []
        var captureCount = 0
        var failureAt: Set<Int> = []
        var captureDelay: TimeInterval = 0.02

        func connect() async throws {}
        func disconnect() async {}
        func apply(_ settings: ExposureSettings) async throws {
            applyCount += 1
            appliedSettings.append(settings)
        }
        func capture(sequence: Int) async throws -> ImageRecord {
            captureCount += 1
            if captureDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(captureDelay * 1_000_000_000))
            }
            if failureAt.contains(sequence) {
                throw CameraError.captureFailed("injected")
            }
            return ImageRecord(sequence: sequence, source: .simulator, fileURL: nil,
                               settings: ExposureSettings(), width: 100, height: 100,
                               isRaw: true)
        }
        func startLiveView() async throws {}
        func stopLiveView() async {}
        func livePreview() async throws -> LivePreview? { nil }
        func focusDrive(direction: FocusDirection, steps: Int) async throws {}
    }

    func testRunsFixedCount() async throws {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 0.01
        plan.interval = .afterExposure(seconds: 0.01)
        plan.end = .count(3)
        let camera = FakeCamera()
        let runner = SequenceRunner(camera: camera, plan: plan, clock: CountingClock())
        let events = await runner.events()
        await runner.start()

        var captured = 0
        var final: SequenceProgress?
        for await event in events {
            switch event {
            case .captured:
                captured += 1
            case .finished(let progress):
                final = progress
            default:
                break
            }
        }
        XCTAssertEqual(captured, 3)
        XCTAssertEqual(final?.phase, .finished)
        XCTAssertEqual(final?.exposed, 3)
        XCTAssertEqual(final?.saved, 3)
        XCTAssertEqual(final?.failed, 0)
        XCTAssertEqual(camera.captureCount, 3)
        XCTAssertGreaterThanOrEqual(camera.applyCount, 3)
    }

    func testRunnerAppliesRampPerFrame() async throws {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 1
        plan.interval = .afterExposure(seconds: 0)
        plan.end = .count(3)
        plan.ramp = ExposureRamp(startSeconds: 1, endSeconds: 3, curve: .linear)
        let camera = FakeCamera()
        camera.captureDelay = 0
        let runner = SequenceRunner(camera: camera, plan: plan, clock: CountingClock())
        let events = await runner.events()
        await runner.start()
        for await event in events {
            if case .finished = event { break }
        }
        XCTAssertEqual(camera.appliedSettings.count, 3)
        XCTAssertEqual(camera.appliedSettings[0].exposureSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(camera.appliedSettings[1].exposureSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(camera.appliedSettings[2].exposureSeconds, 3, accuracy: 0.001)
    }

    func testCountsFailuresSeparately() async throws {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 0.01
        plan.interval = .afterExposure(seconds: 0.01)
        plan.end = .count(3)
        let camera = FakeCamera()
        camera.failureAt = [1]
        let runner = SequenceRunner(camera: camera, plan: plan, clock: CountingClock())
        let events = await runner.events()
        await runner.start()
        var final: SequenceProgress?
        for await event in events {
            if case .finished(let progress) = event { final = progress }
        }
        XCTAssertEqual(final?.exposed, 3)
        XCTAssertEqual(final?.saved, 2)
        XCTAssertEqual(final?.failed, 1)
        XCTAssertNotNil(final?.lastError)
    }

    func testPauseAndResume() async throws {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 0.03
        plan.interval = .afterExposure(seconds: 0.05)
        plan.end = .count(50)
        let camera = FakeCamera()
        camera.captureDelay = 0.03
        let runner = SequenceRunner(camera: camera, plan: plan)
        _ = await runner.events()
        await runner.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        await runner.pause()
        try await Task.sleep(nanoseconds: 250_000_000)
        let a = await runner.snapshot()
        try await Task.sleep(nanoseconds: 250_000_000)
        let b = await runner.snapshot()
        XCTAssertEqual(a.phase, .paused)
        XCTAssertEqual(a.exposed, b.exposed, "暂停后不应继续曝光")
        await runner.resume()
        try await Task.sleep(nanoseconds: 900_000_000)
        let c = await runner.snapshot()
        XCTAssertGreaterThan(c.exposed, b.exposed)
        await runner.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testStopLeavesStoppedPhase() async throws {
        var plan = CapturePlan()
        plan.start = .immediate
        plan.exposureSeconds = 0.01
        plan.interval = .afterExposure(seconds: 0.2)
        plan.end = .manual
        let runner = SequenceRunner(camera: FakeCamera(), plan: plan)
        let events = await runner.events()
        await runner.start()
        try await Task.sleep(nanoseconds: 80_000_000)
        await runner.stop()
        var final: SequenceProgress?
        for await event in events {
            if case .finished(let progress) = event { final = progress }
        }
        XCTAssertEqual(final?.phase, .stopped)
    }

    func testFatalPlanFailsWithoutRunning() async throws {
        var plan = CapturePlan()
        plan.exposureSeconds = 0
        let camera = FakeCamera()
        let runner = SequenceRunner(camera: camera, plan: plan, clock: CountingClock())
        let events = await runner.events()
        await runner.start()
        var final: SequenceProgress?
        for await event in events {
            if case .finished(let progress) = event { final = progress }
        }
        XCTAssertEqual(final?.phase, .failed)
        XCTAssertEqual(camera.captureCount, 0)
    }
}
