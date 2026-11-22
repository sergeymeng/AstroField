import SwiftUI
import AstroFieldKit

struct RightPanelView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    PlanPanel()
                    AutoPanel().id("auto")
                    GroupsPanel()
                    DarkPanel().id("dark")
                    SessionPanel().id("session")
                    FocusPanel()
                    ViewfinderPanel().id("viewfinder")
                    AnalysisPanel()
                    TrialPanel()
                    StackPanel()
                    QualityPanel()
                    SimulatorPanel()
                }
            }
            .onChange(of: model.panelScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                model.panelScrollTarget = nil
            }
        }
        .background(palette.panel)
    }
}

// MARK: - Auto exposure

private struct AutoPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var focalText = ""

    var body: some View {
        PanelSection(title: "AUTO",
                     subtitle: model.autoExposure.isRunning ? L10n.text("搜索中") : L10n.text("星空自动曝光"),
                     help: L10n.text("按焦距估算能拍多久才会拖线，再试拍调整天空亮度。焦距留空时会读取第一张照片的 EXIF。"),
                     expandedByDefault: true) {
            HStack(spacing: 8) {
                TextField(L10n.text("焦距 mm（留空读 EXIF）"), text: $focalText)
                    .textFieldStyle(.roundedBorder)
                    .font(CinemaFont.tiny(10))
                    .frame(width: 150)
                    .onChange(of: focalText) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            model.plan.focalLengthMM = nil
                        } else if let focal = Double(trimmed), focal > 0 {
                            model.plan.focalLengthMM = focal
                        }
                    }
                Spacer()
                Button(model.autoExposure.isRunning ? L10n.text("搜索中…") : L10n.text("星空 Auto")) {
                    model.runAutoExposure()
                }
                .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                .disabled(!model.canRunAutoExposure)
                if model.autoExposure.isRunning {
                    Button(L10n.text("取消")) { model.cancelAutoExposure() }
                        .buttonStyle(CinemaButtonStyle(danger: true, compact: true))
                }
            }

            InfoRow(label: L10n.text("焦距"),
                    value: model.plan.focalLengthMM.map { String(format: "%.0f mm", $0) } ?? L10n.text("未记录"))

            if !model.autoExposure.message.isEmpty {
                Text(model.autoExposure.message)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(model.autoExposure.result?.status.isRecommended == true
                                     ? palette.textSecondary : palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = model.autoExposure.result {
                InfoRow(label: L10n.text("结论"), value: result.status.displayText,
                        color: result.status.isRecommended ? palette.textSecondary : palette.amber)
                InfoRow(label: L10n.text("建议"), value: String(
                    format: "ISO %d  %@  f/%.1f",
                    result.settings.iso,
                    CapturePlan.formatDuration(result.settings.exposureSeconds),
                    result.settings.aperture ?? 2.8))
            }

            if !model.autoExposure.samples.isEmpty {
                ForEach(Array(model.autoExposure.samples.enumerated()), id: \.offset) { index, sample in
                    Text(String(format: L10n.text("%d. ISO %d  %@  背景 %.0f  星点 %d  偏心 %.2f"),
                                index + 1, sample.settings.iso,
                                CapturePlan.formatDuration(sample.settings.exposureSeconds),
                                sample.metrics.background, sample.metrics.starCount,
                                sample.metrics.medianEccentricity))
                        .font(CinemaFont.tiny(9))
                        .foregroundStyle(palette.textDim)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Plan

private struct PlanPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var showSavePreset = false

    var body: some View {
        PanelSection(title: "PLAN",
                         subtitle: model.isRunning ? L10n.text("运行中") : L10n.text("拍摄计划"),
                         help: L10n.text("固定开拍间隔会把曝光时间算在内。上一张还没拍完时，可以让后面的照片顺延，也可以跳过这一张。")) {
            Text(model.plan.summary)
                .font(CinemaFont.tiny(10))
                .foregroundStyle(palette.textDim.opacity(0.95))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.text("曝光渐变（黎明/黄昏延时）"), isOn: rampToggle)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
            if model.plan.ramp != nil {
                HStack(spacing: 6) {
                    Text(L10n.text("起"))
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                    TextField(L10n.text("秒"), value: rampStart, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text(L10n.text("止"))
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                    TextField(L10n.text("秒"), value: rampEnd, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Picker("", selection: rampCurve) {
                        ForEach(ExposureRamp.Curve.allCases, id: \.self) { curve in
                            Text(curve.displayName).tag(curve)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 74)
                }
            }

            if !model.planIssues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.planIssues, id: \.self) { issue in
                        HStack(alignment: .top, spacing: 5) {
                            Circle().fill(palette.amber).frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(issue)
                                .font(CinemaFont.tiny(10))
                                .foregroundStyle(palette.amber)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button(L10n.text("保存预设")) { showSavePreset = true }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                Menu {
                    if model.presets.isEmpty {
                        Text(L10n.text("无预设"))
                    } else {
                        ForEach(model.presets) { preset in
                            Button(preset.name) { model.loadPreset(preset) }
                        }
                        Divider()
                        Menu(L10n.text("删除预设")) {
                            ForEach(model.presets) { preset in
                                Button(preset.name, role: .destructive) {
                                    model.deletePreset(preset)
                                }
                            }
                        }
                    }
                } label: {
                    Text(L10n.text("载入预设"))
                        .font(CinemaFont.label(11))
                        .foregroundStyle(palette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .popover(isPresented: $showSavePreset, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("保存预设"))
                        .font(CinemaFont.label(11))
                        .foregroundStyle(palette.textSecondary)
                    TextField(L10n.text("预设名"), text: $model.presetName)
                        .textFieldStyle(.roundedBorder)
                        .font(CinemaFont.label(11))
                        .frame(width: 200)
                    HStack {
                        Spacer()
                        Button(L10n.text("取消")) { showSavePreset = false }
                            .buttonStyle(CinemaButtonStyle(compact: true))
                        Button(L10n.text("保存")) {
                            model.savePreset()
                            showSavePreset = false
                        }
                        .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                    }
                }
                .padding(12)
                .frame(width: 244)
                .background(palette.panel)
            }

            Toggle(L10n.text("达到合格张数后暂停"), isOn: qualifiedToggle)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
            if qualifiedToggle.wrappedValue {
                Stepper(value: qualifiedTarget, in: 1...100000) {
                    Text(L10n.text("合格目标 %@ 张", qualifiedTarget.wrappedValue))
                        .font(CinemaFont.label(11))
                }
            }
        }
    }

    private var rampToggle: Binding<Bool> {
        Binding(get: { model.plan.ramp != nil }, set: { enabled in
            if enabled {
                let start = max(0.1, model.plan.exposureSeconds)
                model.plan.ramp = ExposureRamp(startSeconds: start,
                                               endSeconds: max(start * 4, start + 1),
                                               curve: .geometric)
            } else {
                model.plan.ramp = nil
            }
        })
    }

    private var rampStart: Binding<Double> {
        Binding(get: { model.plan.ramp?.startSeconds ?? model.plan.exposureSeconds },
                set: { value in
                    guard var ramp = model.plan.ramp else { return }
                    ramp.startSeconds = max(0.05, value)
                    model.plan.ramp = ramp
                })
    }

    private var rampEnd: Binding<Double> {
        Binding(get: { model.plan.ramp?.endSeconds ?? model.plan.exposureSeconds * 4 },
                set: { value in
                    guard var ramp = model.plan.ramp else { return }
                    ramp.endSeconds = max(0.05, value)
                    model.plan.ramp = ramp
                })
    }

    private var rampCurve: Binding<ExposureRamp.Curve> {
        Binding(get: { model.plan.ramp?.curve ?? .geometric },
                set: { curve in
                    guard var ramp = model.plan.ramp else { return }
                    ramp.curve = curve
                    model.plan.ramp = ramp
                })
    }

    private var qualifiedToggle: Binding<Bool> {
        Binding(get: { model.quality.qualifiedTarget != nil },
                set: { model.quality.qualifiedTarget = $0 ? 20 : nil })
    }

    private var qualifiedTarget: Binding<Int> {
        Binding(get: { model.quality.qualifiedTarget ?? 20 },
                set: { model.quality.qualifiedTarget = $0 })
    }
}

private struct GroupsPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "GROUPS",
                     subtitle: model.groupRunning ? (model.activeGroup?.displayName ?? L10n.text("运行中")) : L10n.text("分组拍摄"),
                     help: L10n.text("勾选要拍的分组。每组可以单独设置曝光和对焦偏移，最后一组拍完后镜头会按相反步数回调。")) {
            ForEach(model.groups) { group in
                let index = model.groups.firstIndex(where: { $0.id == group.id }) ?? 0
                let active = model.activeGroupIndex == index
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(active ? palette.amber : Color.clear)
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            Toggle("", isOn: Binding(
                                get: { group.enabled },
                                set: { model.setGroupEnabled(group.id, $0) }))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            Text(group.displayName)
                                .font(CinemaFont.label(11))
                                .foregroundStyle(active ? palette.text : palette.textSecondary)
                            if active {
                                StatusChip(text: L10n.text("当前"), color: palette.amber)
                            }
                            Spacer()
                        }
                        Text(model.groupSummary(group))
                            .font(CinemaFont.micro(8.5))
                            .tracking(0.3)
                            .foregroundStyle(palette.textDim)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Button(L10n.text("载入")) { model.loadGroupPlan(group) }
                                .buttonStyle(CinemaButtonStyle(compact: true))
                            Button(L10n.text("用当前计划更新")) { model.updateGroupFromPlan(group.id) }
                                .buttonStyle(CinemaButtonStyle(compact: true))
                            Menu {
                                ForEach([-200, -100, -50, 0, 50, 100, 200], id: \.self) { steps in
                                    Button(String(format: L10n.text("%+d 步"), steps)) {
                                        model.setGroupFocusOffset(group.id, steps)
                                    }
                                }
                            } label: {
                                Text(focusLabel(group.focusOffsetSteps))
                                    .font(CinemaFont.label(10))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 5)
            }

            HStack(spacing: 8) {
                Button(L10n.text("开始分组")) { model.startGroupShoot() }
                    .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                    .disabled(model.isRunning || !model.status.state.isConnected
                              || !model.groups.contains(where: { $0.enabled }))
                Spacer()
                Text(L10n.text("%@ 组启用", model.groups.filter { $0.enabled }.count))
                    .font(CinemaFont.tiny(9))
                    .foregroundStyle(palette.textDim)
            }
        }
    }

    private func focusLabel(_ steps: Int) -> String {
        steps == 0 ? L10n.text("对焦 +0") : String(format: L10n.text("对焦 %+d"), steps)
    }
}

// MARK: - Focus

private struct FocusPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "FOCUS",
                         subtitle: model.focus.isRunning ? L10n.text("搜索中") : L10n.text("对焦"),
                         help: L10n.text("搜索时镜头会向两个方向移动。拍完验证帧后，比较星点的 FWHM，数值越小，星点越紧。方向 1 和 2 随镜头而异。")) {
            HStack(spacing: 6) {
                Button(model.focus.isRunning ? L10n.text("搜索中…") : L10n.text("自动对焦")) {
                    model.runAutoFocus()
                }
                .buttonStyle(CinemaButtonStyle(compact: true))
                .disabled(!model.canAutoFocus)

                if model.focus.isRunning {
                    Button(L10n.text("取消")) { model.cancelFocus() }
                        .buttonStyle(CinemaButtonStyle(danger: true, compact: true))
                }
                Button(model.focusBracketRunning ? L10n.text("包围中…") : L10n.text("焦点包围")) {
                    model.runFocusBracket()
                }
                .buttonStyle(CinemaButtonStyle(compact: true))
                .disabled(model.focusBracketRunning || !model.canAutoFocus)
                Spacer()
            }

            if !model.focus.message.isEmpty {
                Text(model.focus.message)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(model.focus.result?.status == .confirmed
                                     ? palette.textSecondary : palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FocusCurveView(samples: model.focus.samples,
                           bestSteps: model.focus.result?.bestRelativeSteps)

            if let result = model.focus.result {
                HStack(spacing: 6) {
                    StatusChip(text: result.status.displayText,
                               color: result.status == .confirmed ? palette.selected : palette.amber)
                    Spacer()
                    Text(String(format: L10n.text("置信 %.0f%%"), result.confidence * 100))
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                        .monospacedDigit()
                }
                if let baseline = result.baseline, let best = result.best {
                    InfoRow(label: "FWHM",
                            value: String(format: "%.2f → %.2f", baseline.medianFWHM, best.medianFWHM))
                    InfoRow(label: L10n.text("样本数"), value: "\(result.samples.count)")
                }
            }

            Text(L10n.text("手动微调"))
                .font(CinemaFont.tiny(10))
                .foregroundStyle(palette.textDim)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                GridItem(.flexible(), spacing: 4)], spacing: 4) {
                nudgeButton(L10n.text("方向 1  +50"), .one, 50)
                nudgeButton(L10n.text("方向 1  +10"), .one, 10)
                nudgeButton(L10n.text("方向 2  +10"), .two, 10)
                nudgeButton(L10n.text("方向 2  +50"), .two, 50)
            }

            if model.canControlCameraScreen {
                Toggle(L10n.text("关闭相机屏"), isOn: Binding(
                    get: { model.cameraScreenOff },
                    set: { model.setCameraScreen(off: $0) }))
                    .toggleStyle(.checkbox)
                    .font(CinemaFont.label(11))
                    .help(L10n.text("PC mode 下关闭机身屏；打开时恢复 remote mode"))
            }

        }
    }

    private func nudgeButton(_ title: String, _ direction: FocusDirection, _ steps: Int) -> some View {
        Button(title) {
            model.nudgeFocus(direction: direction, steps: steps)
        }
        .buttonStyle(CinemaButtonStyle(compact: true))
        .disabled(!model.status.state.isConnected || model.isRunning)
    }
}

