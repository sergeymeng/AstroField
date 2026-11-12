import Foundation
import AFSpikeCore

let usage = """
afspike <command> [options]

Commands:
  devices                          Load SDK and list USB devices
  caps [--index N]                 Connect and list capabilities
  get <name> [--index N]           Read a capability (enum or uint)
  set <name> <value> [--index N]   Write a capability
  enum <name> [--index N]          List enum values for a capability
  probe [--index N]                Read key settings and live view status
  liveview --seconds N [--out DIR] [--size 1|2|3] [--index N]
  shoot --dir DIR [--af] [--index N]
  bulb --dir DIR --seconds N [--index N]
  focus --direction 0|1 --steps N [--index N]
  selftest                         Run synthetic star-field analysis
  scan                             Run a synthetic FWHM/noise matrix
  icc [--seconds N]                Enumerate cameras via ImageCaptureCore
  icclv --seconds N [--out DIR] [--size 1|2|3]  Live view via ImageCaptureCore PTP
  iccshoot --out DIR [--timeout N] [--exposure S] [--remote] [--jpeg|--keep]
  iccbulb --seconds N --out DIR [--remote] [--jpeg|--keep]  Bulb capture + download
  iccfocus --direction 1|2 --steps N  Manual focus drive via ImageCaptureCore
  icccmd --opcode 0xXXXX [--params a,b,c] [--data 01,00]  Send one PTP command
  iccprops [--ids 0x5001,0x500D]   Read PTP properties with width and raw bytes
  iccmode remote|pc                ChangeCameraMode: host control vs camera dials
  iccmonitor on|off                Turn the camera screen on/off (PC mode only)

Environment:
  NIKON_SDK_HEADERS  SDK header directory at build time (optional MAID commands)
  NIKON_SDK_MODULE   Path to "TypeCommon Module" executable
"""

func argValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func flag(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}

#if ASTROFIELD_NIKON_SDK
func sdkLoadAndInit() throws -> NikonSDK {
    let sdk = NikonSDK()
    try sdk.load()
    try sdk.initialize()
    return sdk
}

func connectFirst(_ sdk: NikonSDK, index: Int = 0) throws -> SDKDevice {
    let devices = try sdk.devices()
    guard !devices.isEmpty else { throw SDKError.notConnected }
    let idx = min(max(0, index), devices.count - 1)
    try sdk.connect(index: idx)
    return devices[idx]
}

func printDevices(_ devices: [SDKDevice]) {
    if devices.isEmpty {
        print("no devices")
        return
    }
    for (i, d) in devices.enumerated() {
        print("[\(i)] \(d.name)  id=\(d.id)  fw=\(d.version)  available=\(d.available)  pid=\(d.pid)")
    }
}

func commandDevices(_ args: [String]) throws {
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    printDevices(try sdk.devices())
}

func commandCaps(_ args: [String]) throws {
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let index = Int(argValue("--index", in: args) ?? "0") ?? 0
    let device = try connectFirst(sdk, index: index)
    print("connected: \(device.name) fw=\(device.version)")
    let caps = try sdk.capabilities()
    print("capabilities: \(caps.count)")
    for c in caps {
        print(String(format: "0x%08x  type=%u ops=0x%x  %@", c.id, c.type, c.ops, c.desc))
    }
}

func commandGet(_ args: [String]) throws {
    guard args.count >= 3 else { print(usage); exit(2) }
    let name = args[2]
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let index = Int(argValue("--index", in: args) ?? "0") ?? 0
    _ = try connectFirst(sdk, index: index)
    if let value = try? sdk.getEnum(name) {
        print("\(name) = \(value)")
    } else {
        let value = try sdk.getUInt(name)
        print("\(name) = \(value)")
    }
}

