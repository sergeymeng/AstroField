import Foundation
import AFSpikeCore

/// Tunables for the star-field auto exposure helper.
public struct AutoExposureConfig: Sendable, Equatable {
    /// Target background as a fraction of the full 16-bit range.
    public var targetBackgroundFraction: Double = 0.12
    /// Acceptable band around the target background, as a multiplier.
    public var backgroundTolerance: Double = 0.4
    /// Reject candidates whose saturated fraction exceeds this. Bright stars
    /// clipping is expected in star fields, so the limit is generous.
    public var maxSaturatedFraction: Double = 0.02
    /// Reject candidates with more trailing than this median eccentricity.
    public var maxEccentricity: Double = 0.35
    /// Minimum detectable stars for a usable frame.
    public var minStars: Int = 20
    public var isoRange: ClosedRange<Int> = 400...12_800
    public var shutterRange: ClosedRange<Double> = 0.4...30
    public var initialShutterSeconds: Double = 8
    public var maxTrailingRetries: Int = 3
    public var maxExposureAdjustments: Int = 3
    /// Sensor pixel pitch in micrometres (Z7 II / Z8 ≈ 4.35).
    public var pixelPitchMicrons: Double = 4.35
    /// Fallback focal length when EXIF is unavailable.
    public var fallbackFocalLengthMM: Double = 35

    public init() {}
}

/// One measured candidate frame.
public struct AutoExposureSample: Sendable, Equatable {
    public var settings: ExposureSettings
    public var metrics: FrameMetrics
    /// Full-scale value of the measured luminance (65535 for display-referred,
    /// the sensor white level for linear RAW).
    public var maxValue: Float

    public init(settings: ExposureSettings, metrics: FrameMetrics,
                maxValue: Float = 65_535) {
        self.settings = settings
        self.metrics = metrics
        self.maxValue = maxValue
    }
}

public enum AutoExposureStatus: Sendable, Equatable {
    case recommended
    case unconfirmed(String)

    public var isRecommended: Bool {
        if case .recommended = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .recommended: return L10n.text("已确认")
        case .unconfirmed(let reason): return reason
        }
    }
}

public struct AutoExposureResult: Sendable {
    public var status: AutoExposureStatus
    /// Best (last measured) candidate; only written back when recommended.
    public var settings: ExposureSettings
    public var samples: [AutoExposureSample]
    public var message: String

    public init(status: AutoExposureStatus, settings: ExposureSettings,
                samples: [AutoExposureSample], message: String) {
        self.status = status
        self.settings = settings
        self.samples = samples
        self.message = message
    }
}

/// Pure math used by the auto exposure helper.
public enum AutoExposureMath {
    /// NPF-style trailing limit: `t = (35·N + 30·p) / f`.
    ///
    /// N is aperture, p the pixel pitch in micrometres, f the focal length in
    /// millimetres. Returns a value clamped to a practical range.
    public static func trailingLimitSeconds(focalLengthMM: Double,
                                            aperture: Double,
                                            pixelPitchMicrons: Double) -> Double {
        guard focalLengthMM > 0 else { return 8 }
        let seconds = (35.0 * aperture + 30.0 * pixelPitchMicrons) / focalLengthMM
        return min(30, max(0.4, seconds))
    }

    /// Target background level in ADU for a 16-bit luminance image.
    public static func targetBackground(fraction: Double) -> Double {
        targetBackground(fraction: fraction, maxValue: 65_535)
    }

    /// Target background for a specific full-scale value.
    public static func targetBackground(fraction: Double, maxValue: Float) -> Double {
        max(1, Double(maxValue)) * max(0, min(1, fraction))
    }