private struct ViewfinderPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "VIEWFINDER",
                     subtitle: model.findStarMode ? L10n.text("找星") : (model.liveAssistEnabled ? L10n.text("取景辅助") : L10n.text("取景")),
                     help: L10n.text("调增益和黑场可以看清暗星，对焦用原始帧。找星时 ISO 暂时升到 12800，退出后恢复。")) {
            HStack(spacing: 8) {
                Button(model.findStarMode ? L10n.text("退出找星") : L10n.text("找星模式")) {
                    model.toggleFindStarMode()
                }
                .buttonStyle(CinemaButtonStyle(prominent: !model.findStarMode, compact: true))
                .disabled(!model.findStarMode && !model.canUseFindStarMode)

                if model.findStarMode {
                    Button(L10n.text("对焦最亮星")) {
                        model.focusBrightestStar()
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(!model.canFocusBrightestStar)
                }
                Spacer()
            }

            if model.findStarMode {
                InfoRow(label: L10n.text("临时 ISO"), value: "12800", color: palette.amber)
                if let star = model.liveBrightestStar {
                    InfoRow(label: L10n.text("最亮星"),
                            value: String(format: L10n.text("峰值 %.0f  FWHM %.2f"), star.peak, star.fwhm))
                }
                if !model.findStarFocusMessage.isEmpty {
                    InfoRow(label: L10n.text("对焦结果"), value: model.findStarFocusMessage,
                            color: model.findStarFocusMessage.hasPrefix(L10n.text("已对焦"))
                                ? palette.selected : palette.amber)
                }
                if !model.findStarStatus.isEmpty {
                    Text(model.findStarStatus)
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(model.findStarStatus.localizedCaseInsensitiveContains(L10n.text("未检测到星点"))
                                         ? palette.amber : palette.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Toggle(L10n.text("取景辅助"), isOn: Binding(
                    get: { model.liveAssistEnabled },
                    set: { model.setLiveAssist($0) }))
                    .toggleStyle(.checkbox)
                    .font(CinemaFont.label(11))
                    .disabled(model.findStarMode)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.liveZoom },
                    set: { model.setLiveZoom($0) })) {
                    ForEach(LiveZoom.allCases) { zoom in
                        Text(zoom.displayName).tag(zoom)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                .disabled(!model.liveAssistEnabled)
            }

            if model.supportsLiveStretch {
                Toggle(L10n.text("取景拉伸"), isOn: Binding(
                    get: { model.liveStretch.enabled },
                    set: { model.setLiveStretchEnabled($0) }))
                    .toggleStyle(.checkbox)
                    .font(CinemaFont.label(11))
                stretchRow(label: L10n.text("增益"),
                           value: 30 / max(0.1, model.liveStretch.gainSigma),
                           range: 0.5...5, step: 0.1,
                           text: String(format: "%.1f×", 30 / max(0.1, model.liveStretch.gainSigma))) {
                    model.setLiveStretchGain(30 / max(0.1, $0))
                }
                .disabled(!model.liveStretch.enabled)
                stretchRow(label: L10n.text("黑场"), value: model.liveStretch.blackSigma, range: -3...3, step: 0.25,
                           text: String(format: "%+.1fσ", model.liveStretch.blackSigma)) {
                    model.setLiveStretchBlack($0)
                }
                .disabled(!model.liveStretch.enabled)
                if let stats = model.liveStretchStats {
                    InfoRow(label: L10n.text("背景"),
                            value: String(format: L10n.text("中位 %.0f / σ %.1f"), stats.median, stats.sigma))
                }
                Toggle(L10n.text("保持后台活跃"), isOn: Binding(
                    get: { model.keepAlive },
                    set: { model.setKeepAlive($0) }))
                    .toggleStyle(.checkbox)
                    .font(CinemaFont.label(11))
                    .help(L10n.text("Nikon 连接期间阻止 App Nap 节流；显示仍可休眠"))
            }

            if model.liveAssistEnabled {
                InfoRow(label: L10n.text("实时 FWHM"),
                        value: model.liveFWHM.map { String(format: "%.2f px", $0) } ?? "—")
                InfoRow(label: L10n.text("星点"), value: "\(model.liveStars.count)")
                InfoRow(label: L10n.text("高光比例"),
                        value: String(format: "%.2f%%", model.liveClipFraction * 100),
                        color: model.liveClipFraction > 0.001 ? palette.amber : nil)
                HistogramView(bins: model.liveHistogram)
            }
        }
    }

    private func stretchRow(label: String, value: Double,
                            range: ClosedRange<Double>, step: Double,
                            text: String,
                            set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(CinemaFont.tiny(10))
                .foregroundStyle(palette.textDim)
                .fixedSize()
                .frame(minWidth: 54, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range, step: step)
            Text(text)
                .font(CinemaFont.tiny(10))
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Dark

private struct DarkPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "DARK",
                     subtitle: model.darkCollecting ? L10n.text("采集中") : (model.darkEnabled ? L10n.text("已启用") : L10n.text("暗场校准")),
                     help: L10n.text("盖上镜头盖，用拍星时的 ISO 和曝光时间采集几张暗场。应用取平均后，用它校正分析图和叠加图。"),
                     expandedByDefault: true) {
            Toggle(L10n.text("拍摄时减暗场"), isOn: Binding(
                get: { model.darkEnabled },
                set: { model.setDarkEnabled($0) }))
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))

            HStack(spacing: 8) {
                Stepper(value: $model.darkTarget, in: 1...32) {
                    Text(L10n.text("%@ 帧", model.darkTarget))
                        .font(CinemaFont.label(11))
                        .monospacedDigit()
                }
                Button(model.darkCollecting ? L10n.text("采集中…") : L10n.text("采集暗场")) {
                    model.collectDarks()
                }
                .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                .disabled(!model.canCollectDarks)
                Spacer()
            }

            if model.darkCollecting {
                Text(L10n.text("已采集 %@/%@　%@", model.darkProgress, model.darkTarget, model.darkStatus))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.amber)
            } else if !model.darkStatus.isEmpty {
                Text(model.darkStatus)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            }

            if model.darkMetas.isEmpty {
                Text(L10n.text("尚未采集"))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            } else {
                ForEach(model.darkMetas.prefix(6)) { meta in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: "ISO %d  %@", meta.iso,
                                        CapturePlan.formatDuration(meta.exposureSeconds)))
                                .font(CinemaFont.smallValue(10.5))
                                .foregroundStyle(palette.textSecondary)
                            if meta.isUsable {
                                Text(String(format: L10n.text("%d 帧  %@  热像素 %d"), meta.frameCount,
                                            meta.createdAt.formatted(date: .omitted, time: .shortened),
                                            meta.hotPixelCount))
                                    .font(CinemaFont.tiny(9))
                                    .foregroundStyle(palette.textDim)
                            } else {
                                Text(L10n.text("分布异常，未启用"))
                                    .font(CinemaFont.tiny(9))
                                    .foregroundStyle(palette.amber)
                            }
                        }
                        Spacer()
                        Button(L10n.text("删除")) { model.deleteDark(meta) }
                            .buttonStyle(CinemaButtonStyle(danger: true, compact: true))
                    }
                }
            }
        }
    }
}

