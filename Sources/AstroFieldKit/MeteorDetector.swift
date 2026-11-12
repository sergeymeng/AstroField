import Foundation

public struct MeteorCandidate: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var centerX: Double
    public var centerY: Double
    public var width: Int
    public var height: Int
    public var length: Int
    public var aspect: Double
    public var peak: Double
    public var pixelCount: Int
    public var angleDegrees: Double

    public init(id: UUID = UUID(), centerX: Double, centerY: Double,
                width: Int, height: Int, length: Int, aspect: Double,
                peak: Double, pixelCount: Int, angleDegrees: Double) {
        self.id = id
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.length = length
        self.aspect = aspect
        self.peak = peak
        self.pixelCount = pixelCount
        self.angleDegrees = angleDegrees
    }
}

/// Bright elongated-component detector for meteor / satellite candidates.
/// This is a candidate finder, not a classifier: results must be reviewed by a
/// person and never cause frames to be discarded automatically.
public enum MeteorDetector {
    public static func detect(in image: LumaImage,
                              thresholdSigma: Double = 7.0,
                              minLength: Int = 40,
                              minAspect: Double = 3.0,
                              maxCandidates: Int = 40) -> [MeteorCandidate] {
        let width = image.width
        let height = image.height
        let pixels = image.pixels
        guard width > 16, height > 16 else { return [] }

        let background = Double(image.median())
        let stride = max(1, pixels.count / 60_000)
        var deviations: [Float] = []
        var i = 0
        while i < pixels.count {
            deviations.append(abs(pixels[i] - Float(background)))
            i += stride
        }
        deviations.sort()
        let mad = deviations.isEmpty ? 0 : Double(deviations[deviations.count / 2])
        let sigma = max(1e-3, 1.4826 * mad)
        let threshold = Float(background + thresholdSigma * sigma)

        var visited = [Bool](repeating: false, count: pixels.count)
        var candidates: [MeteorCandidate] = []
        let neighbours = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for start in 0..<pixels.count where !visited[start] && pixels[start] >= threshold {
            visited[start] = true
            var stack = [start]
            var component: [Int] = []
            var minX = width, maxX = 0, minY = height, maxY = 0
            var peak: Float = 0
            var overflow = false
            while let index = stack.popLast() {
                component.append(index)
                if component.count > 60_000 { overflow = true; break }
                let x = index % width
                let y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                peak = max(peak, pixels[index])
                for (dx, dy) in neighbours {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                    let neighbour = ny * width + nx
                    if !visited[neighbour] && pixels[neighbour] >= threshold {
                        visited[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }
            if overflow { continue }
            let boxWidth = maxX - minX + 1
            let boxHeight = maxY - minY + 1
            let length = max(boxWidth, boxHeight)
            let short = max(1, min(boxWidth, boxHeight))
            let aspect = Double(length) / Double(short)
            guard length >= minLength, aspect >= minAspect,
                  component.count >= length else { continue }

            var sw = 0.0, sx = 0.0, sy = 0.0
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for index in component {
                let x = Double(index % width)
                let y = Double(index / width)
                let w = Double(max(0, pixels[index] - Float(background)))
                sw += w; sx += w * x; sy += w * y
                sxx += w * x * x; syy += w * y * y; sxy += w * x * y
            }
            guard sw > 0 else { continue }
            let cx = sx / sw, cy = sy / sw
            let mu20 = sxx / sw - cx * cx
            let mu02 = syy / sw - cy * cy
            let mu11 = sxy / sw - cx * cy
            let angle = 0.5 * atan2(2 * mu11, mu20 - mu02) * 180 / Double.pi
            candidates.append(MeteorCandidate(centerX: cx / Double(width),
                                              centerY: cy / Double(height),
                                              width: boxWidth,
                                              height: boxHeight,
                                              length: length,
                                              aspect: aspect,
                                              peak: Double(peak),
                                              pixelCount: component.count,
                                              angleDegrees: angle))
        }
        candidates.sort { $0.length > $1.length }
        return Array(candidates.prefix(maxCandidates))
    }
}
