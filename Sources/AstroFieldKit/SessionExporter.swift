import Foundation
import AFSpikeCore

/// 会话内一帧在拍摄流程中的角色。
public enum SessionRole: String, Codable, Equatable, Sendable, CaseIterable {
    /// 正式拍摄帧。
    case light
    /// 试拍候选帧。
    case trial
    /// 自动对焦后的验证帧。
    case focusVerify
    /// 焦点包围序列中的帧。
    case focusBracket
    /// 其他验证帧。
    case verification
    /// 未分类帧。
    case other
}

/// 会话内一帧的相机参数快照。直接复用 `ExposureSettings`，避免字段漂移。
public typealias SettingsSnapshot = ExposureSettings

/// `FrameMetrics` 的可编码快照（`FrameMetrics` 本身不是 Codable）。
public struct MetricsSnapshot: Codable, Equatable, Sendable {
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

    /// 从测量结果建立快照。
    public init(_ metrics: FrameMetrics) {
        self.init(starCount: metrics.starCount,
                  background: metrics.background,
                  noise: metrics.noise,
                  medianFWHM: metrics.medianFWHM,
                  medianEccentricity: metrics.medianEccentricity,
                  saturatedFraction: metrics.saturatedFraction)
    }
}

/// 质量判定的可编码快照。保存代码与显示文本，避免枚举跨版本变化导致旧 sidecar 无法解码。
public struct VerdictSnapshot: Codable, Equatable, Sendable {
    /// 判定代码：accepted / warning / rejected / unmeasured。
    public var code: String
    /// 面向用户的判定文本。
    public var text: String

    public init(code: String, text: String) {
        self.code = code
        self.text = text
    }

    /// 从运行时的 `QualityVerdict` 建立快照。
    public init(_ verdict: QualityVerdict) {
        switch verdict {
        case .accepted:
            self.init(code: "accepted", text: verdict.shortText)
        case .warning(let message):
            self.init(code: "warning", text: message)
        case .rejected(let message):
            self.init(code: "rejected", text: message)
        case .unmeasured(let message):
            self.init(code: "unmeasured", text: message)
        }
    }

    /// 还原为运行时质量判定；未知代码按未测量处理。
    public var verdict: QualityVerdict {
        switch code {
        case "accepted": return .accepted
        case "warning": return .warning(text)
        case "rejected": return .rejected(text)
        default: return .unmeasured(text)
        }
    }
}

/// 一帧的 sidecar。`frameID` 是稳定主键；`fileName` 只指向会话目录内由本模块写出的
/// 图像文件，真实相机的原文件只记录在 `originalPath`，不复制也不修改。
public struct FrameSidecar: Codable, Equatable, Sendable, Identifiable {
    /// 帧的唯一标识，也是 sidecar 文件名与去重的依据。
    public var frameID: UUID
    /// 所属会话的 `SessionInfo.id`。
    public var sessionID: UUID
    /// 会话内序号，仅用于显示与排序。
    public var sequence: Int
    public var timestamp: Date
    public var role: SessionRole
    public var source: ImageSource
    /// 会话目录内的图像文件名（仅模拟帧写出 TIFF 时有值）。
    public var fileName: String?
    /// 相机原始文件路径（真实 NEF/JPEG 回放时记录，不复制）。
    public var originalPath: String?
    public var settings: SettingsSnapshot
    /// 图像宽度（写 TIFF 帧时由像素数据覆盖）。
    public var width: Int
    /// 图像高度（写 TIFF 帧时由像素数据覆盖）。
    public var height: Int
    /// 分析结果快照，未分析时为 nil。
    public var metrics: MetricsSnapshot?
    /// 质量判定快照，未判定时为 nil。
    public var verdict: VerdictSnapshot?
    public var qualityGroup: String?
    public var note: String?
    /// 是否已应用暗场校正。
    public var darkApplied: Bool

    public var id: UUID { frameID }

