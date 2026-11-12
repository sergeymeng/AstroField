import Foundation
import AFSpikeCore

/// Fast frame metrics for interactive use. Unlike `StarAnalyzer.analyze`, this
/// samples background/noise and uses `StarDetector` for star measurements, so a
/// 2 MP frame finishes in well under a second.
public enum FrameAnalyzer {
    public static func metrics(_ image: LumaImage) -> FrameMetrics {
        let background = Double(image.median())
        let stride = max(1, image.pixels.count / 80_000)
        var deviations: [Float] = []
        deviations.reserveCapacity(image.pixels.count / stride + 1)
        var saturated = 0
        var sampled = 0
        var i = 0
        let saturation = image.maxValue * 0.98
        while i < image.pixels.count {
            let value = image.pixels[i]
            deviations.append(abs(value - Float(background)))
            if value >= saturation { saturated += 1 }
            sampled += 1
            i += stride
        }
        deviations.sort()
        let mad = deviations.isEmpty ? 0 : Double(deviations[deviations.count / 2])
        let noise = 1.4826 * mad

        let stars = StarDetector.detect(in: image)
        let usable = stars.filter { !$0.saturated }
        let fwhms = usable.map { $0.fwhm }.sorted()
        let eccentricities = usable.map { $0.eccentricity }.sorted()

        return FrameMetrics(starCount: usable.count,
                            background: background,
                            noise: noise,
                            medianFWHM: median(fwhms),
                            medianEccentricity: median(eccentricities),
                            saturatedFraction: sampled > 0
                                ? Double(saturated) / Double(sampled) : 0)
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2]
                          : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
