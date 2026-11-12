import Foundation

public enum CaptureWatcher {
    public static let rawExtensions: Set<String> = ["nef", "nrw", "jpg", "jpeg", "tif", "tiff", "heif", "heic"]

    public static func snapshot(_ directory: URL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(items.filter { isCapture($0) })
    }

    public static func newestNewFile(in directory: URL, excluding: Set<String>) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { isCapture($0.lastPathComponent) && !excluding.contains($0.lastPathComponent) }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .first
    }

    public static func waitForNewFile(in directory: URL, excluding: Set<String>,
                                      timeout: TimeInterval) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let f = newestNewFile(in: directory, excluding: excluding) { return f }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    public static func isCapture(_ name: String) -> Bool {
        rawExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}