// MARK: - Session

private struct SessionPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "SESSION",
                     subtitle: model.sessionInfo == nil ? L10n.text("会话") : L10n.text("%@ 帧", model.sessionFrameCount),
                     help: L10n.text("每组拍摄都有自己的目录，里面有逐张记录、叠加图和导出的报告。实拍 NEF 保存在下载位置。"),
                     expandedByDefault: true) {
            if let info = model.sessionInfo {
                Text(info.name)
                    .font(CinemaFont.smallValue(11))
                    .foregroundStyle(palette.textSecondary)
                Text(pathText(info.directory))
                    .font(CinemaFont.tiny(9))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(L10n.text("尚未开始拍摄"))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            }

            HStack(spacing: 6) {
                Button(L10n.text("打开目录")) { model.revealSession() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.sessionInfo == nil)
                Button(L10n.text("导出叠加")) { model.exportStackImage() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(!model.canExportStack)
                Button(L10n.text("导出报告")) { model.exportSessionReport() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.sessionInfo == nil)
                Spacer()
            }

            HStack(spacing: 6) {
                Button(model.sessionStack.isRunning ? L10n.text("叠加中…") : L10n.text("自动叠加")) {
                    model.stackSession()
                }
                .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                .disabled(!model.canStackSession)
                Spacer()
                if model.sessionStack.isRunning {
                    Text("\(model.sessionStack.processed)/\(model.sessionStack.total)")
                        .font(CinemaFont.tiny(9))
                        .monospacedDigit()
                        .foregroundStyle(palette.textDim)
                }
            }

            if !model.sessionStack.message.isEmpty {
                Text(model.sessionStack.message)
                    .font(CinemaFont.tiny(9.5))
                    .foregroundStyle(model.sessionStack.summary != nil
                                     ? palette.textSecondary : palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = model.sessionLastExport {
                Text(L10n.text("最近导出 %@", url.lastPathComponent))
                    .font(CinemaFont.tiny(9))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(1)
            }
        }
    }

    private func pathText(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home) {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}

// MARK: - Analysis

private struct AnalysisPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "ANALYSIS",
                         subtitle: model.selectedRecord?.displayName ?? L10n.text("分析"),
                         help: L10n.text("放大中心或四角检查星形。星点大小和背景亮度取自原始解码帧。")) {
            Picker("", selection: $model.analysisCrop) {
                ForEach(AnalysisCropMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: model.analysisCrop) { _, newValue in
                model.setAnalysisCrop(newValue)
            }

            if model.selectedRecord == nil {
                Text(L10n.text("选择一张照片"))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            } else {
                Text(model.analysisNote)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(2)

                if let metrics = model.analysisMetrics {
                    InfoRow(label: L10n.text("检测星数"), value: "\(metrics.starCount)")
                    InfoRow(label: L10n.text("中位 FWHM"), value: String(format: "%.2f px", metrics.medianFWHM))
                    InfoRow(label: L10n.text("中位偏心度"), value: String(format: "%.3f", metrics.medianEccentricity))
                    InfoRow(label: L10n.text("背景"), value: String(format: "%.0f ADU", metrics.background))
                    InfoRow(label: L10n.text("噪声 σ"), value: String(format: "%.1f", metrics.noise))
                    InfoRow(label: L10n.text("饱和比例"),
                            value: String(format: "%.4f%%", metrics.saturatedFraction * 100),
                            color: metrics.saturatedFraction > 0.001 ? palette.amber : nil)
                } else {
                    Text(L10n.text("分析中…"))
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                }

                if let dark = model.selectedRecord?.darkApplied {
                    Text(L10n.text("已减暗场  %@", dark))
                        .font(CinemaFont.tiny(9.5))
                        .foregroundStyle(palette.textDim)
                }

                if let measurement = model.analysisMeasurement {
                    InfoRow(label: L10n.text("裁切 FWHM"),
                            value: String(format: L10n.text("%.2f px   %d 星"),
                                          measurement.medianFWHM, measurement.starCount),
                            color: palette.textSecondary)
                }

                if !model.cornerFWHM.isEmpty {
                    ForEach(model.cornerFWHM.keys.sorted(), id: \.self) { key in
                        InfoRow(label: key,
                                value: String(format: "FWHM %.2f", model.cornerFWHM[key] ?? 0))
                    }
                }

                HistogramView(bins: model.histogram)

                HStack(spacing: 6) {
                    Button(model.meteorScanning ? L10n.text("扫描中…") : L10n.text("扫描流星候选")) {
                        model.scanForMeteors()
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.meteorScanning || model.selectedRecord == nil)
                    Spacer()
                    if !model.meteorCandidates.isEmpty {
                        Text(L10n.text("%@ 个候选", model.meteorCandidates.count))
                            .font(CinemaFont.tiny(10))
                            .foregroundStyle(palette.amber)
                    }
                }
                ForEach(model.meteorCandidates.prefix(5)) { candidate in
                    InfoRow(label: L10n.text("候选"),
                            value: String(format: L10n.text("长 %dpx   比例 %.1f   %.0f°"),
                                          candidate.length, candidate.aspect,
                                          candidate.angleDegrees),
                            color: palette.amber)
                }

                Toggle(L10n.text("显示星点标记"), isOn: $model.showStarMarkers)
                    .toggleStyle(.checkbox)
                    .font(CinemaFont.label(11))

            }
        }
    }
}