func commandSet(_ args: [String]) throws {
    guard args.count >= 4 else { print(usage); exit(2) }
    let name = args[2], value = args[3]
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let index = Int(argValue("--index", in: args) ?? "0") ?? 0
    _ = try connectFirst(sdk, index: index)
    if let _ = try? sdk.getEnum(name) {
        try sdk.setEnum(name, value)
        print("\(name) = \(try sdk.getEnum(name))")
    } else {
        guard let v = UInt32(value) else { print("not a number: \(value)"); exit(2) }
        try sdk.setUInt(name, v)
        print("\(name) = \(try sdk.getUInt(name))")
    }
}

func commandEnum(_ args: [String]) throws {
    guard args.count >= 3 else { print(usage); exit(2) }
    let name = args[2]
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let index = Int(argValue("--index", in: args) ?? "0") ?? 0
    _ = try connectFirst(sdk, index: index)
    for v in try sdk.listEnum(name) { print(v) }
}

func commandLiveView(_ args: [String]) throws {
    let seconds = Double(argValue("--seconds", in: args) ?? "10") ?? 10
    let outDir = URL(fileURLWithPath: argValue("--out", in: args) ?? "liveview")
    let index = Int(argValue("--index", in: args) ?? "0") ?? 0
    let requestedSize = argValue("--size", in: args)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let csv = try CSVLog(url: outDir.appendingPathComponent("liveview.csv"))
    defer { csv.close() }

    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let device = try connectFirst(sdk, index: index)
    print("connected: \(device.name)")
    if let requestedSize {
        try? sdk.setEnum("liveviewsize", requestedSize)
        if let actual = try? sdk.getEnum("liveviewsize") {
            print("liveviewsize = \(actual)")
        }
    }
    try sdk.startLiveView()
    defer { sdk.stopLiveView() }

    let start = Date()
    var lastSeq: UInt64 = 0
    var saved = 0
    while Date().timeIntervalSince(start) < seconds {
        if let frame = try sdk.latestFrame(), frame.sequence != lastSeq {
            lastSeq = frame.sequence
            let name = String(format: "frame_%06llu.jpg", frame.sequence)
            try frame.jpeg.write(to: outDir.appendingPathComponent(name))
            saved += 1
            if saved % 10 == 0 {
                print("frame \(frame.sequence) \(frame.width)x\(frame.height) \(frame.jpeg.count) bytes")
            }
            csv.write(LogRecord(backend: "nikon-sdk", command: "liveview",
                                durationMS: 0, result: "ok",
                                detail: "seq=\(frame.sequence) \(frame.width)x\(frame.height) bytes=\(frame.jpeg.count)"))
        }
        sdk.pump(20)
    }
    let elapsed = Date().timeIntervalSince(start)
    let fps = elapsed > 0 ? Double(saved) / elapsed : 0
    print(String(format: "saved=%d frames, %.1f fps, seq=%llu", saved, fps, lastSeq))
    csv.write(LogRecord(backend: "nikon-sdk", command: "liveview.summary",
                        durationMS: elapsed * 1000, result: "ok",
                        detail: String(format: "frames=%d fps=%.2f", saved, fps)))
}


func waitForCapture(sdk: NikonSDK, dir: URL, before: Set<String>, timeout: TimeInterval) -> URL? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sdk.waitCapture(timeoutMS: 200) { break }
        if let f = CaptureWatcher.newestNewFile(in: dir, excluding: before) { return f }
    }
    return CaptureWatcher.newestNewFile(in: dir, excluding: before)
}

func commandShoot(_ args: [String]) throws {
    let dir = URL(fileURLWithPath: argValue("--dir", in: args) ?? "capture")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let device = try connectFirst(sdk, index: Int(argValue("--index", in: args) ?? "0") ?? 0)
    print("connected: \(device.name)")
    if !flag("--jpeg", in: args) {
        try? sdk.setEnum("compressionlevel", "RAW")
        if let q = try? sdk.getEnum("compressionlevel") { print("compressionlevel = \(q)") }
    }
    let before = CaptureWatcher.snapshot(dir)
    try sdk.shootSingle(directory: dir, autofocus: flag("--af", in: args))
    let file = waitForCapture(sdk: sdk, dir: dir, before: before, timeout: 120)
    if let file { print("capture saved: \(file.path)") } else { print("capture timeout") }
    exit(file == nil ? 3 : 0)
}

