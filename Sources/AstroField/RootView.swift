import SwiftUI
import AstroFieldKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            StatusBarView()
            DividerLine()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MonitorView()
                    DividerLine()
                    ParameterBarView()
                    DividerLine()
                    FilmstripView()
                }
                if model.rightPanelVisible {
                    Rectangle().fill(palette.divider).frame(width: 0.6)
                    RightPanelView().frame(width: 320)
                }
            }
            DividerLine()
            BottomBarView()
        }
        .background(palette.background)
        .foregroundStyle(palette.text)
        .overlay(alignment: .top) { toastOverlay }
        .animation(.easeInOut(duration: 0.15), value: model.toast)
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            let color = toastColor(toast.kind)
            HStack(spacing: 8) {
                Rectangle().fill(color).frame(width: 2, height: 16)
                Text(toast.text)
                    .font(CinemaFont.label(11))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.panelRaised)
            .overlay(alignment: .bottom) {
                Rectangle().fill(color.opacity(0.4)).frame(height: 0.6)
            }
            .padding(.top, 52)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func toastColor(_ kind: ToastState.Kind) -> Color {
        switch kind {
        case .info: return palette.textSecondary
        case .success: return palette.selected
        case .warning: return palette.amber
        case .error: return palette.red
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("ASTROFIELD")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(palette.text)
                Text("0.1")
                    .font(CinemaFont.micro(8))
                    .tracking(1)
                    .foregroundStyle(palette.textDim)
            }
            .padding(.leading, 16)

            Rectangle().fill(palette.divider).frame(width: 0.6, height: 16)
                .padding(.horizontal, 14)

            sourceMenu

            Rectangle().fill(palette.divider).frame(width: 0.6, height: 16)
                .padding(.horizontal, 12)

            HStack(spacing: 6) {
                StatusDot(color: model.connectionColor, size: 5)
                Text(model.status.state.displayText)
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(model.connectionColor)
                    .lineLimit(1)
                if model.isConnecting {
                    ProgressView().controlSize(.mini).scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                }
            }

            Spacer(minLength: 8)

            if !capabilityText.isEmpty {
                Text(capabilityText)
                    .font(CinemaFont.micro(8.5))
                    .tracking(1.2)
                    .foregroundStyle(palette.textDim)
                    .padding(.trailing, 14)
            }

            if let battery = model.status.batteryPercent {
                HStack(spacing: 4) {
                    Image(systemName: batteryIcon(battery))
                        .font(.system(size: 9))
                    Text("\(battery)%")
                        .font(CinemaFont.micro(9))
                        .monospacedDigit()
                }
                .foregroundStyle(battery < 20 ? palette.amber : palette.textDim)
                .padding(.trailing, 14)
            }

            HStack(spacing: 5) {
                StatusDot(color: phaseInfo(model.progress.phase).1, size: 5)
                Text(phaseInfo(model.progress.phase).0)
                    .font(CinemaFont.micro(9))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSecondary)
            }
            .padding(.trailing, 12)

            toolbar
                .padding(.trailing, 12)
        }
        .frame(height: 42)
        .background(palette.panelGradient)
    }

    private var capabilityText: String {
        guard model.status.state.isConnected else { return "" }
        var parts: [String] = []
        if model.status.capabilities.contains(.liveView) { parts.append("LV") }
        if model.status.capabilities.contains(.rawOutput) { parts.append("RAW") }
        if model.status.capabilities.contains(.manualFocusDrive) { parts.append("MF") }
        return parts.joined(separator: "   ")
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                Task { await model.connect(.simulator) }
            } label: {
                Label("模拟相机", systemImage: "sparkles")
            }
            Button {
                Task { await model.connect(.nikon) }
            } label: {
                Label("Nikon USB", systemImage: "camera")
            }
            Button {
                model.choosePlaybackDirectory()
            } label: {
                Label("照片回放…", systemImage: "folder")
            }
            Divider()
            Button("断开") { model.disconnect() }
        } label: {
            HStack(spacing: 7) {
                Text(model.sourceLabel.uppercased())
                    .font(CinemaFont.micro(9))
                    .tracking(1.4)
                    .foregroundStyle(palette.textSecondary)
                Text(model.status.model)
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(palette.textDim)
            }
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func batteryIcon(_ percent: Int) -> String {
        if percent > 75 { return "battery.100" }
        if percent > 50 { return "battery.75" }
        if percent > 25 { return "battery.50" }
        return "battery.25"
    }

    private func phaseInfo(_ phase: SequenceProgress.Phase) -> (String, Color) {
        switch phase {
        case .idle: return ("待机", palette.textDim)
        case .waitingToStart: return ("等待开始", palette.amber)
        case .exposing: return ("曝光中", palette.red)
        case .waitingInterval: return ("等待间隔", palette.amber)
        case .paused: return ("已暂停", palette.amber)
        case .stopping: return ("停止中", palette.amber)
        case .finished: return ("已完成", palette.textSecondary)
        case .stopped: return ("已停止", palette.textSecondary)
        case .failed: return ("失败", palette.red)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            iconButton(systemName: "grid", active: model.showGrid, help: "九宫格") {
                model.showGrid.toggle()
            }
            iconButton(systemName: "scope", active: model.showStarMarkers, help: "星点标记") {
                model.showStarMarkers.toggle()
            }
            iconButton(systemName: "moon", active: model.nightMode, help: "夜间模式") {
                model.nightMode.toggle()
            }
            iconButton(systemName: "sidebar.right", active: model.rightPanelVisible, help: "右侧面板") {
                model.rightPanelVisible.toggle()
            }
        }
    }

    private func iconButton(systemName: String, active: Bool,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? palette.text : palette.textDim)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(active ? Color.white.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct BottomBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var showLogs = false

    var body: some View {
        HStack(spacing: 8) {
            if let last = model.logs.last {
                Rectangle().fill(logColor(last.level)).frame(width: 2, height: 10)
                Text(last.text)
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("就绪")
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(palette.textDim)
            }
            Spacer(minLength: 12)
            Text("\(model.records.count) 张，\(model.records.filter { $0.verdict?.isAccepted == true }.count) 合格")
                .font(CinemaFont.micro(9))
                .monospacedDigit()
                .tracking(0.4)
                .foregroundStyle(palette.textDim)
            Button {
                showLogs.toggle()
            } label: {
                Text("日志")
                    .font(CinemaFont.micro(9))
                    .tracking(0.8)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showLogs, arrowEdge: .top) {
                LogPopover()
                    .environmentObject(model)
                    .environment(\.palette, palette)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(palette.panel)
    }

    private func logColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return palette.textDim
        case .warning: return palette.amber
        case .error: return palette.red
        }
    }
}

struct LogPopover: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.logs.suffix(120).reversed()) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.date, style: .time)
                            .font(CinemaFont.micro(8.5))
                            .foregroundStyle(palette.textDim)
                            .monospacedDigit()
                        Text(entry.text)
                            .font(CinemaFont.tiny(9.5))
                            .foregroundStyle(color(entry.level))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 420, height: 320)
        .background(palette.panel)
    }

    private func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return palette.textSecondary
        case .warning: return palette.amber
        case .error: return palette.red
        }
    }
}
