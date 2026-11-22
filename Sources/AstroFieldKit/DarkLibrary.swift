import Foundation

/// Layout constants for the `.darkbin` master dark format.
///
/// Header: ASCII "AFDK", then three 32-bit little-endian integers (format
/// version, width, height), followed by `width * height` Float32 little-endian
/// pixel values.
enum MasterDarkFormat {
    static let version: Int = 1
    static let fileExtension = "darkbin"
    /// "AFDK".
    static let magic: [UInt8] = [0x41, 0x46, 0x44, 0x4B]
    static let headerBytes = 16

    static func fileName(for id: UUID) -> String {
        "\(id.uuidString).\(fileExtension)"
    }
}

/// Errors reported by `DarkLibrary` and `DarkAccumulator`.
public enum DarkLibraryError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The index exists but cannot be decoded. The original file is left untouched.
    case indexCorrupted(String)
    /// Reading or writing a library file failed.
    case ioFailed(String)
    /// A frame had zero size or an inconsistent pixel buffer.
    case invalidFrame
    /// The accumulator received a frame with a different size than its first frame.
    case frameSizeMismatch(expectedWidth: Int, expectedHeight: Int, gotWidth: Int, gotHeight: Int)
    /// The accumulator received a frame captured with different exposure settings.
    case settingsMismatch

    public var description: String {
        switch self {
        case .indexCorrupted(let path):
            return L10n.text("暗场索引损坏：%@", path)
        case .ioFailed(let why):
            return L10n.text("暗场文件读写失败：%@", why)
        case .invalidFrame:
            return L10n.text("暗场帧无效")
        case .frameSizeMismatch(let expectedWidth, let expectedHeight,
                                let gotWidth, let gotHeight):
            return L10n.text("暗场帧尺寸不一致：期望 %@×%@，实际 %@×%@", expectedWidth, expectedHeight, gotWidth, gotHeight)
        case .settingsMismatch:
            return L10n.text("暗场帧曝光参数不一致")
        }
    }
}

/// Metadata for one master dark frame stored in a `DarkLibrary`.
public struct MasterDarkMeta: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier; the binary file name is derived from it.
    public var id: UUID
    /// Creation time of the master frame.
    public var createdAt: Date
    /// Camera backend that produced the source frames.
    public var source: ImageSource
    /// Exposure time used for every accumulated frame, in seconds.
    public var exposureSeconds: Double
    /// ISO used for every accumulated frame.
    public var iso: Int
    /// Number of accumulated frames.
    public var frameCount: Int
    /// Master frame width in pixels.
    public var width: Int
    /// Master frame height in pixels.
    public var height: Int
    /// Mean pixel level of the master frame.
    public var meanLevel: Float
    /// Pixels above median + 20 × 1.4826 × MAD in the master frame.
    public var hotPixelCount: Int
    /// Binary file name inside the library directory.
    public var fileName: String
    /// On-disk format version of the companion `.darkbin` file.
    public var formatVersion: Int
    /// False when the decoded master has a degenerate distribution (for example
    /// a Core Image NEF decode that clips most dark pixels to zero). Such a
    /// master is kept for inspection but never auto-matched for subtraction.
    /// Optional so indexes written before this flag still decode; nil means true.
    public var usable: Bool?

    /// Creates metadata. `fileName` defaults to `<id>.darkbin`.
    public init(id: UUID = UUID(),
                createdAt: Date = Date(),
                source: ImageSource = .simulator,
                exposureSeconds: Double,
                iso: Int,
                frameCount: Int,
                width: Int,
                height: Int,
                meanLevel: Float = 0,
                hotPixelCount: Int = 0,
                fileName: String? = nil,
                formatVersion: Int = 1,
                usable: Bool? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.exposureSeconds = exposureSeconds
        self.iso = iso
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.meanLevel = meanLevel
        self.hotPixelCount = hotPixelCount
        self.fileName = fileName ?? "\(id.uuidString).\(MasterDarkFormat.fileExtension)"
        self.formatVersion = formatVersion
        self.usable = usable
    }

    /// True unless the master was explicitly marked unusable.
    public var isUsable: Bool { usable != false }
}