    public init(frameID: UUID = UUID(), sessionID: UUID, sequence: Int,
                timestamp: Date = Date(), role: SessionRole, source: ImageSource,
                fileName: String? = nil, originalPath: String? = nil,
                settings: SettingsSnapshot, width: Int = 0, height: Int = 0,
                metrics: MetricsSnapshot? = nil, verdict: VerdictSnapshot? = nil,
                qualityGroup: String? = nil, note: String? = nil,
                darkApplied: Bool = false) {
        self.frameID = frameID
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.role = role
        self.source = source
        self.fileName = fileName
        self.originalPath = originalPath
        self.settings = settings
        self.width = width
        self.height = height
        self.metrics = metrics
        self.verdict = verdict
        self.qualityGroup = qualityGroup
        self.note = note
        self.darkApplied = darkApplied
    }
}

/// 一次拍摄会话的标识与落盘位置。
public struct SessionInfo: Codable, Equatable, Sendable, Identifiable {
    /// 会话唯一标识，写入每一帧 sidecar 的 `sessionID`。
    public var id: UUID
    /// 会话目录名（本地时区 `yyyy-MM-dd_HHmmss`，重名时带 `-2` 后缀）。
    public var name: String
    public var directory: URL
    public var startedAt: Date

    public init(id: UUID = UUID(), name: String, directory: URL,
                startedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.directory = directory
        self.startedAt = startedAt
    }
}

/// `report.json` 的帧计数。verdict 为空或 `.unmeasured` 的帧计入 `unmeasured`。
public struct SessionSummary: Codable, Equatable, Sendable {
    public var frames: Int
    public var accepted: Int
    public var warning: Int
    public var rejected: Int
    public var unmeasured: Int

    public init(frames: Int, accepted: Int, warning: Int,
                rejected: Int, unmeasured: Int) {
        self.frames = frames
        self.accepted = accepted
        self.warning = warning
        self.rejected = rejected
        self.unmeasured = unmeasured
    }
}

/// `SessionStore.readFrames(in:)` 的结果：成功解析的帧与无法解码的文件。
public struct FrameReadResult: Equatable, Sendable {
    /// 成功解析并按 `sequence`/`timestamp` 排序、按 `frameID` 去重后的帧。
    public var frames: [FrameSidecar]
    /// 文件名匹配 sidecar 但内容无法解码的文件。
    public var invalidFiles: [URL]

    public init(frames: [FrameSidecar], invalidFiles: [URL]) {
        self.frames = frames
        self.invalidFiles = invalidFiles
    }
}

/// 会话报告生成器。全部为纯函数：CSV 表头固定为英文，字段按 RFC 4180 规则转义；
/// JSON 顶层包含 `generatedAt`、`session`、`summary`、`frames`。
public enum SessionReport {
    /// CSV 表头（英文，逗号分隔）。
    public static let csvHeader = "sequence,timestamp,role,source,file,iso,exposure_s,aperture,width,height,stars,fwhm,eccentricity,background,noise,saturated_fraction,verdict,group,dark,note"

    /// 统计各判定状态的帧数。
    public static func summary(frames: [FrameSidecar]) -> SessionSummary {
        var result = SessionSummary(frames: frames.count, accepted: 0, warning: 0,
                                    rejected: 0, unmeasured: 0)
        for frame in frames {
            switch frame.verdict?.code {
            case "accepted": result.accepted += 1
            case "warning": result.warning += 1
            case "rejected": result.rejected += 1
            default: result.unmeasured += 1
            }
        }
        return result
    }