// MARK: - Stack

private struct StackPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "STACK",
                         subtitle: model.stack.enabled ? L10n.text("开启") : L10n.text("现场叠加"),
                         help: L10n.text("用星点对齐各张照片，再取平均。对齐仅校正水平和垂直位移。"),
                         expandedByDefault: false) {
            Toggle(L10n.text("累积新到照片"), isOn: Binding(
                get: { model.stack.enabled },
                set: { model.toggleStacking($0) }))
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))

            Picker("", selection: Binding(
                get: { model.stack.mode },
                set: { model.setStackMode($0) })) {
                ForEach(StackMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.stack.mode == .mean {
                InfoRow(label: L10n.text("参与张数"), value: "\(model.stack.accepted)")
                InfoRow(label: L10n.text("拒绝张数"), value: "\(model.stack.rejected)")
                InfoRow(label: L10n.text("有效覆盖"), value: String(format: "%.0f%%", model.stack.coverage * 100))
                InfoRow(label: L10n.text("最近平移"), value: model.stack.shiftText)
            } else {
                InfoRow(label: L10n.text("帧数"), value: "\(model.stack.accepted)")
                InfoRow(label: L10n.text("累计曝光"), value: CapturePlan.formatDuration(model.stack.totalExposure))
                InfoRow(label: L10n.text("间断次数"), value: "\(model.stack.gapCount)")
                InfoRow(label: L10n.text("最大间断"),
                        value: model.stack.maxGap > 0
                            ? CapturePlan.formatDuration(model.stack.maxGap) : "—",
                        color: model.stack.gapCount > 0 ? palette.amber : nil)
                InfoRow(label: L10n.text("拒绝帧数"), value: "\(model.stack.rejected)")
            }

            if let reason = model.stack.lastReason {
                Text(reason)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.amber)
            }

            HStack {
                Button(L10n.text("重置叠加")) { model.resetStack() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                Spacer()
            }

        }
    }
}

