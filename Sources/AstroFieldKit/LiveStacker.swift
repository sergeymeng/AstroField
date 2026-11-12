import Foundation
import CoreGraphics

public struct StackUpdate: Sendable {
    public var accepted: Bool
    public var reason: String?
    public var shift: (dx: Int, dy: Int)?
    public var acceptedCount: Int
    public var rejectedCount: Int
    public var coverage: Double
    public var mean: LumaImage?
    public var preview: CGImage?
}

/// Translation-aligned live stacker for small preview-resolution frames.
///
/// It aligns on star centroids and accumulates a mean. Rotation, field rotation,
/// parallax and complex foregrounds are explicitly out of scope for this stage.
public final class LiveStacker: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var width: Int
    public private(set) var height: Int
    private var sum: [Double]
    private var counts: [UInt16]
    private var reference: LumaImage
    private var referenceStars: [DetectedStar]
    private var acceptedCount = 0
    private var rejectedCount = 0
    public var maxShift = 220
    public var minStarsForAlignment = 3

    public init(reference: LumaImage, maxWidth: Int = 1000) {
        let ref = reference.downsampled(maxWidth: maxWidth)
        self.reference = ref
        self.width = ref.width
        self.height = ref.height
        self.sum = ref.pixels.map(Double.init)
        self.counts = [UInt16](repeating: 1, count: ref.width * ref.height)
        self.referenceStars = StarDetector.detect(in: ref, maxStars: 40)
        self.acceptedCount = 1
    }

    public func reset(with image: LumaImage, maxWidth: Int = 1000) {
        let ref = image.downsampled(maxWidth: maxWidth)
        lock.lock()
        reference = ref
        width = ref.width
        height = ref.height
        sum = ref.pixels.map(Double.init)
        counts = [UInt16](repeating: 1, count: ref.width * ref.height)
        referenceStars = StarDetector.detect(in: ref, maxStars: 40)
        acceptedCount = 1
        rejectedCount = 0
        lock.unlock()
    }

    public func add(_ image: LumaImage) -> StackUpdate {
        lock.lock(); defer { lock.unlock() }
        let frame = image.downsampled(maxWidth: width)
        guard frame.width == width, frame.height == height else {
            rejectedCount += 1
            return snapshot(accepted: false, reason: "尺寸不一致", shift: nil)
        }
        let stars = StarDetector.detect(in: frame, maxStars: 40)
        guard stars.count >= minStarsForAlignment else {
            rejectedCount += 1
            return snapshot(accepted: false, reason: "星点不足，未参与叠加", shift: nil)
        }
        guard let shift = estimateShift(referenceStars: referenceStars, newStars: stars) else {
            rejectedCount += 1
            return snapshot(accepted: false, reason: "无法估计平移，未参与叠加", shift: nil)
        }
        if abs(shift.dx) > maxShift || abs(shift.dy) > maxShift {
            rejectedCount += 1
            return snapshot(accepted: false,
                            reason: "位移过大（\(shift.dx), \(shift.dy)），可能已换构图",
                            shift: shift)
        }

        for y in 0..<height {
            let sy = y + shift.dy
            if sy < 0 || sy >= height { continue }
            let dstRow = y * width
            let srcRow = sy * width
            for x in 0..<width {
                let sx = x + shift.dx
                if sx < 0 || sx >= width { continue }
                let di = dstRow + x
                sum[di] += Double(frame.pixels[srcRow + sx])
                if counts[di] < UInt16.max { counts[di] += 1 }
            }
        }
        acceptedCount += 1
        return snapshot(accepted: true, reason: nil, shift: shift)
    }

    public func currentMean() -> LumaImage? {
        lock.lock(); defer { lock.unlock() }
        return meanLocked()
    }

    public var countsSummary: (accepted: Int, rejected: Int) {
        lock.lock(); defer { lock.unlock() }
        return (acceptedCount, rejectedCount)
    }

    // MARK: - Private

    private func snapshot(accepted: Bool, reason: String?,
                          shift: (dx: Int, dy: Int)?) -> StackUpdate {
        let total = width * height
        var covered = 0
        for count in counts where count > 0 { covered += 1 }
        let mean = meanLocked()
        return StackUpdate(accepted: accepted,
                           reason: reason,
                           shift: shift,
                           acceptedCount: acceptedCount,
                           rejectedCount: rejectedCount,
                           coverage: total > 0 ? Double(covered) / Double(total) : 0,
                           mean: mean,
                           preview: mean?.displayImage())
    }

    private func meanLocked() -> LumaImage? {
        var pixels = [Float](repeating: 0, count: width * height)
        for i in pixels.indices {
            let count = counts[i]
            if count > 0 {
                pixels[i] = Float(sum[i] / Double(count))
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    private func estimateShift(referenceStars: [DetectedStar],
                               newStars: [DetectedStar]) -> (dx: Int, dy: Int)? {
        let ref = Array(referenceStars.prefix(30))
        let new = Array(newStars.prefix(30))
        guard ref.count >= 3, new.count >= 3 else { return nil }
        struct Bin { var count = 0; var sumX = 0; var sumY = 0 }
        var bins: [String: Bin] = [:]
        for a in ref {
            for b in new {
                let dx = Int((b.x - a.x).rounded())
                let dy = Int((b.y - a.y).rounded())
                if abs(dx) > maxShift || abs(dy) > maxShift { continue }
                let key = "\(Int((Double(dx) / 4).rounded()))_\(Int((Double(dy) / 4).rounded()))"
                var bin = bins[key] ?? Bin()
                bin.count += 1
                bin.sumX += dx
                bin.sumY += dy
                bins[key] = bin
            }
        }
        guard let best = bins.values.max(by: { $0.count < $1.count }),
              best.count >= 3 else { return nil }
        let dx = Int((Double(best.sumX) / Double(best.count)).rounded())
        let dy = Int((Double(best.sumY) / Double(best.count)).rounded())
        return (dx, dy)
    }
}