    /// 生成 report.csv 文本（含表头与结尾换行）。
    public static func csv(frames: [FrameSidecar]) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = [csvHeader]
        for frame in frames {
            var columns: [String] = []
            columns.append(String(frame.sequence))
            columns.append(iso.string(from: frame.timestamp))
            columns.append(frame.role.rawValue)
            columns.append(frame.source.rawValue)
            columns.append(frame.fileName ?? frame.originalPath ?? "")
            columns.append(String(frame.settings.iso))
            columns.append(decimal(frame.settings.exposureSeconds, digits: 3))
            columns.append(frame.settings.aperture.map { decimal($0, digits: 1) } ?? "")
            columns.append(String(frame.width))
            columns.append(String(frame.height))
            columns.append(frame.metrics.map { String($0.starCount) } ?? "")
            columns.append(frame.metrics.map { decimal($0.medianFWHM, digits: 3) } ?? "")
            columns.append(frame.metrics.map { decimal($0.medianEccentricity, digits: 4) } ?? "")
            columns.append(frame.metrics.map { decimal($0.background, digits: 2) } ?? "")
            columns.append(frame.metrics.map { decimal($0.noise, digits: 2) } ?? "")
            columns.append(frame.metrics.map { decimal($0.saturatedFraction, digits: 6) } ?? "")
            columns.append(frame.verdict?.code ?? "")
            columns.append(frame.qualityGroup ?? "")
            columns.append(frame.darkApplied ? "1" : "0")
            columns.append(frame.note ?? "")
            lines.append(columns.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 生成 report.json 数据（ISO8601 日期，键排序）。
    public static func json(session: SessionInfo, frames: [FrameSidecar],
                            generatedAt: Date = Date()) throws -> Data {
        let report = ReportFile(generatedAt: generatedAt, session: session,
                                summary: summary(frames: frames), frames: frames)
        return try SessionCoding.encoder().encode(report)
    }

    // MARK: - Helpers

    private struct ReportFile: Codable {
        var generatedAt: Date
        var session: SessionInfo
        var summary: SessionSummary
        var frames: [FrameSidecar]
    }

    /// RFC 4180 转义：含逗号、引号、换行时整体加引号，内部引号翻倍。
    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// 固定英文小数点，避免系统区域设置把逗号带进 CSV。
    static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f",
               locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// 创建会话和保存文件时可能出现的错误。
public enum SessionStoreError: Error, LocalizedError, Equatable {
    /// 尚未调用 `beginSession`。
    case noActiveSession
    /// sidecar 属于其他会话，拒绝写入当前会话目录。
    case sessionMismatch
    case directoryCreationFailed(URL, String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "没有进行中的会话"
        case .sessionMismatch:
            return "帧不属于当前会话"
        case .directoryCreationFailed(let url, let reason):
            return "无法创建会话目录 \(url.path)：\(reason)"
        case .writeFailed(let url, let reason):
            return "无法保存 \(url.lastPathComponent)：\(reason)"
        }
    }
}

/// 会话目录管理：创建会话、写 16-bit TIFF 帧与 sidecar、导出叠加图、生成 CSV/JSON 报告。
///
/// 所有方法都可以在后台线程调用，内部用 `NSLock` 串行化；写失败抛错。
public final class SessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL
    private var activeSession: SessionInfo?

    /// 默认根目录：`ASTROFIELD_SESSION_ROOT` 环境变量优先，否则与 Nikon 下载目录一致
    /// （`~/Pictures/AstroField`）。
    public static func defaultRoot() -> URL {
        if let value = ProcessInfo.processInfo.environment["ASTROFIELD_SESSION_ROOT"],
           !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return NikonCamera.defaultOutputDirectory()
    }

    /// 用指定根目录创建 store；nil 使用 `defaultRoot()`。
    public init(root: URL? = nil) {
        rootURL = root ?? SessionStore.defaultRoot()
    }

    /// 会话根目录。
    public var root: URL { rootURL }

    /// 当前活动会话；未开始时为 nil。
    public var currentSession: SessionInfo? {
        lock.lock(); defer { lock.unlock() }
        return activeSession
    }

    /// 新建会话目录（本地时区 `yyyy-MM-dd_HHmmss`，重名追加 `-2`、`-3`…）并设为活动会话。
    ///
    /// - Parameter name: 自定义目录名；nil 时使用时间戳。
    @discardableResult
    public func beginSession(name: String? = nil,
                             startedAt: Date = Date()) throws -> SessionInfo {
        lock.lock(); defer { lock.unlock() }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw SessionStoreError.directoryCreationFailed(rootURL, error.localizedDescription)
        }
        let fallback = Self.timestampName(startedAt)
        let base = Self.filenameSafe(name ?? fallback, fallback: fallback)
        let directory = try makeUniqueDirectory(base: base)
        let info = SessionInfo(name: directory.lastPathComponent,
                               directory: directory, startedAt: startedAt)
        activeSession = info
        return info
    }