func commandBulb(_ args: [String]) throws {
    let dir = URL(fileURLWithPath: argValue("--dir", in: args) ?? "capture")
    let seconds = Int(argValue("--seconds", in: args) ?? "30") ?? 30
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let device = try connectFirst(sdk, index: Int(argValue("--index", in: args) ?? "0") ?? 0)
    print("connected: \(device.name), bulb \(seconds)s")
    if !flag("--jpeg", in: args) {
        try? sdk.setEnum("compressionlevel", "RAW")
        if let q = try? sdk.getEnum("compressionlevel") { print("compressionlevel = \(q)") }
    }
    let before = CaptureWatcher.snapshot(dir)
    try sdk.shootBulb(directory: dir, seconds: seconds)
    let file = waitForCapture(sdk: sdk, dir: dir, before: before, timeout: Double(seconds + 60))
    if let file { print("capture saved: \(file.path)") } else { print("capture timeout") }
    exit(file == nil ? 3 : 0)
}

func commandFocus(_ args: [String]) throws {
    let direction = Int(argValue("--direction", in: args) ?? "0") ?? 0
    let steps = Int(argValue("--steps", in: args) ?? "10") ?? 10
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let device = try connectFirst(sdk, index: Int(argValue("--index", in: args) ?? "0") ?? 0)
    print("connected: \(device.name), focus dir=\(direction) steps=\(steps)")
    try sdk.startLiveView()
    defer { sdk.stopLiveView() }
    try sdk.focus(direction: direction, steps: steps)
    print("focus done")
}


func commandProbe(_ args: [String]) throws {
    let sdk = try sdkLoadAndInit()
    defer { sdk.shutdown() }
    let device = try connectFirst(sdk, index: Int(argValue("--index", in: args) ?? "0") ?? 0)
    print("device: \(device.name)  fw=\(device.version)  id=\(device.id)")
    let keys = ["batterylevel", "savemedia", "liveviewsize", "monitoroff",
                "shutterspeed", "aperture", "sensitivity", "exposuremode", "lensinfo"]
    for key in keys {
        if let v = try? sdk.getEnum(key) {
            print("\(key): \(v)")
        } else if let v = try? sdk.getUInt(key) {
            print("\(key): \(v)")
        } else {
            print("\(key): <unavailable>")
        }
    }
    let status = sdk.liveViewStatus()
    print("liveview_status: \(status)")
    if let sizes = try? sdk.listEnum("liveviewsize") {
        print("liveviewsize values: \(sizes.joined(separator: ", "))")
    }
}


#endif

func parseHexBytes(_ text: String) -> Data? {    var bytes: [UInt8] = []
    for part in text.split(separator: ",") {
        var hex = part.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard let byte = UInt8(hex, radix: 16) else { return nil }
        bytes.append(byte)
    }
    return bytes.isEmpty ? nil : Data(bytes)
}

func iccCompression(_ args: [String]) -> CompressionSetting? {
    if flag("--jpeg", in: args) { return .jpegFine }
    if flag("--keep", in: args) { return nil }
    return .raw
}