// MARK: - Quality

private struct QualityPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "QUALITY",
                         subtitle: model.quality.lastAction.isEmpty ? L10n.text("质量规则") : L10n.text("有提醒"),
                         help: L10n.text("星数减少或天空变亮时会提醒。星点连续变大时，可以让序列暂停或重新对焦。"),
                         expandedByDefault: false) {
            Toggle(L10n.text("清晰度异常时暂停等待复核"), isOn: $model.quality.autoPause)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
            Toggle(L10n.text("自动重新对焦"), isOn: $model.quality.autoRefocus)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
                .disabled(!model.status.capabilities.contains(.manualFocusDrive))

            InfoRow(label: L10n.text("合格张数"), value: "\(model.quality.qualified)")
            if !model.quality.lastAction.isEmpty {
                Text(model.quality.lastAction)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            QualityTimelineView(points: model.qualityTimeline)
        }
    }
}

// MARK: - Trials

private struct TrialPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "TRIALS",
                         subtitle: model.isTrialRunning ? L10n.text("拍摄中") : L10n.text("参数试拍"),
                         help: L10n.text("比较同一构图下的试拍，把选中的参数写回计划，也可以连同拍摄条件存入镜头档案。"),
                         expandedByDefault: false) {
            HStack(spacing: 6) {
                Button(L10n.text("快门试拍")) { model.runShutterTrial() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.isTrialRunning || model.isRunning)
                Button(L10n.text("光圈试拍")) { model.runApertureTrial() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.isTrialRunning || model.isRunning)
                Button(L10n.text("包围试拍")) { model.runBracketTrial() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.isTrialRunning || model.isRunning)
                Spacer()
            }

            if model.trialCandidates.isEmpty {
                Text(L10n.text("暂无候选"))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            } else {
                ForEach(model.trialCandidates) { candidate in
                    HStack(spacing: 7) {
                        if let preview = candidate.preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 58, height: 38)
                                .clipped()
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(palette.divider, lineWidth: 1)
                                )
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(candidate.label)
                                    .font(CinemaFont.smallValue(11))
                                    .foregroundStyle(palette.text)
                                if candidate.recommended {
                                    StatusChip(text: L10n.text("推荐"), color: palette.amber)
                                }
                            }
                            Text(metricText(candidate))
                                .font(CinemaFont.tiny(9))
                                .foregroundStyle(palette.textDim)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(L10n.text("采用")) { model.adoptTrial(candidate) }
                            .buttonStyle(CinemaButtonStyle(compact: true))
                    }
                }
            }

            HStack(spacing: 6) {
                Button(L10n.text("保存到镜头档案")) { model.saveLensProfile() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.trialCandidates.isEmpty)
                Spacer()
                Text(L10n.text("%@ 条档案", model.lensProfileCount))
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            }

        }
    }

    private func metricText(_ candidate: TrialCandidate) -> String {
        var parts: [String] = []
        if let metrics = candidate.metrics {
            parts.append(String(format: "FWHM %.2f", metrics.medianFWHM))
            parts.append(L10n.text("%@ 星", metrics.starCount))
            parts.append(String(format: L10n.text("饱和 %.3f%%"), metrics.saturatedFraction * 100))
            parts.append(String(format: L10n.text("偏心 %.2f"), metrics.medianEccentricity))
        } else {
            parts.append(L10n.text("无测量"))
        }
        return parts.joined(separator: "   ")
    }
}

