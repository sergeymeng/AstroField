import Foundation

public struct TrialRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var exposureSeconds: Double
    public var aperture: Double?
    public var medianFWHM: Double?
    public var starCount: Int?
    public var saturatedFraction: Double?
    public var eccentricity: Double?

    public init(id: UUID = UUID(), label: String, exposureSeconds: Double,
                aperture: Double?, medianFWHM: Double?, starCount: Int?,
                saturatedFraction: Double?, eccentricity: Double?) {
        self.id = id
        self.label = label
        self.exposureSeconds = exposureSeconds
        self.aperture = aperture
        self.medianFWHM = medianFWHM
        self.starCount = starCount
        self.saturatedFraction = saturatedFraction
        self.eccentricity = eccentricity
    }
}

public struct LensProfileEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var lensName: String
    public var cameraModel: String
    public var iso: Int
    public var note: String
    public var trials: [TrialRecord]

    public init(id: UUID = UUID(), createdAt: Date, lensName: String,
                cameraModel: String, iso: Int, note: String, trials: [TrialRecord]) {
        self.id = id
        self.createdAt = createdAt
        self.lensName = lensName
        self.cameraModel = cameraModel
        self.iso = iso
        self.note = note
        self.trials = trials
    }
}

/// Local lens profile library. Stores what was measured and under which settings;
/// it deliberately does not treat past focus positions as valid next time.
public final class LensProfileStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AstroField", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("lens-profiles.json")
    }

    public var location: URL { fileURL }

    public func load() -> [LensProfileEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([LensProfileEntry].self, from: data)) ?? []
    }

    @discardableResult
    public func add(lensName: String, cameraModel: String, iso: Int,
                    note: String, trials: [TrialRecord]) -> [LensProfileEntry] {
        var entries = load()
        entries.append(LensProfileEntry(id: UUID(), createdAt: Date(),
                                        lensName: lensName, cameraModel: cameraModel,
                                        iso: iso, note: note, trials: trials))
        lock.lock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
        lock.unlock()
        return entries
    }
}
