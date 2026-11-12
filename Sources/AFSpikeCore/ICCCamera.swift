import Foundation
import ImageCaptureCore

/// Errors surfaced by `ICCCamera`.
public enum ICCError: Error, CustomStringConvertible, Equatable {
    case noCamera
    case notConnected
    case sessionFailed(String)
    case timeout(String)
    case transport(String)
    case ptp(opcode: UInt16, code: UInt16)
    case invalidResponse(String)
    case fileIO(String)

    public var description: String {
        switch self {
        case .noCamera:
            return "no ICC camera found"
        case .notConnected:
            return "camera not connected or session not open"
        case .sessionFailed(let message):
            return "session failed: \(message)"
        case .timeout(let what):
            return "timeout: \(what)"
        case .transport(let message):
            return "transport error: \(message)"
        case .ptp(let opcode, let code):
            return String(format: "op 0x%04X failed with response 0x%04X", opcode, code)
        case .invalidResponse(let message):
            return "invalid response: \(message)"
        case .fileIO(let message):
            return "file error: \(message)"
        }
    }
}

/// Nikon CompressionSetting values (property 0x5004).
public enum CompressionSetting: UInt8, Sendable {
    case jpegBasic = 1
    case jpegNormal = 2
    case jpegFine = 3
    case raw = 7
}

/// Best-effort read of the properties AstroField cares about. Missing values are nil.
public struct ICCSnapshot: Sendable {
    public var batteryLevel: Int?
    public var compression: UInt8?
    public var fNumber: UInt16?
    public var exposureTime: UInt32?
    public var exposureProgram: UInt16?
    public var exposureIndex: UInt16?
    public var liveViewProhibit: UInt32?
    public var liveViewImageSize: UInt32?
    public var cameraLiveViewStatus: UInt8?
    public var monitorOffStatus: UInt8?
}

/// Result of a completed capture + download.
public struct CaptureResult: Sendable {
    public var handle: UInt32
    public var info: PTPObjectInfo
    public var url: URL
    public var bytes: Int
    public var seconds: Double
}

/// Outcome of a manual-focus drive.
public enum MfDriveOutcome: Sendable, Equatable {
    case completed
    case reachedEnd
    case insufficientSteps
}

public protocol ICCCameraDelegate: AnyObject {
    func cameraDidOpenSession(_ camera: ICCCamera, name: String)
    func camera(_ camera: ICCCamera, didCloseSessionWithError error: Error?)
    func camera(_ camera: ICCCamera, didReceive event: PTPEvent)
    func cameraWasRemoved(_ camera: ICCCamera)
}

extension ICCCameraDelegate {
    public func cameraDidOpenSession(_ camera: ICCCamera, name: String) {}
    public func camera(_ camera: ICCCamera, didCloseSessionWithError error: Error?) {}
    public func camera(_ camera: ICCCamera, didReceive event: PTPEvent) {}
    public func cameraWasRemoved(_ camera: ICCCamera) {}
}

/// Unified ImageCaptureCore PTP camera.
///
/// This is the shared backend for the `afspike` CLI and future SwiftUI UI:
/// connection, PTP pass-through, property read/write, live view, capture,
/// bulb, object download, manual focus drive and monitor control.
///
/// Threading: create and drive this class from the main thread. Callbacks from
/// ImageCaptureCore are processed while the synchronous helpers pump the main
/// run loop. Async completion-based APIs (`send`) can also be used directly.
public final class ICCCamera: NSObject, ICDeviceBrowserDelegate, ICDeviceDelegate {

    // MARK: - Public hooks

    /// Receives human-readable progress lines. Called on the caller's thread.
    public var log: ((String) -> Void)?
    /// Every PTP event (ObjectAdded, DeviceReady, property changes, ...).
    public var onEvent: ((PTPEvent) -> Void)?
    public weak var delegate: ICCCameraDelegate?

    public private(set) var deviceName: String?

    // MARK: - Private state

    private let browser = ICDeviceBrowser()
    private let lock = NSLock()
    private var device: ICCameraDevice?
    private var browserRunning = false
    private var sessionOpen = false
    private var sessionError: Error?
    private var sessionName: String?
    private var liveViewOn = false
    private var transaction: UInt32 = 0
    private var frameSequence: UInt64 = 0

