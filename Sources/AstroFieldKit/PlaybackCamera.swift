import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AFSpikeCore

/// Playback source: delivers real files (or generated samples) through the same
/// camera interface. It never claims that parameter changes alter the images.
public final class PlaybackCamera: CameraDevice, @unchecked Sendable {
    public let id = UUID()
    public var kind: CameraKind { .playback }
    public var displayName: String { "照片回放" }

    private let lock = NSLock()
    private var statusStorage: CameraStatus
    public var status: CameraStatus {
        lock.lock(); defer { lock.unlock() }
        return statusStorage
    }
    public var onStatusChange: ((CameraStatus) -> Void)?

    private var settings = ExposureSettings()
    private var files: [URL] = []
    private var index = 0
    private var tempDirectory: URL?
    public var deliveryDelay: Double = 0.35
    public var simulateTiming = true
    public var notes: [String] = []

    public init(directory: URL? = nil) {
        var loaded: [URL] = []
        var temp: URL?
        if let directory {
            loaded = Self.listImages(in: directory)
        }
        if loaded.isEmpty {
            let generated = Self.makeSamples()
            loaded = generated.files
            temp = generated.directory
        }
        self.files = loaded
        self.tempDirectory = temp
        let caps = Self.capabilities(for: loaded)
        self.statusStorage = CameraStatus(state: .disconnected,
                                          model: "Playback",
                                          capabilities: caps,
                                          notes: ["回放模式：文件原样呈现，参数修改不会改变照片"])
    }

    deinit {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
    }

    // MARK: - CameraDevice

    public func connect() async throws {
        setStatus(CameraStatus(state: .connecting, model: "Playback",
                               capabilities: Self.capabilities(for: files),
                               notes: playbackNotes))
        if simulateTiming { try? await sleep(0.25) }
        index = 0
        setStatus(CameraStatus(state: .connected, model: "Playback",
                               capabilities: Self.capabilities(for: files),
                               notes: playbackNotes))
    }

    public func disconnect() async {
        setStatus(CameraStatus(state: .disconnected, model: "Playback",
                               capabilities: Self.capabilities(for: files),
                               notes: ["回放已停止"]))
    }

    public func apply(_ settings: ExposureSettings) async throws {
        guard status.state.isConnected else { throw CameraError.disconnected }
        lock.lock()
        self.settings = settings
        lock.unlock()
        // Playback deliberately does not physically change anything.
    }

    public func capture(sequence: Int) async throws -> ImageRecord {
        guard status.state.isConnected else { throw CameraError.disconnected }
        guard !files.isEmpty else { throw CameraError.captureFailed("回放目录为空") }
        lock.lock()
        let url = files[index % files.count]
        index += 1
        let settings = self.settings
        lock.unlock()
        if simulateTiming { try? await sleep(deliveryDelay) }

        let meta = ImageLoader.metadata(url: url)
        let size = Self.imageSize(url: url)
        let ext = url.pathExtension.lowercased()
        var effective = settings
        var note = "回放文件 \(url.lastPathComponent)"
        if let meta {
            if let iso = meta.iso { effective.iso = iso }
            if let exposure = meta.exposureSeconds { effective.exposureSeconds = exposure }
            if let aperture = meta.aperture { effective.aperture = aperture }
            note += "（参数来自文件元数据；不随计划改变）"
        } else {
            note += "（文件无元数据，参数仅记录，不改变文件）"
        }
        return ImageRecord(sequence: sequence,
                           source: .playback,
                           fileURL: url,
                           settings: effective,
                           width: size.width,
                           height: size.height,
                           isRaw: ext == "nef" || ext == "nrw",
                           metrics: nil,
                           preview: nil,
                           note: note)
    }

    public func startLiveView() async throws {
        throw CameraError.unsupported("回放模式没有 LiveView")
    }

    public func stopLiveView() async {}

    public func livePreview() async throws -> LivePreview? {
        nil
    }

    public func focusDrive(direction: FocusDirection, steps: Int) async throws {
        throw CameraError.unsupported("回放模式不能驱动镜头")
    }

    // MARK: - Files

    public func useDirectory(_ directory: URL) {
        let loaded = Self.listImages(in: directory)
        lock.lock()
        files = loaded
        index = 0
        lock.unlock()
        if !loaded.isEmpty {
            setStatus(CameraStatus(state: status.state, model: "Playback",
                                   capabilities: Self.capabilities(for: loaded),
                                   notes: ["回放目录：\(directory.path)"]))
        }
    }

    public var fileCount: Int {
        lock.lock(); defer { lock.unlock() }
        return files.count
    }

    public var fileURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return files
    }

    private var playbackNotes: [String] {
        ["回放模式：\(files.count) 个文件", "参数修改只记录在计划中，不改变照片内容"]
    }

    private static func capabilities(for files: [URL]) -> Set<CameraCapability> {
        var caps: Set<CameraCapability> = [.stillCapture]
        if files.contains(where: { ["nef", "nrw"].contains($0.pathExtension.lowercased()) }) {
            caps.insert(.rawOutput)
        }
        return caps
    }

    private static func listImages(in directory: URL) -> [URL] {
        let exts: Set<String> = ["nef", "nrw", "jpg", "jpeg", "tif", "tiff", "png"]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func imageSize(url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }

    /// Build a few clearly-labeled synthetic JPEGs so playback works without samples.
    private static func makeSamples() -> (directory: URL, files: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldPlayback-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []
        let exposures: [Double] = [4, 10, 20]
        for (i, exposure) in exposures.enumerated() {
            var scene = SimulatorScene()
            scene.width = 1600
            scene.height = 1067
            scene.seed = 20261112 &+ UInt64(i) &* 97
            let sky = SimulatorSky(scene: scene)
            let settings = ExposureSettings(iso: 1600, exposureSeconds: exposure, aperture: 2.8)
            let luma = sky.render(settings: settings,
                                  focusSigma: 1.3 + Double(i) * 1.7,
                                  timeSeconds: Double(i) * 45,
                                  width: scene.width,
                                  height: scene.height,
                                  seedOffset: UInt64(i) &+ 1,
                                  isLive: false)
            guard let image = luma.displayImage() else { continue }
            let url = directory.appendingPathComponent(String(format: "SAMPLE_%04d.JPG", i + 1))
            if let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                          UTType.jpeg.identifier as CFString,
                                                          1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                CGImageDestinationFinalize(dest)
                files.append(url)
            }
        }
        return (directory, files)
    }

    private func sleep(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func setStatus(_ status: CameraStatus) {
        lock.lock()
        statusStorage = status
        lock.unlock()
        onStatusChange?(status)
    }
}
