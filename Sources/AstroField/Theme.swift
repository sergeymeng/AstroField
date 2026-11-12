import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

struct Palette: Equatable {
    var background: Color
    var panel: Color
    var panelRaised: Color
    var divider: Color
    var text: Color
    var textSecondary: Color
    var textDim: Color
    var red: Color
    var amber: Color
    var selected: Color
    var monitorBackground: Color

    var panelGradient: LinearGradient {
        LinearGradient(colors: [panelRaised.opacity(0.55), panel],
                       startPoint: .top, endPoint: .bottom)
    }

    var monitorGradient: LinearGradient {
        LinearGradient(colors: [monitorBackground, background],
                       startPoint: .top, endPoint: .bottom)
    }

    static let dark = Palette(
        background: Color(hex: 0x060708),
        panel: Color(hex: 0x0C0E10),
        panelRaised: Color(hex: 0x14171A),
        divider: Color(hex: 0x1F2327),
        text: Color(hex: 0xEDF1F3),
        textSecondary: Color(hex: 0x97A0A8),
        textDim: Color(hex: 0x59626A),
        red: Color(hex: 0xF03A3E),
        amber: Color(hex: 0xE3A33B),
        selected: Color(hex: 0xFFFFFF),
        monitorBackground: Color(hex: 0x000000)
    )

    static let night = Palette(
        background: Color(hex: 0x030405),
        panel: Color(hex: 0x080A0B),
        panelRaised: Color(hex: 0x0F1113),
        divider: Color(hex: 0x181B1E),
        text: Color(hex: 0xB9C0C6),
        textSecondary: Color(hex: 0x757E86),
        textDim: Color(hex: 0x454D54),
        red: Color(hex: 0xB62D31),
        amber: Color(hex: 0xA8762A),
        selected: Color(hex: 0xD8DDE1),
        monitorBackground: Color(hex: 0x000000)
    )
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

enum CinemaFont {
    /// Small uppercase technical label.
    static func micro(_ size: CGFloat = 9) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium)
    }

    static func tiny(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular)
    }

    static func value(_ size: CGFloat = 24) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func smallValue(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func title(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .semibold)
    }
}

extension View {
    func technicalLabel(_ color: Color, size: CGFloat = 9, tracking: CGFloat = 1.4) -> some View {
        self.font(CinemaFont.micro(size))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}