/// Read PTP properties and print width, value and raw bytes. Useful for filling in
/// property types before adding UI controls.
func commandICCProps(_ args: [String]) {
    let defaults: [(UInt32, String)] = [
        (0x5001, "BatteryLevel"),
        (0x5003, "ImageSize"),
        (0x5004, "CompressionSetting"),
        (0x5005, "WhiteBalance"),
        (0x5007, "FNumber"),
        (0x500A, "FocusMode"),
        (0x500D, "ExposureTime"),
        (0x500E, "ExposureProgramMode"),
        (0x500F, "ExposureIndex"),
        (0x5010, "ExposureBiasCompensation"),
        (0x5011, "DateTime"),
        (0x5013, "StillCaptureMode"),
        (0xD100, "ShutterSpeed"),
        (0xD1A2, "RemoteLiveViewStatus"),
        (0xD1A4, "LiveViewProhibit"),
        (0xD1AC, "LiveViewImageSize"),
        (0xD1B8, "CameraLiveViewStatus"),
        (0xD1BA, "MonitorOffStatus")
    ]
    var entries = defaults
    if let raw = argValue("--ids", in: args) {
        entries = raw.split(separator: ",").compactMap { item in
            let text = item.trimmingCharacters(in: .whitespaces)
            let hex = text.hasPrefix("0x") || text.hasPrefix("0X")
                ? String(text.dropFirst(2)) : text
            guard let id = UInt32(hex, radix: 16) else { return nil }
            return (id, "")
        }
    }
    let camera = ICCCamera()
    camera.log = { print("icc: \($0)") }
    do {
        try camera.connect()
        for (id, name) in entries {
            do {
                let data = try camera.getPropertyData(id)
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                let value = (try? camera.getInteger(id)).map { "\($0)" } ?? "?"
                let field = name.padding(toLength: 28, withPad: " ", startingAt: 0)
                print(String(format: "0x%04X %@ %dB = %@  [%@]", id, field, data.count, value, hex))
            } catch {
                print(String(format: "0x%04X %@: %@", id, name, "\(error)"))
            }
        }
    } catch {
        print("icc props failed: \(error)")
    }
    camera.close()
}

func withICCCamera(_ body: (ICCCamera) throws -> Void) {
    let camera = ICCCamera()
    camera.log = { print("icc: \($0)") }
    do {
        try camera.connect()
        try body(camera)
    } catch {
        print("icc failed: \(error)")
    }
    camera.close()
}

func commandICCMode(_ args: [String]) {
    let mode = args.count >= 3 ? args[2].lowercased() : "remote"
    withICCCamera { camera in
        try camera.setCameraMode(remote: mode != "pc")
    }
}

func commandICCMonitor(_ args: [String]) {
    let screenOff = (args.count >= 3 ? args[2].lowercased() : "off") == "off"
    withICCCamera { camera in
        try camera.setMonitorOff(screenOff)
        camera.pump(0.5)
        let status = (try? camera.monitorOffStatus()).map { "\($0)" } ?? "?"
        print("monitor_off_status: \(status)")
    }
}

func commandScan() {
    print("sigma  noise  stars  fwhm_meas  fwhm_exp  err%   ecc")
    var failures = 0
    for sigma in [1.2, 1.6, 2.0, 2.8, 3.5] {
        for noise in [5.0, 20.0, 50.0] {
            let field = SyntheticFieldGenerator.make(width: 512, height: 512, starCount: 24,
                                                     sigma: sigma, background: 1000, noise: noise,
                                                     seed: UInt64(sigma * 100 + noise))
            let m = StarAnalyzer.analyze(pixels: field.pixels, width: field.width, height: field.height)
            let expected = 2.3548 * sigma
            let err = abs(m.medianFWHM - expected) / expected
            if m.starCount < 20 || err > 0.20 { failures += 1 }
            print(String(format: "%.1f    %5.1f  %5d  %9.2f  %8.2f  %5.1f  %.3f",
                         sigma, noise, m.starCount, m.medianFWHM, expected, err * 100,
                         m.medianEccentricity))
        }
    }
    print(failures == 0 ? "SCAN PASS" : "SCAN FAILURES: \(failures)")
    exit(failures == 0 ? 0 : 1)
}

