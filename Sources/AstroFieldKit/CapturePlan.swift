import Foundation

/// Exposure ramp for twilight / dawn-lapse (S11-B). Interpolates exposure seconds
/// across the planned frames. Only exposure changes; ISO and aperture stay fixed.
public struct ExposureRamp: Codable, Equatable, Sendable {
    public enum Curve: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        case linear
        case geometric

        public var displayName: String {
            switch self {
            case .linear: return "线性"
            case .geometric: return "等比"
            }
        }
    }

    public var startSeconds: Double
    public var endSeconds: Double
    public var curve: Curve

    public init(startSeconds: Double, endSeconds: Double, curve: Curve = .geometric) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.curve = curve
    }

    public func exposure(at fraction: Double) -> Double {
        let f = min(1, max(0, fraction))
        switch curve {
        case .linear:
            return startSeconds + (endSeconds - startSeconds) * f
        case .geometric:
            guard startSeconds > 0, endSeconds > 0 else {
                return startSeconds + (endSeconds - startSeconds) * f
            }
            return startSeconds * pow(endSeconds / startSeconds, f)
        }
    }
}

/// A shooting plan. Pure data; the same plan drives simulator, playback and real camera.
public struct CapturePlan: Codable, Equatable, Sendable {
    public enum StartMode: Codable, Equatable, Sendable {
        case immediate
        case delay(seconds: Double)
        case at(Date)
    }

    public enum IntervalMode: Codable, Equatable, Sendable {
        /// Start every N seconds on a grid.
        case fixedStart(seconds: Double)
        /// Wait at least N seconds after the previous exposure ends.
        case afterExposure(seconds: Double)
    }

    public enum EndMode: Codable, Equatable, Sendable {
        case count(Int)
        case duration(seconds: Double)
        case at(Date)
        case manual
    }

    public enum MissedSlotPolicy: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
        /// Delay this and all following slots.
        case shift
        /// Skip missed slots and keep the original grid.
        case skip

        public var displayName: String {
            switch self {
            case .shift: return "顺延后续"
            case .skip: return "跳过时间点"
            }
        }
    }

    public var start: StartMode
    public var exposureSeconds: Double
    public var interval: IntervalMode
    public var end: EndMode
    public var policy: MissedSlotPolicy
    public var iso: Int
    public var aperture: Double?
    public var compression: CompressionChoice
    public var ramp: ExposureRamp?

    public init(start: StartMode = .delay(seconds: 5),
                exposureSeconds: Double = 10,
                interval: IntervalMode = .afterExposure(seconds: 3),
                end: EndMode = .count(10),
                policy: MissedSlotPolicy = .shift,
                iso: Int = 1600,
                aperture: Double? = 2.8,
                compression: CompressionChoice = .raw,
                ramp: ExposureRamp? = nil) {
        self.start = start
        self.exposureSeconds = exposureSeconds
        self.interval = interval
        self.end = end
        self.policy = policy
        self.iso = iso
        self.aperture = aperture
        self.compression = compression
        self.ramp = ramp
    }

    public var settings: ExposureSettings {
        ExposureSettings(iso: iso,
                         exposureSeconds: exposureSeconds,
                         aperture: aperture,
                         compression: compression)
    }

    /// Exposure for a frame, taking an optional ramp into account.
    public func settingsForFrame(index: Int, totalFrames: Int?,
                                 elapsed: Double, duration: Double?) -> ExposureSettings {
        var exposure = exposureSeconds
        if let ramp {
            let fraction: Double
            if let totalFrames, totalFrames > 1 {
                fraction = Double(index) / Double(totalFrames - 1)
            } else if let duration, duration > 0 {
                fraction = elapsed / duration
            } else {
                fraction = 0
            }
            exposure = ramp.exposure(at: fraction)
        }
        return ExposureSettings(iso: iso,
                                exposureSeconds: max(0.0001, exposure),
                                aperture: aperture,
                                compression: compression)
    }

    // MARK: - Display

    public var startText: String {
        switch start {
        case .immediate:
            return "立即开始"
        case .delay(let seconds):
            return "\(Self.formatDuration(seconds))后开始"
        case .at(let date):
            return "在 \(Self.timeFormatter.string(from: date)) 开始"
        }
    }

    public var intervalText: String {
        switch interval {
        case .fixedStart(let seconds):
            return "固定间隔 \(Self.formatDuration(seconds))（按开始时刻）"
        case .afterExposure(let seconds):
            return "曝光结束后等待 \(Self.formatDuration(seconds))"
        }
    }

    public var endText: String {
        switch end {
        case .count(let count):
            return "拍满 \(count) 张停止"
        case .duration(let seconds):
            return "持续 \(Self.formatDuration(seconds))"
        case .at(let date):
            return "到 \(Self.timeFormatter.string(from: date)) 停止"
        case .manual:
            return "手动停止"
        }
    }

    public var summary: String {
        let exposureText = ramp.map {
            "曝光 \(Self.formatDuration($0.startSeconds)) → \(Self.formatDuration($0.endSeconds))（\($0.curve.displayName)渐变）"
        } ?? "每张曝光 \(Self.formatDuration(exposureSeconds))"
        return "\(startText)，\(exposureText)，\(intervalText)，\(endText)。ISO \(iso)\(aperture.map { String(format: "，f/%.1f", $0) } ?? "")，\(compression.displayName)"
    }

    public static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.2f 秒", seconds)
        }
        if seconds.rounded() == seconds {
            return String(format: "%.0f 秒", seconds)
        }
        return String(format: "%.1f 秒", seconds)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
}

