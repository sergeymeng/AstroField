import Foundation
import AFSpikeCore

public enum QualityVerdict: Codable, Equatable, Sendable {
    case accepted
    case warning(String)
    case rejected(String)
    case unmeasured(String)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    public var shortText: String {
        switch self {
        case .accepted: return "正常"
        case .warning(let text): return text
        case .rejected(let text): return text
        case .unmeasured(let text): return text
        }
    }
}

public enum QualityAction: Equatable, Sendable {
    case none
    case notice(String)
    case pauseForReview(String)
    case suggestRefocus(String)
}

public struct QualityBaseline: Equatable, Sendable {
    public var medianFWHM: Double
    public var background: Double
    public var medianStarCount: Double
    public var samples: Int
}

/// 连续拍摄的质量规则。只根据可比较的指标给建议；背景变化、星数不足不会被
/// 当成失焦证据。
public struct QualityEngine: Sendable {
    public private(set) var baseline: QualityBaseline?
    public var refocusSuggestions = 0
    public var maxRefocusSuggestions = 3
    public var minStars = 6
    public var noticeRatio = 1.25
    public var pauseRatio = 1.5
    public var backgroundRatio = 0.45

    public init() {}

    public mutating func reset() {
        baseline = nil
        refocusSuggestions = 0
    }

    public mutating func observe(_ metrics: FrameMetrics) -> (verdict: QualityVerdict, action: QualityAction) {
        guard metrics.starCount >= minStars else {
            return (.unmeasured("星点不足 \(metrics.starCount)"),
                    .none)
        }
        guard let base = baseline else {
            baseline = QualityBaseline(medianFWHM: metrics.medianFWHM,
                                       background: metrics.background,
                                       medianStarCount: Double(metrics.starCount),
                                       samples: 1)
            return (.accepted, .none)
        }

        let bgChange = base.background > 0
            ? abs(metrics.background - base.background) / base.background : 0
        if bgChange > backgroundRatio {
            baseline?.samples += 1
            return (.warning(String(format: "背景变化 %.0f%%", bgChange * 100)),
                    .notice("背景变化，清晰度暂缓判断"))
        }

        let fwhmRatio = base.medianFWHM > 0 ? metrics.medianFWHM / base.medianFWHM : 1
        if fwhmRatio > pauseRatio {
            if refocusSuggestions < maxRefocusSuggestions {
                refocusSuggestions += 1
                return (.warning(String(format: "FWHM +%.0f%%", (fwhmRatio - 1) * 100)),
                        .suggestRefocus(String(format: "FWHM +%.0f%%，建议复核对焦", (fwhmRatio - 1) * 100)))
            }
            return (.warning("星点偏大，已达复核上限"),
                    .notice("需人工检查"))
        }
        if fwhmRatio > noticeRatio {
            return (.warning(String(format: "FWHM +%.0f%%", (fwhmRatio - 1) * 100)),
                    .notice("清晰度下降趋势"))
        }
        if Double(metrics.starCount) < base.medianStarCount * 0.5 {
            return (.warning("星数减少"), .notice("可能薄云/遮挡"))
        }
        return (.accepted, .none)
    }
}
