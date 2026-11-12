import Foundation
import CoreGraphics

/// Simulated camera: a controllable device that shares the exact same interface as
/// the real Nikon adapter and the playback source.
public final class SimulatorCamera: CameraDevice, @unchecked Sendable {
    public let id = UUID()
    public var kind: CameraKind { .simulator }
    public var displayName: String { "模拟星空相机" }

    private let lock = NSLock()
    private var statusStorage: CameraStatus
    public var status: CameraStatus {
        lock.lock(); defer { lock.unlock() }
        return statusStorage
    }
    public var onStatusChange: ((CameraStatus) -> Void)?

    public var scene: SimulatorScene
    public var focusModel: SimulatorFocusModel
    public var settings: ExposureSettings
    /// Divides all simulated delays. Set high in tests; 1 in the app.
    public var timeScale: Double = 1
    public var simulateTiming = true
    /// When set, the sky does not advance with wall time (deterministic tests).
    public var fixedSimulationTime: Double?
    public var faults: [SimulatorFault] = []
    public var batteryPercent: Int = 78

    private var connectedAt: Date?
    private var liveSequence: UInt64 = 0
    private var captureCount = 0
    private var liveViewOn = false
    private var lastCapture: ImageRecord?

    public init(scene: SimulatorScene = SimulatorScene(),
                settings: ExposureSettings = ExposureSettings()) {
        self.scene = scene
        self.settings = settings
        self.focusModel = SimulatorFocusModel()
        self.statusStorage = CameraStatus(state: .disconnected,
                                          model: "AstroField Simulator",
                                          firmware: "sim-1",
                                          lens: "SIM 35mm f/2.8",
                                          batteryPercent: nil,
                                          capabilities: Self.allCapabilities,
                                          notes: ["模拟设备：数值与图像均为仿真，不代表真实相机读数"])
    }

    public static let allCapabilities: Set<CameraCapability> = [
        .liveView, .stillCapture, .bulbCapture, .rawOutput,
        .isoControl, .shutterControl, .apertureControl,
        .manualFocusDrive, .batteryStatus
    ]

    // MARK: - Lifecycle

    public func connect() async throws {
        setStatus(CameraStatus(state: .connecting, model: "AstroField Simulator",
                               firmware: "sim-1", lens: "SIM 35mm f/2.8",
                               batteryPercent: batteryPercent,
                               capabilities: Self.allCapabilities,
                               notes: ["模拟设备：数值与图像均为仿真，不代表真实相机读数"]))
        if simulateTiming { try? await sleep(0.35) }
        connectedAt = Date()
        captureCount = 0
        setStatus(CameraStatus(state: .connected, model: "AstroField Simulator",
                               firmware: "sim-1", lens: "SIM 35mm f/2.8",
                               batteryPercent: batteryPercent,
                               capabilities: Self.allCapabilities,
                               notes: ["模拟设备：数值与图像均为仿真，不代表真实相机读数"]))
    }

    public func disconnect() async {
        liveViewOn = false
        connectedAt = nil
        setStatus(CameraStatus(state: .disconnected, model: "AstroField Simulator",
                               capabilities: Self.allCapabilities,
                               notes: ["模拟设备已断开"]))
    }

    // MARK: - Settings

    public func apply(_ settings: ExposureSettings) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        guard (32...102400).contains(settings.iso) else {
            throw CameraError.unsupported("ISO \(settings.iso)")
        }
        guard settings.exposureSeconds > 0, settings.exposureSeconds <= 900 else {
            throw CameraError.unsupported("曝光 \(settings.exposureSeconds)s")
        }
        if let aperture = settings.aperture, !(1.0...22.0).contains(aperture) {
            throw CameraError.unsupported("光圈 f/\(aperture)")
        }
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    // MARK: - Capture

