import Foundation

/// `afspike iccshoot` / `iccbulb`: capture + object download, backed by `ICCCamera`.
public final class ICCCapture {
    private let outDir: URL
    private let timeout: TimeInterval
    private let bulbSeconds: Double?
    private let exposureSeconds: Double?
    private let compression: CompressionSetting?
    private let remoteMode: Bool

    public init(outDir: URL, timeout: TimeInterval = 90, bulbSeconds: Double? = nil,
                exposureSeconds: Double? = nil,
                compression: CompressionSetting? = .raw,
                remoteMode: Bool = false) {
        self.outDir = outDir
        self.timeout = timeout
        self.bulbSeconds = bulbSeconds
        self.exposureSeconds = exposureSeconds
        self.compression = compression
        self.remoteMode = remoteMode
    }

    public func run() {
        let camera = ICCCamera()
        camera.log = { print("icc: \($0)") }
        do {
            try camera.connect()
            let result: CaptureResult
            if let bulbSeconds {
                result = try camera.captureBulb(seconds: bulbSeconds, to: outDir,
                                                compression: compression,
                                                remoteMode: remoteMode, timeout: timeout)
            } else {
                result = try camera.capture(to: outDir, compression: compression,
                                            exposure: exposureSeconds,
                                            remoteMode: remoteMode, timeout: timeout)
            }
            print("capture saved: \(result.url.path)")
        } catch {
            print("icc capture failed: \(error)")
        }
        camera.close()
    }
}
