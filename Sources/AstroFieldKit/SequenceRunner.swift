import Foundation

public protocol SequenceClock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async throws
}

public struct RealSequenceClock: SequenceClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 3600) * 1_000_000_000))
    }
}

/// Test clock: sleeping advances its own time instantly. Useful for running long
/// plans without waiting; timing math itself is covered by ScheduleCalculator.
public final class CountingClock: SequenceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = now
    }
    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    public func sleep(seconds: Double) async throws {
        lock.lock()
        current = current.addingTimeInterval(max(0, seconds))
        lock.unlock()
        await Task.yield()
    }
}

public struct SequenceProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case idle
        case waitingToStart
        case exposing
        case waitingInterval
        case paused
        case stopping
        case finished
        case stopped
        case failed
    }

    public var phase: Phase = .idle
    public var message: String = ""
    public var issues: [String] = []
    public var startedAt: Date?
    public var nextStart: Date?
    public var exposureEnd: Date?
    public var expectedEnd: Date?
    public var exposed = 0
    public var saved = 0
    public var failed = 0
    public var qualified = 0
    public var lastError: String?

    public init() {}
}

/// Runs a CapturePlan against any CameraDevice. Emits progress and captured images.
public actor SequenceRunner {
    public enum Event: Sendable {
        case progress(SequenceProgress)
        case captured(ImageRecord)
        case failed(index: Int, message: String)
        case finished(SequenceProgress)
    }

    private let camera: CameraDevice
    private var plan: CapturePlan
    private let clock: SequenceClock
    private let sequenceStart: Int
    private var stream: AsyncStream<Event>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var stopRequested = false
    private var paused = false
    private var pauseAfterCurrentRequested = false
    private var capturing = false
    private var progress = SequenceProgress()

    public init(camera: CameraDevice, plan: CapturePlan,
                clock: SequenceClock = RealSequenceClock(),
                sequenceStart: Int = 0) {
        self.camera = camera
        self.plan = plan
        self.clock = clock
        self.sequenceStart = sequenceStart
    }

    public func events() -> AsyncStream<Event> {
        if let stream { return stream }
        var cont: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event> { cont = $0 }
        self.stream = stream
        self.continuation = cont
        return stream
    }

    public func snapshot() -> SequenceProgress {
        progress
    }

    public func updatePlan(_ plan: CapturePlan) {
        self.plan = plan
    }

    public func start() {
        guard loopTask == nil else { return }
        stopRequested = false
        paused = false
        pauseAfterCurrentRequested = false
        capturing = false
        progress = SequenceProgress()
        progress.phase = .idle
        emit(.progress(progress))
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Pause after the frame currently being exposed. If the runner is waiting
    /// between frames, it pauses immediately.
    public func pause() {
        guard loopTask != nil else { return }
        if capturing {
            pauseAfterCurrentRequested = true
        } else {
            paused = true
        }
    }

    public func resume() {
        paused = false
        pauseAfterCurrentRequested = false
    }

    /// Stop scheduling new frames. An exposure already in progress is allowed to
    /// finish (a real camera cannot abort a timed exposure reliably).
    public func stop() {
        stopRequested = true
        paused = false
        if loopTask != nil, !capturing {
            progress.phase = .stopping
            emit(.progress(progress))
        }
    }

    public var isRunning: Bool {
        loopTask != nil
    }

    // MARK: - Loop

    private func runLoop() async {
        defer {
            continuation?.finish()
            loopTask = nil
            continuation = nil
            stream = nil
        }

        if let fatal = fatalIssue() {
            progress.phase = .failed
            progress.message = fatal
            progress.issues = ScheduleCalculator.preflight(plan: plan)
            emit(.progress(progress))
            emit(.finished(progress))
            return
        }
        let warnings = ScheduleCalculator.preflight(plan: plan)
        progress.issues = warnings
        if !warnings.isEmpty {
            progress.message = warnings.joined(separator: "；")
            emit(.progress(progress))
        }

        let first = ScheduleCalculator.firstStart(plan: plan, now: clock.now)
        var startedAt = first
        progress.startedAt = startedAt
        progress.expectedEnd = ScheduleCalculator.expectedEnd(plan: plan, now: clock.now)
        progress.phase = .waitingToStart
        progress.nextStart = first
        emit(.progress(progress))

        var nextStart = first
        var lastPlanned = first
        var frame = 0

        while !stopRequested {
            if paused {
                progress.phase = .paused
                progress.nextStart = nil
                progress.message = "已暂停（拍完当前张）"
                emit(.progress(progress))
                while paused && !stopRequested {
                    try? await clock.sleep(seconds: 0.1)
                }
                if stopRequested { break }
                nextStart = clock.now.addingTimeInterval(0.5)
                lastPlanned = nextStart
                progress.phase = .waitingInterval
                progress.message = "已继续"
                emit(.progress(progress))
            }

            let wait = nextStart.timeIntervalSince(clock.now)
            if wait > 0 {
                progress.phase = frame == 0 ? .waitingToStart : .waitingInterval
                progress.nextStart = nextStart
                progress.exposureEnd = nil
                progress.message = frame == 0 ? "等待开始" : "等待下一张"
                emit(.progress(progress))
                var remaining = wait
                while remaining > 0 && !stopRequested && !paused {
                    try? await clock.sleep(seconds: min(remaining, 0.1))
                    remaining = nextStart.timeIntervalSince(clock.now)
                }
                if stopRequested { break }
                if paused { continue }
            }

            if ScheduleCalculator.endReached(plan: plan, start: startedAt,
                                             nextStart: nextStart, frame: frame) {
                break
            }

            // Apply the plan settings before every frame so a paused/resumed run
            // follows the latest plan, but never mid-exposure. An exposure ramp
            // is evaluated per frame (S11-B).
            let totalFrames: Int? = {
                if case .count(let count) = plan.end { return count }
                return nil
            }()
            let durationEnd: Double? = {
                if case .duration(let seconds) = plan.end { return seconds }
                return nil
            }()
            let elapsed = clock.now.timeIntervalSince(startedAt)
            let frameSettings = plan.settingsForFrame(index: frame,
                                                      totalFrames: totalFrames,
                                                      elapsed: elapsed,
                                                      duration: durationEnd)
            do {
                try await camera.apply(frameSettings)
            } catch {
                progress.lastError = String(describing: error)
                emit(.progress(progress))
            }

            lastPlanned = nextStart
            progress.phase = .exposing
            progress.nextStart = nil
            progress.exposureEnd = clock.now.addingTimeInterval(frameSettings.exposureSeconds)
            progress.message = String(format: "曝光 %.1f 秒", frameSettings.exposureSeconds)
            emit(.progress(progress))

            capturing = true
            progress.exposed += 1
            do {
                let record = try await camera.capture(sequence: sequenceStart + frame)
                progress.saved += 1
                emit(.captured(record))
            } catch {
                progress.failed += 1
                progress.lastError = String(describing: error)
                emit(.failed(index: frame, message: progress.lastError ?? "未知错误"))
            }
            capturing = false
            frame += 1

            if pauseAfterCurrentRequested {
                pauseAfterCurrentRequested = false
                paused = true
            }

            nextStart = nextStartAfterFrame(previousPlanned: lastPlanned, frame: frame)
            progress.expectedEnd = estimateEnd(startedAt: startedAt, framesDone: frame)
            progress.message = ""
            emit(.progress(progress))
        }

        progress.phase = stopRequested ? .stopped : .finished
        progress.nextStart = nil
        progress.exposureEnd = nil
        progress.message = stopRequested ? "已停止" : "计划完成"
        emit(.progress(progress))
        emit(.finished(progress))
    }

    // MARK: - Timing

    private func fatalIssue() -> String? {
        if plan.exposureSeconds <= 0 { return "曝光时间必须大于 0" }
        switch plan.interval {
        case .fixedStart(let seconds) where seconds <= 0:
            return "固定间隔必须大于 0"
        case .afterExposure(let seconds) where seconds < 0:
            return "曝光后等待不能为负"
        default:
            break
        }
        switch plan.end {
        case .count(let count) where count <= 0:
            return "目标张数必须大于 0"
        case .duration(let seconds) where seconds <= 0:
            return "持续时长必须大于 0"
        case .at(let date) where date < clock.now:
            return "结束时刻已经过去"
        default:
            break
        }
        return nil
    }

    private func nextStartAfterFrame(previousPlanned: Date, frame: Int) -> Date {
        let now = clock.now
        let guardTime = 0.3
        switch plan.interval {
        case .afterExposure(let gap):
            return now.addingTimeInterval(max(0, gap))
        case .fixedStart(let interval):
            var candidate = previousPlanned.addingTimeInterval(max(0, interval))
            if candidate >= now.addingTimeInterval(guardTime) {
                return candidate
            }
            if plan.policy == .shift {
                progress.message = "设备忙或下载较慢，后续时间点已顺延"
                return now.addingTimeInterval(guardTime)
            }
            var skipped = 0
            while candidate < now.addingTimeInterval(guardTime) {
                candidate = candidate.addingTimeInterval(max(0, interval))
                skipped += 1
                if skipped > 100_000 { break }
            }
            if skipped > 0 {
                progress.message = "跳过 \(skipped) 个固定时间点"
            }
            return candidate
        }
    }

    private func estimateEnd(startedAt: Date, framesDone: Int) -> Date? {
        switch plan.end {
        case .count(let count):
            let remaining = max(0, count - framesDone)
            let cycle: Double
            switch plan.interval {
            case .fixedStart(let seconds): cycle = max(seconds, plan.exposureSeconds + 1)
            case .afterExposure(let seconds): cycle = plan.exposureSeconds + seconds
            }
            return clock.now.addingTimeInterval(Double(max(0, remaining - 1)) * cycle + plan.exposureSeconds)
        case .duration(let seconds):
            return startedAt.addingTimeInterval(seconds)
        case .at(let date):
            return date
        case .manual:
            return nil
        }
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }
}
