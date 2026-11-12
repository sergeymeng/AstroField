import Foundation

public enum ShootGroupKind: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case sky
    case foreground

    public var displayName: String {
        switch self {
        case .sky: return "天空"
        case .foreground: return "地景"
        }
    }
}

/// One group in a multi-group night session. Each group carries its own plan and an
/// optional relative focus move applied before the group starts.
public struct ShootGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ShootGroupKind
    public var plan: CapturePlan
    public var enabled: Bool
    /// Signed relative MFDrive steps. Positive uses direction one, negative direction two.
    /// The physical direction depends on the lens; no absolute position is assumed.
    public var focusOffsetSteps: Int

    public init(id: UUID = UUID(), name: String, kind: ShootGroupKind,
                plan: CapturePlan, enabled: Bool = true,
                focusOffsetSteps: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.plan = plan
        self.enabled = enabled
        self.focusOffsetSteps = focusOffsetSteps
    }

    public static func defaults() -> [ShootGroup] {
        var sky = CapturePlan()
        sky.start = .immediate
        sky.exposureSeconds = 10
        sky.interval = .afterExposure(seconds: 2)
        sky.end = .count(20)
        sky.iso = 1600
        sky.aperture = 2.8
        sky.compression = .raw

        var foreground = CapturePlan()
        foreground.start = .immediate
        foreground.exposureSeconds = 30
        foreground.interval = .afterExposure(seconds: 0)
        foreground.end = .count(1)
        foreground.iso = 800
        foreground.aperture = 4.0
        foreground.compression = .raw

        return [
            ShootGroup(name: "天空", kind: .sky, plan: sky),
            ShootGroup(name: "地景", kind: .foreground, plan: foreground,
                       focusOffsetSteps: 0)
        ]
    }
}