/// Pure scheduling math, testable with virtual time.
public enum ScheduleCalculator {
    /// First exposure start, resolved against `now`.
    public static func firstStart(plan: CapturePlan, now: Date) -> Date {
        switch plan.start {
        case .immediate:
            return now
        case .delay(let seconds):
            return now.addingTimeInterval(max(0, seconds))
        case .at(let date):
            return max(now, date)
        }
    }

    /// Theoretical start times ignoring overruns. Used for plan preview and tests.
    public static func theoreticalStartTimes(plan: CapturePlan, now: Date,
                                             limit: Int = 10_000) -> [Date] {
        let first = firstStart(plan: plan, now: now)
        var times: [Date] = []
        var t = first
        var index = 0
        while index < limit {
            if endReached(plan: plan, start: first, nextStart: t, frame: index) { break }
            times.append(t)
            index += 1
            switch plan.interval {
            case .fixedStart(let seconds):
                guard seconds > 0 else { break }
                t = t.addingTimeInterval(seconds)
            case .afterExposure(let seconds):
                t = t.addingTimeInterval(max(0, plan.exposureSeconds) + max(0, seconds))
            }
        }
        return times
    }

    public static func endReached(plan: CapturePlan, start: Date,
                                  nextStart: Date, frame: Int,
                                  now: Date? = nil) -> Bool {
        switch plan.end {
        case .count(let count):
            return frame >= count
        case .duration(let seconds):
            return nextStart >= start.addingTimeInterval(seconds)
        case .at(let date):
            return nextStart >= date
        case .manual:
            if let now, now < nextStart { return false }
            return false
        }
    }

    /// Non-fatal scheduling problems that must be shown to the user.
    public static func preflight(plan: CapturePlan, overhead: Double = 1.0) -> [String] {
        var issues: [String] = []
        if plan.exposureSeconds <= 0 {
            issues.append("曝光时间必须大于 0")
        }
        if let ramp = plan.ramp {
            if ramp.startSeconds <= 0 || ramp.endSeconds <= 0 {
                issues.append("曝光渐变的起止值必须大于 0")
            }
        }
        switch plan.interval {
        case .fixedStart(let seconds):
            if seconds <= 0 {
                issues.append("固定间隔必须大于 0")
            } else if seconds < plan.exposureSeconds + overhead {
                issues.append(String(format: "固定间隔 %.0f 秒小于曝光 %.0f 秒 + 处理时间，时间点会顺延或跳过",
                                     seconds, plan.exposureSeconds))
            }
        case .afterExposure(let seconds):
            if seconds < 0 { issues.append("曝光后等待不能为负") }
        }
        switch plan.end {
        case .count(let count):
            if count <= 0 { issues.append("目标张数必须大于 0") }
        case .duration(let seconds):
            if seconds <= 0 { issues.append("持续时长必须大于 0") }
        case .at(let date):
            if date < Date() { issues.append("结束时刻已经过去") }
        case .manual:
            break
        }
        return issues
    }

    /// Rough expected end used by the UI before the run starts.
    public static func expectedEnd(plan: CapturePlan, now: Date) -> Date? {
        switch plan.end {
        case .count(let count):
            let first = firstStart(plan: plan, now: now)
            let cycle: Double
            switch plan.interval {
            case .fixedStart(let seconds): cycle = max(seconds, plan.exposureSeconds + 1)
            case .afterExposure(let seconds): cycle = plan.exposureSeconds + seconds
            }
            return first.addingTimeInterval(Double(max(0, count - 1)) * cycle + plan.exposureSeconds)
        case .duration(let seconds):
            return firstStart(plan: plan, now: now).addingTimeInterval(seconds)
        case .at(let date):
            return date
        case .manual:
            return nil
        }
    }
}
