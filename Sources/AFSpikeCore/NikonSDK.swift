#if ASTROFIELD_NIKON_SDK
import Foundation
import CNikonMAID

public struct SDKDevice: Codable, Sendable, Equatable {
    public var id: UInt32
    public var name: String
    public var version: String
    public var available: Bool
    public var pid: UInt32
}

public struct SDKCapability: Codable, Sendable, Equatable {
    public var id: UInt32
    public var type: UInt32
    public var ops: UInt32
    public var desc: String
}

public enum SDKError: Error, CustomStringConvertible {
    case load(String)
    case initFailed(Int32)
    case notConnected
    case call(String, Int32)
    case decode(String)

    public var description: String {
        switch self {
        case .load(let s): return "load: \(s)"
        case .initFailed(let c): return "init failed: \(c)"
        case .notConnected: return "not connected"
        case .call(let name, let c): return "\(name) failed: \(c)"
        case .decode(let s): return "decode: \(s)"
        }
    }
}

public final class NikonSDK {
    public static var defaultModulePath: String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/nikon-z-2.1.0/TestApp-extracted/TestApp/TestApp/TypeCommon Module.bundle/Contents/MacOS/TypeCommon Module")
            .path
    }

    public private(set) var loaded = false
    public private(set) var initialized = false
    public private(set) var connected = false

    public init() {}

    deinit {
        shutdown()
    }

    public var lastError: String {
        String(cString: af_last_error())
    }

    public func load(modulePath: String? = nil) throws {
        let path = modulePath
            ?? ProcessInfo.processInfo.environment["NIKON_SDK_MODULE"]
            ?? Self.defaultModulePath
        let code = path.withCString { af_load($0) }
        guard code == 0 else { throw SDKError.load("\(code) \(lastError)") }
        loaded = true
    }

    public func initialize() throws {
        guard loaded else { throw SDKError.load("not loaded") }
        let code = af_init()
        guard code == 0 else { throw SDKError.initFailed(code) }
        initialized = true
    }

    public func shutdown() {
        if connected { af_disconnect() }
        if initialized { af_free() }
        loaded = false
        initialized = false
        connected = false
    }

    public func devices() throws -> [SDKDevice] {
        _ = af_refresh_devices()
        var buf = [CChar](repeating: 0, count: 64 * 1024)
        let code = af_devices_json(&buf, Int32(buf.count))
        guard code == 0 else { throw SDKError.call("devices", code) }
        let json = String(cString: buf)
        guard let data = json.data(using: .utf8) else { throw SDKError.decode("utf8") }
        return try JSONDecoder().decode([SDKDevice].self, from: data)
    }

    public func connect(index: Int) throws {
        let code = af_connect(Int32(index))
        guard code == 0 else { throw SDKError.call("connect", code) }
        connected = true
    }

    public func disconnect() {
        if connected { af_disconnect() }
        connected = false
    }

    public func capabilities() throws -> [SDKCapability] {
        var buf = [CChar](repeating: 0, count: 256 * 1024)
        let code = af_caps_json(&buf, Int32(buf.count))
        guard code == 0 else { throw SDKError.call("caps", code) }
        let json = String(cString: buf)
        guard let data = json.data(using: .utf8) else { throw SDKError.decode("utf8") }
        return try JSONDecoder().decode([SDKCapability].self, from: data)
    }

    public func getUInt(_ name: String) throws -> UInt32 {
        var value: UInt32 = 0
        let code = name.withCString { af_cap_get_u32($0, &value) }
        guard code == 0 else { throw SDKError.call("get \(name)", code) }
        return value
    }

    public func setUInt(_ name: String, _ value: UInt32) throws {
        let code = name.withCString { af_cap_set_u32($0, value) }
        guard code == 0 else { throw SDKError.call("set \(name)", code) }
    }

    public func getEnum(_ name: String) throws -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let code = name.withCString { af_cap_get_enum($0, &buf, Int32(buf.count)) }
        guard code == 0 else { throw SDKError.call("get enum \(name)", code) }
        return String(cString: buf)
    }

    public func setEnum(_ name: String, _ value: String) throws {
        let code = name.withCString { n in
            value.withCString { v in af_cap_set_enum(n, v) }
        }
        guard code == 0 else { throw SDKError.call("set enum \(name)=\(value)", code) }
    }

    public func listEnum(_ name: String) throws -> [String] {
        var buf = [CChar](repeating: 0, count: 64 * 1024)
        let code = name.withCString { af_cap_list_enum($0, &buf, Int32(buf.count)) }
        guard code == 0 else { throw SDKError.call("list enum \(name)", code) }
        return String(cString: buf)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public func startLiveView() throws {
        let code = af_lv_start()
        guard code == 0 else { throw SDKError.call("startLiveView", code) }
    }

    public func stopLiveView() {
        _ = af_lv_stop()
    }

    public func liveViewStatus() -> Int32 {
        var status: Int32 = 0
        return af_lv_status(&status) == 0 ? status : -1
    }

    public func latestFrame() throws -> LiveFrame? {
        var buf = [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        var length: Int32 = 0
        var w: Int32 = 0
        var h: Int32 = 0
        var seq: UInt64 = 0
        let code = af_lv_get(&buf, Int32(buf.count), &length, &w, &h, &seq)
        guard code == 0 else {
            if code == 1 { return nil }
            throw SDKError.call("latestFrame", code)
        }
        return LiveFrame(sequence: seq, width: Int(w), height: Int(h),
                         jpeg: Data(buf.prefix(Int(length))))
    }

    public func pump(_ milliseconds: Int) {
        _ = af_pump(Int32(milliseconds))
    }

    public func frameCount() -> UInt64 {
        af_lv_frames()
    }

    public func shootSingle(directory: URL, autofocus: Bool) throws {
        let code = directory.path.withCString { af_shoot_single($0, autofocus ? 1 : 0) }
        guard code == 0 else { throw SDKError.call("shootSingle", code) }
    }

    public func shootBulb(directory: URL, seconds: Int) throws {
        let code = directory.path.withCString { af_shoot_bulb($0, Int32(seconds)) }
        guard code == 0 else { throw SDKError.call("shootBulb", code) }
    }

    public func waitCapture(timeoutMS: Int) -> Bool {
        af_wait_capture(Int32(timeoutMS)) == 0
    }

    public func focus(direction: Int, steps: Int) throws {
        let code = af_focus(Int32(direction), Int32(steps))
        guard code == 0 else { throw SDKError.call("focus", code) }
    }
}
#endif
