import Foundation

/// PTP container types (PIMA 15740 §5.4).
public enum PTPContainerType: UInt16 {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// One PTP response: the response code plus any data-phase payload.
public struct PTPResponse: Sendable, Equatable {
    public var code: UInt16
    public var data: Data

    public init(code: UInt16, data: Data) {
        self.code = code
        self.data = data
    }
}

/// One PTP event delivered through `ICCameraDevice.ptpEventHandler`.
public struct PTPEvent: Sendable, Equatable {
    public var code: UInt16
    public var params: [UInt32]

    public init(code: UInt16, params: [UInt32]) {
        self.code = code
        self.params = params
    }
}

/// Parsed PTP ObjectInfo (PIMA 15740 §13.4).
public struct PTPObjectInfo: Sendable, Equatable {
    public var handle: UInt32
    public var storageID: UInt32
    public var format: UInt16
    public var compressedSize: Int
    public var imageWidth: Int
    public var imageHeight: Int
    public var filename: String

    public init(handle: UInt32, storageID: UInt32, format: UInt16,
                compressedSize: Int, imageWidth: Int, imageHeight: Int,
                filename: String) {
        self.handle = handle
        self.storageID = storageID
        self.format = format
        self.compressedSize = compressedSize
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.filename = filename
    }

    /// File extension that matches the PTP object format.
    public var fileExtension: String {
        PTP.fileExtension(for: format)
    }
}

/// Nikon PTP opcodes used by AstroField. Full tables live in `docs/`.
public enum PTPOpcode {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getStorageInfo: UInt16 = 0x1005
    public static let getNumObjects: UInt16 = 0x1006
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let deleteObject: UInt16 = 0x100B
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let setDevicePropValue: UInt16 = 0x1016
    public static let getPartialObject: UInt16 = 0x101B

    public static let deviceReady: UInt16 = 0x90C8
    /// 0x90C2 ChangeCameraMode: param 1 = remote mode, 0 = PC camera mode.
    public static let changeCameraMode: UInt16 = 0x90C2
    public static let startLiveView: UInt16 = 0x9201
    public static let endLiveView: UInt16 = 0x9202
    /// Legacy live-view image opcode (pre-Z-series bodies).
    public static let getLiveViewImage: UInt16 = 0x9203
    public static let mfDrive: UInt16 = 0x9204
    public static let initiateCapture: UInt16 = 0x9207
    public static let terminateCapture: UInt16 = 0x920C
    public static let changeMonitorOff: UInt16 = 0x9422
    /// Nikon Z-series live-view image opcode (Z8/Z7 II).
    public static let getLiveViewImageEx: UInt16 = 0x9428
}

/// Nikon PTP property codes used by AstroField. Full tables live in `docs/`.
public enum PTPProperty {
    public static let batteryLevel: UInt32 = 0x5001
    public static let imageSize: UInt32 = 0x5003
    public static let compressionSetting: UInt32 = 0x5004
    public static let whiteBalance: UInt32 = 0x5005
    public static let fNumber: UInt32 = 0x5007
    public static let focalLength: UInt32 = 0x5008
    public static let focusMode: UInt32 = 0x500A
    public static let exposureTime: UInt32 = 0x500D
    public static let exposureProgramMode: UInt32 = 0x500E
    public static let exposureIndex: UInt32 = 0x500F
    public static let exposureBiasCompensation: UInt32 = 0x5010
    public static let dateTime: UInt32 = 0x5011
    public static let stillCaptureMode: UInt32 = 0x5013
    public static let shutterSpeed: UInt32 = 0xD100
    public static let liveViewProhibitCondition: UInt32 = 0xD1A4
    public static let liveViewImageSize: UInt32 = 0xD1AC
    public static let cameraLiveViewStatus: UInt32 = 0xD1B8
    public static let monitorOffStatus: UInt32 = 0xD1BA
}

/// PTP response codes observed on Nikon bodies.
public enum PTPResponseCode {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let operationNotSupported: UInt16 = 0x2005
    public static let deviceBusy: UInt16 = 0x2019
    public static let invalidObjectHandle: UInt16 = 0xA001
    /// Nikon MfDrive: focus reached the end of the focusable range.
    public static let mfDriveReachedEnd: UInt16 = 0xA00C
    /// Nikon MfDrive: requested steps exceed the remaining range.
    public static let mfDriveStepInsufficiency: UInt16 = 0xA00E
    /// Nikon: bulb exposure is still in progress (expected while polling DeviceReady).
    public static let bulbReleaseBusy: UInt16 = 0xA200
}

/// PTP event codes observed on Nikon bodies.
public enum PTPEventCode {
    public static let objectAdded: UInt16 = 0x4002
    public static let deviceInfoChanged: UInt16 = 0x4003
    public static let devicePropChanged: UInt16 = 0x4006
    public static let deviceReady: UInt16 = 0x400D
}

/// PTP object formats.
public enum PTPObjectFormat {
    public static let nef: UInt16 = 0x3000
    public static let exifJPEG: UInt16 = 0x3801
}

/// Pure PTP encoding/decoding helpers. Everything here is testable without a camera.
public enum PTP {
    // MARK: - Little-endian primitives