func commandSelftest() {
    let field = SyntheticFieldGenerator.make(width: 512, height: 512, starCount: 24,
                                             sigma: 2.0, background: 1000, noise: 20)
    let m = StarAnalyzer.analyze(pixels: field.pixels, width: field.width, height: field.height)
    let expected = 2.3548 * 2.0
    let error = abs(m.medianFWHM - expected) / expected
    print(String(format: "stars=%d expected_fwhm=%.2f measured_fwhm=%.2f err=%.1f%%",
                 m.starCount, expected, m.medianFWHM, error * 100))
    print(String(format: "background=%.1f noise=%.2f ecc=%.3f sat=%.4f",
                 m.background, m.noise, m.medianEccentricity, m.saturatedFraction))
    let pass = m.starCount >= 20 && m.medianFWHM > 3.5 && m.medianFWHM < 6.0 && error < 0.15
    print(pass ? "SELFTEST PASS" : "SELFTEST FAIL")
    exit(pass ? 0 : 1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { print(usage); exit(2) }
let command = args[1]

do {
    switch command {
    #if ASTROFIELD_NIKON_SDK
    case "devices": try commandDevices(args)
    case "caps": try commandCaps(args)
    case "get": try commandGet(args)
    case "set": try commandSet(args)
    case "enum": try commandEnum(args)
    case "probe": try commandProbe(args)
    case "liveview": try commandLiveView(args)
    case "shoot": try commandShoot(args)
    case "bulb": try commandBulb(args)
    case "focus": try commandFocus(args)
    #else
    case "devices", "caps", "get", "set", "enum", "probe", "liveview", "shoot", "bulb", "focus":
        fputs("This command requires the optional Nikon MAID backend. Set NIKON_SDK_HEADERS when building; see docs/DEVELOPMENT.md. ImageCaptureCore commands (icc*) work without the SDK.\n", stderr)
        exit(2)
    #endif
    case "selftest": commandSelftest()
    case "scan": commandScan()
    case "icc":
        let seconds = Double(argValue("--seconds", in: args) ?? "5") ?? 5
        ICCProbe().start(timeout: seconds)
    case "icclv":
        let seconds = Double(argValue("--seconds", in: args) ?? "10") ?? 10
        let out = URL(fileURLWithPath: argValue("--out", in: args) ?? "logs/icclv")
        let size = argValue("--size", in: args).flatMap { UInt8($0) }
        ICCLiveView(seconds: seconds, outDir: out,
                    saveFrames: !flag("--no-save", in: args),
                    liveViewSize: size).run()
    case "iccshoot":
        let out = URL(fileURLWithPath: argValue("--out", in: args) ?? "logs/iccshoot")
        let timeout = Double(argValue("--timeout", in: args) ?? "90") ?? 90
        let exposure = argValue("--exposure", in: args).flatMap { Double($0) }
        let compression = iccCompression(args)
        ICCCapture(outDir: out, timeout: timeout,
                   exposureSeconds: exposure, compression: compression,
                   remoteMode: flag("--remote", in: args)).run()
    case "iccbulb":
        let out = URL(fileURLWithPath: argValue("--out", in: args) ?? "logs/iccbulb")
        let seconds = Double(argValue("--seconds", in: args) ?? "30") ?? 30
        let compression = iccCompression(args)
        ICCCapture(outDir: out, timeout: seconds + 90,
                   bulbSeconds: seconds, compression: compression,
                   remoteMode: flag("--remote", in: args)).run()
    case "iccprops":
        commandICCProps(args)
    case "iccmode":
        commandICCMode(args)
    case "iccmonitor":
        commandICCMonitor(args)
    case "iccfocus":
        let dir = UInt32(argValue("--direction", in: args) ?? "1") ?? 1
        let steps = UInt32(argValue("--steps", in: args) ?? "100") ?? 100
        ICCFocus(direction: dir, steps: steps).run()
    case "icccmd":
        let raw = argValue("--opcode", in: args) ?? "0x1001"
        let op = UInt16(raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw, radix: 16) ?? 0x1001
        let plist = (argValue("--params", in: args) ?? "").split(separator: ",")
        let params = plist.compactMap { s -> UInt32? in
            let v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("0x") || v.hasPrefix("0X") {
                return UInt32(v.dropFirst(2), radix: 16)
            }
            return UInt32(v)
        }
        let outData = argValue("--data", in: args).flatMap { parseHexBytes($0) }
        ICCCommand(opcode: op, params: params, outData: outData).run()
    default: print(usage); exit(2)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