// MARK: - Simulator

private struct SimulatorPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        if model.sourceKind == .simulator {
            PanelSection(title: "SIMULATOR",
                         subtitle: L10n.text("仿真"),
                         help: L10n.text("试试薄云、焦点偏移或慢下载，看看拍摄中的画面和计数怎样变化。"),
                         expandedByDefault: false) {
                Menu(L10n.text("场景：%@", model.simulatorCondition.displayName)) {
                    ForEach(SkyCondition.allCases, id: \.rawValue) { condition in
                        Button(condition.displayName) {
                            model.setSimulatorCondition(condition)
                        }
                    }
                }
                .font(CinemaFont.label(11))

                HStack {
                    Text(L10n.text("焦点位置"))
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                    Slider(value: Binding(
                        get: { model.simulatorFocusPosition },
                        set: { model.setSimulatorFocus($0) }), in: 0...1000)
                    Text(String(format: "%.0f", model.simulatorFocusPosition))
                        .font(CinemaFont.smallValue(11))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }

                HStack(spacing: 5) {
                    Button(L10n.text("复位焦点")) { model.resetSimulatorFocus() }
                        .buttonStyle(CinemaButtonStyle(compact: true))
                    Button(L10n.text("曝光失败")) {
                        model.injectSimulatorFault(.failNextCapture(L10n.text("模拟曝光失败")))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    Button(L10n.text("设备忙 2s")) {
                        model.injectSimulatorFault(.busy(seconds: 2))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                }
                HStack(spacing: 5) {
                    Button(L10n.text("慢下载 3s")) {
                        model.injectSimulatorFault(.slowDownload(seconds: 3))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    Button(L10n.text("拍 2 张后断连")) {
                        model.injectSimulatorFault(.disconnectAfter(2))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                }

            }
        }
    }
}
