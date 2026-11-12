import Foundation

/// `afspike iccfocus`: manual focus drive over ImageCaptureCore PTP.
public final class ICCFocus {
    private let direction: UInt32
    private let steps: UInt32

    public init(direction: UInt32, steps: UInt32) {
        self.direction = direction
        self.steps = steps
    }

    public func run() {
        let camera = ICCCamera()
        camera.log = { print("icc: \($0)") }
        do {
            try camera.connect()
            try camera.startLiveView()
            print("live view ready; MfDrive dir=\(direction) steps=\(steps)")
            let outcome = try camera.mfDrive(direction: direction, steps: steps)
            switch outcome {
            case .completed: print("MfDrive complete")
            case .reachedEnd: print("MfDrive reached step end")
            case .insufficientSteps: print("MfDrive step insufficiency")
            }
            try? camera.endLiveView()
        } catch {
            print("icc focus failed: \(error)")
        }
        camera.close()
    }
}
