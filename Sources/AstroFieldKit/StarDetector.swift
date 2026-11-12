import Foundation
import CoreGraphics

public struct DetectedStar: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var peak: Double
    public var fwhm: Double
    public var eccentricity: Double
    public var saturated: Bool
}

public struct FocusMeasurement: Sendable, Equatable {
    public var medianFWHM: Double
    public var starCount: Int
    public var medianEccentricity: Double

    public init(medianFWHM: Double, starCount: Int, medianEccentricity: Double) {
        self.medianFWHM = medianFWHM
        self.starCount = starCount
        self.medianEccentricity = medianEccentricity
    }

    public var isUsable: Bool { starCount > 0 && medianFWHM > 0 }
}

/// Star detection on decoded luminance. Used for focus and alignment; measurements
/// keep their source image so the UI can show what was measured.
public enum StarDetector {
    public static func detect(in image: LumaImage, thresholdSigma: Double = 5.0,
                              maxStars: Int = 300) -> [DetectedStar] {
        let pixels = image.pixels
        let width = image.width
        let height = image.height
        guard pixels.count == width * height, width > 4, height > 4 else { return [] }

        let bg = Double(image.median())
        let stride = max(1, pixels.count / 80_000)
        var deviations: [Double] = []
        var i = 0
        while i < pixels.count {
            deviations.append(abs(Double(pixels[i]) - bg))
            i += stride
        }
        deviations.sort()
        let mad = deviations.isEmpty ? 0 : deviations[deviations.count / 2]
        let sigma = max(1e-3, 1.4826 * mad)
        let threshold = Float(bg + thresholdSigma * sigma)
        let saturation: Float = image.maxValue * 0.98

        var visited = [Bool](repeating: false, count: pixels.count)
        var stars: [DetectedStar] = []
        let neighbours = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in 0..<pixels.count {
            if visited[start] || pixels[start] < threshold { continue }
            visited[start] = true
            var stack = [start]
            var component: [Int] = []
            while let idx = stack.popLast() {
                component.append(idx)
                if component.count > 4096 { break }
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
            guard component.count >= 4, component.count <= 4096 else { continue }

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
            guard sw > 0 else { continue }
            let cx = sx / sw
            let cy = sy / sw
            let mu20 = sxx / sw - cx * cx
            let mu02 = syy / sw - cy * cy
            let mu11 = sxy / sw - cx * cy
            let varAvg = max(0, (mu20 + mu02) / 2)
            let fwhm = 2.3548 * sqrt(varAvg)
            guard fwhm >= 0.6, fwhm <= 60 else { continue }
            let common = sqrt(max(0, pow((mu20 - mu02) / 2, 2) + mu11 * mu11))
            let l1 = varAvg + common
            let l2 = max(0, varAvg - common)
            let ecc = l1 > 1e-9 ? sqrt(max(0, 1 - l2 / l1)) : 0
            stars.append(DetectedStar(x: cx, y: cy, peak: Double(peak),
                                      fwhm: fwhm, eccentricity: ecc,
                                      saturated: peak >= saturation))
        }

        stars.sort { $0.peak > $1.peak }
        return Array(stars.prefix(maxStars))
    }

    /// Measure the median FWHM of unsaturated stars inside an optional normalized region.
    public static func measure(in image: LumaImage, region: CGRect? = nil) -> FocusMeasurement {
        var cropped = image
        if let region {
            let x = max(0, Int(region.minX * Double(image.width)))
            let y = max(0, Int(region.minY * Double(image.height)))
            let w = max(2, Int(region.width * Double(image.width)))
            let h = max(2, Int(region.height * Double(image.height)))
            if let c = image.cropped(x: x, y: y, width: min(w, image.width - x),
                                     height: min(h, image.height - y)) {
                cropped = c
            }
        }
        let stars = detect(in: cropped)
        let usable = stars.filter { !$0.saturated }
        guard !usable.isEmpty else {
            return FocusMeasurement(medianFWHM: 0, starCount: 0, medianEccentricity: 0)
        }
        let fwhms = usable.map { $0.fwhm }.sorted()
        let eccs = usable.map { $0.eccentricity }.sorted()
        return FocusMeasurement(medianFWHM: median(fwhms),
                                starCount: usable.count,
                                medianEccentricity: median(eccs))
    }


    /// Fast local-maximum measurement for focus search. Relative values are what
    /// matter here; full-frame analysis still uses `detect`/`measure`.
    public static func measureFast(in image: LumaImage, region: CGRect? = nil) -> FocusMeasurement {
        var cropped = image
        if let region {
            let x = max(0, Int(region.minX * Double(image.width)))
            let y = max(0, Int(region.minY * Double(image.height)))
            let w = max(2, Int(region.width * Double(image.width)))
            let h = max(2, Int(region.height * Double(image.height)))
            if let c = image.cropped(x: x, y: y, width: min(w, image.width - x),
                                     height: min(h, image.height - y)) {
                cropped = c
            }
        }
        let w = cropped.width
        let h = cropped.height
        guard w > 8, h > 8 else {
            return FocusMeasurement(medianFWHM: 0, starCount: 0, medianEccentricity: 0)
        }
        let pixels = cropped.pixels
        let bg = Double(cropped.median())
        let stride = max(1, pixels.count / 40_000)
        var deviations: [Float] = []
        var i = 0
        while i < pixels.count {
            deviations.append(abs(pixels[i] - Float(bg)))
            i += stride
        }
        deviations.sort()
        let mad = deviations.isEmpty ? 0 : Double(deviations[deviations.count / 2])
        let sigma = max(1e-3, 1.4826 * mad)
        let threshold = Float(bg + 4.0 * sigma)
        let saturation = cropped.maxValue * 0.98

        var fwhms: [Double] = []
        var eccentricities: [Double] = []
        for y in 3..<(h - 3) {
            let row = y * w
            for x in 3..<(w - 3) {
                let value = pixels[row + x]
                if value < threshold || value >= saturation { continue }
                var isMaximum = true
                for dy in -1...1 {
                    let nrow = (y + dy) * w
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        if pixels[nrow + x + dx] > value { isMaximum = false; break }
                    }
                    if !isMaximum { break }
                }
                if !isMaximum { continue }
                var sw = 0.0, sx = 0.0, sy = 0.0
                var sxx = 0.0, syy = 0.0, sxy = 0.0
                for dy in -3...3 {
                    let nrow = (y + dy) * w
                    for dx in -3...3 {
                        let weight = Double(max(0, pixels[nrow + x + dx] - Float(bg)))
                        if weight <= 0 { continue }
                        let px = Double(x + dx)
                        let py = Double(y + dy)
                        sw += weight
                        sx += weight * px
                        sy += weight * py
                        sxx += weight * px * px
                        syy += weight * py * py
                        sxy += weight * px * py
                    }
                }
                guard sw > 0 else { continue }
                let cx = sx / sw
                let cy = sy / sw
                let mu20 = sxx / sw - cx * cx
                let mu02 = syy / sw - cy * cy
                let mu11 = sxy / sw - cx * cy
                let varAvg = max(0, (mu20 + mu02) / 2)
                let fwhm = 2.3548 * sqrt(varAvg)
                guard fwhm >= 0.5, fwhm <= 60 else { continue }
                let common = sqrt(max(0, pow((mu20 - mu02) / 2, 2) + mu11 * mu11))
                let l1 = varAvg + common
                let l2 = max(0, varAvg - common)
                let ecc = l1 > 1e-9 ? sqrt(max(0, 1 - l2 / l1)) : 0
                fwhms.append(fwhm)
                eccentricities.append(ecc)
            }
        }
        guard !fwhms.isEmpty else {
            return FocusMeasurement(medianFWHM: 0, starCount: 0, medianEccentricity: 0)
        }
        fwhms.sort()
        eccentricities.sort()
        return FocusMeasurement(medianFWHM: median(fwhms),
                                starCount: fwhms.count,
                                medianEccentricity: median(eccentricities))
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2]
                          : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
