import Foundation
import CoreGraphics
import AFSpikeCore

public enum CameraKind: String, Codable, Sendable, CaseIterable {
    case simulator
    case playback
    case nikon

    public var displayName: String {
        switch self {
        case .simulator: return "模拟相机"
        case .playback: return "照片回放"
        case .nikon: return "Nikon USB"
        }
    }
}

public enum CameraCapability: String, Codable, Sendable, CaseIterable {
    case liveView
    case stillCapture
    case bulbCapture
    case rawOutput
    case isoControl
    case shutterControl
    case apertureControl
    case manualFocusDrive
    case monitorControl
    case batteryStatus

    public var displayName: String {
        switch self {
        case .liveView: return "LiveView"
        case .stillCapture: return "单张拍摄"
        case .bulbCapture: return "Bulb"
        case .rawOutput: return "RAW"
        case .isoControl: return "ISO"
        case .shutterControl: return "快门"
        case .apertureControl: return "光圈"
        case .manualFocusDrive: return "MFDrive"
        case .monitorControl: return "关屏"
        case .batteryStatus: return "电量"
        }
    }
}

public enum CameraState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case busy(String)
    case error(String)

    public var isConnected: Bool {
        switch self {
        case .connected, .busy: return true
        default: return false
        }
    }

    public var displayText: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .busy(let what): return "忙碌：\(what)"
        case .error(let message): return "错误：\(message)"
        }
    }
}

public struct CameraStatus: Sendable, Equatable {
    public var state: CameraState
    public var model: String
    public var firmware: String?
    public var lens: String?
    public var batteryPercent: Int?
    public var capabilities: Set<CameraCapability>
    public var notes: [String]

    public init(state: CameraState = .disconnected,
                model: String = "",
                firmware: String? = nil,
                lens: String? = nil,
                batteryPercent: Int? = nil,
                capabilities: Set<CameraCapability> = [],
                notes: [String] = []) {
        self.state = state
        self.model = model
        self.firmware = firmware
        self.lens = lens
        self.batteryPercent = batteryPercent
        self.capabilities = capabilities
        self.notes = notes
    }
}

public struct ExposureSettings: Codable, Equatable, Sendable {
    public var iso: Int
    public var exposureSeconds: Double
    public var aperture: Double?
    public var compression: CompressionChoice

    public init(iso: Int = 800,
                exposureSeconds: Double = 10,
                aperture: Double? = 2.8,
                compression: CompressionChoice = .raw) {
        self.iso = iso
        self.exposureSeconds = exposureSeconds
        self.aperture = aperture
        self.compression = compression
    }
}

public enum CompressionChoice: String, Codable, Sendable, CaseIterable {
    case raw
    case jpegFine

    public var displayName: String {
        switch self {
        case .raw: return "RAW"
        case .jpegFine: return "JPEG 精细"
        }
    }
}

public enum FocusDirection: Int, Codable, Sendable {
    /// Nikon MfDrive direction values are 1 and 2; physical meaning depends on lens.
    case one = 1
    case two = 2
}

public enum CameraError: Error, CustomStringConvertible, Equatable {
    case unsupported(String)
    case disconnected
    case busy(String)
    case captureFailed(String)
    case downloadFailed(String)
    case io(String)

    public var description: String {
        switch self {
        case .unsupported(let what): return "设备不支持：\(what)"
        case .disconnected: return "相机未连接"
        case .busy(let what): return "相机忙碌：\(what)"
        case .captureFailed(let why): return "拍摄失败：\(why)"
        case .downloadFailed(let why): return "下载失败：\(why)"
        case .io(let why): return "文件错误：\(why)"
        }
    }
}

/// One live-view preview frame. `isSimulated` must be true for any synthetic source.
public struct LivePreview: @unchecked Sendable {
    public var sequence: UInt64
    public var image: CGImage
    public var width: Int
    public var height: Int
    public var timestamp: Date
    public var isSimulated: Bool

    public init(sequence: UInt64, image: CGImage, width: Int, height: Int,
                timestamp: Date = Date(), isSimulated: Bool) {
        self.sequence = sequence
        self.image = image
        self.width = width
        self.height = height
        self.timestamp = timestamp
        self.isSimulated = isSimulated
    }
}

public enum ImageSource: String, Codable, Sendable {
    case simulator
    case playback
    case nikon
}

/// A delivered photo, independent of backend.
public struct ImageRecord: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let sequence: Int
    public let timestamp: Date
    public let source: ImageSource
    public let fileURL: URL?
    public let settings: ExposureSettings
    public let width: Int
    public let height: Int
    public let isRaw: Bool
    public var metrics: FrameMetrics?
    public var preview: CGImage?
    /// Small star-preserving thumbnail for the filmstrip.
    public var thumbnail: CGImage?
    /// Decoded luminance kept for immediate analysis (simulator). Older records may
    /// drop it to bound memory; analysis then reloads from `fileURL`.
    public var analysisLuma: LumaImage?
    public var verdict: QualityVerdict?
    public var note: String?
    public var qualityGroup: String?

    public init(id: UUID = UUID(), sequence: Int, timestamp: Date = Date(),
                source: ImageSource, fileURL: URL?,
                settings: ExposureSettings, width: Int, height: Int,
                isRaw: Bool, metrics: FrameMetrics? = nil,
                preview: CGImage? = nil, thumbnail: CGImage? = nil,
                analysisLuma: LumaImage? = nil,
                verdict: QualityVerdict? = nil,
                note: String? = nil,
                qualityGroup: String? = nil) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.source = source
        self.fileURL = fileURL
        self.settings = settings
        self.width = width
        self.height = height
        self.isRaw = isRaw
        self.metrics = metrics
        self.preview = preview
        self.thumbnail = thumbnail
        self.analysisLuma = analysisLuma
        self.verdict = verdict
        self.note = note
        self.qualityGroup = qualityGroup
    }

    public var displayName: String {
        if let fileURL { return fileURL.lastPathComponent }
        return String(format: "SIM_%04d", sequence)
    }
}

/// Backend-independent camera interface. Real, simulated and playback cameras share it.
public protocol CameraDevice: AnyObject, Sendable {
    var id: UUID { get }
    var kind: CameraKind { get }
    var displayName: String { get }
    var status: CameraStatus { get }

    /// Called on an arbitrary queue; UI layers must hop to the main actor.
    var onStatusChange: ((CameraStatus) -> Void)? { get set }

    func connect() async throws
    func disconnect() async
    func apply(_ settings: ExposureSettings) async throws
    func capture(sequence: Int) async throws -> ImageRecord
    func startLiveView() async throws
    func stopLiveView() async
    func livePreview() async throws -> LivePreview?
    func focusDrive(direction: FocusDirection, steps: Int) async throws
}
