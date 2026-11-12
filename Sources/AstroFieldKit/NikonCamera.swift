import Foundation
import CoreGraphics
import AFSpikeCore

/// Serial engine that owns ICCCamera on its own run-loop thread. All camera calls
/// are funneled through this queue, matching ImageCaptureCore's run-loop delivery.
final class ICCEngine: @unchecked Sendable {
    private let camera = ICCCamera()
    private let condition = NSCondition()
    private var queue: [() -> Void] = []
    private var thread: Thread?
    private var ready = false
    private var stopped = false

    var log: ((String) -> Void)? {
        didSet { camera.log = log }
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            condition.lock()
            if thread != nil {
                condition.unlock()
                continuation.resume()
                return
            }
            ready = false
            stopped = false
            let worker = Thread { [weak self] in self?.run() }
            worker.name = "AstroField.ICCEngine"
            worker.qualityOfService = .userInitiated
            thread = worker
            worker.start()
            while !ready { condition.wait() }
            condition.unlock()
            continuation.resume()
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            condition.lock()
            guard thread != nil else {
                condition.unlock()
                continuation.resume()
                return
            }
            stopped = true
            condition.broadcast()
            condition.unlock()
            DispatchQueue.global().async {
                while true {
                    self.condition.lock()
                    let done = self.thread == nil
                    self.condition.unlock()
                    if done { break }
                    usleep(10_000)
                }
                continuation.resume()
            }
        }
    }

    func perform<T>(_ body: @escaping (ICCCamera) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            condition.lock()
            guard thread != nil else {
                condition.unlock()
                continuation.resume(throwing: CameraError.disconnected)
                return
            }
            let camera = self.camera
            queue.append {
                do {
                    continuation.resume(returning: try body(camera))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    private func run() {
        condition.lock()
        ready = true
        condition.broadcast()
        condition.unlock()

        while true {
            condition.lock()
            while queue.isEmpty && !stopped { condition.wait() }
            if queue.isEmpty && stopped {
                condition.unlock()
                break
            }
            let work = queue.removeFirst()
            condition.unlock()
            work()
        }

        condition.lock()
        thread = nil
        condition.broadcast()
        condition.unlock()
    }
}

/// Real Nikon adapter. Sharing the CameraDevice interface keeps the same plan,
/// state machine, analysis and UI as the simulator and playback sources.
public final class NikonCamera: CameraDevice, @unchecked Sendable {
    public let id = UUID()
    public var kind: CameraKind { .nikon }
    public var displayName: String { "Nikon USB" }

    private let lock = NSLock()
    private var statusStorage: CameraStatus
    public var status: CameraStatus {
        lock.lock(); defer { lock.unlock() }
        return statusStorage
    }
    public var onStatusChange: ((CameraStatus) -> Void)?

    private let engine = ICCEngine()
    private var liveViewOn = false
    private var settings = ExposureSettings()
    private var outputDirectory: URL
    private var lastLog: String?

    public init(outputDirectory: URL? = nil) {
        self.outputDirectory = outputDirectory ?? NikonCamera.defaultOutputDirectory()
        self.statusStorage = CameraStatus(state: .disconnected, model: "Nikon",
                                          capabilities: [],
                                          notes: ["尚未连接"])
        engine.log = { [weak self] line in
            self?.lastLog = line
        }
    }

    public static func defaultOutputDirectory() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("AstroField", isDirectory: true)
    }

    public func setOutputDirectory(_ url: URL) {
        lock.lock(); outputDirectory = url; lock.unlock()
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        setStatus(CameraStatus(state: .connecting, model: "Nikon",
                               capabilities: [], notes: ["正在打开 ICC 会话"]))
        await engine.start()
        do {
            let status = try await engine.perform { camera -> CameraStatus in
                try camera.connect(timeout: 15)
                let name = camera.deviceName ?? "Nikon"
                var caps: Set<CameraCapability> = [.liveView, .stillCapture, .bulbCapture, .rawOutput]
                var notes: [String] = ["ICC PTP passthrough"]

                do {
                    try camera.setCameraMode(remote: true)
                    notes.append("remote mode：主机参数生效")
                } catch {
                    notes.append("remote mode 切换失败")
                }

                let snapshot = camera.snapshot()
                if let battery = snapshot.batteryLevel {
                    caps.insert(.batteryStatus)
                    _ = battery
                }
                if let compression = snapshot.compression,
                   (try? camera.setCompression(CompressionSetting(rawValue: compression) ?? .raw)) != nil {
                    caps.insert(.rawOutput)
                }
                if let iso = snapshot.exposureIndex,
                   (try? camera.setUInt16(PTPProperty.exposureIndex, iso)) != nil {
                    caps.insert(.isoControl)
                }
                if let aperture = snapshot.fNumber, aperture > 0,
                   (try? camera.setUInt16(PTPProperty.fNumber, aperture)) != nil {
                    caps.insert(.apertureControl)
                    caps.insert(.manualFocusDrive)
                    notes.append("MFDrive 未自动探测（避免移动镜头）；Z7 II 100 步已实测")
                }
                if let time = snapshot.exposureTime,
                   let seconds = PTP.exposureSeconds(units: time),
                   (try? camera.setExposureTime(seconds: seconds)) != nil {
                    caps.insert(.shutterControl)
                }
                // MonitorOff works only in PC camera mode; do not probe it here.
                caps.insert(.monitorControl)
                notes.append("关屏需切回 PC mode 设置")

                return CameraStatus(state: .connected, model: name,
                                    firmware: nil, lens: nil,
                                    batteryPercent: snapshot.batteryLevel,
                                    capabilities: caps, notes: notes)
            }
            setStatus(status)
        } catch {
            setStatus(CameraStatus(state: .error(String(describing: error)), model: "Nikon",
                                   capabilities: [], notes: ["连接失败：\(lastLog ?? "")"]))
            await engine.stop()
            throw error
        }
    }

    public func disconnect() async {
        if liveViewOn {
            _ = try? await engine.perform { camera in
                try camera.endLiveView()
            }
            liveViewOn = false
        }
        _ = try? await engine.perform { camera in
            camera.close()
        }
        await engine.stop()
        setStatus(CameraStatus(state: .disconnected, model: "Nikon",
                               capabilities: [], notes: ["已断开"]))
    }

    // MARK: - Settings

    public func apply(_ settings: ExposureSettings) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        do {
            try await engine.perform { camera in
                try camera.setCameraMode(remote: true)
                try camera.setExposureTime(seconds: settings.exposureSeconds)
                try camera.setUInt16(PTPProperty.exposureIndex,
                                     UInt16(clamping: settings.iso))
                if let aperture = settings.aperture {
                    try camera.setUInt16(PTPProperty.fNumber,
                                         UInt16(clamping: Int((aperture * 100).rounded())))
                }
                try camera.setCompression(settings.compression == .raw ? .raw : .jpegFine)
            }
            lock.lock(); self.settings = settings; lock.unlock()
        } catch {
            throw CameraError.unsupported("设置参数失败：\(error)")
        }
    }

    // MARK: - Capture

    public func capture(sequence: Int) async throws -> ImageRecord {
        guard status.state.isConnected else { throw CameraError.disconnected }
        lock.lock()
        let settings = self.settings
        let directory = outputDirectory
        lock.unlock()
        do {
            let result = try await engine.perform { camera -> (URL, Int, Int) in
                let capture = try camera.capture(to: directory,
                                                 compression: settings.compression == .raw ? .raw : .jpegFine,
                                                 exposure: settings.exposureSeconds,
                                                 remoteMode: true,
                                                 timeout: 300)
                let dims = ImageLoader.dimensions(url: capture.url) ?? (0, 0)
                return (capture.url, dims.0, dims.1)
            }
            return ImageRecord(sequence: sequence,
                               source: .nikon,
                               fileURL: result.0,
                               settings: settings,
                               width: result.1,
                               height: result.2,
                               isRaw: settings.compression == .raw,
                               metrics: nil,
                               preview: nil,
                               note: "Nikon USB，\(result.0.lastPathComponent)")
        } catch {
            throw CameraError.captureFailed(String(describing: error))
        }
    }

    // MARK: - Live view

    public func startLiveView() async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        try await engine.perform { camera in
            try camera.startLiveView()
        }
        liveViewOn = true
    }

    public func stopLiveView() async {
        guard liveViewOn else { return }
        _ = try? await engine.perform { camera in
            try camera.endLiveView()
        }
        liveViewOn = false
    }

    public func livePreview() async throws -> LivePreview? {
        guard liveViewOn else { return nil }
        return try await engine.perform { camera -> LivePreview? in
            let frame = try camera.fetchLiveViewFrame(timeout: 5)
            guard let image = ImageLoader.cgImage(fromJPEG: frame.jpeg) else { return nil }
            return LivePreview(sequence: frame.sequence,
                               image: image,
                               width: frame.width,
                               height: frame.height,
                               timestamp: frame.timestamp,
                               isSimulated: false)
        }
    }

    // MARK: - Focus

    public func focusDrive(direction: FocusDirection, steps: Int) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        guard status.capabilities.contains(.manualFocusDrive) else {
            throw CameraError.unsupported("MFDrive（镜头能力未确认）")
        }
        try await engine.perform { camera in
            let wasLive = camera.isLiveViewActive
            if !wasLive { try camera.startLiveView() }
            _ = try camera.mfDrive(direction: UInt32(direction.rawValue),
                                   steps: UInt32(max(0, steps)),
                                   timeout: 90)
            if !wasLive { try? camera.endLiveView() }
        }
    }

    // MARK: - Helpers

    public var logTail: String? {
        lastLog
    }

    private func setStatus(_ status: CameraStatus) {
        lock.lock()
        statusStorage = status
        lock.unlock()
        onStatusChange?(status)
    }
}
