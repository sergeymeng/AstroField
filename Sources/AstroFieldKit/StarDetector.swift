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

/// Pixel-integrated Gaussian PSF fit for one star.
///
/// The model integrates the Gaussian over each pixel instead of sampling its
/// centre, which removes most of the systematic FWHM bias for the 1–2 px stars
/// seen on undersampled wide-field frames.
public struct PSFFit: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var sigma: Double
    public var fwhm: Double
    public var peak: Double
    public var background: Double
    public var residual: Double

    public init(x: Double, y: Double, sigma: Double, peak: Double,
                background: Double, residual: Double) {
        self.x = x
        self.y = y
        self.sigma = sigma
        self.fwhm = 2.3548 * sigma
        self.peak = peak
        self.background = background
        self.residual = residual
    }
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

    /// Pixel-integrated Gaussian fit around one star.
    ///
    /// Fits `background + peak · Ix(σ) · Iy(σ)` where `Ix`/`Iy` are the Gaussian
    /// integrated over each pixel. This removes most of the FWHM bias of a
    /// centre-sampled second-moment estimate on undersampled stars.
    public static func fitPSF(in image: LumaImage, x: Double, y: Double,
                              radius: Int = 4) -> PSFFit? {
        let width = image.width
        let height = image.height
        let cx = Int(x.rounded())
        let cy = Int(y.rounded())
        let x0 = max(1, cx - radius)
        let x1 = min(width - 2, cx + radius)
        let y0 = max(1, cy - radius)
        let y1 = min(height - 2, cy + radius)
        guard x1 - x0 >= 4, y1 - y0 >= 4 else { return nil }

        var edge: [Float] = []
        edge.reserveCapacity(4 * (x1 - x0 + y1 - y0 + 2))
        for yy in y0...y1 {
            edge.append(image.pixels[yy * width + x0])
            edge.append(image.pixels[yy * width + x1])
        }
        for xx in x0...x1 {
            edge.append(image.pixels[y0 * width + xx])
            edge.append(image.pixels[y1 * width + xx])
        }
        edge.sort()
        let background0 = Double(edge[edge.count / 2])

        var sw = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0
        for yy in y0...y1 {
            let row = yy * width
            for xx in x0...x1 {
                let value = Double(image.pixels[row + xx]) - background0
                if value <= 0 { continue }
                let dx = Double(xx)
                let dy = Double(yy)
                sw += value
                sx += value * dx
                sy += value * dy
                sxx += value * dx * dx
                syy += value * dy * dy
            }
        }
        guard sw > 0 else { return nil }
        let mx = sx / sw
        let my = sy / sw
        let varX = max(0.01, sxx / sw - mx * mx)
        let varY = max(0.01, syy / sw - my * my)
        let sigma0 = max(0.4, min(3.5, sqrt((varX + varY) / 2)))

        var values = [Double](repeating: 0, count: (x1 - x0 + 1) * (y1 - y0 + 1))
        var index = 0
        for yy in y0...y1 {
            let row = yy * width
            for xx in x0...x1 {
                values[index] = Double(image.pixels[row + xx])
                index += 1
            }
        }

        func fitAt(sigma: Double) -> (sse: Double, peak: Double, bg: Double) {
            let inv = 1.0 / (sqrt(2.0) * sigma)
            var basis = [Double](repeating: 0, count: values.count)
            var i = 0
            for yy in y0...y1 {
                let iy = 0.5 * (erf((Double(yy) + 0.5 - my) * inv)
                                - erf((Double(yy) - 0.5 - my) * inv))
                for xx in x0...x1 {
                    let ix = 0.5 * (erf((Double(xx) + 0.5 - mx) * inv)
                                    - erf((Double(xx) - 0.5 - mx) * inv))
                    basis[i] = ix * iy
                    i += 1
                }
            }
            let n = Double(basis.count)
            var sb = 0.0, sbb = 0.0, sy = 0.0, sby = 0.0
            for i in basis.indices {
                let b = basis[i]
                let y = values[i]
                sb += b
                sbb += b * b
                sy += y
                sby += b * y
            }
            let det = n * sbb - sb * sb
            guard abs(det) > 1e-12 else { return (1e30, 0, background0) }
            let peak = (n * sby - sb * sy) / det
            let bg = (sy * sbb - sb * sby) / det
            var sse = 0.0
            for i in basis.indices {
                let model = bg + peak * basis[i]
                let d = values[i] - model
                sse += d * d
            }
            return (sse, peak, bg)
        }

        var lo = max(0.3, sigma0 * 0.5)
        var hi = min(4.0, sigma0 * 2.0)
        if hi <= lo { hi = lo + 0.2 }
        let phi = (sqrt(5.0) - 1) / 2
        var a = lo, b = hi
        var c = b - phi * (b - a)
        var d = a + phi * (b - a)
        var fc = fitAt(sigma: c).sse
        var fd = fitAt(sigma: d).sse
        for _ in 0..<16 {
            if fc < fd {
                b = d; d = c; fd = fc
                c = b - phi * (b - a)
                fc = fitAt(sigma: c).sse
            } else {
                a = c; c = d; fc = fd
                d = a + phi * (b - a)
                fd = fitAt(sigma: d).sse
            }
        }
        let sigma = (a + b) / 2
        let fit = fitAt(sigma: sigma)
        guard fit.peak > 0 else { return nil }
        let count = Double(values.count)
        return PSFFit(x: mx, y: my, sigma: sigma, peak: fit.peak,
                      background: fit.bg, residual: sqrt(max(0, fit.sse / count)))
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
        var fwhms: [Double] = []
        fwhms.reserveCapacity(usable.count)
        for star in usable.prefix(60) {
            if let fit = fitPSF(in: cropped, x: star.x, y: star.y) {
                fwhms.append(fit.fwhm)
            } else {
                fwhms.append(star.fwhm)
            }
        }
        let eccs = usable.map { $0.eccentricity }.sorted()
        fwhms.sort()
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
