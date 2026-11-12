import Foundation
import CoreGraphics

public enum SkyCondition: String, Codable, CaseIterable, Sendable {
    case clear
    case fewStars
    case overcast
    case brightSky
    case noStars
    case obstruction

    public var displayName: String {
        switch self {
        case .clear: return "晴空"
        case .fewStars: return "少星"
        case .overcast: return "薄云"
        case .brightSky: return "亮背景"
        case .noStars: return "无星"
        case .obstruction: return "前景遮挡"
        }
    }
}

public struct SimulatedStar: Sendable {
    /// Normalized position 0...1 at t = 0.
    public var x: Double
    public var y: Double
    /// Peak amplitude at 1 s, ISO 800, f/2.8.
    public var peakFlux: Double
}

public struct SimulatorScene: Sendable {
    public var width = 2000
    public var height = 1333
    public var starCount = 80
    public var seed: UInt64 = 20261112
    /// Sky drift in full-resolution pixels per second.
    public var driftX: Double = 0.55
    public var driftY: Double = 0.12
    /// Background ADU at 1 s, ISO 800, f/2.8.
    public var background: Double = 120
    public var readNoise: Double = 14
    /// Relative brightening toward the bottom of the frame (light pollution).
    public var lightPollution: Double = 0.18
    public var condition: SkyCondition = .clear
    public var liveWidth = 1024

    public init() {}

    public func stars() -> [SimulatedStar] {
        var rng = SeededRandom(seed: seed)
        var out: [SimulatedStar] = []
        out.reserveCapacity(starCount)
        for i in 0..<starCount {
            let x = 0.03 + rng.uniform() * 0.94
            let y = 0.03 + rng.uniform() * 0.94
            // Log-uniform brightness with a few bright outliers.
            let logFlux = 2.35 + rng.uniform() * 1.75
            var flux = pow(10.0, logFlux)
            if i % 17 == 0 { flux *= 2.6 }
            out.append(SimulatedStar(x: x, y: y, peakFlux: flux))
        }
        return out
    }
}

/// Deterministic renderer for the simulated sky. All output is explicitly synthetic.
public final class SimulatorSky: @unchecked Sendable {
    public var scene: SimulatorScene
    private let stars: [SimulatedStar]

    public init(scene: SimulatorScene = SimulatorScene()) {
        self.scene = scene
        self.stars = scene.stars()
    }

    /// Render one frame.
    /// - Parameters:
    ///   - focusSigma: PSF sigma in full-resolution pixels.
    ///   - timeSeconds: simulated elapsed time since session start (drives drift).
    ///   - width/height: output size; normalized coordinates keep the same field of view.
    public func render(settings: ExposureSettings,
                       focusSigma: Double,
                       timeSeconds: Double,
                       width: Int,
                       height: Int,
                       seedOffset: UInt64,
                       isLive: Bool) -> LumaImage {
        let scale = Double(width) / Double(max(1, scene.width))
        let exposure = isLive ? min(max(settings.exposureSeconds, 0.25), 2.0)
                              : max(settings.exposureSeconds, 0.0001)
        let aperture = settings.aperture ?? 2.8
        let apertureFactor = pow(2.8 / max(aperture, 1.0), 2)
        let isoFactor = Double(max(settings.iso, 50)) / 800.0
        let gain = exposure * apertureFactor * isoFactor

        var background = scene.background * gain
        var starGain = gain
        var extraSigma: Double = 0
        var activeStars = stars

        switch scene.condition {
        case .clear:
            break
        case .fewStars:
            activeStars = Array(stars.prefix(max(3, stars.count / 6)))
            starGain *= 0.8
        case .overcast:
            background *= 6
            starGain *= 0.18
            extraSigma = 1.4
        case .brightSky:
            background = max(background, 3800 * isoFactor)
            starGain *= 0.5
        case .noStars:
            activeStars = []
        case .obstruction:
            activeStars = stars.filter { s in
                !(s.x < 0.38 && s.y > 0.55)
            }
        }

        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let pollution = 1.0 + scene.lightPollution * (Double(y) / Double(height) - 0.5)
            let value = Float(background * pollution)
            let row = y * width
            for x in 0..<width { pixels[row + x] = value }
        }

        let sigma = max(0.65, focusSigma * scale + extraSigma)
        let trail = max(0, abs(scene.driftX) * exposure * scale)
        let sigmaMajor = sqrt(sigma * sigma + pow(trail / 2.3548, 2))
        let sigmaMinor = sigma
        let angle = atan2(scene.driftY, scene.driftX)
        let cosA = cos(angle)
        let sinA = sin(angle)