/// A master dark frame: metadata plus the averaged pixel buffer.
public struct MasterDark: Sendable {
    /// Metadata describing how the master was built.
    public var meta: MasterDarkMeta
    /// Averaged pixel buffer, `meta.width * meta.height` values.
    public var pixels: [Float]

    /// Creates a master from metadata and its pixel buffer.
    public init(meta: MasterDarkMeta, pixels: [Float]) {
        self.meta = meta
        self.pixels = pixels
    }
}

/// Streaming accumulator for dark frames.
///
/// Each frame is folded into one Double sum buffer, so eight 2 MP frames never
/// have to be kept in memory at once. The first frame fixes the expected size;
/// frames of another size or with other exposure settings are rejected.
public final class DarkAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var sums: [Double] = []
    private var widthStorage = 0
    private var heightStorage = 0
    private var count = 0
    private var settingsStorage: ExposureSettings?

    /// Creates an empty accumulator.
    public init() {}

    /// Number of frames accumulated so far.
    public var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Width of the first accumulated frame, nil while empty.
    public var frameWidth: Int? {
        lock.lock(); defer { lock.unlock() }
        return count > 0 ? widthStorage : nil
    }

    /// Height of the first accumulated frame, nil while empty.
    public var frameHeight: Int? {
        lock.lock(); defer { lock.unlock() }
        return count > 0 ? heightStorage : nil
    }

    /// Exposure settings carried by the first frame, if any were supplied.
    public var recordedSettings: ExposureSettings? {
        lock.lock(); defer { lock.unlock() }
        return settingsStorage
    }

    /// Adds one dark frame to the running sum.
    ///
    /// - Parameters:
    ///   - frame: Luminance frame to accumulate.
    ///   - settings: Settings the frame was captured with. When supplied for the
    ///     first frame it is recorded, and later frames must match it.
    public func add(_ frame: LumaImage, settings: ExposureSettings? = nil) throws {
        guard frame.width > 0, frame.height > 0,
              frame.pixels.count == frame.width * frame.height else {
            throw DarkLibraryError.invalidFrame
        }
        lock.lock()
        defer { lock.unlock() }
        if count == 0 {
            widthStorage = frame.width
            heightStorage = frame.height
            sums = [Double](repeating: 0, count: frame.pixels.count)
        } else if frame.width != widthStorage || frame.height != heightStorage {
            throw DarkLibraryError.frameSizeMismatch(expectedWidth: widthStorage,
                                                      expectedHeight: heightStorage,
                                                      gotWidth: frame.width,
                                                      gotHeight: frame.height)
        }
        if let settings {
            if let recorded = settingsStorage {
                guard recorded == settings else { throw DarkLibraryError.settingsMismatch }
            } else {
                settingsStorage = settings
            }
        }
        for index in sums.indices {
            sums[index] += Double(frame.pixels[index])
        }
        count += 1
    }

    /// Builds the mean master frame.
    ///
    /// - Parameters:
    ///   - settings: Settings recorded in the metadata. When frame settings were
    ///     supplied to `add`, they must match.
    ///   - createdAt: Creation timestamp for the metadata.
    ///   - source: Camera backend that produced the frames.
    /// - Returns: The master frame, or nil when nothing was accumulated or the
    ///   settings disagree with the recorded ones.
    public func build(settings: ExposureSettings,
                      createdAt: Date = Date(),
                      source: ImageSource = .simulator) -> MasterDark? {
        lock.lock()
        let frames = count
        let width = widthStorage
        let height = heightStorage
        let sumsCopy = sums
        let recorded = settingsStorage
        lock.unlock()

        guard frames > 0, width > 0, height > 0,
              sumsCopy.count == width * height else { return nil }
        if let recorded, recorded != settings { return nil }

        let divisor = Double(frames)
        var pixels = [Float](repeating: 0, count: sumsCopy.count)
        var total: Double = 0
        for index in sumsCopy.indices {
            let value = sumsCopy[index] / divisor
            pixels[index] = Float(value)
            total += value
        }
        let meanLevel = Float(total / Double(pixels.count))
        let sorted = pixels.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.90))]
        let deviations = pixels.map { abs($0 - median) }
        let mad = Self.median(deviations)
        // A decoded NEF dark can collapse to a two-level image (most pixels
        // clipped to zero, the rest at a high level). Such a master would
        // over-subtract a normal frame, so keep it but never auto-match it.
        let degenerate = median <= 1 && p90 - median > 5000
        // Robust hot-pixel threshold: never below a visible absolute level.
        let sigma = 20.0 * 1.4826 * Double(mad)
        let threshold = median + Float(max(sigma, 2000))
        let hotPixelCount = pixels.reduce(into: 0) { count, value in
            if value > threshold { count += 1 }
        }
        let meta = MasterDarkMeta(createdAt: createdAt,
                                  source: source,
                                  exposureSeconds: settings.exposureSeconds,
                                  iso: settings.iso,
                                  frameCount: frames,
                                  width: width,
                                  height: height,
                                  meanLevel: meanLevel,
                                  hotPixelCount: hotPixelCount,
                                  usable: !degenerate)
        return MasterDark(meta: meta, pixels: pixels)
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// On-disk library of master dark frames.
///
/// The library keeps a JSON index plus one `<uuid>.darkbin` per master in its
/// directory (default `~/Library/Application Support/AstroField/Darks`). All
/// methods are thread-safe; index access is locked and large pixel files are
/// read and written outside the index lock.
public final class DarkLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    /// Single-entry pixel cache; masters are ~10 MB at full resolution.
    private var cached: MasterDark?

    /// Creates a library rooted at `directory`, defaulting to
    /// `~/Library/Application Support/AstroField/Darks`. The directory is
    /// created when missing.
    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AstroField/Darks",
                                    isDirectory: true)
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Library directory containing the index and `.darkbin` files.
    public var location: URL { directory }

    /// All known masters, newest first. Ties on `createdAt` break by id so the
    /// order is stable across calls.
    public func all() -> [MasterDarkMeta] {
        lock.lock()
        let metas = (try? readIndexLocked()) ?? []
        lock.unlock()
        return metas.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Finds the best master for a capture.
    ///
    /// ISO must match exactly and the exposure time may differ by at most 10 %
    /// (relative to the longer exposure). A source must match when given; the
    /// same-size master is preferred over one that has to be resampled. Among
    /// equally good masters the newest wins.
    public func match(iso: Int,
                      exposureSeconds: Double,
                      source: ImageSource? = nil,
                      width: Int? = nil,
                      height: Int? = nil) -> MasterDarkMeta? {
        let tolerance = 0.10
        let candidates = all().filter { meta in
            guard meta.isUsable else { return false }
            guard meta.iso == iso else { return false }
            let reference = max(abs(meta.exposureSeconds), abs(exposureSeconds))
            if reference > 0 {
                guard abs(meta.exposureSeconds - exposureSeconds) / reference <= tolerance else {
                    return false
                }
            } else {
                guard meta.exposureSeconds == exposureSeconds else { return false }
            }
            if let source, meta.source != source { return false }
            return true
        }
        if let width, let height,
           let exact = candidates.first(where: { $0.width == width && $0.height == height }) {
            return exact
        }
        return candidates.first
    }

    /// Writes the master pixel buffer and upserts its metadata in the index.
    ///
    /// The file name is always derived from the metadata id.
    /// - Returns: The stored metadata with the final `fileName`.
    /// - Throws: `DarkLibraryError` when the frame buffer is inconsistent, the
    ///   index is corrupt (the file is preserved) or a write fails.
    @discardableResult
    public func save(_ dark: MasterDark) throws -> MasterDarkMeta {
        var meta = dark.meta
        meta.fileName = MasterDarkFormat.fileName(for: meta.id)
        meta.formatVersion = MasterDarkFormat.version
        guard meta.width > 0, meta.height > 0,
              dark.pixels.count == meta.width * meta.height else {
            throw DarkLibraryError.invalidFrame
        }
        // Validate the index before writing the large pixel file so a corrupt
        // index never leaves an orphan binary behind.
        lock.lock()
        do { _ = try readIndexLocked() } catch { lock.unlock(); throw error }
        lock.unlock()

        let fileURL = directory.appendingPathComponent(meta.fileName)
        let data = Self.encode(meta: meta, pixels: dark.pixels)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw DarkLibraryError.ioFailed(error.localizedDescription)
        }

        lock.lock()
        defer { lock.unlock() }
        var metas = try readIndexLocked()
        if let index = metas.firstIndex(where: { $0.id == meta.id }) {
            metas[index] = meta
        } else {
            metas.append(meta)
        }
        try writeIndexLocked(metas)
        if cached?.meta.id == meta.id { cached = nil }
        return meta
    }

    /// Loads a master by id. Returns nil when the entry is missing or the file
    /// fails validation (bad magic, version, size or metadata mismatch).
    public func load(id: UUID) -> MasterDark? {
        lock.lock()
        if let cached, cached.meta.id == id {
            lock.unlock()
            return cached
        }
        let meta = ((try? readIndexLocked()) ?? []).first(where: { $0.id == id })
        lock.unlock()
        guard let meta else { return nil }
        return load(meta: meta)
    }

    /// Loads the pixels for known metadata. Returns nil when the file is
    /// missing, truncated or inconsistent with `meta`.
    public func load(meta: MasterDarkMeta) -> MasterDark? {
        lock.lock()
        if let cached, cached.meta.id == meta.id {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fileURL = directory.appendingPathComponent(meta.fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = Self.decode(data),
              decoded.version == meta.formatVersion,
              decoded.width == meta.width,
              decoded.height == meta.height else { return nil }
        let dark = MasterDark(meta: meta, pixels: decoded.pixels)
        lock.lock()
        cached = dark
        lock.unlock()
        return dark
    }

    /// Deletes the master with `id`, removing its file and index entry.
    ///
    /// Missing entries are ignored (idempotent).
    /// - Returns: true when a file or index entry was removed.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var removed = false
        var metas = (try? readIndexLocked()) ?? []
        let fileName = metas.first(where: { $0.id == id })?.fileName
            ?? MasterDarkFormat.fileName(for: id)
        let fileURL = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                removed = true
            } catch {
                // Keep going: the index entry is still cleaned up below.
            }
        }
        if metas.contains(where: { $0.id == id }) {
            metas.removeAll { $0.id == id }
            if (try? writeIndexLocked(metas)) != nil { removed = true }
        }
        if cached?.meta.id == id { cached = nil }
        return removed
    }

    // MARK: - Index

    private func indexURL() -> URL {
        directory.appendingPathComponent("index.json")
    }

    /// Reads and decodes the index. Callers must hold `lock`.
    private func readIndexLocked() throws -> [MasterDarkMeta] {
        let url = indexURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DarkLibraryError.ioFailed(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode([MasterDarkMeta].self, from: data)
        } catch {
            throw DarkLibraryError.indexCorrupted(url.path)
        }
    }

    /// Encodes and atomically writes the index. Callers must hold `lock`.
    private func writeIndexLocked(_ metas: [MasterDarkMeta]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(metas)
        } catch {
            throw DarkLibraryError.ioFailed(error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try data.write(to: indexURL(), options: .atomic)
        } catch {
            throw DarkLibraryError.ioFailed(error.localizedDescription)
        }
    }

    // MARK: - Binary format

    private struct DecodedDark {
        var version: Int
        var width: Int
        var height: Int
        var pixels: [Float]
    }

    private static func encode(meta: MasterDarkMeta, pixels: [Float]) -> Data {
        var data = Data(capacity: MasterDarkFormat.headerBytes + pixels.count * 4)
        data.append(contentsOf: MasterDarkFormat.magic)
        appendUInt32(UInt32(clamping: meta.formatVersion), to: &data)
        appendUInt32(UInt32(clamping: meta.width), to: &data)
        appendUInt32(UInt32(clamping: meta.height), to: &data)
        var bits = [UInt32](repeating: 0, count: pixels.count)
        for index in pixels.indices { bits[index] = pixels[index].bitPattern.littleEndian }
        bits.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func decode(_ data: Data) -> DecodedDark? {
        guard data.count >= MasterDarkFormat.headerBytes else { return nil }
        let header = [UInt8](data.prefix(MasterDarkFormat.headerBytes))
        guard Array(header[0..<4]) == MasterDarkFormat.magic else { return nil }
        let version = Int(readUInt32(header, at: 4))
        guard version == MasterDarkFormat.version else { return nil }
        let width = Int(readUInt32(header, at: 8))
        let height = Int(readUInt32(header, at: 12))
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              width * height <= 200_000_000 else { return nil }
        guard data.count == MasterDarkFormat.headerBytes + width * height * 4 else {
            return nil
        }
        var pixels = [Float](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            for index in pixels.indices {
                let offset = MasterDarkFormat.headerBytes + index * 4
                let byte0 = UInt32(raw[offset])
                let byte1 = UInt32(raw[offset + 1]) << 8
                let byte2 = UInt32(raw[offset + 2]) << 16
                let byte3 = UInt32(raw[offset + 3]) << 24
                pixels[index] = Float(bitPattern: byte0 | byte1 | byte2 | byte3)
            }
        }
        return DecodedDark(version: version, width: width, height: height, pixels: pixels)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        let byte0 = UInt32(bytes[offset])
        let byte1 = UInt32(bytes[offset + 1]) << 8
        let byte2 = UInt32(bytes[offset + 2]) << 16
        let byte3 = UInt32(bytes[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }
}

/// Applies a master dark to a luminance frame.
public enum DarkSubtraction {
    /// Subtracts `dark` from `frame`, clamped to `0...frame.maxValue`.
    ///
    /// The frame is returned unchanged when the master has an inconsistent
    /// pixel buffer. When sizes differ the master is resampled to the frame
    /// size with a box filter first; that path deliberately does not promise
    /// hot-pixel removal because box filtering spreads single-pixel defects.
    public static func subtract(_ dark: MasterDark, from frame: LumaImage) -> LumaImage {
        guard frame.width > 0, frame.height > 0,
              frame.pixels.count == frame.width * frame.height else { return frame }
        let darkPixels: [Float]
        if dark.meta.width == frame.width, dark.meta.height == frame.height,
           dark.pixels.count == frame.width * frame.height {
            darkPixels = dark.pixels
        } else if dark.meta.width > 0, dark.meta.height > 0,
                  dark.pixels.count == dark.meta.width * dark.meta.height {
            darkPixels = resample(dark.pixels,
                                  fromWidth: dark.meta.width, fromHeight: dark.meta.height,
                                  toWidth: frame.width, toHeight: frame.height)
        } else {
            return frame
        }
        var out = [Float](repeating: 0, count: frame.pixels.count)
        let maxValue = frame.maxValue
        for index in out.indices {
            out[index] = min(maxValue, max(0, frame.pixels[index] - darkPixels[index]))
        }
        return LumaImage(width: frame.width, height: frame.height,
                         pixels: out, maxValue: frame.maxValue)
    }

    /// Area-average resample to an exact target size.
    private static func resample(_ pixels: [Float],
                                 fromWidth: Int, fromHeight: Int,
                                 toWidth: Int, toHeight: Int) -> [Float] {
        var out = [Float](repeating: 0, count: toWidth * toHeight)
        for oy in 0..<toHeight {
            let sy0 = oy * fromHeight / toHeight
            let sy1 = max(sy0 + 1, min(fromHeight, (oy + 1) * fromHeight / toHeight))
            for ox in 0..<toWidth {
                let sx0 = ox * fromWidth / toWidth
                let sx1 = max(sx0 + 1, min(fromWidth, (ox + 1) * fromWidth / toWidth))
                var sum: Double = 0
                var count = 0
                for sy in sy0..<sy1 {
                    let row = sy * fromWidth
                    for sx in sx0..<sx1 {
                        sum += Double(pixels[row + sx])
                        count += 1
                    }
                }
                out[oy * toWidth + ox] = count > 0 ? Float(sum / Double(count)) : 0
            }
        }
        return out
    }
}
