import SwiftUI
import AstroFieldKit

struct MonitorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                palette.monitorBackground

                if model.monitorMode == .compare {
                    compareContent(size: geo.size)
                } else {
                    imageContent(size: geo.size)
                }

                if model.monitorMode != .compare, model.monitorImage != nil {
                    frameOverlay(size: geo.size)
                }

                if model.showGrid {
                    gridOverlay(size: geo.size)
                }
                if model.showStarMarkers, model.monitorMode != .live, model.monitorMode != .compare {
                    starOverlay(size: geo.size)
                }

                if model.status.state.isConnected || model.isConnecting {
                    overlayChrome(size: geo.size)
                }

                if !model.status.state.isConnected {
                    disconnectedOverlay(size: geo.size)
                }
            }
            .clipped()
        }
        .background(palette.monitorBackground)
    }

    // MARK: - Content

    @ViewBuilder
    private func imageContent(size: CGSize) -> some View {
        if let image = model.monitorImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func compareContent(size: CGSize) -> some View {
        let pair = Array(model.records.suffix(2))
        if pair.count == 2 {
            HStack(spacing: 1) {
                compareCell(pair[0], label: "较早")
                compareCell(pair[1], label: "较新")
            }
            .frame(width: size.width, height: size.height)
        } else if pair.last != nil {
            imageContent(size: size)
                .overlay(alignment: .top) {
                    Text("需要两张照片")
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.amber)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(.top, 44)
                }
                .opacity(0.9)
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private func compareCell(_ record: ImageRecord, label: String) -> some View {
        ZStack {
            palette.monitorBackground
            if let image = record.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("无预览")
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            }
            VStack {
                HStack(spacing: 7) {
                    Text(label.uppercased())
                        .font(CinemaFont.micro(8))
                        .tracking(1.4)
                        .foregroundStyle(palette.textSecondary)
                    Text(record.displayName)
                        .font(CinemaFont.tiny(9))
                        .foregroundStyle(palette.textDim)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 46)
                Spacer()
            }
        }
    }

    private var emptyState: some View {
        Group {
            if model.status.state.isConnected {
                VStack(spacing: 10) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 30, weight: .thin))
                        .foregroundStyle(palette.textDim)
                    Text(model.isConnecting ? "正在连接…" : "等待画面")
                        .font(CinemaFont.label(12))
                        .foregroundStyle(palette.textSecondary)
                }
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func overlayChrome(size: CGSize) -> some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.72), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 78)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, Color.black.opacity(0.76)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 88)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    topLeftInfo
                    Spacer(minLength: 8)
                    exposureStats
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.monitorMode != .stack, let record = model.selectedRecord {
                            Text(qualityLabel(record))
                        }
                    }
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)

                    Spacer(minLength: 12)

                    if showsCountdown {
                        countdownBlock
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            if model.progress.phase == .exposing {
                VStack {
                    Spacer()
                    Rectangle().fill(palette.red).frame(height: 1.6)
                }
                VStack {
                    HStack(spacing: 5) {
                        Circle().fill(palette.red).frame(width: 5, height: 5)
                        Text("REC")
                            .font(CinemaFont.micro(8.5))
                            .tracking(1.8)
                            .foregroundStyle(palette.red)
                    }
                    .padding(.top, 10)
                    Spacer()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(model.monitorMode != .compare)
    }

    private var topLeftInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if model.monitorMode == .live, model.liveImage != nil {
                    let liveColor = model.liveFrozen ? palette.amber : palette.red
                    Circle().fill(liveColor).frame(width: 5, height: 5)
                    Text(model.liveFrozen ? "LIVE HOLD" : "LIVE")
                        .font(CinemaFont.micro(8.5))
                        .tracking(1.6)
                        .foregroundStyle(liveColor)
                } else if model.monitorMode == .stack {
                    Text("STACK")
                        .font(CinemaFont.micro(8.5))
                        .tracking(1.6)
                        .foregroundStyle(palette.textSecondary)
                } else {
                    Text("VIEW")
                        .font(CinemaFont.micro(8.5))
                        .tracking(1.6)
                        .foregroundStyle(palette.textSecondary)
                }
                Text(sourceCode)
                    .font(CinemaFont.micro(8.5))
                    .tracking(1.4)
                    .foregroundStyle(model.sourceKind == .simulator ? palette.amber : palette.textDim)
            }

            Text(secondaryLine)
                .font(CinemaFont.tiny(9))
                .foregroundStyle(palette.textDim)
                .lineLimit(1)
                .truncationMode(.middle)

            if model.monitorMode == .live, model.liveSequence > 0 {
                Text(String(format: "F %06llu", model.liveSequence))
                    .font(CinemaFont.micro(8))
                    .tracking(0.8)
                    .foregroundStyle(palette.textDim)
                    .monospacedDigit()
            }
        }
    }

    private var sourceCode: String {
        switch model.sourceKind {
        case .simulator: return "SIM"
        case .playback: return "PLAY"
        case .nikon: return "NIKON"
        }
    }

    private var secondaryLine: String {
        let sizeText: String
        if let image = model.monitorImage {
            sizeText = "\(image.width)×\(image.height)"
        } else {
            sizeText = "—"
        }
        switch model.monitorMode {
        case .live:
            return sizeText
        case .stack:
            return stackStatsText
        case .compare:
            return "两张对比"
        case .last:
            if let record = model.selectedRecord {
                let crop = model.analysisCrop == .full ? "" : "  \(model.analysisCrop.displayName)"
                return "\(record.displayName)   \(sizeText)\(crop)"
            }
            return "无照片"
        }
    }

    private var exposureStats: some View {
        let settings = model.monitorMode == .last
            ? (model.selectedRecord?.settings ?? model.plan.settings)
            : model.plan.settings
        return HStack(spacing: 0) {
            statColumn("ISO", "\(settings.iso)")
            statSeparator
            statColumn("SHUTTER", CapturePlan.formatDuration(settings.exposureSeconds))
            statSeparator
            statColumn("IRIS", settings.aperture.map { String(format: "f/%.1f", $0) } ?? "—")
            if model.monitorMode != .live, let record = model.selectedRecord {
                statSeparator
                statColumn("FRAME", String(format: "%04d", record.sequence))
            }
        }
    }

    private func statColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(CinemaFont.micro(7.5))
                .tracking(1.5)
                .foregroundStyle(palette.textDim)
            Text(value)
                .font(CinemaFont.smallValue(13))
                .foregroundStyle(palette.text)
                .monospacedDigit()
        }
        .frame(minWidth: 48, alignment: .trailing)
    }

    private var statSeparator: some View {
        Rectangle().fill(Color.white.opacity(0.14))
            .frame(width: 0.6, height: 24)
            .padding(.horizontal, 9)
    }

    private var showsCountdown: Bool {
        switch model.progress.phase {
        case .exposing, .waitingToStart, .waitingInterval, .paused, .stopping:
            return true
        default:
            return false
        }
    }

    private var countdownBlock: some View {
        let info = countdownInfo
        return VStack(alignment: .trailing, spacing: 0) {
            Text(info.label)
                .font(CinemaFont.micro(8))
                .tracking(1.6)
                .foregroundStyle(info.color)
            Text(info.value)
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.text)
                .monospacedDigit()
        }
    }

    private var countdownInfo: (label: String, value: String, color: Color) {
        if model.progress.phase == .exposing, let end = model.progress.exposureEnd {
            if end > model.now {
                return ("EXPOSURE", model.formatCountdown(end.timeIntervalSince(model.now)), palette.red)
            }
            return ("PROCESSING", "…", palette.amber)
        }
        if model.progress.phase == .paused {
            return ("PAUSED", "—", palette.amber)
        }
        if model.progress.phase == .stopping {
            return ("STOPPING", "…", palette.amber)
        }
        if let next = model.progress.nextStart {
            return ("NEXT", model.formatCountdown(next.timeIntervalSince(model.now)), palette.amber)
        }
        return ("WAIT", "—", palette.amber)
    }

    private var stackStatsText: String {
        if model.stack.mode == .trails {
            var parts = ["帧数 \(model.stack.accepted)",
                         "累计 \(CapturePlan.formatDuration(model.stack.totalExposure))"]
            if model.stack.gapCount > 0 {
                parts.append("间断 \(model.stack.gapCount)")
            }
            return parts.joined(separator: "   ")
        }
        var parts = ["参与 \(model.stack.accepted)", "拒绝 \(model.stack.rejected)",
                     String(format: "覆盖 %.0f%%", model.stack.coverage * 100)]
        if model.stack.shiftText != "—" {
            parts.append("位移 \(model.stack.shiftText)")
        }
        return parts.joined(separator: "   ")
    }

    private func qualityLabel(_ record: ImageRecord) -> String {
        if let verdict = record.verdict {
            switch verdict {
            case .accepted: return "正常"
            case .warning(let text): return text
            case .rejected(let text): return text
            case .unmeasured(let text): return text
            }
        }
        if let metrics = record.metrics {
            return String(format: "FWHM %.2f   %d 星", metrics.medianFWHM, metrics.starCount)
        }
        return "分析中…"
    }

    private func frameOverlay(size: CGSize) -> some View {
        let rect = imageRect(in: size)
        let length: CGFloat = 16
        return ZStack {
            Rectangle()
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.6)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            Path { path in
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
                    (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                    (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
                    (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
                ]
                for (corner, dx, dy) in corners {
                    path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
                }
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Grid / stars

    private func imageRect(in size: CGSize) -> CGRect {
        guard let image = model.monitorImage, image.width > 0, image.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func gridOverlay(size: CGSize) -> some View {
        let rect = imageRect(in: size)
        return Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(palette.text.opacity(0.18), lineWidth: 0.6)
        .allowsHitTesting(false)
    }

    private func starOverlay(size: CGSize) -> some View {
        let rect = imageRect(in: size)
        return Canvas { context, _ in
            for star in model.analysisStars.prefix(60) {
                let x = rect.minX + CGFloat(star.x) * rect.width
                let y = rect.minY + CGFloat(star.y) * rect.height
                let radius: CGFloat = star.saturated ? 6 : 4
                let circle = Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                    width: radius * 2, height: radius * 2))
                context.stroke(circle,
                               with: .color(star.saturated ? palette.red.opacity(0.8)
                                                           : palette.amber.opacity(0.75)),
                               lineWidth: 0.8)
            }
        }
        .allowsHitTesting(false)
    }

    private func disconnectedOverlay(size: CGSize) -> some View {
        ZStack {
            palette.monitorBackground.opacity(0.94)
            VStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 28, weight: .thin))
                    .foregroundStyle(palette.textDim)
                Text(model.isConnecting ? "正在连接…" : "未连接")
                    .font(CinemaFont.title(14))
                    .foregroundStyle(palette.text)
                Text(model.status.notes.first ?? "选择来源")
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(palette.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 8) {
                    Button("模拟相机") { Task { await model.connect(.simulator) } }
                        .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                    Button("Nikon USB") { Task { await model.connect(.nikon) } }
                        .buttonStyle(CinemaButtonStyle(compact: true))
                    Button("照片回放…") { model.choosePlaybackDirectory() }
                        .buttonStyle(CinemaButtonStyle(compact: true))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
