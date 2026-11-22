import Foundation

/// Summary of a batch auto-stack over one session.
public struct SessionStackSummary: Sendable, Equatable {
    public var total: Int
    public var accepted: Int
    public var rejected: Int
    public var coverage: Double
    public var rejectedReasons: [String: Int]

    public init(total: Int, accepted: Int, rejected: Int,
                coverage: Double, rejectedReasons: [String: Int]) {
        self.total = total
        self.accepted = accepted
        self.rejected = rejected
        self.coverage = coverage
        self.rejectedReasons = rejectedReasons
    }

    public var reasonText: String {
        guard !rejectedReasons.isEmpty else { return "" }
        return rejectedReasons
            .sorted { $0.value > $1.value }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: L10n.text("，"))
    }
}

/// Batch star-aligned stacking for a finished session.
///
/// The first accepted frame is the astrometric reference; every later frame is
/// aligned by star centroids (translation only, matching a fixed tripod) and
/// averaged. Frames with too few stars or a too-large shift are rejected and
/// counted by reason instead of being forced into the stack.
public final class SessionStacker: @unchecked Sendable {
    private let lock = NSLock()
    private let maxWidth: Int
    private var live: LiveStacker?
    private var totalAdded = 0
    private var rejectedReasons: [String: Int] = [:]
    private var lastShift: (dx: Int, dy: Int)?
    private var lastCoverage: Double = 1

    public init(maxWidth: Int = 2_000) {
        self.maxWidth = maxWidth
    }

    /// True once a reference frame has been accepted.
    public var hasReference: Bool {
        lock.lock(); defer { lock.unlock() }
        return live != nil
    }

    /// Add one decoded frame. Returns true when it joined the stack.
    @discardableResult
    public func add(_ image: LumaImage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        totalAdded += 1
        if live == nil {
            live = LiveStacker(reference: image, maxWidth: maxWidth)
            return true
        }
        let update = live!.add(image)
        if update.accepted {
            if let shift = update.shift { lastShift = shift }
            lastCoverage = update.coverage
        } else {
            let reason = update.reason ?? L10n.text("未参与叠加")
            rejectedReasons[reason, default: 0] += 1
        }
        return update.accepted
    }

    /// Current mean image and a summary. Returns nil before any frame.
    public func result() -> (image: LumaImage, summary: SessionStackSummary)? {
        lock.lock(); defer { lock.unlock() }
        guard let live, let mean = live.currentMean() else { return nil }
        let counts = live.countsSummary
        return (mean, SessionStackSummary(total: totalAdded,
                                          accepted: counts.accepted,
                                          rejected: counts.rejected,
                                          coverage: lastCoverage,
                                          rejectedReasons: rejectedReasons))
    }

    public var lastAlignmentShift: (dx: Int, dy: Int)? {
        lock.lock(); defer { lock.unlock() }
        return lastShift
    }
}