    /// 结束当前会话（只清状态，不删除文件）。
    public func endSession() {
        lock.lock(); defer { lock.unlock() }
        activeSession = nil
    }

    /// 写一帧 16-bit TIFF 与 sidecar。返回的 sidecar 含最终 `fileName` 与以像素为准的
    /// `width`/`height`；sidecar 写入失败时会尽力删除已写的 TIFF 并抛错。
    @discardableResult
    public func writeTIFFFrame(_ image: LumaImage,
                               sidecar: FrameSidecar) throws -> FrameSidecar {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession else { throw SessionStoreError.noActiveSession }
        var record = sidecar
        record.sessionID = session.id
        record.width = image.width
        record.height = image.height
        let fileName = Self.frameFileName(for: record)
        record.fileName = fileName
        let url = session.directory.appendingPathComponent(fileName)
        do {
            try TIFFWriter.write(image, to: url)
        } catch {
            throw SessionStoreError.writeFailed(url, error.localizedDescription)
        }
        do {
            try writeSidecarLocked(record, session: session)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return record
    }

    /// 覆盖更新 sidecar（按 `frameID` 定位），用于分析完成后回填 metrics/verdict。
    public func writeSidecar(_ sidecar: FrameSidecar) throws {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession else { throw SessionStoreError.noActiveSession }
        try writeSidecarLocked(sidecar, session: session)
    }

    /// 在当前会话目录导出叠加/星轨成片：16-bit TIFF 与 8-bit PNG。
    @discardableResult
    public func exportStack(_ image: LumaImage,
                            name: String = "stack") throws -> (tiff: URL, png: URL) {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession else { throw SessionStoreError.noActiveSession }
        let base = Self.filenameSafe(name, fallback: "stack")
        let tiffURL = session.directory.appendingPathComponent(base + ".tif")
        let pngURL = session.directory.appendingPathComponent(base + ".png")
        do {
            try TIFFWriter.write(image, to: tiffURL)
        } catch {
            throw SessionStoreError.writeFailed(tiffURL, error.localizedDescription)
        }
        do {
            try TIFFWriter.writePNG(image, to: pngURL)
        } catch {
            throw SessionStoreError.writeFailed(pngURL, error.localizedDescription)
        }
        return (tiffURL, pngURL)
    }

    /// 从磁盘读回当前会话的 sidecar，写 `report.csv` 与 `report.json`。
    @discardableResult
    public func writeReport(generatedAt: Date = Date()) throws -> (csv: URL, json: URL) {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession else { throw SessionStoreError.noActiveSession }
        let frames = readFramesLocked(in: session.directory).frames
        let csvURL = session.directory.appendingPathComponent("report.csv")
        let jsonURL = session.directory.appendingPathComponent("report.json")
        let csvText = SessionReport.csv(frames: frames)
        let jsonData: Data
        do {
            jsonData = try SessionReport.json(session: session, frames: frames,
                                              generatedAt: generatedAt)
        } catch {
            throw SessionStoreError.writeFailed(jsonURL, error.localizedDescription)
        }
        do {
            try Data(csvText.utf8).write(to: csvURL, options: .atomic)
        } catch {
            throw SessionStoreError.writeFailed(csvURL, error.localizedDescription)
        }
        do {
            try jsonData.write(to: jsonURL, options: .atomic)
        } catch {
            throw SessionStoreError.writeFailed(jsonURL, error.localizedDescription)
        }
        return (csvURL, jsonURL)
    }

    /// 从磁盘读回 sidecar，按 `sequence`/`timestamp` 排序并按 `frameID` 去重；
    /// 无法解码的文件会被跳过（需要报告时用 `readFrames(in:)`）。
    public func frames(in directory: URL) -> [FrameSidecar] {
        lock.lock(); defer { lock.unlock() }
        return readFramesLocked(in: directory).frames
    }

    /// 同 `frames(in:)`，另外返回无法解码的 sidecar 文件，便于上层告警。
    public func readFrames(in directory: URL) -> FrameReadResult {
        lock.lock(); defer { lock.unlock() }
        return readFramesLocked(in: directory)
    }

    // MARK: - Locked internals

    private func writeSidecarLocked(_ sidecar: FrameSidecar,
                                    session: SessionInfo) throws {
        guard sidecar.sessionID == session.id else { throw SessionStoreError.sessionMismatch }
        let url = session.directory.appendingPathComponent(
            Self.sidecarFileName(for: sidecar.frameID))
        let data: Data
        do {
            data = try SessionCoding.encoder().encode(sidecar)
        } catch {
            throw SessionStoreError.writeFailed(url, error.localizedDescription)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SessionStoreError.writeFailed(url, error.localizedDescription)
        }
    }

    private func readFramesLocked(in directory: URL) -> FrameReadResult {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else {
            return FrameReadResult(frames: [], invalidFiles: [])
        }
        var decoded: [FrameSidecar] = []
        var invalid: [URL] = []
        for url in urls {
            guard Self.isSidecarFile(url) else { continue }
            guard let data = try? Data(contentsOf: url) else {
                invalid.append(url)
                continue
            }
            do {
                decoded.append(try SessionCoding.decoder().decode(FrameSidecar.self, from: data))
            } catch {
                invalid.append(url)
            }
        }
        // 同一 frameID 的多次覆盖只保留时间较新的一份。
        var byID: [UUID: FrameSidecar] = [:]
        for frame in decoded {
            if let existing = byID[frame.frameID], existing.timestamp > frame.timestamp {
                continue
            }
            byID[frame.frameID] = frame
        }
        let frames = byID.values.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.frameID.uuidString < rhs.frameID.uuidString
        }
        invalid.sort { $0.lastPathComponent < $1.lastPathComponent }
        return FrameReadResult(frames: frames, invalidFiles: invalid)
    }

    private func makeUniqueDirectory(base: String) throws -> URL {
        let fileManager = FileManager.default
        for attempt in 1...9999 {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            let url = rootURL.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain
                    && (nsError.code == NSFileWriteFileExistsError
                        || nsError.code == NSFileWriteUnknownError) {
                    continue
                }
                throw SessionStoreError.directoryCreationFailed(url, error.localizedDescription)
            }
        }
        throw SessionStoreError.directoryCreationFailed(rootURL, "目录名重复过多")
    }

    // MARK: - Naming

    private static func timestampName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    private static func filenameSafe(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return replaced.isEmpty ? fallback : replaced
    }

    private static func frameFileName(for sidecar: FrameSidecar) -> String {
        let sequence = String(format: "%05d", sidecar.sequence)
        return "\(sidecar.role.rawValue)_\(sequence)_\(sidecar.frameID.uuidString.lowercased()).tif"
    }

    private static func sidecarFileName(for frameID: UUID) -> String {
        "frame-\(frameID.uuidString.lowercased()).json"
    }

    private static func isSidecarFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("frame-") && url.pathExtension.lowercased() == "json"
    }
}

/// sidecar/report 共用的 JSON 编解码策略（ISO8601 日期、键排序）。
enum SessionCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
