import Foundation

public protocol FocusProbe: Sendable {
    func measure() async throws -> FocusMeasurement
    /// Positive steps move in direction one, negative in direction two.
    func move(signedSteps: Int) async throws
}

public final class ClosureFocusProbe: FocusProbe, @unchecked Sendable {
    private let measureClosure: () async throws -> FocusMeasurement
    private let moveClosure: (Int) async throws -> Void

    public init(measure: @escaping () async throws -> FocusMeasurement,
                move: @escaping (Int) async throws -> Void) {
        self.measureClosure = measure
        self.moveClosure = move
    }

    public func measure() async throws -> FocusMeasurement {
        try await measureClosure()
    }

    public func move(signedSteps: Int) async throws {
        try await moveClosure(signedSteps)
    }
}

public struct FocusSample: Sendable, Equatable {
    public var relativeSteps: Int
    public var measurement: FocusMeasurement

    public init(relativeSteps: Int, measurement: FocusMeasurement) {
        self.relativeSteps = relativeSteps
        self.measurement = measurement
    }
}

public enum FocusSearchStatus: String, Sendable, Equatable {
    case confirmed
    case unconfirmed
    case failed
    case cancelled

    public var displayText: String {
        switch self {
        case .confirmed: return "已确认"
        case .unconfirmed: return "尚未确认"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct FocusSearchResult: Sendable, Equatable {
    public var status: FocusSearchStatus
    public var bestRelativeSteps: Int?
    public var baseline: FocusMeasurement?
    public var best: FocusMeasurement?
    public var confidence: Double
    public var samples: [FocusSample]
    public var message: String
}

public struct FocusSearchConfig: Sendable {
    public var coarseStep: Int = 40
    public var fineStep: Int = 6
    public var maxCoarseMovesPerDirection: Int = 10
    public var fineOffsets: [Int] = [-2, -1, 1, 2]
    public var minStars: Int = 5
    public var minImprovement: Double = 0.06
    public var verifySamples: Int = 2

    public init() {}
}

/// Coarse-to-fine focus search. MFDrive has no absolute position, so every move is
/// relative and the search never assumes a repeatable step size across sessions.
public actor FocusSearcher {
    public init() {}

    public func run(probe: FocusProbe,
                    config: FocusSearchConfig = FocusSearchConfig(),
                    onSample: (@Sendable (FocusSample) -> Void)? = nil,
                    shouldCancel: @Sendable () -> Bool = { false }) async -> FocusSearchResult {
        var samples: [FocusSample] = []
        var position = 0

        func finish(_ status: FocusSearchStatus, bestSteps: Int?,
                    baseline: FocusMeasurement?, best: FocusMeasurement?,
                    confidence: Double, message: String) -> FocusSearchResult {
            FocusSearchResult(status: status, bestRelativeSteps: bestSteps,
                              baseline: baseline, best: best,
                              confidence: confidence, samples: samples, message: message)
        }

        do {
            let baseline = try await probe.measure()
            let baseSample = FocusSample(relativeSteps: 0, measurement: baseline)
            samples.append(baseSample)
            onSample?(baseSample)
            guard baseline.starCount >= config.minStars, baseline.medianFWHM > 0 else {
                return finish(.unconfirmed, bestSteps: nil, baseline: baseline, best: nil,
                              confidence: 0,
                              message: "星点不足 \(baseline.starCount)")
            }

            var best = baseline
            var bestPos = 0

            for direction in [1, -1] {
                if shouldCancel() {
                    return finish(.cancelled, bestSteps: bestPos, baseline: baseline,
                                  best: best, confidence: 0, message: "已取消")
                }
                if position != 0 {
                    try await probe.move(signedSteps: -position)
                    position = 0
                }
                var localBest = baseline
                var localBestPos = 0
                var improved = false
                var worsening = 0
                var lostStars = false

                for _ in 0..<config.maxCoarseMovesPerDirection {
                    if shouldCancel() {
                        return finish(.cancelled, bestSteps: bestPos, baseline: baseline,
                                      best: best, confidence: 0, message: "已取消")
                    }
                    let delta = direction * config.coarseStep
                    try await probe.move(signedSteps: delta)
                    position += delta
                    let measurement = try await probe.measure()
                    let sample = FocusSample(relativeSteps: position, measurement: measurement)
                    samples.append(sample)
                    onSample?(sample)

                    if measurement.starCount < config.minStars {
                        lostStars = true
                        break
                    }
                    if measurement.medianFWHM < localBest.medianFWHM * 0.985 {
                        localBest = measurement
                        localBestPos = position
                        improved = true
                        worsening = 0
                    } else {
                        worsening += 1
                    }
                    if worsening >= 2 { break }
                }

                if improved, localBest.medianFWHM < best.medianFWHM {
                    best = localBest
                    bestPos = localBestPos
                }
                if improved { break }
                if lostStars { break }
            }

            // Fine search around the coarse best.
            if bestPos != position {
                try await probe.move(signedSteps: bestPos - position)
                position = bestPos
            }
            var fineBest = best
            var fineBestPos = bestPos
            for offset in config.fineOffsets {
                if shouldCancel() {
                    return finish(.cancelled, bestSteps: bestPos, baseline: baseline,
                                  best: best, confidence: 0, message: "已取消")
                }
                let target = bestPos + offset * config.fineStep
                let delta = target - position
                if delta != 0 {
                    try await probe.move(signedSteps: delta)
                    position = target
                }
                let measurement = try await probe.measure()
                let sample = FocusSample(relativeSteps: position, measurement: measurement)
                samples.append(sample)
                onSample?(sample)
                if measurement.starCount >= config.minStars,
                   measurement.medianFWHM < fineBest.medianFWHM {
                    fineBest = measurement
                    fineBestPos = target
                }
            }
            if fineBestPos != position {
                try await probe.move(signedSteps: fineBestPos - position)
                position = fineBestPos
            }

            // Verify with repeated measurements at the chosen position.
            var verifications: [FocusMeasurement] = []
            for _ in 0..<max(1, config.verifySamples) {
                if shouldCancel() {
                    return finish(.cancelled, bestSteps: fineBestPos, baseline: baseline,
                                  best: fineBest, confidence: 0, message: "已取消")
                }
                verifications.append(try await probe.measure())
            }
            let verified = medianMeasurement(verifications) ?? fineBest
            let improvement = baseline.medianFWHM > 0
                ? (baseline.medianFWHM - verified.medianFWHM) / baseline.medianFWHM
                : 0
            let confidence = max(0, min(1, improvement / 0.20))

            if verified.starCount >= config.minStars, improvement >= config.minImprovement {
                return finish(.confirmed, bestSteps: fineBestPos, baseline: baseline,
                              best: verified, confidence: confidence,
                              message: String(format: "已确认，FWHM 改善 %.0f%%，相对步数 %+d",
                                              improvement * 100, fineBestPos))
            }
            return finish(.unconfirmed, bestSteps: fineBestPos, baseline: baseline,
                          best: verified, confidence: confidence,
                          message: String(format: "尚未确认，改善 %.0f%%（阈值 %.0f%%）",
                                          improvement * 100, config.minImprovement * 100))
        } catch {
            return finish(.failed, bestSteps: nil, baseline: nil, best: nil,
                          confidence: 0, message: "对焦失败：\(error)")
        }
    }

    private func medianMeasurement(_ list: [FocusMeasurement]) -> FocusMeasurement? {
        guard !list.isEmpty else { return nil }
        let fwhm = list.map { $0.medianFWHM }.sorted()
        let ecc = list.map { $0.medianEccentricity }.sorted()
        let stars = list.map { Double($0.starCount) }.sorted()
        func median(_ sorted: [Double]) -> Double {
            let n = sorted.count
            guard n > 0 else { return 0 }
            return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return FocusMeasurement(medianFWHM: median(fwhm),
                                starCount: Int(median(stars).rounded()),
                                medianEccentricity: median(ecc))
    }
}
