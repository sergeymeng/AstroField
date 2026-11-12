import Foundation
import CoreGraphics

public struct StarTrailUpdate: Sendable {
    public var accepted: Bool
    public var reason: String?
    public var frames: Int
    public var rejected: Int
    public var totalExposure: Double
    public var maxGap: Double
    public var gapCount: Int
    public var preview: CGImage?
}

/// Fixed-tripod star trail accumulator: maximum blending, no alignment, plus
/// coverage gap statistics from frame timestamps.
public final class StarTrailStacker: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var width: Int
    public private(set) var height: Int
    private var maxPixels: [Float]
    private var frames = 1
    private var rejected = 0
    private var totalExposure: Double
    private var firstTimestamp: Date?
    private var lastTimestamp: Date?
    private var lastExposure: Double
    private var maxGap: Double = 0
    private var gapCount = 0
    public var gapTolerance: Double = 5.0

    public init(reference: LumaImage,
                referenceExposure: Double = 0,
                referenceTimestamp: Date? = nil,
                maxWidth: Int = 1000) {
        let ref = reference.downsampled(maxWidth: maxWidth)
        self.width = ref.width
        self.height = ref.height
        self.maxPixels = ref.pixels
        self.totalExposure = referenceExposure
        self.lastExposure = referenceExposure
        self.firstTimestamp = referenceTimestamp
        self.lastTimestamp = referenceTimestamp
    }

    public func add(_ image: LumaImage, exposureSeconds: Double,
                    timestamp: Date = Date()) -> StarTrailUpdate {
        lock.lock(); defer { lock.unlock() }
        let frame = image.downsampled(maxWidth: width)
        guard frame.width == width, frame.height == height else {
            rejected += 1
            return snapshot(accepted: false, reason: "尺寸不一致")
        }
        if let last = lastTimestamp {
            let gap = timestamp.timeIntervalSince(last)
            let expected = max(lastExposure, 0.1) + gapTolerance
            if gap > expected {
                gapCount += 1
                maxGap = max(maxGap, gap)
            }
        } else {
            firstTimestamp = timestamp
        }
        for i in maxPixels.indices {
            maxPixels[i] = max(maxPixels[i], frame.pixels[i])
        }
        frames += 1
        totalExposure += exposureSeconds
        lastTimestamp = timestamp
        lastExposure = exposureSeconds
        return snapshot(accepted: true, reason: nil)
    }

    public func current() -> LumaImage? {
        lock.lock(); defer { lock.unlock() }
        return meanLocked()
    }

    public var counts: (frames: Int, rejected: Int) {
        lock.lock(); defer { lock.unlock() }
        return (frames, rejected)
    }

    // MARK: - Private

    private func meanLocked() -> LumaImage? {
        LumaImage(width: width, height: height, pixels: maxPixels)
    }

    private func snapshot(accepted: Bool, reason: String?) -> StarTrailUpdate {
        let image = meanLocked()
        return StarTrailUpdate(accepted: accepted,
                               reason: reason,
                               frames: frames,
                               rejected: rejected,
                               totalExposure: totalExposure,
                               maxGap: maxGap,
                               gapCount: gapCount,
                               preview: image?.displayImage())
    }
}