    public func capture(sequence: Int) async throws -> ImageRecord {
        guard status.state.isConnected else { throw CameraError.disconnected }

        var busySeconds: Double?
        var downloadExtra: Double = 0
        var forcedError: String?
        lock.lock()
        if !faults.isEmpty {
            let fault = faults.removeFirst()
            switch fault {
            case .failNextCapture(let why): forcedError = why
            case .busy(let seconds): busySeconds = seconds
            case .slowDownload(let seconds): downloadExtra = seconds
            case .disconnectAfter(let count):
                if captureCount >= count {
                    lock.unlock()
                    liveViewOn = false
                    setStatus(CameraStatus(state: .error("模拟断连"),
                                           model: "AstroField Simulator",
                                           capabilities: Self.allCapabilities,
                                           notes: ["模拟断连"]))
                    throw CameraError.disconnected
                }
            }
        }
        let settings = self.settings
        let sigma = focusModel.focusSigma
        let sceneSnapshot = scene
        lock.unlock()

        if let busySeconds {
            if simulateTiming { try? await sleep(busySeconds) }
        }
        if let forcedError {
            throw CameraError.captureFailed(forcedError)
        }
        if simulateTiming {
            try? await sleep(settings.exposureSeconds + downloadExtra)
        }

        let time = simulationTime()
        let sky = SimulatorSky(scene: sceneSnapshot)
        let luma = sky.render(settings: settings,
                              focusSigma: sigma,
                              timeSeconds: time,
                              width: sceneSnapshot.width,
                              height: sceneSnapshot.height,
                              seedOffset: UInt64(bitPattern: Int64(sequence)),
                              isLive: false)
        let preview = luma.downsampled(maxWidth: 1200).displayImage()
        let thumbnail = luma.downsampledMax(maxWidth: 140).displayImage()
        let record = ImageRecord(sequence: sequence,
                                 source: .simulator,
                                 fileURL: nil,
                                 settings: settings,
                                 width: luma.width,
                                 height: luma.height,
                                 isRaw: true,
                                 metrics: nil,
                                 preview: preview,
                                 thumbnail: thumbnail,
                                 analysisLuma: luma,
                                 note: "模拟图像，\(sceneSnapshot.condition.displayName)")
        lock.lock()
        captureCount += 1
        lastCapture = record
        lock.unlock()
        return record
    }

    // MARK: - Live view

    public func startLiveView() async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        liveViewOn = true
    }

    public func stopLiveView() async {
        liveViewOn = false
    }

    public func livePreview() async throws -> LivePreview? {
        guard let luma = try await liveLumaPreview() else { return nil }
        guard let image = luma.displayImage() else { return nil }
        let sequence = lock.withLock { liveSequence }
        return LivePreview(sequence: sequence, image: image,
                           width: luma.width, height: luma.height, isSimulated: true)
    }

    /// Raw luminance of the next live frame. Focus measurement uses this directly
    /// instead of round-tripping through an 8-bit display image.
    public func liveLumaPreview() async throws -> LumaImage? {
        guard status.state.isConnected else { return nil }
        lock.lock()
        guard liveViewOn else { lock.unlock(); return nil }
        let sceneSnapshot = scene
        let settings = self.settings
        let sigma = focusModel.focusSigma
        let time = simulationTime()
        liveSequence &+= 1
        let sequence = liveSequence
        lock.unlock()

        let width = max(160, sceneSnapshot.liveWidth)
        let height = max(90, Int(Double(width) * Double(sceneSnapshot.height) / Double(sceneSnapshot.width)))
        let sky = SimulatorSky(scene: sceneSnapshot)
        return sky.render(settings: settings,
                          focusSigma: sigma,
                          timeSeconds: time,
                          width: width,
                          height: height,
                          seedOffset: sequence,
                          isLive: true)
    }

    // MARK: - Focus

    public func focusDrive(direction: FocusDirection, steps: Int) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        guard status.capabilities.contains(.manualFocusDrive) else {
            throw CameraError.unsupported("MFDrive")
        }
        guard steps >= 0 else { throw CameraError.unsupported("负步数") }
        if simulateTiming { try? await sleep(focusModel.responseDelay) }
        lock.lock()
        focusModel.move(direction: direction, steps: steps)
        lock.unlock()
    }

    // MARK: - Test / UI controls

    public func updateScene(_ update: (inout SimulatorScene) -> Void) {
        lock.lock()
        update(&scene)
        lock.unlock()
    }

    public func setCondition(_ condition: SkyCondition) {
        lock.lock()
        scene.condition = condition
        lock.unlock()
    }

    public func setFocus(position: Double) {
        lock.lock()
        focusModel.position = min(focusModel.maxPosition,
                                  max(focusModel.minPosition, position))
        lock.unlock()
    }

    public func resetFocusToBest() {
        lock.lock()
        focusModel.position = focusModel.bestPosition
        focusModel.lastDirection = nil
        lock.unlock()
    }

    public var focusPosition: Double {
        lock.lock(); defer { lock.unlock() }
        return focusModel.position
    }

    public var lastCapturedRecord: ImageRecord? {
        lock.lock(); defer { lock.unlock() }
        return lastCapture
    }

    // MARK: - Helpers

    private func simulationTime() -> Double {
        if let fixedSimulationTime { return fixedSimulationTime }
        guard let connectedAt else { return 0 }
        return Date().timeIntervalSince(connectedAt)
    }

    private func sleep(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        let scaled = seconds / max(timeScale, 0.01)
        guard scaled > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(scaled, 3600) * 1_000_000_000))
    }

    private func setStatus(_ status: CameraStatus) {
        lock.lock()
        statusStorage = status
        lock.unlock()
        onStatusChange?(status)
    }
}