    /// Standard 1/3-stop shutter speeds accepted by Nikon bodies, in seconds.
    public static let standardShutterSeconds: [Double] = [
        1.0 / 8000, 1.0 / 6400, 1.0 / 5000, 1.0 / 4000, 1.0 / 3200, 1.0 / 2500,
        1.0 / 2000, 1.0 / 1600, 1.0 / 1250, 1.0 / 1000, 1.0 / 800, 1.0 / 640,
        1.0 / 500, 1.0 / 400, 1.0 / 320, 1.0 / 250, 1.0 / 200, 1.0 / 160,
        1.0 / 125, 1.0 / 100, 1.0 / 80, 1.0 / 60, 1.0 / 50, 1.0 / 40,
        1.0 / 30, 1.0 / 25, 1.0 / 20, 1.0 / 15, 1.0 / 13, 1.0 / 10,
        1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 1.0 / 3, 0.4, 0.5, 0.6, 0.8,
        1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30
    ]

    /// Standard 1/3-stop ISO values accepted by Nikon bodies.
    public static let standardISOValues: [Int] = [
        100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250,
        1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
        16000, 20000, 25600, 32000, 40000, 51200, 64000, 81920, 102_400
    ]

    /// Largest standard shutter at or below `seconds`. Cameras reject
    /// non-standard values with 0x201C, so every candidate is quantized.
    public static func standardShutter(atMost seconds: Double) -> Double {
        guard seconds > 0 else { return standardShutterSeconds[0] }
        for value in standardShutterSeconds.reversed() where value <= seconds + 1e-9 {
            return value
        }
        return standardShutterSeconds[0]
    }

    /// Nearest standard ISO value.
    public static func standardISO(nearest value: Int) -> Int {
        guard let first = standardISOValues.first else { return value }
        var best = first
        var bestDistance = abs(first - value)
        for candidate in standardISOValues {
            let distance = abs(candidate - value)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }
}

/// Closed-loop star-field exposure search.
///
/// The runner probes a few candidate exposures through a caller-supplied
/// closure (simulator or real camera), shortens the shutter while trailing is
/// too strong, then moves ISO toward the target background. It only reports
/// `recommended` when the final frame passes every check.
public struct AutoExposureRunner: Sendable {
    public var config: AutoExposureConfig

    public init(config: AutoExposureConfig = AutoExposureConfig()) {
        self.config = config
    }