        for star in activeStars {
            // Star position at mid-exposure, with linear drift.
            let t = timeSeconds + exposure / 2
            var fullX = star.x * Double(scene.width) + scene.driftX * t
            var fullY = star.y * Double(scene.height) + scene.driftY * t
            fullX = fullX.truncatingRemainder(dividingBy: Double(scene.width))
            fullY = fullY.truncatingRemainder(dividingBy: Double(scene.height))
            if fullX < 0 { fullX += Double(scene.width) }
            if fullY < 0 { fullY += Double(scene.height) }

            let peak = star.peakFlux * starGain
            if peak <= 0 { continue }
            let cx = fullX * scale
            let cy = fullY * scale

            if scene.condition == .obstruction, fullX < 0.38 * Double(scene.width),
               fullY > 0.55 * Double(scene.height) {
                continue
            }

            let radius = Int(ceil(4.0 * sigmaMajor)) + 1
            let x0 = max(0, Int(cx) - radius), x1 = min(width - 1, Int(cx) + radius)
            let y0 = max(0, Int(cy) - radius), y1 = min(height - 1, Int(cy) + radius)
            if x0 > x1 || y0 > y1 { continue }
            let invMaj = 1.0 / (2.0 * sigmaMajor * sigmaMajor)
            let invMin = 1.0 / (2.0 * sigmaMinor * sigmaMinor)
            for py in y0...y1 {
                let dy = Double(py) - cy
                for px in x0...x1 {
                    let dx = Double(px) - cx
                    let u = dx * cosA + dy * sinA
                    let v = -dx * sinA + dy * cosA
                    let value = peak * exp(-(u * u * invMaj + v * v * invMin))
                    pixels[py * width + px] += Float(value)
                }
            }
        }

        // Foreground obstruction: dark branch/roof across the lower-left area.
        if scene.condition == .obstruction {
            let x1 = Int(0.38 * Double(width))
            let y0 = Int(0.55 * Double(height))
            for y in y0..<height {
                let row = y * width
                for x in 0..<x1 {
                    pixels[row + x] = 0
                }
            }
        }

        // Fast deterministic noise: a precomputed gaussian table plus one RNG
        // lookup per pixel. Noise is dominated by the background level; using a
        // constant sigma keeps this fast without changing the image statistics.
        var tableRng = SeededRandom(seed: scene.seed ^ (seedOffset &* 0x9E3779B97F4A7C15))
        var noiseTable = [Double](repeating: 0, count: 4096)
        for i in 0..<noiseTable.count { noiseTable[i] = tableRng.gaussian() }
        var rng = SeededRandom(seed: scene.seed ^ (seedOffset &* 0xD1B54A32D192ED03))
        let sigmaNoise = scene.readNoise + 0.45 * sqrt(max(background, 0))
        for i in pixels.indices {
            let index = Int(rng.next() & 4095)
            let value = Double(pixels[i]) + noiseTable[index] * sigmaNoise
            pixels[i] = Float(min(65535.0, max(0.0, value)))
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }
}

/// Simulated focus motor. Direction-dependent slope and backlash make the curve
/// deliberately asymmetric so a focus algorithm cannot pass with an ideal model.
public struct SimulatorFocusModel: Sendable {
    public var position: Double = 500
    public var bestPosition: Double = 500
    public var travelPerStep: Double = 1.2
    public var backlashSteps: Int = 6
    public var minPosition: Double = 0
    public var maxPosition: Double = 1000
    public var baseSigma: Double = 1.15
    /// Sigma slope when the motor is below the best position.
    public var slopeBelow: Double = 0.024
    /// Sigma slope when the motor is above the best position.
    public var slopeAbove: Double = 0.017
    public var lastDirection: FocusDirection?
    public var responseDelay: Double = 0.08

    public init() {}

    public var focusSigma: Double {
        let delta = position - bestPosition
        let slope = delta < 0 ? slopeBelow : slopeAbove
        return min(9.0, baseSigma + abs(delta) * slope)
    }

    public mutating func move(direction: FocusDirection, steps: Int) {
        guard steps != 0 else { return }
        var effective = Double(abs(steps)) * travelPerStep
        if let last = lastDirection, last != direction {
            effective = max(0, effective - Double(backlashSteps) * travelPerStep)
        }
        let signed = direction == .one ? effective : -effective
        position = min(maxPosition, max(minPosition, position + signed))
        lastDirection = direction
    }
}

public enum SimulatorFault: Sendable, Equatable {
    case failNextCapture(String)
    case busy(seconds: Double)
    case slowDownload(seconds: Double)
    case disconnectAfter(Int)
}
