import SwiftUI
import AstroFieldKit

private struct ChipButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CinemaFont.smallValue(12))
            .foregroundStyle(selected ? palette.background : palette.text)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(selected ? palette.selected : palette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(palette.divider, lineWidth: selected ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ParameterBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var editor: EditorField?

    fileprivate enum EditorField: String, Identifiable {
        case iso, exposure, aperture, start, interval, end
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ParameterCell(label: "ISO", value: "\(model.plan.iso)") {
                    editor = .iso
                }
                .popover(isPresented: binding(.iso), arrowEdge: .bottom) {
                    ISOEditor(editor: $editor)
                        .environmentObject(model)
                        .environment(\.palette, palette)
                }

                ParameterCell(label: "SHUTTER",
                              value: exposureValue,
                              unit: "秒",
                              detail: model.plan.ramp.map {
                                  "渐变 \(CapturePlan.formatDuration($0.startSeconds))→\(CapturePlan.formatDuration($0.endSeconds))"
                              }) {
                    editor = .exposure
                }
                .popover(isPresented: binding(.exposure), arrowEdge: .bottom) {
                    ExposureEditor(editor: $editor)
                        .environmentObject(model)
                        .environment(\.palette, palette)
                }

                ParameterCell(label: "IRIS",
                              value: model.plan.aperture.map { String(format: "f/%.1f", $0) } ?? "—") {
                    editor = .aperture
                }
                .popover(isPresented: binding(.aperture), arrowEdge: .bottom) {
                    ApertureEditor(editor: $editor)
                        .environmentObject(model)
                        .environment(\.palette, palette)
                }

                ParameterCell(label: "START", value: shortStart) {
                    editor = .start
                }
                .popover(isPresented: binding(.start), arrowEdge: .bottom) {
                    StartEditor(editor: $editor)
                        .environmentObject(model)
                        .environment(\.palette, palette)
                }

                ParameterCell(label: "INTERVAL",
                              value: shortInterval,
                              detail: intervalDetail) {
                    editor = .interval
                }
                .popover(isPresented: binding(.interval), arrowEdge: .bottom) {
                    IntervalEditor(editor: $editor)
                        .environmentObject(model)
                        .environment(\.palette, palette)
                }

                        ParameterCell(label: "END", value: shortEnd) {
                            editor = .end
                        }
                        .popover(isPresented: binding(.end), arrowEdge: .bottom) {
                            EndEditor(editor: $editor)
                                .environmentObject(model)
                                .environment(\.palette, palette)
                        }
                    }
                }

                Spacer(minLength: 8)
                actionButtons.fixedSize()
            }

            if !model.planIssues.isEmpty {
                Text(model.planIssues.joined(separator: "；"))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.amber)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.panel)
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button {
                model.captureOnce()
            } label: {
                Label("试拍", systemImage: "camera")
            }
            .buttonStyle(CinemaButtonStyle(compact: true))
            .disabled(model.isRunning || model.isSingleShot)

            Button {
                model.toggleStartPause()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.isRunning
                          ? (model.isPaused ? "play.fill" : "pause.fill")
                          : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(model.isRunning ? (model.isPaused ? "继续" : "暂停") : "开始")
                }
            }
            .buttonStyle(CinemaButtonStyle(prominent: !model.isRunning || model.isPaused, compact: true))
            .disabled(model.status.state.isConnected == false)

            Button {
                model.stopSequence()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .buttonStyle(CinemaButtonStyle(danger: true, compact: true))
            .disabled(!model.isRunning)
        }
    }

    private var exposureValue: String {
        let seconds = model.plan.exposureSeconds
        if seconds.rounded() == seconds && seconds < 10_000 {
            return String(format: "%.0f", seconds)
        }
        return String(format: "%.1f", seconds)
    }

    private var shortStart: String {
        switch model.plan.start {
        case .immediate: return "立即"
        case .delay(let seconds): return "+\(CapturePlan.formatDuration(seconds))"
        case .at(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
    }

    private var shortInterval: String {
        switch model.plan.interval {
        case .fixedStart(let seconds): return CapturePlan.formatDuration(seconds)
        case .afterExposure(let seconds): return CapturePlan.formatDuration(seconds)
        }
    }

    private var intervalDetail: String {
        switch model.plan.interval {
        case .fixedStart: return "固定开始间隔"
        case .afterExposure: return "曝光结束后"
        }
    }

    private var shortEnd: String {
        switch model.plan.end {
        case .count(let count): return "\(count) 张"
        case .duration(let seconds): return CapturePlan.formatDuration(seconds)
        case .at(let date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        case .manual: return "手动"
        }
    }

    private func binding(_ field: EditorField) -> Binding<Bool> {
        Binding(get: { editor == field },
                set: { if !$0, editor == field { editor = nil } })
    }
}

// MARK: - Editors

private struct EditorShell<Content: View>: View {
    @Environment(\.palette) private var palette
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(CinemaFont.label(11))
                .foregroundStyle(palette.textSecondary)
            content()
        }
        .padding(12)
        .frame(width: 268)
        .background(palette.panel)
    }
}

