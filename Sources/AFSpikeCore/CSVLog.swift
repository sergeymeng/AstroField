import Foundation

public final class CSVLog {
    private let url: URL
    private var handle: FileHandle?
    private let iso = ISO8601DateFormatter()

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let header = "timestamp,backend,command,duration_ms,result,detail\n"
        handle?.write(header.data(using: .utf8)!)
    }

    public func write(_ record: LogRecord) {
        let line = [
            iso.string(from: record.timestamp),
            escape(record.backend),
            escape(record.command),
            String(format: "%.1f", record.durationMS),
            escape(record.result),
            escape(record.detail)
        ].joined(separator: ",") + "\n"
        handle?.write(line.data(using: .utf8)!)
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