    public static func uint8(_ data: Data, at offset: Int = 0) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in raw[offset] }
    }

    public static func uint16le(_ data: Data, at offset: Int = 0) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
        }
    }

    public static func uint32le(_ data: Data, at offset: Int = 0) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt32(raw[offset])
                | (UInt32(raw[offset + 1]) << 8)
                | (UInt32(raw[offset + 2]) << 16)
                | (UInt32(raw[offset + 3]) << 24)
        }
    }

    public static func data8(_ value: UInt8) -> Data { Data([value]) }

    public static func data16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    public static func data32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: - Containers

    /// Command container: length, type=1, opcode, transaction, params.
    public static func commandPacket(opcode: UInt16, params: [UInt32], transaction: UInt32) -> Data {
        var data = Data(capacity: 12 + params.count * 4)
        data.append(data32(UInt32(12 + params.count * 4)))
        data.append(data16(PTPContainerType.command.rawValue))
        data.append(data16(opcode))
        data.append(data32(transaction))
        for p in params { data.append(data32(p)) }
        return data
    }

    /// Response container: length, type=3, response code, transaction, params.
    public static func responsePacket(code: UInt16, params: [UInt32] = [], transaction: UInt32 = 1) -> Data {
        var data = Data()
        data.append(data32(UInt32(12 + params.count * 4)))
        data.append(data16(PTPContainerType.response.rawValue))
        data.append(data16(code))
        data.append(data32(transaction))
        for p in params { data.append(data32(p)) }
        return data
    }

    /// Event container: length, type=4, event code, transaction, params.
    public static func eventPacket(code: UInt16, params: [UInt32] = [], transaction: UInt32 = 0) -> Data {
        var data = Data()
        data.append(data32(UInt32(12 + params.count * 4)))
        data.append(data16(PTPContainerType.event.rawValue))
        data.append(data16(code))
        data.append(data32(transaction))
        for p in params { data.append(data32(p)) }
        return data
    }

    /// Response code from a response container (bytes 6–7). 0 when the container is too short.
    public static func responseCode(_ container: Data) -> UInt16 {
        uint16le(container, at: 6) ?? 0
    }

    /// Parse a response container into its code. The data phase is delivered separately
    /// by ImageCaptureCore, so `PTPResponse.data` here is always empty.
    public static func parseResponse(_ container: Data) -> PTPResponse? {
        guard container.count >= 12 else { return nil }
        return PTPResponse(code: responseCode(container), data: Data())
    }

    /// Parse a PTP event container. Includes the transaction ID slot at bytes 8–11
    /// followed by parameters from byte 12.
    public static func parseEvent(_ container: Data) -> PTPEvent? {
        guard container.count >= 12 else { return nil }
        guard let code = uint16le(container, at: 6) else { return nil }
        var params: [UInt32] = []
        var offset = 12
        while offset + 4 <= container.count {
            if let v = uint32le(container, at: offset) { params.append(v) }
            offset += 4
        }
        return PTPEvent(code: code, params: params)
    }

    // MARK: - Strings

    /// Strict PTP string at `offset`: UINT8 character count (including terminator),
    /// then that many UTF-16LE code units.
    public static func parseString(_ data: Data, at offset: Int) -> (value: String, next: Int)? {
        guard offset >= 0, offset < data.count else { return nil }
        let count = Int(data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in raw[offset] })
        if count == 0 { return ("", offset + 1) }
        let byteCount = count * 2
        guard offset + 1 + byteCount <= data.count else { return nil }
        let bytes = data.subdata(in: (offset + 1)..<(offset + 1 + byteCount))
        var value = String(data: bytes, encoding: .utf16LittleEndian) ?? ""
        value = value.replacingOccurrences(of: "\u{0}", with: "")
        return (value, offset + 1 + byteCount)
    }

    /// Tolerant filename parser for ObjectInfo.
    ///
    /// Nikon bodies have been observed to disagree about what the PTP string count
    /// byte means (characters vs bytes), which used to produce names such as
    /// `D\0S\0C\0_...`. This tries every plausible interpretation and scores the
    /// results, returning the most filename-like one.
    public static func parseFilename(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        let count = Int(data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in raw[offset] })
        guard count > 0 else { return nil }

        var candidates: [String] = []

        // A: count = UTF-16 code units (spec).
        appendCandidate(&candidates, bytes(data, offset + 1, count * 2), encoding: .utf16LittleEndian)
        // B: count = bytes of a UTF-16 string.
        appendCandidate(&candidates, bytes(data, offset + 1, count - (count % 2)), encoding: .utf16LittleEndian)
        // C: plain UTF-8/ASCII string of `count` bytes.
        appendCandidate(&candidates, bytes(data, offset + 1, count), encoding: .utf8)
        // D: plain UTF-8/ASCII string of 2*count bytes, cut at NUL.
        appendCandidate(&candidates, bytes(data, offset + 1, count * 2), encoding: .utf8)

        let scored = candidates
            .map { ($0, filenameScore($0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        return scored.first?.0
    }

    private static func bytes(_ data: Data, _ start: Int, _ length: Int) -> Data? {
        guard length > 0, start >= 0, start + length <= data.count else { return nil }
        return data.subdata(in: start..<(start + length))
    }

    private static func appendCandidate(_ out: inout [String], _ bytes: Data?, encoding: String.Encoding) {
        guard var s = bytes.flatMap({ String(data: $0, encoding: encoding) }) else { return }
        s = s.replacingOccurrences(of: "\u{0}", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        out.append(s)
    }

    /// Higher is more filename-like; 0 means unusable.
    private static func filenameScore(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var score = s.count
        let scalars = s.unicodeScalars
        for scalar in scalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return 0 }
        }
        let printable = scalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.count
        guard printable * 2 >= scalars.count else { return 0 }  // mostly ASCII
        if s.hasPrefix("DSC") { score += 20 }
        if s.contains(".") { score += 5 }
        if s.contains("/") || s.contains("\\") { score -= 30 }
        return score
    }

    // MARK: - Object info

    /// Parse a PTP ObjectInfo dataset.
    ///
    /// The PIMA 15740 header is 48 bytes and the filename PTP string follows at
    /// offset 48. Nikon bodies have been observed to put it at 52 instead, so the
    /// filename is located by scanning the plausible range and scoring candidates
    /// (see `parseFilename`).
    public static func parseObjectInfo(_ data: Data, handle: UInt32) -> PTPObjectInfo? {
        guard data.count >= 50 else { return nil }
        guard let storage = uint32le(data, at: 0),
              let format = uint16le(data, at: 4),
              let size = uint32le(data, at: 8) else { return nil }
        // Spec offsets: image width 26, height 30. Old code used the thumbnail
        // fields at 24/28; fall back to those when the spec fields are zero.
        var width = Int(uint32le(data, at: 26) ?? 0)
        var height = Int(uint32le(data, at: 30) ?? 0)
        if width == 0 || height == 0 {
            width = Int(uint32le(data, at: 24) ?? 0)
            height = Int(uint32le(data, at: 28) ?? 0)
        }
        let name = findFilename(in: data) ?? "capture"
        return PTPObjectInfo(handle: handle, storageID: storage, format: format,
                             compressedSize: Int(size),
                             imageWidth: width, imageHeight: height,
                             filename: name)
    }

    /// Find the most filename-like PTP string in the ObjectInfo tail.
    public static func findFilename(in data: Data) -> String? {
        var best: (value: String, score: Int)?
        let lower = 46
        let upper = min(64, data.count - 1)
        guard lower <= upper else { return nil }
        for offset in lower...upper {
            guard let candidate = parseFilename(data, at: offset) else { continue }
            let score = filenameScore(candidate)
            guard score > 0 else { continue }
            if best == nil || score > best!.score {
                best = (candidate, score)
            }
        }
        return best?.value
    }

    /// Extension for a PTP object format code.
    public static func fileExtension(for format: UInt16) -> String {
        switch format {
        case 0x3000: return "nef"
        case 0x3001: return "nrw"
        case 0x3002: return "cr2"
        case 0x3003: return "crw"
        case 0x300E: return "tif"
        case 0x3801, 0x3800: return "jpg"
        default: return "bin"
        }
    }

    /// Make a camera-provided name safe for the local filesystem.
    public static func sanitizeFilename(_ name: String, fallbackExtension: String) -> String {
        var clean = name
            .replacingOccurrences(of: "\u{0}", with: "")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] {
            clean = clean.replacingOccurrences(of: bad, with: "_")
        }
        if clean.isEmpty || clean == "." || clean == ".." {
            clean = "capture"
        }
        let ext = (clean as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            clean += "." + fallbackExtension
        }
        return clean
    }

    // MARK: - Exposure

    /// Nikon exposure time unit is 0.1 ms. Returns nil when the value is out of range.
    public static func exposureUnits(seconds: Double) -> UInt32? {
        guard seconds > 0, seconds.isFinite else { return nil }
        let units = (seconds * 10_000.0).rounded()
        guard units >= 1, units <= 0xFFFF_FFFE else { return nil }
        return UInt32(units)
    }

    public static func exposureSeconds(units: UInt32) -> Double? {
        guard units != 0xFFFF_FFFF else { return nil }  // bulb
        return Double(units) / 10_000.0
    }
}

