import Foundation

/// `afspike icclv`: live view over ImageCaptureCore PTP, backed by `ICCCamera`.
public final class ICCLiveView {
    private let seconds: Double
    private let outDir: URL
    private let saveFrames: Bool
    private let liveViewSize: UInt8?

    public init(seconds: Double, outDir: URL, saveFrames: Bool = true,
                liveViewSize: UInt8? = nil) {
        self.seconds = seconds
        self.outDir = outDir
        self.saveFrames = saveFrames
        self.liveViewSize = liveViewSize
    }

    public func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let camera = ICCCamera()
        camera.log = { print("icc: \($0)") }
        var frames = 0
        var start = Date()
        do {
            try camera.connect()
            if let liveViewSize {
                try camera.setLiveViewSize(liveViewSize)
                print("liveviewsize = \(try camera.liveViewImageSize())")
            }
            try camera.startLiveView()
            start = Date()
            while Date().timeIntervalSince(start) < seconds {
                let frame = try camera.fetchLiveViewFrame(timeout: 5)
                if saveFrames {
                    let name = String(format: "icc_%06d.jpg", frames)
                    try? frame.jpeg.write(to: outDir.appendingPathComponent(name))
                }
                frames += 1
                if frames % 10 == 0 {
                    print("frames=\(frames) bytes=\(frame.jpeg.count) size=\(frame.width)x\(frame.height) header=\(frame.headerSize)")
                }
            }
            try? camera.endLiveView()
        } catch {
            print("icc live view failed: \(error)")
        }
        camera.close()
        let elapsed = Date().timeIntervalSince(start)
        let fps = elapsed > 0 ? Double(frames) / elapsed : 0
        print(String(format: "icc live view: %d frames in %.1fs = %.1f fps", frames, elapsed, fps))
    }
}
