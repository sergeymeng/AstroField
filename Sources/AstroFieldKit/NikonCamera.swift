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
///
/// Session handling: `ICCCamera` reports a closed PTP session or a removed
/// device through its delegate. The adapter turns that into an error status and
/// one `onSessionLost` callback; `reconnect()` rebuilds the ICC session from
/// scratch (browser, session, remote mode) without duplicating the engine.
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
    private var liveStretch = LiveViewStretchSettings.default

    /// Guards against re-entrant lifecycle work and stale reconnects.
    private var generation = 0
    private var reconnecting = false
    private var suppressSessionLoss = true
    private var sessionLossNotified = false

    /// Called on the ICC engine thread when the camera closes the PTP session
    /// or disappears from USB. The UI must hop to its own actor.
    public var onSessionLost: ((String) -> Void)?
    /// Called after `reconnect()` successfully rebuilt the session.
    public var onSessionRestored: (() -> Void)?
    /// Filtered ICC log lines useful for diagnosing session loss.
    public var onDiagnostic: ((String) -> Void)?

    public init(outputDirectory: URL? = nil) {
        self.outputDirectory = outputDirectory ?? NikonCamera.defaultOutputDirectory()
        self.statusStorage = CameraStatus(state: .disconnected, model: "Nikon",
                                          capabilities: [],
                                          notes: ["尚未连接"])
        engine.log = { [weak self] line in
            guard let self else { return }
            self.lastLog = line
            let lower = line.lowercased()
            if lower.contains("session") || lower.contains("removed")
                || lower.contains("error") || lower.contains("failed") {
                self.onDiagnostic?(line)
            }
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

    public func setLiveStretch(_ settings: LiveViewStretchSettings) {
        lock.lock(); liveStretch = settings; lock.unlock()
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        let gen = beginGeneration()
        setStatus(CameraStatus(state: .connecting, model: "Nikon",
                               capabilities: [], notes: ["正在打开 ICC 会话"]))
        await engine.start()
        do {
            let status = try await openSession(probeCapabilities: true, timeout: 15)
            guard isCurrent(gen) else { throw CameraError.disconnected }
            finishSessionOpen(status)
        } catch {
            setStatus(CameraStatus(state: .error(String(describing: error)), model: "Nikon",
                                   capabilities: [], notes: ["连接失败：\(lastLog ?? "")"]))
            await closeICCSession()
            await engine.stop()
            throw error
        }
    }

    /// Rebuild the ICC browser and session after the camera closed it.
    /// Capability probing is skipped: the previous status is reused so a
    /// reconnect normally completes in a few seconds.
    public func reconnect() async throws {
        lock.lock()
        guard !reconnecting else {
            lock.unlock()
            throw CameraError.busy("正在重连")
        }
        reconnecting = true
        generation &+= 1
        let gen = generation
        suppressSessionLoss = true
        liveViewOn = false
        lock.unlock()
        defer {
            lock.lock(); reconnecting = false; lock.unlock()
        }

        await closeICCSession()
        await engine.stop()
        guard isCurrent(gen) else { throw CameraError.disconnected }
        await engine.start()
        do {
            let status = try await openSession(probeCapabilities: false, timeout: 6)
            guard isCurrent(gen) else { throw CameraError.disconnected }
            finishSessionOpen(status)
            onSessionRestored?()
        } catch {
            // Stop the browser while the engine is still pumping its run loop;
            // otherwise the next attempt would inherit a browser tied to a
            // stopped thread.
            await closeICCSession()
            await engine.stop()
            throw error
        }
    }

    public func disconnect() async {
        lock.lock()
        generation &+= 1
        suppressSessionLoss = true
        sessionLossNotified = true
        let wasLive = liveViewOn
        lock.unlock()
        if wasLive {
            _ = try? await engine.perform { camera in
                try camera.endLiveView()
            }
        }
        await closeICCSession()
        await engine.stop()
        lock.lock(); liveViewOn = false; lock.unlock()
        setStatus(CameraStatus(state: .disconnected, model: "Nikon",
                               capabilities: [], notes: ["已断开"]))
    }

    // MARK: - Settings

    public func apply(_ settings: ExposureSettings) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        do {
            try await engine.perform { camera in
                try camera.setCameraMode(remote: true)
                // A-mode dials reject ExposureTime with 0x200F; remote writes
                // only become authoritative in Manual exposure program.
                try camera.setManualMode()
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
        lock.lock(); let stretch = liveStretch; lock.unlock()
        return try await engine.perform { camera -> LivePreview? in
            let frame = try camera.fetchLiveViewFrame(timeout: 5)
            // Keep the decoded camera JPEG as the measurement frame. The
            // stretched copy is display-only and never reaches focus/analysis.
            guard let raw = ImageLoader.cgImage(fromJPEG: frame.jpeg) else { return nil }
            var display: CGImage?
            var stats: LiveViewStretchStats?
            if let result = LiveViewStretch.stretch(raw, settings: stretch) {
                display = result.image
                stats = result.stats
            }
            return LivePreview(sequence: frame.sequence,
                               image: raw,
                               width: frame.width,
                               height: frame.height,
                               timestamp: frame.timestamp,
                               isSimulated: false,
                               displayImage: display,
                               stretchStats: stats)
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

    /// Turns the camera monitor off (PC mode required by the protocol) or back
    /// on (then restores remote mode so host settings stay authoritative).
    public func setScreen(on: Bool) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        do {
            try await engine.perform { camera in
                if on {
                    try camera.setMonitorOff(false)
                    try camera.setCameraMode(remote: true)
                } else {
                    try camera.setCameraMode(remote: false)
                    try camera.setMonitorOff(true)
                }
            }
        } catch {
            throw CameraError.unsupported("相机屏控制失败：\(error)")
        }
    }

    // MARK: - Finder frame

    /// One-off JPEG captured while searching for stars. It is written to a
    /// temporary directory and deleted after decoding; it never touches the
    /// session directory or the sequence counters.
    public struct FinderFrame: @unchecked Sendable {
        public var image: CGImage
        public var luma: LumaImage
    }

    public func captureFinderFrame(iso: Int, exposureSeconds: Double) async throws -> FinderFrame {
        guard status.state.isConnected else { throw CameraError.disconnected }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroField-Finder", isDirectory: true)
        let url = try await engine.perform { camera -> URL in
            try camera.setCameraMode(remote: true)
            try camera.setManualMode()
            try camera.setUInt16(PTPProperty.exposureIndex, UInt16(clamping: iso))
            let capture = try camera.capture(to: directory,
                                             compression: .jpegFine,
                                             exposure: exposureSeconds,
                                             remoteMode: true,
                                             timeout: 120)
            return capture.url
        }
        // The capture flow ends LiveView; keep the adapter's flag in sync even
        // if a later step throws.
        defer {
            lock.lock(); liveViewOn = false; lock.unlock()
            try? FileManager.default.removeItem(at: url)
        }
        guard let image = ImageLoader.preview(url: url, maxWidth: 2200),
              let luma = ImageLoader.luma(url: url, maxWidth: 2200) else {
            throw CameraError.io("无法读取找星试拍的 JPEG")
        }
        return FinderFrame(image: image, luma: luma)
    }

    // MARK: - Session events

    private func noteSessionLost(_ reason: String) {
        lock.lock()
        if suppressSessionLoss || sessionLossNotified {
            lock.unlock()
            return
        }
        sessionLossNotified = true
        liveViewOn = false
        let current = statusStorage
        lock.unlock()

        let lost = CameraStatus(state: .error("ICC 会话已关闭"),
                                model: current.model,
                                firmware: current.firmware,
                                lens: current.lens,
                                batteryPercent: current.batteryPercent,
                                capabilities: current.capabilities,
                                notes: ["ICC 会话断开：\(reason)"])
        setStatus(lost)
        onDiagnostic?("session lost: \(reason)")
        onSessionLost?(reason)
    }

    // MARK: - Lifecycle helpers

    private func beginGeneration() -> Int {
        lock.lock()
        generation &+= 1
        let gen = generation
        suppressSessionLoss = true
        sessionLossNotified = false
        lock.unlock()
        return gen
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    func finishSessionOpen(_ status: CameraStatus) {
        lock.lock()
        liveViewOn = false
        suppressSessionLoss = false
        sessionLossNotified = false
        lock.unlock()
        setStatus(status)
    }

    private func closeICCSession() async {
        _ = try? await engine.perform { camera in
            camera.close()
            // Let ImageCaptureCore deliver the close callback before the
            // browser is torn down and restarted.
            camera.pump(0.3)
        }
    }

    private func openSession(probeCapabilities: Bool, timeout: TimeInterval) async throws -> CameraStatus {
        try await engine.perform { [weak self] camera -> CameraStatus in
            camera.delegate = self
            try camera.connect(timeout: timeout)
            var notes: [String] = ["ICC PTP passthrough"]
            do {
                try camera.setCameraMode(remote: true)
                notes.append("remote mode：主机参数生效")
            } catch {
                notes.append("remote mode 切换失败")
            }
            // A body that closes the session during setup must not be reported
            // as connected.
            guard camera.isSessionOpen else { throw ICCError.notConnected }
            guard let self else { throw CameraError.disconnected }

            if !probeCapabilities {
                let previous = self.status
                notes.append("ICC 会话已恢复")
                return CameraStatus(state: .connected,
                                    model: camera.deviceName ?? previous.model,
                                    firmware: previous.firmware,
                                    lens: previous.lens,
                                    batteryPercent: previous.batteryPercent,
                                    capabilities: previous.capabilities,
                                    notes: notes)
            }

            var caps: Set<CameraCapability> = [.liveView, .stillCapture, .bulbCapture, .rawOutput]
            let snapshot = camera.snapshot()
            if snapshot.batteryLevel != nil {
                caps.insert(.batteryStatus)
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

            return CameraStatus(state: .connected,
                                model: camera.deviceName ?? "Nikon",
                                firmware: nil,
                                lens: nil,
                                batteryPercent: snapshot.batteryLevel,
                                capabilities: caps,
                                notes: notes)
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

extension NikonCamera: ICCCameraDelegate {
    public func cameraDidOpenSession(_ camera: ICCCamera, name: String) {}

    public func camera(_ camera: ICCCamera, didCloseSessionWithError error: Error?) {
        if let error {
            noteSessionLost("session closed: \(error.localizedDescription)")
        } else {
            noteSessionLost("session closed")
        }
    }

    public func camera(_ camera: ICCCamera, didReceive event: PTPEvent) {}

    public func cameraWasRemoved(_ camera: ICCCamera) {
        noteSessionLost("device removed")
    }
}