    public func run(initial: ExposureSettings,
                    focalLengthMM: Double?,
                    probe: @escaping @Sendable (ExposureSettings) async throws -> AutoExposureSample,
                    onStep: @escaping @Sendable (AutoExposureSample) async -> Void = { _ in }) async -> AutoExposureResult {
        let aperture = initial.aperture ?? 2.8
        let focal = max(1, focalLengthMM ?? config.fallbackFocalLengthMM)
        let trailingLimit = AutoExposureMath.trailingLimitSeconds(
            focalLengthMM: focal, aperture: aperture,
            pixelPitchMicrons: config.pixelPitchMicrons)

        var settings = ExposureSettings(
            iso: quantizedISO(initial.iso),
            exposureSeconds: quantizedShutter(
                min(config.initialShutterSeconds, trailingLimit)),
            aperture: initial.aperture,
            compression: initial.compression)

        var samples: [AutoExposureSample] = []
        var trailingRetries = 0
        var exposureAdjustments = 0
        var loops = 0

        while loops < 12 {
            loops += 1
            let sample: AutoExposureSample
            do {
                sample = try await probe(settings)
            } catch {
                return AutoExposureResult(
                    status: .unconfirmed(L10n.text("测量失败：%@", error)),
                    settings: settings, samples: samples,
                    message: L10n.text("自动曝光中止：%@", error))
            }
            samples.append(sample)
            await onStep(sample)

            let metrics = sample.metrics
            if isDecodeSuspect(metrics) {
                let message = String(format: L10n.text("解码异常：背景 %.0f，无法评估（Core Image RAW 限制）"),
                                     metrics.background)
                return AutoExposureResult(status: .unconfirmed(message),
                                          settings: settings, samples: samples,
                                          message: message)
            }
            // Trailing is the hard constraint: shorten before raising ISO.
            if metrics.medianEccentricity > config.maxEccentricity,
               settings.exposureSeconds > config.shutterRange.lowerBound + 1e-6,
               trailingRetries < config.maxTrailingRetries {
                settings.exposureSeconds = quantizedShutter(settings.exposureSeconds / 2)
                trailingRetries += 1
                continue
            }

            let target = AutoExposureMath.targetBackground(
                fraction: config.targetBackgroundFraction,
                maxValue: sample.maxValue)
            let lower = target * (1 - config.backgroundTolerance)
            let upper = target * (1 + config.backgroundTolerance)
            if metrics.background < lower || metrics.background > upper {
                if exposureAdjustments < config.maxExposureAdjustments {
                    let ratio = target / max(metrics.background, 1)
                    let newISO = quantizedISO(Int((Double(settings.iso) * ratio).rounded()))
                    if newISO != settings.iso {
                        settings.iso = newISO
                        exposureAdjustments += 1
                        continue
                    }
                    // ISO is clamped: move the shutter, but never past the
                    // trailing limit measured for this lens.
                    var newExposure = quantizedShutter(settings.exposureSeconds * ratio)
                    newExposure = min(newExposure, max(trailingLimit,
                                                       config.shutterRange.lowerBound))
                    newExposure = quantizedShutter(newExposure)
                    if abs(newExposure - settings.exposureSeconds) > 1e-6 {
                        settings.exposureSeconds = newExposure
                        exposureAdjustments += 1
                        continue
                    }
                }
            }
            break
        }

        let final = samples.last ?? AutoExposureSample(settings: settings,
                                                       metrics: FrameMetrics(
                                                        starCount: 0, background: 0, noise: 0,
                                                        medianFWHM: 0, medianEccentricity: 0,
                                                        saturatedFraction: 0))
        let target = AutoExposureMath.targetBackground(
            fraction: config.targetBackgroundFraction,
            maxValue: final.maxValue)
        var problems: [String] = []
        if final.metrics.starCount < config.minStars {
            problems.append(L10n.text("星点不足 %@（需 %@）", final.metrics.starCount, config.minStars))
        }
        if final.metrics.medianEccentricity > config.maxEccentricity {
            problems.append(String(format: L10n.text("偏心 %.2f（拖线）"), final.metrics.medianEccentricity))
        }
        if final.metrics.saturatedFraction > config.maxSaturatedFraction {
            problems.append(String(format: L10n.text("饱和 %.3f%%"), final.metrics.saturatedFraction * 100))
        }
        let lower = target * (1 - config.backgroundTolerance)
        let upper = target * (1 + config.backgroundTolerance)
        if final.metrics.background < lower || final.metrics.background > upper {
            problems.append(String(format: L10n.text("背景 %.0f（目标 %.0f）"),
                                   final.metrics.background, target))
        }

        let status: AutoExposureStatus = problems.isEmpty
            ? .recommended
            : .unconfirmed(problems.joined(separator: L10n.text("，")))
        let message = String(format: L10n.text("ISO %d，%@，f/%.1f；背景 %.0f，星点 %d，偏心 %.2f"),
                             final.settings.iso,
                             CapturePlan.formatDuration(final.settings.exposureSeconds),
                             final.settings.aperture ?? aperture,
                             final.metrics.background,
                             final.metrics.starCount,
                             final.metrics.medianEccentricity)
        return AutoExposureResult(status: status, settings: final.settings,
                                  samples: samples, message: message)
    }

    private func quantizedISO(_ iso: Int) -> Int {
        let clamped = min(config.isoRange.upperBound,
                          max(config.isoRange.lowerBound, iso))
        return AutoExposureMath.standardISO(nearest: clamped)
    }

    /// Core Image can decode a very dark NEF into a two-level image: most
    /// pixels zero, the rest at a high plateau. Background and star metrics
    /// are meaningless in that state, so the search must stop instead of
    /// oscillating between extremes.
    private func isDecodeSuspect(_ metrics: FrameMetrics) -> Bool {
        if metrics.background <= 1 { return true }
        if metrics.background >= 40_000, metrics.starCount == 0,
           metrics.medianFWHM == 0 {
            return true
        }
        return false
    }

    private func quantizedShutter(_ seconds: Double) -> Double {
        let clamped = min(config.shutterRange.upperBound,
                          max(config.shutterRange.lowerBound, seconds))
        return AutoExposureMath.standardShutter(atMost: clamped)
    }
}
