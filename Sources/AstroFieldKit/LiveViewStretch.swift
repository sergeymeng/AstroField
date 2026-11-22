import Foundation
import CoreGraphics

/// Display-only stretch for LiveView frames.
///
/// The input is the decoded camera JPEG or a linear 8-bit render of the
/// simulator frame. The output exists only for the monitor: median background
/// is mapped to black, white sits at `gainSigma` noise sigmas above the median,
/// and the result is gamma encoded. Measurement code keeps using the original
/// frame bytes and never sees these pixels.
public struct LiveViewStretchSettings: Codable, Equatable, Sendable {
    /// When false the backend returns no display image and the raw frame is
    /// shown unchanged.
    public var enabled: Bool
    /// White point, in background noise sigmas above the median.
    public var gainSigma: Double
    /// Black point, in noise sigmas relative to the median. Negative pushes
    /// the background below black; 0 puts the median exactly at black.
    public var blackSigma: Double
    /// Display gamma. 0.7 matches the simulator's star-field preview.
    public var gamma: Double

    public init(enabled: Bool = true,
                gainSigma: Double = 30,
                blackSigma: Double = -0.25,
                gamma: Double = 0.7) {
        self.enabled = enabled
        self.gainSigma = gainSigma
        self.blackSigma = blackSigma
        self.gamma = gamma
    }

    public static let `default` = LiveViewStretchSettings()
}

/// Background statistics behind one stretched frame, in 8-bit levels.
public struct LiveViewStretchStats: Equatable, Sendable {
    public var median: Double
    public var sigma: Double
    public var low: Double
    public var high: Double

    public init(median: Double, sigma: Double, low: Double, high: Double) {
        self.median = median
        self.sigma = sigma
        self.low = low
        self.high = high
    }
}

public enum LiveViewStretch {
    /// Renders an 8-bit grayscale display frame. Returns nil when disabled,
    /// when the image cannot be drawn, or when the result would be degenerate.
    public static func stretch(_ image: CGImage,
                               settings: LiveViewStretchSettings)
        -> (image: CGImage, stats: LiveViewStretchStats)? {
        guard settings.enabled else { return nil }
        let width = image.width
        let height = image.height
        guard width > 1, height > 1, width * height < 40_000_000 else { return nil }

        // Draw into RGBA8 once. The camera JPEG is already display-referred;
        // no additional tone mapping is applied here.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var drawn = false
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return
            }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drawn = true
        }
        guard drawn else { return nil }

        let pixelCount = width * height
        let stride = max(1, pixelCount / 120_000)
        var histogram = [Int32](repeating: 0, count: 256)
        var samples = 0
        rgba.withUnsafeBufferPointer { source in
            var index = 0
            while index < pixelCount {
                let offset = index * 4
                let luma = (54 * Int(source[offset])
                            + 183 * Int(source[offset + 1])
                            + 19 * Int(source[offset + 2])) >> 8
                histogram[min(255, max(0, luma))] += 1
                samples += 1
                index += stride
            }
        }
        guard samples > 0 else { return nil }

        var cumulative = 0
        var medianBin = 0
        let half = samples / 2
        for bin in 0..<256 {
            cumulative += Int(histogram[bin])
            if cumulative >= half {
                medianBin = bin
                break
            }
        }
        var deviation = 0
        histogram.withUnsafeBufferPointer { bins in
            for bin in 0..<256 {
                deviation += Int(bins[bin]) * abs(bin - medianBin)
            }
        }
        let mad = Double(deviation) / Double(samples)
        // Quantization floor: a uniform JPEG still needs a usable sigma.
        let sigma = max(0.8, 1.4826 * mad)

        var low = Double(medianBin) + settings.blackSigma * sigma
        var high = Double(medianBin) + settings.gainSigma * sigma
        low = min(255, max(0, low))
        high = min(255, max(low + 1, high))

        var table = [UInt8](repeating: 0, count: 256)
        let span = high - low
        for value in 0..<256 {
            var normalized = (Double(value) - low) / span
            normalized = min(1, max(0, normalized))
            if settings.gamma != 1 {
                normalized = pow(normalized, settings.gamma)
            }
            table[value] = UInt8(min(255, max(0, (normalized * 255).rounded())))
        }

        var gray = [UInt8](repeating: 0, count: pixelCount)
        table.withUnsafeBufferPointer { lut in
            gray.withUnsafeMutableBufferPointer { output in
                rgba.withUnsafeBufferPointer { source in
                    for pixel in 0..<pixelCount {
                        let offset = pixel * 4
                        let luma = (54 * Int(source[offset])
                                    + 183 * Int(source[offset + 1])
                                    + 19 * Int(source[offset + 2])) >> 8
                        output[pixel] = lut[min(255, max(0, luma))]
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let output = CGImage(width: width, height: height,
                                   bitsPerComponent: 8, bitsPerPixel: 8,
                                   bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                   provider: provider, decode: nil,
                                   shouldInterpolate: true, intent: .defaultIntent) else {
            return nil
        }
        let stats = LiveViewStretchStats(median: Double(medianBin),
                                         sigma: sigma,
                                         low: low,
                                         high: high)
        return (output, stats)
    }
}
