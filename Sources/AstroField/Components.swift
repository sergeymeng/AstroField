import SwiftUI
import AstroFieldKit

struct CinemaButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var danger = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10 : 11, weight: .medium))
            .foregroundStyle(prominent ? palette.background
                                       : (danger ? palette.red : palette.textSecondary))
            .padding(.horizontal, compact ? 9 : 14)
            .frame(height: compact ? 24 : 30)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(prominent ? palette.selected
                                    : (danger ? palette.red.opacity(0.07)
                                              : Color.white.opacity(0.035)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(danger ? palette.red.opacity(0.28)
                                         : (prominent ? Color.clear : palette.divider),
                                  lineWidth: 0.6)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.3)
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 5

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct StatusChip: View {
    @Environment(\.palette) private var palette
    var text: String
    var color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(CinemaFont.micro(8.5))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(filled ? 0.18 : 0.07))
            )
    }
}

struct InfoRow: View {
    @Environment(\.palette) private var palette
    var label: String
    var value: String
    var color: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(CinemaFont.tiny(10))
                .foregroundStyle(palette.textDim)
            Spacer(minLength: 8)
            Text(value)
                .font(CinemaFont.smallValue(11.5))
                .foregroundStyle(color ?? palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 19)
    }
}

struct PanelSection<Content: View>: View {
    @Environment(\.palette) private var palette
    var title: String
    var subtitle: String?
    var help: String?
    @State private var expanded: Bool
    @State private var showHelp = false
    private let content: () -> Content

    init(title: String,
         subtitle: String? = nil,
         help: String? = nil,
         expandedByDefault: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self._expanded = State(initialValue: expandedByDefault)
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Text(title.uppercased())
                            .font(CinemaFont.micro(9.5))
                            .tracking(1.6)
                            .foregroundStyle(palette.textSecondary)
                        if let subtitle {
                            Text(subtitle)
                                .font(CinemaFont.tiny(9.5))
                                .foregroundStyle(palette.textDim)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(palette.textDim)
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    .padding(.leading, 12)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let help {
                    Button {
                        showHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 9.5))
                            .foregroundStyle(palette.textDim.opacity(0.8))
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("说明")
                    .popover(isPresented: $showHelp, arrowEdge: .trailing) {
                        Text(help)
                            .font(CinemaFont.label(11))
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(width: 280)
                            .background(palette.panel)
                    }
                } else {
                    Spacer().frame(width: 10)
                }
            }
            .padding(.trailing, 4)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
            Rectangle().fill(palette.divider).frame(height: 0.6)
        }
    }
}

struct ParameterCell: View {
    @Environment(\.palette) private var palette
    var label: String
    var value: String
    var unit: String?
    var detail: String?
    var action: () -> Void

    init(label: String, value: String, unit: String? = nil,
         detail: String? = nil, action: @escaping () -> Void) {
        self.label = label
        self.value = value
        self.unit = unit
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(CinemaFont.micro(8.5))
                    .tracking(1.5)
                    .foregroundStyle(palette.textDim)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(CinemaFont.value(22))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let unit {
                        Text(unit)
                            .font(CinemaFont.micro(8.5))
                            .foregroundStyle(palette.textDim)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(CinemaFont.tiny(8.5))
                        .foregroundStyle(palette.textDim)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 70, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.divider)
                .frame(width: 0.6)
                .padding(.vertical, 10)
        }
    }
}

struct FocusCurveView: View {
    @Environment(\.palette) private var palette
    var samples: [FocusSample]
    var bestSteps: Int?

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let xs = samples.map { Double($0.relativeSteps) }
            let ys = samples.map { $0.measurement.medianFWHM }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(),
                  maxX > minX, maxY > minY else { return }
            let pad: CGFloat = 6
            let w = size.width - pad * 2
            let h = size.height - pad * 2

            var baseline = Path()
            baseline.move(to: CGPoint(x: pad, y: size.height - pad))
            baseline.addLine(to: CGPoint(x: size.width - pad, y: size.height - pad))
            context.stroke(baseline, with: .color(palette.divider), lineWidth: 0.6)

            for sample in samples {
                let x = pad + (Double(sample.relativeSteps) - minX) / (maxX - minX) * w
                let y = pad + (1 - (sample.measurement.medianFWHM - minY) / (maxY - minY)) * h
                let isBest = bestSteps != nil && sample.relativeSteps == bestSteps
                let radius: CGFloat = isBest ? 2.6 : 1.7
                let rect = CGRect(x: x - radius, y: y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .color(isBest ? palette.amber : palette.textSecondary.opacity(0.8)))
            }
        }
        .frame(height: samples.count > 1 ? 92 : 44)
        .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(palette.divider, lineWidth: 0.6)
        )
    }
}

struct QualityTimelineView: View {
    @Environment(\.palette) private var palette
    var points: [QualityPoint]

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            let fwhms = points.map { $0.fwhm }
            guard let minY = fwhms.min(), let maxY = fwhms.max(), maxY > minY else { return }
            let w = size.width
            let h = size.height
            for (index, point) in points.enumerated() {
                let x = w * CGFloat(index) / CGFloat(max(1, points.count - 1))
                let y = h - CGFloat((point.fwhm - minY) / (maxY - minY)) * h
                let color: Color
                switch point.verdict {
                case .accepted: color = palette.textSecondary.opacity(0.7)
                case .warning: color = palette.amber
                case .rejected, .unmeasured: color = palette.red
                }
                let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }
}

struct HistogramView: View {
    @Environment(\.palette) private var palette
    var bins: [Double]

    var body: some View {
        Canvas { context, size in
            guard !bins.isEmpty else { return }
            let barWidth = size.width / CGFloat(bins.count)
            for (index, value) in bins.enumerated() {
                let height = CGFloat(pow(max(0, min(1, value)), 0.35)) * size.height
                let rect = CGRect(x: CGFloat(index) * barWidth,
                                  y: size.height - height,
                                  width: max(1, barWidth - 0.5),
                                  height: height)
                context.fill(Path(rect), with: .color(palette.textSecondary.opacity(0.45)))
            }
        }
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
    }
}

struct QualityDot: View {
    @Environment(\.palette) private var palette
    var verdict: QualityVerdict?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 4, height: 4)
    }

    private var color: Color {
        guard let verdict else { return palette.textDim }
        switch verdict {
        case .accepted: return palette.selected.opacity(0.8)
        case .warning: return palette.amber
        case .rejected, .unmeasured: return palette.red
        }
    }
}

struct DividerLine: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Rectangle().fill(palette.divider).frame(height: 0.6)
    }
}
