import XCTest
import CoreGraphics
import ImageIO
import AFSpikeCore
@testable import AstroFieldKit

final class SessionExportTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldSession-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// 只随 x 变化的渐变图：即使读取端纵向翻转也不影响逐像素比较。
    private func gradientImage(width: Int, height: Int) -> LumaImage {
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = Float(x) * 700 + 21
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    private func makeSidecar(sessionID: UUID = UUID(), sequence: Int,
                             role: SessionRole = .light,
                             verdict: VerdictSnapshot? = nil,
                             metrics: MetricsSnapshot? = nil) -> FrameSidecar {
        FrameSidecar(
            sessionID: sessionID,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
            role: role,
            source: .simulator,
            settings: SettingsSnapshot(iso: 1600, exposureSeconds: 10,
                                       aperture: 2.8, compression: .raw),
            metrics: metrics,
            verdict: verdict,
            qualityGroup: "group-1",
            note: "帧 \(sequence)")
    }

    /// 直接读取 ImageIO 解码后的 16-bit 采样，避免 CGContext 颜色管理影响比较。
    private func decodePixels(_ image: CGImage) -> [Float]? {
        guard image.bitsPerComponent == 16, image.bitsPerPixel == 16,
              let data = image.dataProvider?.data else { return nil }
        let bytes = [UInt8](data as Data)
        let littleEndian = image.bitmapInfo.contains(.byteOrder16Little)
        var pixels = [Float](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 2
                guard offset + 1 < bytes.count else { return nil }
                let first = UInt16(bytes[offset])
                let second = UInt16(bytes[offset + 1])
                let value = littleEndian ? (first | second << 8) : (first << 8 | second)
                pixels[y * image.width + x] = Float(value)
            }
        }
        return pixels
    }

    // MARK: - TIFF / PNG

    func testTIFFRoundTrip16Bit() throws {
        let dir = makeTempDir("tiff")
        let url = dir.appendingPathComponent("frame.tif")
        let image = gradientImage(width: 64, height: 40)
        try TIFFWriter.write(image, to: url)

        let dimensions = try XCTUnwrap(ImageLoader.dimensions(url: url))
        XCTAssertEqual(dimensions.width, 64)
        XCTAssertEqual(dimensions.height, 40)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("TIFF 无法被 ImageIO 读取")
        }
        XCTAssertEqual(cgImage.width, 64)
        XCTAssertEqual(cgImage.height, 40)
        XCTAssertEqual(cgImage.bitsPerComponent, 16)

        let pixels = try XCTUnwrap(decodePixels(cgImage))
        XCTAssertEqual(pixels.count, 64 * 40)
        for y in 0..<40 {
            for x in 0..<64 {
                let expected = Float(x) * 700 + 21
                XCTAssertEqual(pixels[y * 64 + x], expected, accuracy: 2,
                               "像素 (\(x),\(y)) 误差超出 2")
            }
        }
    }

    func testPNGExport() throws {
        let dir = makeTempDir("png")
        let url = dir.appendingPathComponent("stack.png")
        let image = gradientImage(width: 48, height: 32)
        try TIFFWriter.writePNG(image, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("PNG 无法被 ImageIO 读取")
        }
        XCTAssertEqual(cgImage.width, 48)
        XCTAssertEqual(cgImage.height, 32)
        XCTAssertEqual(cgImage.bitsPerComponent, 8)
    }

    // MARK: - Session directories

    func testBeginSessionCreatesTimestampedDirectoryAndResolvesCollisions() throws {
        let store = SessionStore(root: makeTempDir("sessions"))
        let first = try store.beginSession()
        let second = try store.beginSession()

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(store.currentSession?.id, second.id)

        let pattern = #"^\d{4}-\d{2}-\d{2}_\d{6}$"#
        XCTAssertNotNil(first.name.range(of: pattern, options: .regularExpression),
                        "目录名应为 yyyy-MM-dd_HHmmss：\(first.name)")
        if second.name.hasPrefix(first.name) {
            XCTAssertEqual(second.name, first.name + "-2")
        }

        // 指定名称时重名从 -2 开始
        let named = try store.beginSession(name: "fixed")
        let namedAgain = try store.beginSession(name: "fixed")
        XCTAssertEqual(named.name, "fixed")
        XCTAssertEqual(namedAgain.name, "fixed-2")
        XCTAssertEqual(namedAgain.directory.lastPathComponent, "fixed-2")
    }

    // MARK: - Frames and sidecars

    func testWriteTIFFFrameAndSidecarRoundTrip() throws {
        let store = SessionStore(root: makeTempDir("frame"))
        let session = try store.beginSession()
        let image = gradientImage(width: 32, height: 24)
        let initial = makeSidecar(sessionID: session.id, sequence: 3)
        let written = try store.writeTIFFFrame(image, sidecar: initial)

        XCTAssertEqual(written.sessionID, session.id)
        XCTAssertEqual(written.width, 32)
        XCTAssertEqual(written.height, 24)
        let fileName = try XCTUnwrap(written.fileName)
        XCTAssertTrue(fileName.hasPrefix("light_00003_"))
        XCTAssertTrue(fileName.hasSuffix(".tif"))
        let tiffURL = session.directory.appendingPathComponent(fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tiffURL.path))

        var updated = written
        let metrics = FrameMetrics(starCount: 12, background: 812.5, noise: 21.25,
                                   medianFWHM: 2.63, medianEccentricity: 0.14,
                                   saturatedFraction: 0.0021)
        updated.metrics = MetricsSnapshot(metrics)
        updated.verdict = VerdictSnapshot(.warning("背景变化 50%"))
        updated.darkApplied = true
        updated.note = "分析完成"
        try store.writeSidecar(updated)

        let frames = store.frames(in: session.directory)
        XCTAssertEqual(frames.count, 1)
        let readBack = try XCTUnwrap(frames.first)
        XCTAssertEqual(readBack.frameID, written.frameID)
        XCTAssertEqual(readBack.sessionID, session.id)
        XCTAssertEqual(readBack.sequence, 3)
        XCTAssertEqual(readBack.fileName, fileName)
        XCTAssertEqual(readBack.metrics, MetricsSnapshot(metrics))
        XCTAssertEqual(readBack.verdict?.code, "warning")
        XCTAssertEqual(readBack.verdict?.text, "背景变化 50%")
        XCTAssertTrue(readBack.darkApplied)
        XCTAssertEqual(readBack.note, "分析完成")
        // 时间戳以 ISO8601 整秒往返
        XCTAssertEqual(readBack.timestamp, initial.timestamp)

        // 一帧一个 TIFF 加一个 sidecar，覆盖更新不新增文件
        let contents = try FileManager.default.contentsOfDirectory(atPath: session.directory.path)
        XCTAssertEqual(contents.count, 2)
    }

    func testFramesReadBackToleratesCorruptSidecarAndIgnoresReport() throws {
        let store = SessionStore(root: makeTempDir("tolerant"))
        let session = try store.beginSession()
        _ = try store.writeTIFFFrame(gradientImage(width: 8, height: 8),
                                     sidecar: makeSidecar(sessionID: session.id, sequence: 1))
        _ = try store.writeTIFFFrame(gradientImage(width: 8, height: 8),
                                     sidecar: makeSidecar(sessionID: session.id, sequence: 2))
        let bad = session.directory.appendingPathComponent("frame-bad.json")
        try Data("{ not valid json".utf8).write(to: bad)

        let result = store.readFrames(in: session.directory)
        XCTAssertEqual(result.frames.count, 2)
        XCTAssertEqual(result.invalidFiles.map { $0.lastPathComponent }, ["frame-bad.json"])
        XCTAssertEqual(store.frames(in: session.directory).map { $0.sequence }, [1, 2])

        let report = try store.writeReport()
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.csv.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.json.path))
        // report.json 不会被当成 sidecar
        XCTAssertEqual(store.frames(in: session.directory).count, 2)
        let csvText = String(decoding: try Data(contentsOf: report.csv), as: UTF8.self)
        XCTAssertEqual(csvText.split(separator: "\n", omittingEmptySubsequences: false).count, 4)
    }

    func testWritesWithoutActiveSessionThrow() throws {
        let store = SessionStore(root: makeTempDir("nosession"))
        XCTAssertNil(store.currentSession)
        let sidecar = makeSidecar(sequence: 1)
        XCTAssertThrowsError(try store.writeTIFFFrame(gradientImage(width: 4, height: 4),
                                                      sidecar: sidecar))
        XCTAssertThrowsError(try store.writeSidecar(sidecar))
        XCTAssertThrowsError(try store.exportStack(gradientImage(width: 4, height: 4)))
        XCTAssertThrowsError(try store.writeReport())

        // 跨会话的 sidecar 被拒绝
        _ = try store.beginSession()
        XCTAssertThrowsError(try store.writeSidecar(sidecar)) { error in
            XCTAssertEqual(error as? SessionStoreError, .sessionMismatch)
        }
    }

    // MARK: - Reports

    func testImageLoaderKeeps16BitPrecision() throws {
        // A 16-bit file must not be quantized to 8 bits by the RAW/CI decode
        // path: values that are not multiples of 256 would otherwise collapse.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroFieldPrecision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let levels: [Float] = [1_000, 2_000, 4_000, 16_000, 32_000]
        var pixels = [Float](repeating: 0, count: 64 * 40)
        for y in 0..<40 {
            for x in 0..<levels.count {
                pixels[y * 64 + x] = levels[x]
            }
        }
        let image = LumaImage(width: 64, height: 40, pixels: pixels)
        let url = dir.appendingPathComponent("levels.tif")
        try TIFFWriter.write(image, to: url)
        guard let decoded = ImageLoader.luma(url: url, maxWidth: nil) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.width, 64)
        for (index, value) in levels.enumerated() {
            let decodedValue = decoded.pixels[20 * 64 + index]
            XCTAssertEqual(decodedValue, value, accuracy: 2,
                           "16-bit level \(value) lost precision")
        }
    }

    func testCSVHeaderAndRowCount() {
        let metrics = MetricsSnapshot(starCount: 10, background: 800, noise: 20,
                                      medianFWHM: 2.5, medianEccentricity: 0.1,
                                      saturatedFraction: 0.001)
        let frames = (1...3).map { makeSidecar(sequence: $0, metrics: metrics) }
        let csv = SessionReport.csv(frames: frames)

        XCTAssertTrue(csv.hasPrefix(SessionReport.csvHeader + "\n"))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 5) // 表头 + 3 行 + 结尾空串
        XCTAssertEqual(String(lines[0]), SessionReport.csvHeader)
        XCTAssertTrue(String(lines[1]).hasPrefix("1,"))
        XCTAssertTrue(String(lines[3]).hasPrefix("3,"))
        XCTAssertEqual(lines[1].split(separator: ",", omittingEmptySubsequences: false).count, 20)
    }

    func testCSVEscapesCommasQuotesAndNewlines() {
        var frame = makeSidecar(sequence: 7)
        frame.note = "a,b \"quoted\"\nsecond line"
        frame.qualityGroup = "组,一"
        let csv = SessionReport.csv(frames: [frame])
        XCTAssertTrue(csv.contains("\"a,b \"\"quoted\"\"\nsecond line\""))
        XCTAssertTrue(csv.contains("\"组,一\""))
        XCTAssertFalse(csv.contains("group-1"))
    }

    func testReportJSONContainsSummaryAndFrames() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let session = SessionInfo(
            id: sessionID,
            name: "2026-11-12_213045",
            directory: URL(fileURLWithPath: "/tmp/AstroField/2026-11-12_213045"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let frames = [
            makeSidecar(sessionID: sessionID, sequence: 1,
                        verdict: VerdictSnapshot(.accepted)),
            makeSidecar(sessionID: sessionID, sequence: 2,
                        verdict: VerdictSnapshot(.warning("FWHM +30%"))),
            makeSidecar(sessionID: sessionID, sequence: 3,
                        verdict: VerdictSnapshot(.rejected("星点不足"))),
            makeSidecar(sessionID: sessionID, sequence: 4,
                        verdict: VerdictSnapshot(.unmeasured("尚未分析"))),
            makeSidecar(sessionID: sessionID, sequence: 5, verdict: nil)
        ]
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let data = try SessionReport.json(session: session, frames: frames,
                                          generatedAt: generatedAt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["generatedAt"] as? String, "2023-11-14T22:15:00Z")
        let sessionObject = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(sessionObject["name"] as? String, "2026-11-12_213045")
        XCTAssertEqual(sessionObject["startedAt"] as? String, "2023-11-14T22:13:20Z")

        let summary = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertEqual(summary["frames"] as? Int, 5)
        XCTAssertEqual(summary["accepted"] as? Int, 1)
        XCTAssertEqual(summary["warning"] as? Int, 1)
        XCTAssertEqual(summary["rejected"] as? Int, 1)
        XCTAssertEqual(summary["unmeasured"] as? Int, 2)

        let jsonFrames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        XCTAssertEqual(jsonFrames.count, 5)
        XCTAssertEqual(jsonFrames[0]["frameID"] as? String, frames[0].frameID.uuidString)
        let verdictObject = try XCTUnwrap(jsonFrames[1]["verdict"] as? [String: Any])
        XCTAssertEqual(verdictObject["code"] as? String, "warning")
        XCTAssertEqual(verdictObject["text"] as? String, "FWHM +30%")

        XCTAssertEqual(SessionReport.summary(frames: frames),
                       SessionSummary(frames: 5, accepted: 1, warning: 1,
                                      rejected: 1, unmeasured: 2))
    }

    // MARK: - Stack export

    func testExportStackWritesTIFFAndPNG() throws {
        let store = SessionStore(root: makeTempDir("stack"))
        let session = try store.beginSession()
        let image = gradientImage(width: 40, height: 30)
        let urls = try store.exportStack(image, name: "stack-group1")

        XCTAssertEqual(urls.tiff.lastPathComponent, "stack-group1.tif")
        XCTAssertEqual(urls.png.lastPathComponent, "stack-group1.png")
        XCTAssertTrue(urls.tiff.path.hasPrefix(session.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.tiff.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.png.path))

        guard let source = CGImageSourceCreateWithURL(urls.tiff as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return XCTFail("导出的 TIFF 无法读取")
        }
        XCTAssertEqual(cgImage.width, 40)
        XCTAssertEqual(cgImage.height, 30)
        XCTAssertEqual(cgImage.bitsPerComponent, 16)
    }
}
