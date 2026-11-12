import Foundation

public struct CapturePreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var plan: CapturePlan
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, plan: CapturePlan,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.plan = plan
        self.createdAt = createdAt
    }
}

/// JSON-backed preset and last-plan storage.
public final class PresetStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    private struct StoreFile: Codable {
        var presets: [CapturePreset] = []
        var lastPlan: CapturePlan?
        var groups: [ShootGroup]?
    }

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AstroField", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("presets.json")
    }

    public var location: URL { fileURL }

    public func load() -> [CapturePreset] {
        read().presets
    }

    public func lastPlan() -> CapturePlan? {
        read().lastPlan
    }

    public func saveLastPlan(_ plan: CapturePlan) {
        var file = read()
        file.lastPlan = plan
        write(file)
    }

    public func loadGroups() -> [ShootGroup] {
        read().groups ?? []
    }

    public func saveGroups(_ groups: [ShootGroup]) {
        var file = read()
        file.groups = groups
        write(file)
    }

    @discardableResult
    public func upsert(name: String, plan: CapturePlan, id: UUID = UUID()) -> [CapturePreset] {
        var file = read()
        if let index = file.presets.firstIndex(where: { $0.id == id }) {
            file.presets[index].name = name
            file.presets[index].plan = plan
        } else {
            file.presets.append(CapturePreset(id: id, name: name, plan: plan))
        }
        file.presets.sort { $0.createdAt > $1.createdAt }
        write(file)
        return file.presets
    }

    @discardableResult
    public func delete(id: UUID) -> [CapturePreset] {
        var file = read()
        file.presets.removeAll { $0.id == id }
        write(file)
        return file.presets
    }

    // MARK: - IO

    private func read() -> StoreFile {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return StoreFile() }
        return (try? JSONDecoder().decode(StoreFile.self, from: data)) ?? StoreFile()
    }

    private func write(_ file: StoreFile) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
