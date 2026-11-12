import Foundation
import CoreGraphics

/// Linear-ish luminance image used for measurement.
///
/// This is decoded luminance, not sensor-native data. Display stretch and white
/// balance never modify these values.
public struct LumaImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]
    public var maxValue: Float

    public init(width: Int, height: Int, pixels: [Float], maxValue: Float = 65535) {
        precondition(pixels.count == width * height, "pixel buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.maxValue = maxValue
    }

    public static func zeros(width: Int, height: Int) -> LumaImage {
        LumaImage(width: width, height: height,
                  pixels: [Float](repeating: 0, count: width * height))
    }

    // MARK: - From CGImage

    /// Convert a CGImage into 16-bit luminance. The result is color-managed decoded
    /// luminance, suitable for star measurement but not a substitute for raw sensor data.
    public static func from(cgImage: CGImage, maxWidth: Int? = nil) -> LumaImage? {
        var image = cgImage
        if let maxWidth, cgImage.width > maxWidth {
            let scale = Double(maxWidth) / Double(cgImage.width)
            let w = maxWidth
            let h = max(1, Int((Double(cgImage.height) * scale).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            image = scaled
        }
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt16](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 16, bytesPerRow: w * 2,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var pixels = [Float](repeating: 0, count: w * h)
        for i in 0..<pixels.count { pixels[i] = Float(buffer[i]) }
        return LumaImage(width: w, height: h, pixels: pixels)
    }

    // MARK: - Cropping / scaling

    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> LumaImage? {
        guard x >= 0, y >= 0, w > 1, h > 1, x + w <= width, y + h <= height else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            let src = (y + row) * width + x
            let dst = row * w
            out.replaceSubrange(dst..<(dst + w), with: pixels[src..<(src + w)])
        }
        return LumaImage(width: w, height: h, pixels: out, maxValue: maxValue)
    }

    /// Box-filtered downsample that keeps the field of view.
    public func downsampled(maxWidth: Int) -> LumaImage {
        guard maxWidth > 8, width > maxWidth else { return self }
        let factor = Double(width) / Double(maxWidth)
        let w = maxWidth
        let h = max(1, Int((Double(height) / factor).rounded()))
        var out = [Float](repeating: 0, count: w * h)
        for oy in 0..<h {
            let sy0 = Int(Double(oy) * factor)
            let sy1 = min(height, max(sy0 + 1, Int(Double(oy + 1) * factor)))
            for ox in 0..<w {
                let sx0 = Int(Double(ox) * factor)
                let sx1 = min(width, max(sx0 + 1, Int(Double(ox + 1) * factor)))
                var sum: Float = 0
                var count = 0
                for sy in sy0..<sy1 {
                    let row = sy * width
                    for sx in sx0..<sx1 {
                        sum += pixels[row + sx]
                        count += 1
                    }
                }
                out[oy * w + ox] = count > 0 ? sum / Float(count) : 0
            }
        }
        return LumaImage(width: w, height: h, pixels: out, maxValue: maxValue)
    }

    /// Max-pooled downsample for thumbnails: keeps stars visible instead of
    /// averaging them into the background.
    public func downsampledMax(maxWidth: Int) -> LumaImage {
        guard maxWidth > 8, width > maxWidth else { return self }
        let factor = Double(width) / Double(maxWidth)
        let w = maxWidth
        let h = max(1, Int((Double(height) / factor).rounded()))
        var out = [Float](repeating: 0, count: w * h)
        for oy in 0..<h {
            let sy0 = Int(Double(oy) * factor)
            let sy1 = min(height, max(sy0 + 1, Int(Double(oy + 1) * factor)))
            for ox in 0..<w {
                let sx0 = Int(Double(ox) * factor)
                let sx1 = min(width, max(sx0 + 1, Int(Double(ox + 1) * factor)))
                var maximum: Float = 0
                for sy in sy0..<sy1 {
                    let row = sy * width
                    for sx in sx0..<sx1 {
                        maximum = max(maximum, pixels[row + sx])
                    }
                }
                out[oy * w + ox] = maximum
            }
        }
        return LumaImage(width: w, height: h, pixels: out, maxValue: maxValue)
    }

    // MARK: - Statistics

    /// Star-field display range: median background becomes black, white sits at
    /// 30 noise sigma above it. Display only; measurement input is unchanged.
    public func autoRange() -> (low: Float, high: Float) {
        let stride = max(1, pixels.count / 120_000)
        var sample: [Float] = []
        sample.reserveCapacity(pixels.count / stride + 1)
        var i = 0
        while i < pixels.count {
            sample.append(pixels[i])
            i += stride
        }
        guard !sample.isEmpty else { return (0, 1) }
        sample.sort()
        let median = sample[sample.count / 2]
        var deviations: [Float] = []
        deviations.reserveCapacity(sample.count)
        for value in sample { deviations.append(abs(value - median)) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        let sigma = max(1e-3, 1.4826 * mad)
        let low = median - 0.25 * sigma
        let high = min(maxValue, median + 30 * sigma)
        return high > low ? (low, high) : (low, low + 1)
    }

    public func median() -> Float {
        guard !pixels.isEmpty else { return 0 }
        let stride = max(1, pixels.count / 60_000)
        var sample: [Float] = []
        var i = 0
        while i < pixels.count {
            sample.append(pixels[i])
            i += stride
        }
        sample.sort()
        return sample[sample.count / 2]
    }

    // MARK: - Display

    /// 8-bit grayscale preview. `low`/`high` come from the user's display stretch.
    public func displayImage(low: Float? = nil, high: Float? = nil,
                             gamma: Double = 0.7) -> CGImage? {
        let auto = (low == nil || high == nil) ? autoRange() : (0, 0)
        let lowValue = low ?? auto.0
        var highValue = high ?? auto.1
        if highValue <= lowValue { highValue = lowValue + 1 }
        let span = max(1, highValue - lowValue)
        // Lookup table avoids a pow() per pixel on multi-megapixel previews.
        let tableSize = 1024
        var table = [UInt8](repeating: 0, count: tableSize + 1)
        for i in 0...tableSize {
            var v = Float(i) / Float(tableSize)
            if gamma != 1 { v = pow(v, Float(gamma)) }
            table[i] = UInt8(min(255, max(0, v * 255)).rounded())
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in pixels.indices {
            var v = (pixels[i] - lowValue) / span
            v = min(1, max(0, v))
            bytes[i] = table[Int(v * Float(tableSize))]
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Simple deterministic RNG (SplitMix64) shared by simulator and tests.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    public mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
    }

    public mutating func uniform(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + uniform() * (range.upperBound - range.lowerBound)
    }
}
