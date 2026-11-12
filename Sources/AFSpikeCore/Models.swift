import Foundation

public struct DeviceInfo: Sendable, Equatable {
    public var id: UInt32
    public var name: String
    public var version: String
    public var available: Bool
    public var connectedPID: UInt32

    public init(id: UInt32, name: String, version: String, available: Bool, connectedPID: UInt32) {
        self.id = id
        self.name = name
        self.version = version
        self.available = available
        self.connectedPID = connectedPID
    }
}

public struct CapabilityInfo: Sendable, Equatable {
    public var id: UInt32
    public var type: UInt32
    public var operations: UInt32
    public var description: String

    public init(id: UInt32, type: UInt32, operations: UInt32, description: String) {
        self.id = id
        self.type = type
        self.operations = operations
        self.description = description
    }
}

public struct LiveFrame: Sendable {
    public var sequence: UInt64
    public var width: Int
    public var height: Int
    public var jpeg: Data
    public var timestamp: Date
    /// Bytes of Nikon LiveViewObject header before the JPEG SOI (512 on Z7 II, 1024 on Z8).
    public var headerSize: Int

    public init(sequence: UInt64, width: Int, height: Int, jpeg: Data,
                timestamp: Date = Date(), headerSize: Int = 0) {
        self.sequence = sequence
        self.width = width
        self.height = height
        self.jpeg = jpeg
        self.timestamp = timestamp
        self.headerSize = headerSize
    }
}

public struct FrameMetrics: Sendable, Equatable {
    public var starCount: Int
    public var background: Double
    public var noise: Double
    public var medianFWHM: Double
    public var medianEccentricity: Double
    public var saturatedFraction: Double

    public init(starCount: Int, background: Double, noise: Double,
                medianFWHM: Double, medianEccentricity: Double,
                saturatedFraction: Double) {
        self.starCount = starCount
        self.background = background
        self.noise = noise
        self.medianFWHM = medianFWHM
        self.medianEccentricity = medianEccentricity
        self.saturatedFraction = saturatedFraction
    }
}

public enum CameraState: String, Sendable {
    case disconnected, connecting, idle, liveView, capturing, downloading, error
}

public struct LogRecord: Sendable {
    public var timestamp: Date
    public var backend: String
    public var command: String
    public var durationMS: Double
    public var result: String
    public var detail: String

    public init(timestamp: Date = Date(), backend: String, command: String,
                durationMS: Double, result: String, detail: String) {
        self.timestamp = timestamp
        self.backend = backend
        self.command = command
        self.durationMS = durationMS
        self.result = result
        self.detail = detail
    }
}
