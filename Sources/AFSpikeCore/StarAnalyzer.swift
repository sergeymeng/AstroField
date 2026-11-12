import Foundation

public struct SyntheticStar: Sendable {
    public var x: Double
    public var y: Double
    public var flux: Double
    public var sigma: Double
    public init(x: Double, y: Double, flux: Double, sigma: Double) {
        self.x = x; self.y = y; self.flux = flux; self.sigma = sigma
    }
}

public struct SyntheticField {
    public var width: Int
    public var height: Int
    public var pixels: [Float]
    public var truth: [SyntheticStar]
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
    }
}

public enum SyntheticFieldGenerator {
    public static func make(width: Int = 512, height: Int = 512,
                            starCount: Int = 24, sigma: Double = 2.0,
                            background: Double = 1000.0, noise: Double = 20.0,
                            seed: UInt64 = 42) -> SyntheticField {
        var rng = SplitMix64(seed: seed)
        var stars: [SyntheticStar] = []
        stars.reserveCapacity(starCount)
        for _ in 0..<starCount {
            let x = 20.0 + rng.uniform() * Double(width - 40)
            let y = 20.0 + rng.uniform() * Double(height - 40)
            let flux = 3000.0 + rng.uniform() * 12000.0
            stars.append(SyntheticStar(x: x, y: y, flux: flux, sigma: sigma))
        }

        var pixels = [Float](repeating: Float(background), count: width * height)
        for s in stars {
            let radius = Int(ceil(6.0 * s.sigma))
            let x0 = max(0, Int(s.x) - radius), x1 = min(width - 1, Int(s.x) + radius)
            let y0 = max(0, Int(s.y) - radius), y1 = min(height - 1, Int(s.y) + radius)
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - s.x
                    let dy = Double(y) - s.y
                    let v = s.flux * exp(-(dx * dx + dy * dy) / (2.0 * s.sigma * s.sigma))
                    pixels[y * width + x] += Float(v)
                }
            }
        }
        for i in pixels.indices {
            pixels[i] += Float(rng.gaussian() * noise)
            pixels[i] = min(65535, max(0, pixels[i]))
        }
        return SyntheticField(width: width, height: height, pixels: pixels, truth: stars)
    }
}

public enum StarAnalyzer {
    public static func median(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? Double(s[n / 2]) : (Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2
    }

    public static func mad(_ values: [Float], median m: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let dev = values.map { abs(Double($0) - m) }.sorted()
        let n = dev.count
        return n % 2 == 1 ? dev[n / 2] : (dev[n / 2 - 1] + dev[n / 2]) / 2
    }

    public static func analyze(pixels: [Float], width: Int, height: Int,
                               maxValue: Float = 65535) -> FrameMetrics {
        let bg = median(pixels)
        let sigma = max(1e-6, 1.4826 * mad(pixels, median: bg))
        let threshold = Float(bg + 5.0 * sigma)
        let n = width * height
        var visited = [Bool](repeating: false, count: n)
        var fwhms: [Double] = []
        var eccs: [Double] = []
        var saturated = 0

        for i in 0..<n where pixels[i] >= maxValue * 0.98 { saturated += 1 }

        let neighbours = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in 0..<n {
            if visited[start] || pixels[start] < threshold { continue }
            visited[start] = true
            var stack = [start]
            var component: [Int] = []
            while let idx = stack.popLast() {
                component.append(idx)
                let x = idx % width
                let y = idx / width
                for (dx, dy) in neighbours {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                    let ni = ny * width + nx
                    if !visited[ni] && pixels[ni] >= threshold {
                        visited[ni] = true
                        stack.append(ni)
                    }
                }
            }
            guard component.count >= 3, component.count <= 2000 else { continue }

            var sw = 0.0, sx = 0.0, sy = 0.0
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            var peak: Float = 0
            for idx in component {
                let x = Double(idx % width)
                let y = Double(idx / width)
                let w = Double(max(0, pixels[idx] - Float(bg)))
                peak = max(peak, pixels[idx])
                sw += w; sx += w * x; sy += w * y
                sxx += w * x * x; syy += w * y * y; sxy += w * x * y
            }
            if sw <= 0 || peak >= maxValue * 0.98 { continue }
            let cx = sx / sw, cy = sy / sw
            let mu20 = sxx / sw - cx * cx
            let mu02 = syy / sw - cy * cy
            let mu11 = sxy / sw - cx * cy
            let varAvg = max(0, (mu20 + mu02) / 2)
            let fwhm = 2.3548 * sqrt(varAvg)
            if fwhm < 0.8 || fwhm > 50 { continue }
            let common = sqrt(max(0, pow((mu20 - mu02) / 2, 2) + mu11 * mu11))
            let l1 = varAvg + common
            let l2 = max(0, varAvg - common)
            let ecc = l1 > 1e-9 ? sqrt(max(0, 1 - l2 / l1)) : 0
            fwhms.append(fwhm)
            eccs.append(ecc)
        }

        return FrameMetrics(
            starCount: fwhms.count,
            background: bg,
            noise: sigma,
            medianFWHM: median(fwhms.map(Float.init)),
            medianEccentricity: median(eccs.map(Float.init)),
            saturatedFraction: Double(saturated) / Double(n)
        )
    }
}