/// Minimal JPEG inspection: locate the SOI inside a Nikon LiveViewObject
/// (which prefixes the JPEG with a 512- or 1024-byte header) and read SOF dimensions.
public enum JPEGInspector {
    /// Offset of the first JPEG SOI (`FF D8 FF`) at or after `start`.
    public static func findSOI(in data: Data, from start: Int = 0, searchLimit: Int? = nil) -> Int? {
        guard data.count >= 3, start >= 0, start < data.count - 2 else { return nil }
        let end = min(data.count - 3, start + (searchLimit ?? data.count))
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            var i = start
            while i <= end {
                if raw[i] == 0xFF, raw[i + 1] == 0xD8, raw[i + 2] == 0xFF { return i }
                i += 1
            }
            return nil
        }
    }

    /// Decode width/height from the first SOF marker at or after `soi`.
    public static func dimensions(_ data: Data, from soi: Int) -> (width: Int, height: Int)? {
        guard soi >= 0, soi + 2 < data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (width: Int, height: Int)? in
            var i = soi + 2
            while i + 9 < raw.count {
                guard raw[i] == 0xFF else { i += 1; continue }
                let marker = raw[i + 1]
                if marker == 0xD8 || marker == 0xD9 { i += 2; continue }
                if marker >= 0xD0 && marker <= 0xD7 { i += 2; continue }
                let length = Int(raw[i + 2]) << 8 | Int(raw[i + 3])
                if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 || marker == 0xC3 {
                    guard i + 8 < raw.count else { return nil }
                    let height = Int(raw[i + 5]) << 8 | Int(raw[i + 6])
                    let width = Int(raw[i + 7]) << 8 | Int(raw[i + 8])
                    return (width, height)
                }
                i += 2 + max(length, 2)
            }
            return nil
        }
    }

    /// Split a Nikon LiveViewObject payload into header + JPEG and describe it.
    public static func parseLiveViewFrame(_ data: Data, sequence: UInt64,
                                          timestamp: Date = Date()) -> LiveFrame? {
        // Nikon headers are 512 (Z7 II) or 1024 (Z8) bytes; look there first,
        // then fall back to a full scan in case the body changes.
        guard let soi = findSOI(in: data, from: 0, searchLimit: 4096) ?? findSOI(in: data) else {
            return nil
        }
        let jpeg = soi == 0 ? data : data.subdata(in: soi..<data.count)
        let size = dimensions(jpeg, from: 0)
        return LiveFrame(sequence: sequence,
                         width: size?.width ?? 0,
                         height: size?.height ?? 0,
                         jpeg: jpeg,
                         timestamp: timestamp,
                         headerSize: soi)
    }
}
