import SwiftUI
import AstroFieldKit

struct RightPanelView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PlanPanel()
                GroupsPanel()
                FocusPanel()
                AnalysisPanel()
                TrialPanel()
                StackPanel()
                QualityPanel()
                SimulatorPanel()
            }
        }
        .background(palette.panel)
    }
}

// MARK: - Plan

private struct PlanPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var showSavePreset = false

    var body: some View {
        PanelSection(title: "PLAN",
                         subtitle: model.isRunning ? "运行中" : "拍摄计划",
                         help: "开始前会检查曝光与处理时间能否排进节奏；固定间隔被打断时按所选策略顺延或跳过。") {
            Text(model.plan.summary)
                .font(CinemaFont.tiny(10))
                .foregroundStyle(palette.textDim.opacity(0.95))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("曝光渐变（黎明/黄昏延时）", isOn: rampToggle)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
            if model.plan.ramp != nil {
                HStack(spacing: 6) {
                    Text("起")
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                    TextField("秒", value: rampStart, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("止")
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                    TextField("秒", value: rampEnd, format: .number)
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
                Button("保存预设") { showSavePreset = true }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                Menu {
                    if model.presets.isEmpty {
                        Text("无预设")
                    } else {
                        ForEach(model.presets) { preset in
                            Button(preset.name) { model.loadPreset(preset) }
                        }
                        Divider()
                        Menu("删除预设") {
                            ForEach(model.presets) { preset in
                                Button(preset.name, role: .destructive) {
                                    model.deletePreset(preset)
                                }
                            }
                        }
                    }
                } label: {
                    Text("载入预设")
                        .font(CinemaFont.label(11))
                        .foregroundStyle(palette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
            .popover(isPresented: $showSavePreset, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("保存预设")
                        .font(CinemaFont.label(11))
                        .foregroundStyle(palette.textSecondary)
                    TextField("预设名", text: $model.presetName)
                        .textFieldStyle(.roundedBorder)
                        .font(CinemaFont.label(11))
                        .frame(width: 200)
                    HStack {
                        Spacer()
                        Button("取消") { showSavePreset = false }
                            .buttonStyle(CinemaButtonStyle(compact: true))
                        Button("保存") {
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

            Toggle("达到合格张数后暂停", isOn: qualifiedToggle)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
            if qualifiedToggle.wrappedValue {
                Stepper(value: qualifiedTarget, in: 1...100000) {
                    Text("合格目标 \(qualifiedTarget.wrappedValue) 张")
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
                     subtitle: model.groupRunning ? (model.activeGroupName ?? "运行中") : "分组拍摄",
                     help: "按顺序拍摄启用的分组。每组有自己的计划，可设置相对对焦偏移；全部结束后会回到起始焦点。方向 1/2 的物理含义随机身与镜头变化。") {
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
                            Text(group.name)
                                .font(CinemaFont.label(11))
                                .foregroundStyle(active ? palette.text : palette.textSecondary)
                            if active {
                                StatusChip(text: "当前", color: palette.amber)
                            }
                            Spacer()
                        }
                        Text(model.groupSummary(group))
                            .font(CinemaFont.micro(8.5))
                            .tracking(0.3)
                            .foregroundStyle(palette.textDim)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Button("载入") { model.loadGroupPlan(group) }
                                .buttonStyle(CinemaButtonStyle(compact: true))
                            Button("用当前计划更新") { model.updateGroupFromPlan(group.id) }
                                .buttonStyle(CinemaButtonStyle(compact: true))
                            Menu {
                                ForEach([-200, -100, -50, 0, 50, 100, 200], id: \.self) { steps in
                                    Button(String(format: "%+d 步", steps)) {
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
                Button("开始分组") { model.startGroupShoot() }
                    .buttonStyle(CinemaButtonStyle(prominent: true, compact: true))
                    .disabled(model.isRunning || !model.status.state.isConnected
                              || !model.groups.contains(where: { $0.enabled }))
                Spacer()
                Text("\(model.groups.filter { $0.enabled }.count) 组启用")
                    .font(CinemaFont.tiny(9))
                    .foregroundStyle(palette.textDim)
            }
        }
    }

    private func focusLabel(_ steps: Int) -> String {
        steps == 0 ? "对焦 +0" : String(format: "对焦 %+d", steps)
    }
}

// MARK: - Focus

private struct FocusPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "FOCUS",
                         subtitle: model.focus.isRunning ? "搜索中" : "对焦",
                         help: "MFDrive 没有绝对位置，方向 1/2 的物理含义随机身与镜头组合变化。搜索结果需要复拍验证；证据不足时显示尚未确认。") {
            HStack(spacing: 6) {
                Button(model.focus.isRunning ? "搜索中…" : "自动对焦") {
                    model.runAutoFocus()
                }
                .buttonStyle(CinemaButtonStyle(compact: true))
                .disabled(!model.canAutoFocus)

                if model.focus.isRunning {
                    Button("取消") { model.cancelFocus() }
                        .buttonStyle(CinemaButtonStyle(danger: true, compact: true))
                }
                Button(model.focusBracketRunning ? "包围中…" : "焦点包围") {
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
                    Text(String(format: "置信 %.0f%%", result.confidence * 100))
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                        .monospacedDigit()
                }
                if let baseline = result.baseline, let best = result.best {
                    InfoRow(label: "FWHM",
                            value: String(format: "%.2f → %.2f", baseline.medianFWHM, best.medianFWHM))
                    InfoRow(label: "样本数", value: "\(result.samples.count)")
                }
            }

            Text("手动微调")
                .font(CinemaFont.tiny(10))
                .foregroundStyle(palette.textDim)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                GridItem(.flexible(), spacing: 4)], spacing: 4) {
                nudgeButton("方向 1  +50", .one, 50)
                nudgeButton("方向 1  +10", .one, 10)
                nudgeButton("方向 2  +10", .two, 10)
                nudgeButton("方向 2  +50", .two, 50)
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

// MARK: - Analysis

private struct AnalysisPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        PanelSection(title: "ANALYSIS",
                         subtitle: model.selectedRecord?.displayName ?? "分析",
                         help: "测量输入是解码后的线性亮度；显示拉伸和直方图只影响显示，不改变测量值。") {
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
                Text("选择一张照片")
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            } else {
                Text(model.analysisNote)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
                    .lineLimit(2)

                if let metrics = model.analysisMetrics {
                    InfoRow(label: "检测星数", value: "\(metrics.starCount)")
                    InfoRow(label: "中位 FWHM", value: String(format: "%.2f px", metrics.medianFWHM))
                    InfoRow(label: "中位偏心度", value: String(format: "%.3f", metrics.medianEccentricity))
                    InfoRow(label: "背景", value: String(format: "%.0f ADU", metrics.background))
                    InfoRow(label: "噪声 σ", value: String(format: "%.1f", metrics.noise))
                    InfoRow(label: "饱和比例",
                            value: String(format: "%.4f%%", metrics.saturatedFraction * 100),
                            color: metrics.saturatedFraction > 0.001 ? palette.amber : nil)
                } else {
                    Text("分析中…")
                        .font(CinemaFont.tiny(10))
                        .foregroundStyle(palette.textDim)
                }

                if let measurement = model.analysisMeasurement {
                    InfoRow(label: "裁切 FWHM",
                            value: String(format: "%.2f px   %d 星",
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
                    Button(model.meteorScanning ? "扫描中…" : "扫描流星候选") {
                        model.scanForMeteors()
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.meteorScanning || model.selectedRecord == nil)
                    Spacer()
                    if !model.meteorCandidates.isEmpty {
                        Text("\(model.meteorCandidates.count) 个候选")
                            .font(CinemaFont.tiny(10))
                            .foregroundStyle(palette.amber)
                    }
                }
                ForEach(model.meteorCandidates.prefix(5)) { candidate in
                    InfoRow(label: "候选",
                            value: String(format: "长 %dpx   比例 %.1f   %.0f°",
                                          candidate.length, candidate.aspect,
                                          candidate.angleDegrees),
                            color: palette.amber)
                }

                Toggle("显示星点标记", isOn: $model.showStarMarkers)
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
                         subtitle: model.stack.enabled ? "开启" : "现场叠加",
                         help: "按星点平移对齐后做平均累积。旋转、视差和移动地景不在当前处理范围内。",
                         expandedByDefault: false) {
            Toggle("累积新到照片", isOn: Binding(
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
                InfoRow(label: "参与张数", value: "\(model.stack.accepted)")
                InfoRow(label: "拒绝张数", value: "\(model.stack.rejected)")
                InfoRow(label: "有效覆盖", value: String(format: "%.0f%%", model.stack.coverage * 100))
                InfoRow(label: "最近平移", value: model.stack.shiftText)
            } else {
                InfoRow(label: "帧数", value: "\(model.stack.accepted)")
                InfoRow(label: "累计曝光", value: CapturePlan.formatDuration(model.stack.totalExposure))
                InfoRow(label: "间断次数", value: "\(model.stack.gapCount)")
                InfoRow(label: "最大间断",
                        value: model.stack.maxGap > 0
                            ? CapturePlan.formatDuration(model.stack.maxGap) : "—",
                        color: model.stack.gapCount > 0 ? palette.amber : nil)
                InfoRow(label: "拒绝帧数", value: "\(model.stack.rejected)")
            }

            if let reason = model.stack.lastReason {
                Text(reason)
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.amber)
            }

            HStack {
                Button("重置叠加") { model.resetStack() }
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
                         subtitle: model.quality.lastAction.isEmpty ? "质量规则" : "有提醒",
                         help: "背景变化和星数不足只作为提醒，不作为失焦证据；自动重对焦有次数上限。",
                         expandedByDefault: false) {
            Toggle("清晰度异常时暂停等待复核", isOn: $model.quality.autoPause)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
            Toggle("自动重新对焦", isOn: $model.quality.autoRefocus)
                .toggleStyle(.checkbox)
                .font(CinemaFont.label(11))
                .disabled(!model.status.capabilities.contains(.manualFocusDrive))

            InfoRow(label: "合格张数", value: "\(model.quality.qualified)")
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
                         subtitle: model.isTrialRunning ? "拍摄中" : "参数试拍",
                         help: "候选按本次构图与约束比较。镜头档案记录当次条件，历史焦点不作为下一次结果。",
                         expandedByDefault: false) {
            HStack(spacing: 6) {
                Button("快门试拍") { model.runShutterTrial() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.isTrialRunning || model.isRunning)
                Button("光圈试拍") { model.runApertureTrial() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.isTrialRunning || model.isRunning)
                Button("包围试拍") { model.runBracketTrial() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.isTrialRunning || model.isRunning)
                Spacer()
            }

            if model.trialCandidates.isEmpty {
                Text("暂无候选")
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
                                    StatusChip(text: "推荐", color: palette.amber)
                                }
                            }
                            Text(metricText(candidate))
                                .font(CinemaFont.tiny(9))
                                .foregroundStyle(palette.textDim)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("采用") { model.adoptTrial(candidate) }
                            .buttonStyle(CinemaButtonStyle(compact: true))
                    }
                }
            }

            HStack(spacing: 6) {
                Button("保存到镜头档案") { model.saveLensProfile() }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    .disabled(model.trialCandidates.isEmpty)
                Spacer()
                Text("\(model.lensProfileCount) 条档案")
                    .font(CinemaFont.tiny(10))
                    .foregroundStyle(palette.textDim)
            }

        }
    }

    private func metricText(_ candidate: TrialCandidate) -> String {
        var parts: [String] = []
        if let metrics = candidate.metrics {
            parts.append(String(format: "FWHM %.2f", metrics.medianFWHM))
            parts.append("\(metrics.starCount) 星")
            parts.append(String(format: "饱和 %.3f%%", metrics.saturatedFraction * 100))
            parts.append(String(format: "偏心 %.2f", metrics.medianEccentricity))
        } else {
            parts.append("无测量")
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
                         subtitle: "仿真",
                         help: "模拟相机支持曝光、对焦、噪声、移动和故障注入；所有读数均为仿真值。",
                         expandedByDefault: false) {
                Menu("场景：\(model.simulatorCondition.displayName)") {
                    ForEach(SkyCondition.allCases, id: \.rawValue) { condition in
                        Button(condition.displayName) {
                            model.setSimulatorCondition(condition)
                        }
                    }
                }
                .font(CinemaFont.label(11))

                HStack {
                    Text("焦点位置")
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
                    Button("复位焦点") { model.resetSimulatorFocus() }
                        .buttonStyle(CinemaButtonStyle(compact: true))
                    Button("曝光失败") {
                        model.injectSimulatorFault(.failNextCapture("模拟曝光失败"))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    Button("设备忙 2s") {
                        model.injectSimulatorFault(.busy(seconds: 2))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                }
                HStack(spacing: 5) {
                    Button("慢下载 3s") {
                        model.injectSimulatorFault(.slowDownload(seconds: 3))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                    Button("拍 2 张后断连") {
                        model.injectSimulatorFault(.disconnectAfter(2))
                    }
                    .buttonStyle(CinemaButtonStyle(compact: true))
                }

            }
        }
    }
}