private struct ISOEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var editor: ParameterBarView.EditorField?
    private let values = [100, 200, 400, 800, 1600, 3200, 6400, 12800]

    var body: some View {
        EditorShell(title: "ISO") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                      spacing: 4) {
                ForEach(values, id: \.self) { value in
                    Button("\(value)") {
                        model.plan.iso = value
                        editor = nil
                    }
                    .buttonStyle(ChipButtonStyle(selected: model.plan.iso == value))
                }
            }
            Stepper("自定义 \(model.plan.iso)",
                    value: Binding(get: { model.plan.iso },
                                   set: { model.plan.iso = min(102400, max(32, $0)) }),
                    step: 100)
                .font(CinemaFont.label(11))
        }
    }
}

private struct ExposureEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var editor: ParameterBarView.EditorField?
    private let quick: [Double] = [1, 5, 10, 15, 20, 30, 60, 120, 300]

    var body: some View {
        EditorShell(title: "曝光秒数") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                      spacing: 4) {
                ForEach(quick, id: \.self) { value in
                    Button(CapturePlan.formatDuration(value)) {
                        model.plan.exposureSeconds = value
                        editor = nil
                    }
                    .buttonStyle(ChipButtonStyle(selected: abs(model.plan.exposureSeconds - value) < 0.001))
                }
            }
            HStack(spacing: 6) {
                Text("自定义")
                    .font(CinemaFont.label(11))
                    .foregroundStyle(.secondary)
                TextField("秒", value: $model.plan.exposureSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(CinemaFont.smallValue(12))
                Text("秒").font(CinemaFont.label(11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ApertureEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var editor: ParameterBarView.EditorField?
    private let values: [Double] = [1.4, 1.8, 2.0, 2.8, 3.5, 4.0, 5.6, 8.0, 11.0, 16.0]

    var body: some View {
        EditorShell(title: "光圈") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                      spacing: 4) {
                ForEach(values, id: \.self) { value in
                    Button(String(format: "f/%.1f", value)) {
                        model.plan.aperture = value
                        editor = nil
                    }
                    .buttonStyle(ChipButtonStyle(
                        selected: model.plan.aperture.map { abs($0 - value) < 0.01 } ?? false))
                }
            }
            Button("固定光圈 / 无电子光圈") {
                model.plan.aperture = nil
                editor = nil
            }
            .buttonStyle(ChipButtonStyle(selected: model.plan.aperture == nil))
            Text("镜头是否支持由设备能力决定；不支持时只记录不设置。")
                .font(CinemaFont.tiny(10))
                .foregroundStyle(.secondary)
        }
    }
}

private struct StartEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var editor: ParameterBarView.EditorField?

    var body: some View {
        EditorShell(title: "开始方式") {
            Picker("", selection: startIndex) {
                Text("立即").tag(0)
                Text("延迟").tag(1)
                Text("指定时刻").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.plan.start {
            case .delay:
                HStack {
                    Text("延迟").font(CinemaFont.label(11))
                    TextField("秒", value: startDelay, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("秒").font(CinemaFont.label(11))
                }
            case .at:
                DatePicker("开始时刻", selection: startDate,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(CinemaFont.label(11))
            case .immediate:
                Text("连接正常后立刻开始。")
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startIndex: Binding<Int> {
        Binding(get: {
            switch model.plan.start {
            case .immediate: return 0
            case .delay: return 1
            case .at: return 2
            }
        }, set: { newValue in
            switch newValue {
            case 0: model.plan.start = .immediate
            case 1: model.plan.start = .delay(seconds: 10)
            default: model.plan.start = .at(Date().addingTimeInterval(120))
            }
        })
    }

    private var startDelay: Binding<Double> {
        Binding(get: {
            if case .delay(let seconds) = model.plan.start { return seconds }
            return 10
        }, set: { model.plan.start = .delay(seconds: max(0, $0)) })
    }

    private var startDate: Binding<Date> {
        Binding(get: {
            if case .at(let date) = model.plan.start { return date }
            return Date().addingTimeInterval(120)
        }, set: { model.plan.start = .at($0) })
    }
}

private struct IntervalEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var editor: ParameterBarView.EditorField?

    var body: some View {
        EditorShell(title: "拍摄节奏") {
            Picker("", selection: intervalIndex) {
                Text("固定开始间隔").tag(0)
                Text("曝光后等待").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("秒数").font(CinemaFont.label(11))
                TextField("秒", value: intervalSeconds, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("秒").font(CinemaFont.label(11))
            }

            if case .fixedStart = model.plan.interval {
                Picker("被打断时", selection: $model.plan.policy) {
                    ForEach(CapturePlan.MissedSlotPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .font(CinemaFont.label(11))
                Text("固定间隔按开始时刻排程；设备忙或下载慢时按此策略处理。")
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var intervalIndex: Binding<Int> {
        Binding(get: {
            if case .fixedStart = model.plan.interval { return 0 }
            return 1
        }, set: { newValue in
            let seconds = intervalSeconds.wrappedValue
            model.plan.interval = newValue == 0
                ? .fixedStart(seconds: max(0.1, seconds))
                : .afterExposure(seconds: max(0, seconds))
        })
    }

    private var intervalSeconds: Binding<Double> {
        Binding(get: {
            switch model.plan.interval {
            case .fixedStart(let seconds): return seconds
            case .afterExposure(let seconds): return seconds
            }
        }, set: { newValue in
            let value = max(0, newValue)
            switch model.plan.interval {
            case .fixedStart: model.plan.interval = .fixedStart(seconds: value)
            case .afterExposure: model.plan.interval = .afterExposure(seconds: value)
            }
        })
    }
}

private struct EndEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var editor: ParameterBarView.EditorField?

    var body: some View {
        EditorShell(title: "结束条件") {
            Picker("", selection: endIndex) {
                Text("张数").tag(0)
                Text("时长").tag(1)
                Text("时刻").tag(2)
                Text("手动").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.plan.end {
            case .count:
                HStack {
                    Text("目标张数").font(CinemaFont.label(11))
                    TextField("张", value: countBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("张").font(CinemaFont.label(11))
                }
            case .duration:
                HStack {
                    Text("持续").font(CinemaFont.label(11))
                    TextField("秒", value: durationBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("秒").font(CinemaFont.label(11))
                }
            case .at:
                DatePicker("结束时刻", selection: endDateBinding,
                           displayedComponents: [.date, .hourAndMinute])
                    .font(CinemaFont.label(11))
            case .manual:
                Text("手动按下停止才结束；适合整夜拍摄。")
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var endIndex: Binding<Int> {
        Binding(get: {
            switch model.plan.end {
            case .count: return 0
            case .duration: return 1
            case .at: return 2
            case .manual: return 3
            }
        }, set: { newValue in
            switch newValue {
            case 0: model.plan.end = .count(10)
            case 1: model.plan.end = .duration(seconds: 3600)
            case 2: model.plan.end = .at(Date().addingTimeInterval(1800))
            default: model.plan.end = .manual
            }
        })
    }

    private var countBinding: Binding<Int> {
        Binding(get: {
            if case .count(let count) = model.plan.end { return count }
            return 10
        }, set: { model.plan.end = .count(max(1, $0)) })
    }

    private var durationBinding: Binding<Double> {
        Binding(get: {
            if case .duration(let seconds) = model.plan.end { return seconds }
            return 3600
        }, set: { model.plan.end = .duration(seconds: max(1, $0)) })
    }

    private var endDateBinding: Binding<Date> {
        Binding(get: {
            if case .at(let date) = model.plan.end { return date }
            return Date().addingTimeInterval(1800)
        }, set: { model.plan.end = .at($0) })
    }
}