    public override init() {
        super.init()
    }

    // MARK: - State

    public var isBrowserRunning: Bool { withLock { browserRunning } }

    public var isSessionOpen: Bool { withLock { sessionOpen } }

    public var isLiveViewActive: Bool { withLock { liveViewOn } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func emit(_ message: String) {
        log?(message)
    }

    // MARK: - Connection

    /// Start the device browser and wait until a camera shows up.
    public func start(timeout: TimeInterval = 10) throws {
        if withLock({ browserRunning }) { return }
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
        browser.start()
        withLock { browserRunning = true }
        guard waitUntil(timeout: timeout, { self.withLock { self.device != nil } }) else {
            browser.stop()
            withLock { browserRunning = false }
            throw ICCError.noCamera
        }
    }

    /// Open a PTP session on the discovered camera.
    public func openSession(timeout: TimeInterval = 10) throws {
        guard let cam = withLock({ device }) else { throw ICCError.noCamera }
        if withLock({ sessionOpen }) { return }
        withLock {
            sessionError = nil
            sessionName = nil
        }
        cam.delegate = self
        cam.ptpEventHandler = { [weak self] data in
            self?.handlePTPEventContainer(data)
        }
        cam.requestOpenSession()
        let settled = waitUntil(timeout: timeout) {
            self.withLock { self.sessionOpen || self.sessionError != nil }
        }
        if let error = withLock({ sessionError }) {
            throw ICCError.sessionFailed(error.localizedDescription)
        }
        guard settled else { throw ICCError.timeout("open session") }
        deviceName = withLock { sessionName } ?? cam.name
    }

    /// Convenience: browse + open session.
    public func connect(timeout: TimeInterval = 15) throws {
        try start(timeout: timeout)
        try openSession(timeout: timeout)
    }

    /// End live view if needed, close the session and stop the browser.
    public func close() {
        if let cam = withLock({ device }) {
            if withLock({ liveViewOn }) {
                _ = try? sendOK(PTPOpcode.endLiveView, timeout: 5)
                withLock { liveViewOn = false }
            }
            if withLock({ sessionOpen }) {
                cam.requestCloseSession()
                withLock { sessionOpen = false }
            }
            cam.delegate = nil
        }
        if withLock({ browserRunning }) {
            browser.stop()
            withLock { browserRunning = false }
        }
        browser.delegate = nil
        withLock { device = nil }
    }

    // MARK: - Run-loop helpers

    /// Pump the current run loop until `condition` is true or `timeout` elapses.
    /// Returns whether the condition became true.
    @discardableResult
    public func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Pump the run loop for a fixed duration without blocking ImageCaptureCore callbacks.
    public func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    // MARK: - PTP primitives

    /// Send one PTP command. The completion receives the data phase and response code.
    public func send(_ opcode: UInt16, _ params: [UInt32] = [], outData: Data? = nil,
                     completion: @escaping (Result<PTPResponse, ICCError>) -> Void) {
        let cam = withLock { device }
        guard let cam, withLock({ sessionOpen }) else {
            completion(.failure(.notConnected))
            return
        }
        let tx = withLock { () -> UInt32 in
            transaction &+= 1
            return transaction
        }
        let packet = PTP.commandPacket(opcode: opcode, params: params, transaction: tx)
        cam.requestSendPTPCommand(packet, outData: outData) { data, response, error in
            if let error {
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            completion(.success(PTPResponse(code: PTP.responseCode(response), data: data)))
        }
    }

    /// Blocking variant of `send` that pumps the run loop.
    @discardableResult
    public func sendSync(_ opcode: UInt16, _ params: [UInt32] = [], outData: Data? = nil,
                         timeout: TimeInterval = 15) throws -> PTPResponse {
        let box = ResultBox()
        send(opcode, params, outData: outData) { box.set($0) }
        let settled = waitUntil(timeout: timeout) { box.value != nil }
        guard settled, let result = box.value else {
            throw ICCError.timeout(String(format: "op 0x%04X", opcode))
        }
        return try result.get()
    }

    /// Send a command and require response 0x2001. Returns the data phase.
    @discardableResult
    public func sendOK(_ opcode: UInt16, _ params: [UInt32] = [], outData: Data? = nil,
                       timeout: TimeInterval = 15) throws -> Data {
        let response = try sendSync(opcode, params, outData: outData, timeout: timeout)
        guard response.code == PTPResponseCode.ok else {
            throw ICCError.ptp(opcode: opcode, code: response.code)
        }
        return response.data
    }

    // MARK: - Properties

    public func getPropertyData(_ id: UInt32, timeout: TimeInterval = 10) throws -> Data {
        try sendOK(PTPOpcode.getDevicePropValue, [id], timeout: timeout)
    }

    public func setPropertyData(_ id: UInt32, _ value: Data, timeout: TimeInterval = 10) throws {
        _ = try sendOK(PTPOpcode.setDevicePropValue, [id], outData: value, timeout: timeout)
    }

    /// Read a property whose width is 1, 2 or 4 bytes and return it as UInt32.
    public func getInteger(_ id: UInt32, timeout: TimeInterval = 10) throws -> UInt32 {
        let data = try getPropertyData(id, timeout: timeout)
        switch data.count {
        case 1: return UInt32(try PTP.uint8(data).unwrapped("property width"))
        case 2: return UInt32(try PTP.uint16le(data).unwrapped("property width"))
        case 4: return try PTP.uint32le(data).unwrapped("property width")
        default:
            throw ICCError.invalidResponse(String(format: "property 0x%04X has %d bytes", id, data.count))
        }
    }

    public func getUInt8(_ id: UInt32) throws -> UInt8 {
        try PTP.uint8(try getPropertyData(id)).unwrapped("property width")
    }

    public func getUInt16(_ id: UInt32) throws -> UInt16 {
        try PTP.uint16le(try getPropertyData(id)).unwrapped("property width")
    }

    public func getUInt32(_ id: UInt32) throws -> UInt32 {
        try PTP.uint32le(try getPropertyData(id)).unwrapped("property width")
    }

    public func setUInt8(_ id: UInt32, _ value: UInt8) throws {
        try setPropertyData(id, PTP.data8(value))
    }

    public func setUInt16(_ id: UInt32, _ value: UInt16) throws {
        try setPropertyData(id, PTP.data16(value))
    }

    public func setUInt32(_ id: UInt32, _ value: UInt32) throws {
        try setPropertyData(id, PTP.data32(value))
    }

    // MARK: - Typed convenience

    /// ChangeCameraMode (0x90C2).
    ///
    /// In PC camera mode (the default when a computer connects) the camera's dials
    /// are authoritative and host writes to ExposureProgramMode/ExposureTime are
    /// rejected with Access_Denied. Remote mode ignores the dials and uses host
    /// values until the camera is switched back to PC camera mode.
    public func setCameraMode(remote: Bool) throws {
        _ = try sendOK(PTPOpcode.changeCameraMode, [remote ? 1 : 0])
        emit(remote ? "camera mode: remote" : "camera mode: PC")
    }

    /// Exposure program 1 = Manual (property 0x500E, UINT16).
    public func setManualMode() throws {
        try setUInt16(PTPProperty.exposureProgramMode, 1)
    }

    /// Set shutter speed. `seconds` must be > 0; use `setBulbExposure()` for bulb.
    public func setExposureTime(seconds: Double) throws {
        guard let units = PTP.exposureUnits(seconds: seconds) else {
            throw ICCError.invalidResponse("exposure \(seconds)s out of range")
        }
        try setUInt32(PTPProperty.exposureTime, units)
    }

    /// ExposureTime = 0xFFFFFFFF selects bulb on Nikon bodies.
    public func setBulbExposure() throws {
        try setUInt32(PTPProperty.exposureTime, 0xFFFF_FFFF)
    }

    public func setCompression(_ setting: CompressionSetting) throws {
        try setUInt8(PTPProperty.compressionSetting, setting.rawValue)
    }

    public func batteryLevel() throws -> Int {
        Int(try getUInt8(PTPProperty.batteryLevel))
    }

    /// LiveViewImageSize (0xD1AC) is UINT8 on Z-series: 1 = QVGA, 2 = VGA, 3 = XGA.
    public func liveViewImageSize() throws -> UInt32 {
        try getInteger(PTPProperty.liveViewImageSize)
    }

    public func setLiveViewSize(_ value: UInt8) throws {
        try setUInt8(PTPProperty.liveViewImageSize, value)
    }

    /// ChangeMonitorOff (0x9422): true turns the camera screen off.
    ///
    /// Hardware finding (Z7 II, 2026-11-12): the camera only accepts this in
    /// PC camera mode; in remote mode it returns Access_Denied (0x200F). The
    /// forced-off state survives a switch to remote mode, so the usable order
    /// is: switch to PC mode, turn the screen off, then switch back to remote.
    /// The response only acknowledges the request; read `monitorOffStatus` to confirm.
    public func setMonitorOff(_ off: Bool) throws {
        _ = try sendOK(PTPOpcode.changeMonitorOff, [off ? 1 : 0])
    }

    public func monitorOffStatus() throws -> UInt8 {
        try getUInt8(PTPProperty.monitorOffStatus)
    }

    /// Best-effort read of the properties the UI shows. Never throws.
    public func snapshot() -> ICCSnapshot {
        var s = ICCSnapshot()
        s.batteryLevel = (try? getUInt8(PTPProperty.batteryLevel)).map(Int.init)
        s.compression = try? getUInt8(PTPProperty.compressionSetting)
        s.fNumber = try? getUInt16(PTPProperty.fNumber)
        s.exposureTime = try? getUInt32(PTPProperty.exposureTime)
        s.exposureProgram = try? getUInt16(PTPProperty.exposureProgramMode)
        s.exposureIndex = try? getUInt16(PTPProperty.exposureIndex)
        s.liveViewProhibit = try? getInteger(PTPProperty.liveViewProhibitCondition)
        s.liveViewImageSize = try? getInteger(PTPProperty.liveViewImageSize)
        s.cameraLiveViewStatus = try? getUInt8(PTPProperty.cameraLiveViewStatus)
        s.monitorOffStatus = try? getUInt8(PTPProperty.monitorOffStatus)
        return s
    }

    // MARK: - Live view

    public func startLiveView(timeout: TimeInterval = 15) throws {
        if withLock({ liveViewOn }) { return }
        if let prohibit = try? getInteger(PTPProperty.liveViewProhibitCondition), prohibit != 0 {
            emit(String(format: "warning: LiveViewProhibit = 0x%X", prohibit))
        }
        _ = try sendOK(PTPOpcode.startLiveView, timeout: timeout)
        withLock { liveViewOn = true }
        try waitDeviceReady(timeout: timeout)
    }

    public func endLiveView(timeout: TimeInterval = 10) throws {
        _ = try sendOK(PTPOpcode.endLiveView, timeout: timeout)
        withLock { liveViewOn = false }
    }

    /// Fetch one live-view frame (header + JPEG). Requires `startLiveView()`.
    public func fetchLiveViewFrame(timeout: TimeInterval = 10) throws -> LiveFrame {
        var opcode = PTPOpcode.getLiveViewImageEx
        var response = try sendSync(opcode, timeout: timeout)
        if response.code == PTPResponseCode.operationNotSupported {
            opcode = PTPOpcode.getLiveViewImage
            response = try sendSync(opcode, timeout: timeout)
        }
        guard response.code == PTPResponseCode.ok else {
            throw ICCError.ptp(opcode: opcode, code: response.code)
        }
        let sequence = withLock { () -> UInt64 in
            frameSequence &+= 1
            return frameSequence
        }
        guard let frame = JPEGInspector.parseLiveViewFrame(response.data, sequence: sequence) else {
            throw ICCError.invalidResponse("live view payload has no JPEG (\(response.data.count) bytes)")
        }
        return frame
    }

    /// Grab frames for `seconds`, calling `onFrame` for each one. Returns the frame count.
    @discardableResult
    public func streamLiveView(seconds: Double,
                               shouldStop: () -> Bool = { false },
                               onFrame: (LiveFrame) -> Void) -> Int {
        let start = Date()
        var count = 0
        while Date().timeIntervalSince(start) < seconds && !shouldStop() {
            do {
                let frame = try fetchLiveViewFrame(timeout: 5)
                count += 1
                onFrame(frame)
            } catch {
                emit("live view frame error: \(error)")
                pump(0.05)
            }
        }
        return count
    }

    // MARK: - Capture

    /// Poll DeviceReady until the camera reports ready.
    public func waitDeviceReady(timeout: TimeInterval = 60, pollInterval: TimeInterval = 0.2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try sendSync(PTPOpcode.deviceReady, timeout: 10)
            switch response.code {
            case PTPResponseCode.ok:
                return
            case PTPResponseCode.deviceBusy, PTPResponseCode.bulbReleaseBusy:
                pump(pollInterval)
            default:
                throw ICCError.ptp(opcode: PTPOpcode.deviceReady, code: response.code)
            }
        }
        throw ICCError.timeout("DeviceReady")
    }

    /// InitiateCapture (0x9207). Nikon takes params [0xFFFFFFFF, 0].
    public func initiateCapture(timeout: TimeInterval = 15) throws {
        _ = try sendOK(PTPOpcode.initiateCapture, [0xFFFF_FFFF, 0], timeout: timeout)
    }

    public func terminateCapture(timeout: TimeInterval = 15) throws {
        _ = try sendOK(PTPOpcode.terminateCapture, [0, 0, 0], timeout: timeout)
    }

    /// All object handles visible in a storage (0xFFFFFFFF = all storages).
    public func objectHandles(storageID: UInt32 = 0xFFFF_FFFF) throws -> [UInt32] {
        let data = try sendOK(PTPOpcode.getObjectHandles, [storageID, 0, 0])
        guard let count = PTP.uint32le(data, at: 0) else {
            throw ICCError.invalidResponse("GetObjectHandles returned \(data.count) bytes")
        }
        var handles: [UInt32] = []
        handles.reserveCapacity(Int(count))
        var offset = 4
        for _ in 0..<Int(count) {
            guard let handle = PTP.uint32le(data, at: offset) else { break }
            handles.append(handle)
            offset += 4
        }
        return handles
    }

    public func objectInfo(handle: UInt32) throws -> PTPObjectInfo {
        let data = try sendOK(PTPOpcode.getObjectInfo, [handle])
        guard let info = PTP.parseObjectInfo(data, handle: handle) else {
            throw ICCError.invalidResponse("GetObjectInfo returned \(data.count) bytes")
        }
        if info.filename == "capture" {
            // Keep the raw dataset around so the next hardware run can pin down
            // Nikon's exact ObjectInfo layout.
            let head = data.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ")
            emit("warning: filename not parsed; ObjectInfo[\(data.count)] = \(head)")
        }
        return info
    }

    /// Poll until an object handle that is not in `baseline` appears.
    public func waitForNewObject(excluding baseline: Set<UInt32>,
                                 timeout: TimeInterval,
                                 pollInterval: TimeInterval = 0.5) throws -> UInt32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let handles = try? objectHandles(),
               let new = handles.first(where: { !baseline.contains($0) }) {
                return new
            }
            pump(pollInterval)
        }
        throw ICCError.timeout("new object after capture")
    }

    /// GetObjectInfo + chunked GetPartialObject, saved into `directory`.
    @discardableResult
    public func downloadObject(handle: UInt32, to directory: URL,
                               chunkSize: Int = 4 * 1024 * 1024,
                               progress: ((Int, Int) -> Void)? = nil) throws -> CaptureResult {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ICCError.fileIO(error.localizedDescription)
        }
        let info = try objectInfo(handle: handle)
        guard info.compressedSize > 0 else {
            throw ICCError.invalidResponse("object \(handle) has size 0")
        }
        let name = PTP.sanitizeFilename(info.filename, fallbackExtension: info.fileExtension)
        let url = uniqueURL(in: directory, name: name)
        emit(String(format: "object handle=%u format=0x%04X size=%d name=%@",
                    handle, info.format, info.compressedSize, name))

        let start = Date()
        var data = Data(capacity: info.compressedSize)
        var offset = 0
        while offset < info.compressedSize {
            let n = min(chunkSize, info.compressedSize - offset)
            let chunk = try sendOK(PTPOpcode.getPartialObject,
                                   [handle, UInt32(offset), UInt32(n)], timeout: 60)
            guard !chunk.isEmpty else {
                throw ICCError.invalidResponse("GetPartialObject returned 0 bytes at \(offset)")
            }
            data.append(chunk)
            offset += chunk.count
            progress?(offset, info.compressedSize)
        }
        do {
            try data.write(to: url)
        } catch {
            throw ICCError.fileIO(error.localizedDescription)
        }
        let seconds = Date().timeIntervalSince(start)
        let mbs = seconds > 0 ? Double(data.count) / seconds / 1_048_576 : 0
        emit(String(format: "saved %@ (%d bytes, %.1f MB/s)", url.path, data.count, mbs))
        return CaptureResult(handle: handle, info: info, url: url, bytes: data.count, seconds: seconds)
    }

    /// Full still-capture flow: baseline handles → settings → capture → ready →
    /// new object → download. Ends live view first if it is running.
    @discardableResult
    public func capture(to directory: URL,
                        compression: CompressionSetting? = .raw,
                        exposure: Double? = nil,
                        remoteMode: Bool = false,
                        timeout: TimeInterval = 120,
                        progress: ((Int, Int) -> Void)? = nil) throws -> CaptureResult {
        if withLock({ liveViewOn }) {
            try? endLiveView()
        }
        if remoteMode { try setCameraMode(remote: true) }
        let baseline = Set(try objectHandles())
        emit("baseline objects: \(baseline.count)")
        if let compression {
            do { try setCompression(compression) }
            catch { emit("warning: set compression failed: \(error)") }
        }
        do { try setManualMode() }
        catch { emit("warning: set Manual mode failed: \(error)") }
        if let exposure {
            do { try setExposureTime(seconds: exposure) }
            catch { emit("warning: set exposure failed: \(error)") }
        }
        try initiateCapture()
        emit("InitiateCapture accepted")
        try waitDeviceReady(timeout: min(timeout, 90))
        emit("DeviceReady OK; polling for new object")
        let handle = try waitForNewObject(excluding: baseline, timeout: timeout)
        return try downloadObject(handle: handle, to: directory, progress: progress)
    }

    /// Bulb flow: settings → InitiateCapture → wait → TerminateCapture →
    /// ready → new object → download.
    @discardableResult
    public func captureBulb(seconds: Double,
                            to directory: URL,
                            compression: CompressionSetting? = .raw,
                            remoteMode: Bool = false,
                            timeout: TimeInterval = 120,
                            progress: ((Int, Int) -> Void)? = nil) throws -> CaptureResult {
        guard seconds > 0 else { throw ICCError.invalidResponse("bulb duration must be > 0") }
        if withLock({ liveViewOn }) {
            try? endLiveView()
        }
        if remoteMode { try setCameraMode(remote: true) }
        let baseline = Set(try objectHandles())
        emit("baseline objects: \(baseline.count)")
        if let compression {
            do { try setCompression(compression) }
            catch { emit("warning: set compression failed: \(error)") }
        }
        do { try setManualMode() }
        catch { emit("warning: set Manual mode failed: \(error)") }
        do { try setBulbExposure() }
        catch { emit("warning: set bulb exposure failed: \(error)") }
        // Nikon's official bulb sequence sets both ExposureTime and ShutterSpeed
        // to 0xFFFFFFFF; ShutterSpeed rejection is non-fatal.
        do { try setUInt32(PTPProperty.shutterSpeed, 0xFFFF_FFFF) }
        catch { emit("warning: set shutter speed failed: \(error)") }
        try initiateCapture()
        emit("InitiateCapture (bulb \(seconds)s)")
        pump(seconds)
        try terminateCapture()
        emit("TerminateCapture accepted")
        try waitDeviceReady(timeout: min(timeout, 90))
        emit("DeviceReady OK; polling for new object")
        let handle = try waitForNewObject(excluding: baseline, timeout: timeout)
        return try downloadObject(handle: handle, to: directory, progress: progress)
    }

    // MARK: - Focus

    /// MfDrive (0x9204). Live view should already be running on Nikon bodies.
    @discardableResult
    public func mfDrive(direction: UInt32, steps: UInt32,
                        timeout: TimeInterval = 60) throws -> MfDriveOutcome {
        let response = try sendSync(PTPOpcode.mfDrive, [direction, steps], timeout: 20)
        emit(String(format: "MfDrive resp=0x%04X", response.code))
        switch response.code {
        case PTPResponseCode.ok:
            break
        case PTPResponseCode.mfDriveReachedEnd:
            return .reachedEnd
        case PTPResponseCode.mfDriveStepInsufficiency:
            return .insufficientSteps
        default:
            throw ICCError.ptp(opcode: PTPOpcode.mfDrive, code: response.code)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ready = try sendSync(PTPOpcode.deviceReady, timeout: 10)
            switch ready.code {
            case PTPResponseCode.ok:
                return .completed
            case PTPResponseCode.deviceBusy:
                pump(0.2)
            case PTPResponseCode.mfDriveReachedEnd:
                return .reachedEnd
            case PTPResponseCode.mfDriveStepInsufficiency:
                return .insufficientSteps
            default:
                throw ICCError.ptp(opcode: PTPOpcode.deviceReady, code: ready.code)
            }
        }
        throw ICCError.timeout("MfDrive")
    }

    // MARK: - ICDeviceBrowserDelegate

    @objc(deviceBrowser:didAddDevice:moreComing:)
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        withLock { self.device = camera }
        emit("device: \(device.name ?? "?") transport=\(device.transportType ?? "?")")
    }

    @objc(deviceBrowser:didRemoveDevice:moreGoing:)
    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        emit("device removed: \(device.name ?? "?")")
        withLock {
            self.device = nil
            self.sessionOpen = false
            self.liveViewOn = false
        }
        delegate?.cameraWasRemoved(self)
    }

    // MARK: - ICDeviceDelegate

    @objc(device:didOpenSessionWithError:)
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            withLock { sessionError = error }
            emit("open session failed: \(error.localizedDescription)")
            return
        }
        withLock {
            sessionOpen = true
            sessionName = device.name
        }
        emit("session opened: \(device.name ?? "?")")
        delegate?.cameraDidOpenSession(self, name: device.name ?? "")
    }

    @objc(device:didCloseSessionWithError:)
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        withLock { sessionOpen = false }
        if let error {
            emit("session closed with error: \(error.localizedDescription)")
        }
        delegate?.camera(self, didCloseSessionWithError: error)
    }

    @objc(didRemoveDevice:)
    public func didRemove(_ device: ICDevice) {
        emit("device removed: \(device.name ?? "?")")
        withLock {
            self.device = nil
            sessionOpen = false
            liveViewOn = false
        }
        delegate?.cameraWasRemoved(self)
    }

    @objc(deviceDidBecomeReady:)
    public func deviceDidBecomeReady(_ device: ICDevice) {
        emit("device ready: \(device.name ?? "?")")
    }

    // MARK: - Events

    private func handlePTPEventContainer(_ data: Data) {
        guard let event = PTP.parseEvent(data) else { return }
        if event.code == PTPEventCode.objectAdded, let handle = event.params.first {
            emit("event ObjectAdded handle=\(handle)")
        } else {
            emit(String(format: "event 0x%04X params=%@", event.code, "\(event.params)"))
        }
        onEvent?(event)
        delegate?.camera(self, didReceive: event)
    }

    // MARK: - Helpers

    private func uniqueURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: url.path) { return url }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            url = directory.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Result<PTPResponse, ICCError>?

        func set(_ value: Result<PTPResponse, ICCError>) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        var value: Result<PTPResponse, ICCError>? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}

private extension Optional {
    func unwrapped(_ what: String) throws -> Wrapped {
        guard let self else {
            throw ICCError.invalidResponse("missing \(what)")
        }
        return self
    }
}
