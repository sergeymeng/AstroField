import XCTest
@testable import AFSpikeCore

final class StarAnalyzerTests: XCTestCase {
    func testMedianAndMAD() {
        let values: [Float] = [1, 2, 3, 4, 100]
        XCTAssertEqual(StarAnalyzer.median(values), 3, accuracy: 0.001)
        let m = StarAnalyzer.median(values)
        let mad = StarAnalyzer.mad(values, median: m)
        XCTAssertEqual(mad, 1, accuracy: 0.001)
    }

    func testSyntheticFieldRecovery() {
        let field = SyntheticFieldGenerator.make(width: 512, height: 512, starCount: 24,
                                                 sigma: 2.0, background: 1000, noise: 20,
                                                 seed: 7)
        let m = StarAnalyzer.analyze(pixels: field.pixels,
                                     width: field.width,
                                     height: field.height)
        let expected = 2.3548 * 2.0
        XCTAssertGreaterThanOrEqual(m.starCount, 20)
        XCTAssertEqual(m.medianFWHM, expected, accuracy: expected * 0.15)
        XCTAssertEqual(m.background, 1000, accuracy: 15)
        XCTAssertGreaterThan(m.medianEccentricity, 0)
        XCTAssertLessThan(m.medianEccentricity, 0.3)
    }

    func testCSVHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("afspike-test-\(UUID().uuidString).csv")
        let log = try CSVLog(url: url)
        log.write(LogRecord(backend: "test", command: "unit",
                            durationMS: 1.5, result: "ok", detail: "hello, world"))
        log.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("timestamp,backend,command"))
        XCTAssertTrue(text.contains("\"hello, world\""))
        try? FileManager.default.removeItem(at: url)
    }
}

final class CaptureWatcherTests: XCTestCase {
    func testNewFileDetection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("afspike-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("a".utf8).write(to: dir.appendingPathComponent("DSC_0001.NEF"))
        let before = CaptureWatcher.snapshot(dir)
        XCTAssertEqual(before.count, 1)
        XCTAssertNil(CaptureWatcher.newestNewFile(in: dir, excluding: before))

        try Data("b".utf8).write(to: dir.appendingPathComponent("DSC_0002.NEF"))
        let found = CaptureWatcher.newestNewFile(in: dir, excluding: before)
        XCTAssertEqual(found?.lastPathComponent, "DSC_0002.NEF")
    }
}
