import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import AFSpikeCore
import AstroFieldKit

enum MonitorMode: String, CaseIterable, Identifiable, Hashable {
    case live
    case last
    case compare
    case stack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: return "LIVE"
        case .last: return "最后一张"
        case .compare: return "对比"
        case .stack: return "叠加"
        }
    }
}

enum AnalysisCropMode: String, CaseIterable, Identifiable, Hashable {
    case full
    case center
    case corners
    case hundred

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return "全图"
        case .center: return "中心"
        case .corners: return "四角"
        case .hundred: return "100%"
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    enum Level: String { case info, warning, error }
    var id = UUID()
    var date = Date()
    var level: Level = .info
    var text: String
}

struct ToastState: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    var id = UUID()
    var kind: Kind
    var text: String
}

struct FocusUIState {
    var isRunning = false
    var samples: [FocusSample] = []
    var message = ""
    var result: FocusSearchResult?
    var currentFWHM: Double?
}

enum StackMode: String, CaseIterable, Identifiable {
    case mean
    case trails

    var id: String { rawValue }
    var displayName: String { self == .mean ? "平均叠加" : "星轨" }
}

struct StackUIState {
    var enabled = false
    var mode: StackMode = .mean
    var accepted = 0
    var rejected = 0
    var coverage: Double = 0
    var shiftText = "—"
    var totalExposure: Double = 0
    var maxGap: Double = 0
    var gapCount = 0
    var lastReason: String?
}

struct QualityUIState {
    var qualifiedTarget: Int?
    var qualified = 0
    var lastAction = ""
    var autoPause = true
    var autoRefocus = false
}

struct QualityPoint: Identifiable, Equatable {
    var id = UUID()
    var sequence: Int
    var fwhm: Double
    var background: Double
    var stars: Int
    var verdict: QualityVerdict
}

struct GroupTotals: Equatable {
    var exposed = 0
    var saved = 0
    var failed = 0
}

struct TrialCandidate: Identifiable {
    var id = UUID()
    var label: String
    var exposureSeconds: Double
    var aperture: Double?
    var metrics: FrameMetrics?
    var measurement: FocusMeasurement?
    var preview: CGImage?
    var note: String
    var recommended = false
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock(); value = true; lock.unlock()
    }
    func clear() {
        lock.lock(); value = false; lock.unlock()
    }
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Published state

    @Published var sourceKind: CameraKind = .simulator
    @Published var status = CameraStatus(state: .disconnected, model: "—", capabilities: [])
    @Published var isConnecting = false
    @Published var isSingleShot = false

    @Published var plan = CapturePlan()
    @Published var presets: [CapturePreset] = []
    @Published var presetName = ""

    @Published var progress = SequenceProgress()
    @Published var records: [ImageRecord] = []
    @Published var selectedID: UUID?
    @Published var monitorMode: MonitorMode = .live
    @Published var liveImage: CGImage?
    @Published var liveSequence: UInt64 = 0
    @Published var liveFrozen = false
    @Published var stackImage: CGImage?
    @Published var now = Date()

    @Published var showGrid = false
    @Published var showStarMarkers = false
    @Published var nightMode = false
    @Published var rightPanelVisible = true

    @Published var analysisCrop: AnalysisCropMode = .full
    @Published var analysisPreview: CGImage?
    @Published var analysisMetrics: FrameMetrics?
    @Published var analysisMeasurement: FocusMeasurement?
    @Published var analysisStars: [DetectedStar] = []
    @Published var analysisNote = ""
    @Published var histogram: [Double] = []
    @Published var cornerFWHM: [String: Double] = [:]

    @Published var focus = FocusUIState()
    @Published var stack = StackUIState()
    @Published var quality = QualityUIState()
    @Published var qualityTimeline: [QualityPoint] = []

    @Published var logs: [LogEntry] = []
    @Published var toast: ToastState?

    @Published var simulatorCondition: SkyCondition = .clear
    @Published var simulatorFocusPosition: Double = 500
    @Published var playbackDirectory: URL?
    @Published var groups: [ShootGroup] = ShootGroup.defaults()
    @Published var groupRunning = false
    @Published var groupModeActive = false
    @Published var groupTotals = GroupTotals()
    @Published var activeGroupName: String?
    @Published var activeGroupIndex: Int?
    @Published var trialCandidates: [TrialCandidate] = []
    @Published var isTrialRunning = false
    @Published var meteorCandidates: [MeteorCandidate] = []
    @Published var meteorScanning = false
    @Published var focusBracketRunning = false
    @Published var lensProfileCount = 0

    // MARK: - Private state

    private(set) var camera: CameraDevice?
    private var simulator: SimulatorCamera?
    private var runner: SequenceRunner?
    private var runnerTask: Task<Void, Never>?
    private var currentRunID: UUID?
    private var liveTask: Task<Void, Never>?
    private var liveViewStarted = false
    private var suppressLive = false
    private var analysisChain: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var groupTask: Task<Void, Never>?
    private var groupStopRequested = false
    private let focusCancel = CancelFlag()
    private var stacker: LiveStacker?
    private var trailStacker: StarTrailStacker?
    private var stackedIDs: Set<UUID> = []
    private var qualityEngines: [String: QualityEngine] = [:]
    private var ticker: Timer?
    private var sequenceCounter = 0
    private var userPinnedSelection = false
    private let presetStore = PresetStore()
    private let lensStore = LensProfileStore()

    // MARK: - Init

    init() {
        presets = presetStore.load()
        if let last = presetStore.lastPlan() {
            plan = last
        }
        let storedGroups = presetStore.loadGroups()
        if !storedGroups.isEmpty {
            groups = storedGroups
        }
        nightMode = ProcessInfo.processInfo.environment["ASTROFIELD_NIGHT"] == "1"
        lensProfileCount = lensStore.load().count
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        appendLog("AstroField 启动，默认使用模拟相机")
        let env = ProcessInfo.processInfo.environment
        let demo = env["ASTROFIELD_DEMO"]
        if demo == "disconnected" { return }
        if env["ASTROFIELD_SOURCE"] == "nikon" {
            Task { await connect(.nikon) }
            return
        }
        if let dir = env["ASTROFIELD_PLAYBACK_DIR"] {
            let url = URL(fileURLWithPath: dir)
            Task {
                await connect(.playback, playbackDirectory: url)
                await runDemoIfNeeded(demo)
            }
            return
        }
        Task {
            await connect(.simulator)
            await runDemoIfNeeded(demo)
        }
    }

    private func runDemoIfNeeded(_ name: String?) async {
        guard let name, name != "idle", name != "disconnected" else { return }
        switch name {
        case "exposing":
            plan.start = .delay(seconds: 2)
            plan.exposureSeconds = 15
            plan.interval = .afterExposure(seconds: 3)
            plan.end = .count(5)
            startSequence()
        case "waiting":
            plan.start = .delay(seconds: 60)
            plan.end = .count(3)
            startSequence()
        case "focus":
            setSimulatorFocus(380)
            plan.start = .delay(seconds: 120)
            startSequence()
            try? await Task.sleep(nanoseconds: 800_000_000)
            runAutoFocus()
        case "stack":
            plan.start = .immediate
            plan.exposureSeconds = 0.6
            plan.interval = .afterExposure(seconds: 0.1)
            plan.end = .count(6)
            toggleStacking(true)
            startSequence()
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            setMonitorMode(.stack)
        case "analysis", "corners":
            plan.exposureSeconds = 0.5
            captureOnce()
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if name == "corners" {
                setAnalysisCrop(.corners)
            } else {
                setAnalysisCrop(.center)
            }
            setMonitorMode(.last)
        case "paused":
            plan.start = .immediate
            plan.exposureSeconds = 0.5
            plan.interval = .afterExposure(seconds: 0.5)
            plan.end = .manual
            startSequence()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            pauseSequence()
        case "trial":
            plan.exposureSeconds = 0.8
            plan.start = .delay(seconds: 120)
            try? await Task.sleep(nanoseconds: 400_000_000)
            runShutterTrial()
        case "compare":
            plan.exposureSeconds = 0.4
            captureOnce()
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            captureOnce()
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            setMonitorMode(.compare)
        case "focusbracket":
            setSimulatorFocus(380)
            plan.exposureSeconds = 0.4
            try? await Task.sleep(nanoseconds: 500_000_000)
            runFocusBracket()
        case "trails":
            simulator?.updateScene { scene in
                scene.driftX = 12
                scene.driftY = 3
            }
            plan.start = .immediate
            plan.exposureSeconds = 1.0
            plan.interval = .afterExposure(seconds: 0.1)
            plan.end = .count(5)
            toggleStacking(true)
            setStackMode(.trails)
            startSequence()
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            setMonitorMode(.stack)
        case "groups":
            groups = ShootGroup.defaults()
            groups[0].plan.exposureSeconds = 0.3
            groups[0].plan.interval = .afterExposure(seconds: 0.1)
            groups[0].plan.end = .count(2)
            groups[1].plan.exposureSeconds = 0.5
            groups[1].plan.end = .count(1)
            groups[1].focusOffsetSteps = 40
            try? await Task.sleep(nanoseconds: 400_000_000)
            startGroupShoot()
        case "integration":
            setSimulatorFocus(380)
            plan.start = .delay(seconds: 1)
            plan.exposureSeconds = 0.5
            plan.interval = .afterExposure(seconds: 0.1)
            plan.end = .count(4)
            toggleStacking(true)
            runAutoFocus()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            startSequence()
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            setMonitorMode(.stack)
        case "error":
            simulator?.faults.append(.failNextCapture("演示：模拟曝光失败"))
            captureOnce()
        default:
            break
        }
    }

    // MARK: - Derived

    var isRunning: Bool {
        if groupRunning { return true }
        switch progress.phase {
        case .waitingToStart, .exposing, .waitingInterval, .paused, .stopping:
            return true
        default:
            return false
        }
    }

    var isPaused: Bool { progress.phase == .paused }

    var displayedExposed: Int {
        groupModeActive ? groupTotals.exposed + (groupRunning ? progress.exposed : 0) : progress.exposed
    }

    var displayedSaved: Int {
        groupModeActive ? groupTotals.saved + (groupRunning ? progress.saved : 0) : progress.saved
    }

    var displayedFailed: Int {
        groupModeActive ? groupTotals.failed + (groupRunning ? progress.failed : 0) : progress.failed
    }

    var canAutoFocus: Bool {
        status.state.isConnected
            && status.capabilities.contains(.manualFocusDrive)
            && !isRunning
    }

    var planIssues: [String] {
        ScheduleCalculator.preflight(plan: plan)
    }

    var sourceLabel: String {
        switch sourceKind {
        case .simulator: return "模拟"
        case .playback: return "回放"
        case .nikon: return "Nikon"
        }
    }

    var selectedRecord: ImageRecord? {
        guard let selectedID else { return records.last }
        return records.first { $0.id == selectedID } ?? records.last
    }

    var monitorImage: CGImage? {
        switch monitorMode {
        case .live:
            return liveImage
        case .last:
            if analysisCrop != .full, let analysisPreview {
                return analysisPreview
            }
            return selectedRecord?.preview ?? records.last?.preview
        case .stack:
            return stackImage
        case .compare:
            return selectedRecord?.preview ?? records.last?.preview
        }
    }

    var monitorLabel: String {
        switch monitorMode {
        case .live:
            return liveImage == nil ? "无画面" : sourceLabel
        case .last:
            if let record = selectedRecord { return record.displayName }
            return "无照片"
        case .stack:
            return "叠加 \(stack.accepted) 张"
        case .compare:
            return "对比"
        }
    }

    var countdownText: String {
        if let end = progress.exposureEnd, end > now {
            return "曝光 " + formatCountdown(end.timeIntervalSince(now))
        }
        if let next = progress.nextStart, next > now {
            return "下一张 " + formatCountdown(next.timeIntervalSince(now))
        }
        switch progress.phase {
        case .paused: return "已暂停"
        case .finished: return "已完成"
        case .stopped: return "已停止"
        case .failed: return progress.message.isEmpty ? "失败" : progress.message
        case .idle: return "待机"
        default: return "—"
        }
    }

    var connectionColor: Color {
        switch status.state {
        case .connected: return .white.opacity(0.85)
        case .busy: return Palette.dark.amber
        case .connecting: return Palette.dark.amber
        case .error: return Palette.dark.red
        case .disconnected: return Palette.dark.textDim
        }
    }

    // MARK: - Camera lifecycle

    func connect(_ kind: CameraKind, playbackDirectory: URL? = nil) async {
        guard !isConnecting else { return }
        isConnecting = true
        await teardownCamera()
        sourceKind = kind
        self.playbackDirectory = playbackDirectory
        let device: CameraDevice
        switch kind {
        case .simulator:
            var scene = SimulatorScene()
            scene.condition = simulatorCondition
            scene.liveWidth = 1024
            let sim = SimulatorCamera(scene: scene, settings: plan.settings)
            let savedFocus = simulatorFocusPosition
            sim.setFocus(position: savedFocus)
            simulator = sim
            device = sim
        case .playback:
            device = PlaybackCamera(directory: playbackDirectory)
        case .nikon:
            device = NikonCamera()
        }
        camera = device
        device.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.status = status
                if case .error(let message) = status.state {
                    self.appendLog("相机错误：\(message)", level: .error)
                }
            }
        }
        do {
            try await device.connect()
            status = device.status
            appendLog("已连接 \(device.status.model)（\(kind.displayName)）")
            refreshLiveLoop()
        } catch {
            status = CameraStatus(state: .error(String(describing: error)),
                                  model: kind.displayName, capabilities: [],
                                  notes: ["连接失败"])
            appendLog("连接失败：\(error)", level: .error)
            showToast("连接失败：\(error)", kind: .error)
        }
        isConnecting = false
    }

    private func teardownCamera() async {
        focusCancel.set()
        stopSequence()
        liveTask?.cancel()
        liveTask = nil
        if liveViewStarted {
            await camera?.stopLiveView()
            liveViewStarted = false
        }
        await camera?.disconnect()
        camera = nil
        simulator = nil
        liveImage = nil
        stacker = nil
        stackImage = nil
        stack = StackUIState()
        status = CameraStatus(state: .disconnected, model: "—", capabilities: [])
    }

    func disconnect() {
        Task { await teardownCamera() }
    }

    func choosePlaybackDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此目录"
        panel.message = "选择包含 NEF / JPEG 样本的目录"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await connect(.playback, playbackDirectory: url) }
        }
    }

    // MARK: - Live view

    func refreshLiveLoop() {
        liveTask?.cancel()
        liveTask = nil
        guard let camera, status.capabilities.contains(.liveView),
              monitorMode == .live, !suppressLive else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.monitorMode != .live || self.suppressLive { break }
                do {
                    if !self.liveViewStarted {
                        try await camera.startLiveView()
                        self.liveViewStarted = true
                    }
                    if let frame = try await camera.livePreview() {
                        self.liveImage = frame.image
                        self.liveSequence = frame.sequence
                    }
                } catch {
                    self.appendLog("取景错误：\(error)", level: .warning)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
        }
    }

    func setMonitorMode(_ mode: MonitorMode) {
        monitorMode = mode
        if mode == .stack {
            stackImage = stackImage ?? nil
        }
        refreshLiveLoop()
    }

    // MARK: - Sequence

    func startSequence() {
        guard let camera, runner == nil, !groupRunning else { return }
        groupModeActive = false
        groupTotals = GroupTotals()
        qualityEngines.removeAll()
        quality.qualified = 0
        qualityTimeline.removeAll()
        stackedIDs.removeAll()
        userPinnedSelection = false
        let stackMode = stack.mode
        stack = StackUIState(enabled: stack.enabled)
        stack.mode = stackMode
        stacker = nil
        trailStacker = nil
        stackImage = nil
        let id = UUID()
        currentRunID = id
        suppressLive = false
        let sequenceStart = (records.map { $0.sequence }.max() ?? -1) + 1
        let runner = SequenceRunner(camera: camera, plan: plan,
                                    sequenceStart: sequenceStart)
        self.runner = runner
        appendLog("开始计划：\(plan.summary)")

        runnerTask = Task { [weak self] in
            guard let self else { return }
            let events = await runner.events()
            await runner.start()
            for await event in events {
                guard self.currentRunID == id else { break }
                self.handle(event)
            }
            if self.currentRunID == id {
                self.runner = nil
                self.runnerTask = nil
                self.suppressLive = false
                self.liveFrozen = false
                self.refreshLiveLoop()
            }
        }
    }

    func pauseSequence() {
        guard let runner else { return }
        Task { await runner.pause() }
    }

    func resumeSequence() {
        guard let runner else { return }
        Task { await runner.resume() }
    }

    func stopSequence() {
        if groupRunning { groupStopRequested = true }
        guard let runner else { return }
        Task { await runner.stop() }
    }

    func toggleStartPause() {
        if isRunning {
            if isPaused { resumeSequence() } else { pauseSequence() }
        } else {
            startSequence()
        }
    }

    private func handle(_ event: SequenceRunner.Event) {
        switch event {
        case .progress(let progress):
            self.progress = progress
            if progress.phase == .exposing, !self.suppressLive {
                self.suppressLive = true
                self.liveFrozen = true
                self.liveTask?.cancel()
                self.liveTask = nil
            }
        case .captured(let record):
            var annotated = record
            if let group = activeGroupName {
                annotated.note = (record.note ?? "") + "，分组 \(group)"
                annotated.qualityGroup = group
            }
            addRecord(annotated)
            if stack.enabled, annotated.analysisLuma != nil {
                stackIfNeeded(annotated)
            }
            enqueueAnalysis(annotated)
        case .failed(let index, let message):
            appendLog("第 \(index + 1) 张失败：\(message)", level: .error)
        case .finished(let progress):
            self.progress = progress
            appendLog("计划结束：\(progress.message)", level: progress.phase == .failed ? .error : .info)
            presetStore.saveLastPlan(plan)
        }
    }

    func captureOnce() {
        guard let camera, !isSingleShot, !isRunning else { return }
        isSingleShot = true
        let settings = plan.settings
        Task {
            defer { isSingleShot = false }
            do {
                try await camera.apply(settings)
                sequenceCounter += 1
                let record = try await camera.capture(sequence: sequenceCounter)
                addRecord(record)
                enqueueAnalysis(record)
                appendLog("试拍完成：\(record.displayName)")
            } catch {
                appendLog("试拍失败：\(error)", level: .error)
                showToast("试拍失败：\(error)", kind: .error)
            }
        }
    }

    // MARK: - Records & analysis

    private func addRecord(_ record: ImageRecord) {
        records.append(record)
        sequenceCounter = max(sequenceCounter, record.sequence)
        if !userPinnedSelection { selectedID = record.id }
        pruneLuma()
        if monitorMode == .last { refreshAnalysisView() }
    }

    private func pruneLuma() {
        guard records.count > 14 else { return }
        for index in 0..<(records.count - 14) {
            records[index].analysisLuma = nil
        }
    }

    private func enqueueAnalysis(_ record: ImageRecord) {
        let prior = analysisChain
        analysisChain = Task.detached(priority: .utility) { [weak self] in
            await prior?.value
            guard let self else { return }
            var updated = record
            if updated.metrics == nil {
                if let luma = updated.analysisLuma {
                    updated.metrics = FrameAnalyzer.metrics(luma)
                } else if let url = updated.fileURL,
                          let luma = ImageLoader.luma(url: url, maxWidth: 2200) {
                    updated.analysisLuma = luma
                    updated.metrics = FrameAnalyzer.metrics(luma)
                    if updated.preview == nil {
                        updated.preview = ImageLoader.preview(url: url, maxWidth: 1800)
                    }
                }
            }
            if updated.thumbnail == nil, let luma = updated.analysisLuma {
                updated.thumbnail = luma.downsampledMax(maxWidth: 140).displayImage()
            }
            await MainActor.run {
                self.finishAnalysis(updated)
            }
        }
    }

    private func finishAnalysis(_ record: ImageRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].metrics = record.metrics
        records[index].preview = records[index].preview ?? record.preview
        records[index].thumbnail = records[index].thumbnail ?? record.thumbnail
        records[index].analysisLuma = record.analysisLuma ?? records[index].analysisLuma
        if let metrics = record.metrics {
            let key = record.qualityGroup ?? "default"
            var engine = qualityEngines[key] ?? QualityEngine()
            let (verdict, action) = engine.observe(metrics)
            qualityEngines[key] = engine
            records[index].verdict = verdict
            if verdict.isAccepted {
                quality.qualified += 1
            }
            qualityTimeline.append(QualityPoint(sequence: record.sequence,
                                                fwhm: metrics.medianFWHM,
                                                background: metrics.background,
                                                stars: metrics.starCount,
                                                verdict: verdict))
            if qualityTimeline.count > 400 { qualityTimeline.removeFirst(qualityTimeline.count - 400) }
            switch action {
            case .none:
                break
            case .notice(let text):
                quality.lastAction = text
                appendLog(text, level: .warning)
            case .pauseForReview(let text):
                quality.lastAction = text
                appendLog(text, level: .warning)
                if quality.autoPause { pauseSequence() }
            case .suggestRefocus(let text):
                quality.lastAction = text
                appendLog(text, level: .warning)
                if quality.autoRefocus, canAutoFocus {
                    runAutoFocus()
                } else if quality.autoPause {
                    pauseSequence()
                    showToast(text + "，已暂停", kind: .warning)
                }
            }
            if let target = quality.qualifiedTarget, quality.qualified >= target {
                pauseSequence()
                showToast("合格 \(target) 张，已暂停", kind: .success)
                quality.qualifiedTarget = nil
            }
        }
        if selectedID == record.id {
            refreshAnalysisView()
        }
        stackIfNeeded(records[index])
    }

    private func stackIfNeeded(_ record: ImageRecord) {
        guard stack.enabled, !stackedIDs.contains(record.id),
              let luma = record.analysisLuma else { return }
        stackedIDs.insert(record.id)

        if stack.mode == .trails {
            if let trailStacker {
                let exposure = record.settings.exposureSeconds
                let timestamp = record.timestamp
                Task.detached(priority: .utility) { [weak self] in
                    let update = trailStacker.add(luma, exposureSeconds: exposure,
                                                  timestamp: timestamp)
                    await MainActor.run { self?.applyTrailUpdate(update) }
                }
            } else {
                let created = StarTrailStacker(reference: luma,
                                               referenceExposure: record.settings.exposureSeconds,
                                               referenceTimestamp: record.timestamp,
                                               maxWidth: 1000)
                trailStacker = created
                stack.accepted = 1
                stack.totalExposure = record.settings.exposureSeconds
                stack.lastReason = nil
                appendLog("星轨参考帧已建立")
            }
            return
        }

        if let stacker {
            Task.detached(priority: .utility) { [weak self] in
                let update = stacker.add(luma)
                await MainActor.run { self?.applyStackUpdate(update) }
            }
        } else {
            stacker = LiveStacker(reference: luma, maxWidth: 1000)
            stack.accepted = 1
            stack.coverage = 1
            appendLog("叠加参考帧已建立")
        }
    }

    private func applyTrailUpdate(_ update: StarTrailUpdate) {
        stack.accepted = update.frames
        stack.rejected = update.rejected
        stack.totalExposure = update.totalExposure
        stack.maxGap = update.maxGap
        stack.gapCount = update.gapCount
        stack.lastReason = update.reason
        if let preview = update.preview {
            stackImage = preview
        }
    }

    private func applyStackUpdate(_ update: StackUpdate) {
        stack.accepted = update.acceptedCount
        stack.rejected = update.rejectedCount
        stack.coverage = update.coverage
        stack.lastReason = update.reason
        if let shift = update.shift {
            stack.shiftText = "\(shift.dx), \(shift.dy) px"
        }
        if let preview = update.preview {
            stackImage = preview
        }
    }

    // MARK: - Selection & analysis view

    func selectRecord(_ record: ImageRecord) {
        selectedID = record.id
        userPinnedSelection = true
        if monitorMode == .stack { monitorMode = .last }
        refreshAnalysisView()
    }

    func setAnalysisCrop(_ mode: AnalysisCropMode) {
        analysisCrop = mode
        refreshAnalysisView()
    }

    func refreshAnalysisView() {
        guard let record = selectedRecord else {
            analysisPreview = nil
            analysisMetrics = nil
            analysisMeasurement = nil
            analysisStars = []
            histogram = []
            cornerFWHM = [:]
            analysisNote = ""
            return
        }
        analysisMetrics = record.metrics
        if let luma = record.analysisLuma {
            renderAnalysis(from: luma, record: record)
        } else {
            analysisPreview = record.preview
            analysisNote = "正在载入 \(record.displayName)…"
            loadAnalysis(for: record)
        }
    }

    private func loadAnalysis(for record: ImageRecord) {
        guard let url = record.fileURL else { return }
        let mode = analysisCrop
        let nativeWidth = record.width
        let nativeHeight = record.height
        Task.detached(priority: .userInitiated) { [weak self] in
            var luma: LumaImage?
            var preview: CGImage?
            if mode == .full {
                luma = ImageLoader.luma(url: url, maxWidth: 1600)
                preview = ImageLoader.preview(url: url, maxWidth: 1600)
            } else {
                let crop = AppModel.nativeCropRect(for: mode,
                                                   width: nativeWidth,
                                                   height: nativeHeight)
                luma = ImageLoader.luma(url: url, maxWidth: nil, crop: crop)
                preview = ImageLoader.preview(url: url, maxWidth: 1200)
            }
            await MainActor.run {
                guard let self else { return }
                guard let index = self.records.firstIndex(where: { $0.id == record.id }) else { return }
                if mode == .full, let luma {
                    self.records[index].analysisLuma = luma
                }
                if self.records[index].preview == nil { self.records[index].preview = preview }
                if let luma {
                    self.renderAnalysis(from: luma, record: self.records[index])
                } else {
                    self.analysisPreview = self.records[index].preview
                    self.analysisNote = "无法解码该文件的分析数据"
                }
            }
        }
    }

    private func renderAnalysis(from source: LumaImage, record: ImageRecord) {
        let mode = analysisCrop
        switch mode {
        case .full:
            let small = source.downsampled(maxWidth: 1400)
            analysisPreview = small.displayImage()
            let detection = source.downsampled(maxWidth: 900)
            analysisStars = StarDetector.detect(in: detection, maxStars: 80)
                .map { star in
                    var scaled = star
                    scaled.x = star.x / Double(detection.width)
                    scaled.y = star.y / Double(detection.height)
                    return scaled
                }
            analysisNote = "全图 \(source.width)×\(source.height)"
            histogram = AppModel.histogram(of: small, bins: 64)
        case .center:
            let rect = AppModel.nativeCropRect(for: .center,
                                               width: source.width, height: source.height)
            if let crop = source.cropped(x: Int(rect.minX), y: Int(rect.minY),
                                         width: Int(rect.width), height: Int(rect.height)) {
                analysisPreview = crop.displayImage()
                analysisMeasurement = StarDetector.measure(in: crop)
                analysisStars = normalized(StarDetector.detect(in: crop, maxStars: 100), in: crop)
                analysisNote = "中心裁切 \(crop.width)×\(crop.height)"
                histogram = AppModel.histogram(of: crop, bins: 64)
            }
        case .hundred:
            let rect = AppModel.nativeCropRect(for: .hundred,
                                               width: source.width, height: source.height)
            if let crop = source.cropped(x: Int(rect.minX), y: Int(rect.minY),
                                         width: Int(rect.width), height: Int(rect.height)) {
                analysisPreview = crop.displayImage()
                analysisMeasurement = StarDetector.measure(in: crop)
                analysisStars = normalized(StarDetector.detect(in: crop, maxStars: 120), in: crop)
                analysisNote = "1:1 裁切 \(crop.width)×\(crop.height) 像素"
                histogram = AppModel.histogram(of: crop, bins: 64)
            }
        case .corners:
            let labels = ["左上", "右上", "左下", "右下"]
            let rects = AppModel.cornerCrops(width: source.width, height: source.height)
            var images: [CGImage] = []
            var metrics: [String: Double] = [:]
            for (index, rect) in rects.enumerated() {
                guard let crop = source.cropped(x: Int(rect.minX), y: Int(rect.minY),
                                                width: Int(rect.width), height: Int(rect.height)) else { continue }
                if let image = crop.displayImage() { images.append(image) }
                metrics[labels[index]] = StarDetector.measure(in: crop).medianFWHM
            }
            cornerFWHM = metrics
            analysisPreview = AppModel.mosaic(images)
            analysisMeasurement = FocusMeasurement(
                medianFWHM: metrics.values.sorted().dropFirst(metrics.count / 2).first ?? 0,
                starCount: metrics.count, medianEccentricity: 0)
            analysisStars = []
            analysisNote = "四角裁切，各 \(rects.first.map { Int($0.width) } ?? 0)px"
            histogram = AppModel.histogram(of: source.downsampled(maxWidth: 800), bins: 64)
        }
        _ = record
    }

    private func normalized(_ stars: [DetectedStar], in image: LumaImage) -> [DetectedStar] {
        stars.map { star in
            var s = star
            s.x = star.x / Double(image.width)
            s.y = star.y / Double(image.height)
            return s
        }
    }

    // MARK: - Focus

    func cancelFocus() {
        focusCancel.set()
    }

    func nudgeFocus(direction: FocusDirection, steps: Int) {
        guard let camera else { return }
        Task {
            do {
                try await camera.focusDrive(direction: direction, steps: steps)
                appendLog("手动对焦：\(direction == .one ? "方向 1" : "方向 2") \(steps) 步")
            } catch {
                showToast("对焦失败：\(error)", kind: .error)
            }
        }
    }

    func runAutoFocus() {
        guard let camera, !focus.isRunning else { return }
        guard status.capabilities.contains(.manualFocusDrive) else {
            showToast("当前设备不支持电子对焦", kind: .warning)
            return
        }
        focusCancel.clear()
        focus = FocusUIState(isRunning: true, samples: [], message: "准备对焦…",
                             result: nil, currentFWHM: nil)
        let savedSettings = plan.settings
        let focusSettings = ExposureSettings(iso: max(plan.iso, 1600),
                                             exposureSeconds: 1.0,
                                             aperture: plan.aperture,
                                             compression: .jpegFine)
        let isSimulator = sourceKind == .simulator
        focusTask = Task { [weak self] in
            guard let self else { return }
            var startedLive = false
            do {
                suppressLive = true
                liveTask?.cancel()
                try await camera.apply(focusSettings)
                if !liveViewStarted {
                    try await camera.startLiveView()
                    liveViewStarted = true
                    startedLive = true
                }
                let cancelFlag = focusCancel
                let probe = ClosureFocusProbe(
                    measure: {
                        if isSimulator { try? await Task.sleep(nanoseconds: 40_000_000) }
                        let center = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
                        if let sim = camera as? SimulatorCamera,
                           let luma = try? await sim.liveLumaPreview() {
                            let region = StarDetector.measureFast(in: luma, region: center)
                            if region.starCount >= 3 { return region }
                            let whole = StarDetector.measureFast(in: luma)
                            if whole.starCount >= 3 { return whole }
                        }
                        if let frame = try await camera.livePreview(),
                           let luma = LumaImage.from(cgImage: frame.image) {
                            let region = StarDetector.measureFast(in: luma, region: center)
                            if region.starCount >= 3 { return region }
                            let whole = StarDetector.measureFast(in: luma)
                            if whole.starCount >= 3 { return whole }
                        }
                        let record = try await camera.capture(sequence: -1)
                        if let luma = record.analysisLuma {
                            return StarDetector.measureFast(in: luma)
                        }
                        if let preview = record.preview,
                           let luma = LumaImage.from(cgImage: preview) {
                            return StarDetector.measureFast(in: luma)
                        }
                        return FocusMeasurement(medianFWHM: 0, starCount: 0,
                                                medianEccentricity: 0)
                    },
                    move: { signed in
                        let direction: FocusDirection = signed > 0 ? .one : .two
                        try await camera.focusDrive(direction: direction, steps: abs(signed))
                    })
                let result = await FocusSearcher().run(
                    probe: probe,
                    config: FocusSearchConfig(),
                    onSample: { sample in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.focus.samples.append(sample)
                            self.focus.currentFWHM = sample.measurement.medianFWHM
                            self.focus.message = String(format: "步数 %+d，FWHM %.2f",
                                                        sample.relativeSteps,
                                                        sample.measurement.medianFWHM)
                        }
                    },
                    shouldCancel: { cancelFlag.isSet })

                try? await camera.apply(savedSettings)
                if startedLive {
                    await camera.stopLiveView()
                    liveViewStarted = false
                }
                self.finishFocus(result, camera: camera, settings: savedSettings)
            } catch {
                self.focus.isRunning = false
                self.focus.message = "对焦失败：\(error)"
                self.appendLog(focus.message, level: .error)
                self.suppressLive = false
                self.refreshLiveLoop()
            }
        }
    }

    private func finishFocus(_ result: FocusSearchResult, camera: CameraDevice,
                             settings: ExposureSettings) {
        focus.isRunning = false
        focus.result = result
        focus.message = result.message
        appendLog("自动对焦：\(result.message)",
                  level: result.status == .confirmed ? .info : .warning)
        // Verification capture at the real shooting settings.
        Task {
            do {
                try await camera.apply(settings)
                sequenceCounter += 1000
                let record = try await camera.capture(sequence: sequenceCounter)
                var verified = record
                verified.note = (record.note ?? "") + "，对焦验证"
                addRecord(verified)
                enqueueAnalysis(verified)
            } catch {
                appendLog("对焦验证拍摄失败：\(error)", level: .warning)
            }
            suppressLive = false
            refreshLiveLoop()
        }
    }

    // MARK: - Focus bracket (S10-C)

    func runFocusBracket() {
        guard let camera, !isRunning, !focusBracketRunning else { return }
        guard status.state.isConnected,
              status.capabilities.contains(.manualFocusDrive) else {
            showToast("当前设备不支持电子对焦", kind: .warning)
            return
        }
        focusBracketRunning = true
        let settings = plan.settings
        Task {
            defer { focusBracketRunning = false }
            var moved = 0
            do {
                try await camera.apply(settings)
                for offset in [-40, 0, 40] {
                    let delta = offset - moved
                    if delta != 0 {
                        let direction: FocusDirection = delta > 0 ? .one : .two
                        try await camera.focusDrive(direction: direction, steps: abs(delta))
                        moved = offset
                    }
                    sequenceCounter += 1
                    let record = try await camera.capture(sequence: sequenceCounter)
                    var annotated = record
                    annotated.note = (record.note ?? "") + String(format: "，焦点包围 %+d 步", offset)
                    addRecord(annotated)
                    enqueueAnalysis(annotated)
                }
                if moved != 0 {
                    let direction: FocusDirection = moved > 0 ? .two : .one
                    try await camera.focusDrive(direction: direction, steps: abs(moved))
                }
                appendLog("焦点包围完成：−40 / 0 / +40 步，已回到起始位置")
                showToast("焦点包围完成（3 张）", kind: .success)
            } catch {
                appendLog("焦点包围失败：\(error)", level: .error)
                showToast("焦点包围失败：\(error)", kind: .error)
            }
        }
    }

    // MARK: - Trials (S08)

    func runShutterTrial() {
        guard let camera, !isTrialRunning else { return }
        let base = plan.exposureSeconds
        let candidates = [0.5, 1.0, 2.0].map { max(0.3, base * $0) }
        runTrial(candidates: candidates.map { ("\(CapturePlan.formatDuration($0))", $0, plan.aperture) },
                 camera: camera)
    }

    func runApertureTrial() {
        guard let camera, !isTrialRunning else { return }
        let base = plan.aperture ?? 2.8
        let apertures = [base, min(22, base * 1.4), min(22, base * 2.0)]
        runTrial(candidates: apertures.map { (String(format: "f/%.1f", $0), plan.exposureSeconds, $0) },
                 camera: camera)
    }

    private func runTrial(candidates: [(String, Double, Double?)], camera: CameraDevice) {
        isTrialRunning = true
        trialCandidates = []
        let original = plan.settings
        Task {
            defer { isTrialRunning = false }
            for (label, exposure, aperture) in candidates {
                do {
                    let settings = ExposureSettings(iso: original.iso,
                                                    exposureSeconds: exposure,
                                                    aperture: aperture,
                                                    compression: original.compression)
                    try await camera.apply(settings)
                    sequenceCounter += 1
                    let record = try await camera.capture(sequence: sequenceCounter)
                    var luma = record.analysisLuma
                    if luma == nil, let url = record.fileURL {
                        luma = ImageLoader.luma(url: url, maxWidth: 2000)
                    }
                    var metrics: FrameMetrics?
                    var measurement: FocusMeasurement?
                    if let luma {
                        metrics = FrameAnalyzer.metrics(luma)
                        measurement = StarDetector.measure(in: luma)
                    }
                    let candidate = TrialCandidate(label: label,
                                                   exposureSeconds: exposure,
                                                   aperture: aperture,
                                                   metrics: metrics,
                                                   measurement: measurement,
                                                   preview: record.preview,
                                                   note: "ISO \(settings.iso)")
                    trialCandidates.append(candidate)
                } catch {
                    appendLog("试拍 \(label) 失败：\(error)", level: .warning)
                }
            }
            try? await camera.apply(original)
            markRecommendedTrial()
            appendLog("参数试拍完成：\(trialCandidates.count) 个候选")
        }
    }

    private func markRecommendedTrial() {
        guard !trialCandidates.isEmpty else { return }
        var bestIndex: Int?
        var bestScore = -Double.infinity
        for (index, candidate) in trialCandidates.enumerated() {
            guard let metrics = candidate.metrics, metrics.starCount >= 5 else { continue }
            let saturationPenalty = metrics.saturatedFraction * 200
            let eccentricityPenalty = metrics.medianEccentricity * 3
            let fwhmPenalty = metrics.medianFWHM * 0.15
            let score = Double(metrics.starCount) * 0.05 - saturationPenalty
                - eccentricityPenalty - fwhmPenalty
            if score > bestScore { bestScore = score; bestIndex = index }
        }
        if let bestIndex { trialCandidates[bestIndex].recommended = true }
    }

    func runBracketTrial() {
        guard let camera, !isTrialRunning else { return }
        let base = plan.exposureSeconds
        let entries: [(String, Double, Double?)] = [
            ("−1 EV", max(0.1, base * 0.5), plan.aperture),
            ("0 EV", max(0.1, base), plan.aperture),
            ("+1 EV", max(0.1, base * 2.0), plan.aperture)
        ]
        runTrial(candidates: entries, camera: camera)
    }

    func scanForMeteors() {
        guard let record = selectedRecord, !meteorScanning else { return }
        meteorScanning = true
        meteorCandidates = []
        let luma = record.analysisLuma
        let url = record.fileURL
        Task.detached(priority: .userInitiated) { [weak self] in
            var image = luma
            if image == nil, let url {
                image = ImageLoader.luma(url: url, maxWidth: 2600)
            }
            let found = image.map { MeteorDetector.detect(in: $0) } ?? []
            await MainActor.run {
                guard let self else { return }
                self.meteorCandidates = found
                self.meteorScanning = false
                self.appendLog("流星候选扫描：\(found.count) 个（候选，需人工复查）",
                               level: found.isEmpty ? .info : .warning)
            }
        }
    }

    func saveLensProfile() {
        guard !trialCandidates.isEmpty else {
            showToast("还没有试拍候选", kind: .warning)
            return
        }
        let trials = trialCandidates.map { candidate in
            TrialRecord(id: candidate.id,
                        label: candidate.label,
                        exposureSeconds: candidate.exposureSeconds,
                        aperture: candidate.aperture,
                        medianFWHM: candidate.metrics?.medianFWHM,
                        starCount: candidate.metrics?.starCount,
                        saturatedFraction: candidate.metrics?.saturatedFraction,
                        eccentricity: candidate.metrics?.medianEccentricity)
        }
        let lens = status.lens ?? (sourceKind == .simulator ? "SIM 35mm f/2.8" : "未记录镜头")
        let entries = lensStore.add(lensName: lens,
                                    cameraModel: status.model,
                                    iso: plan.iso,
                                    note: "现场参数试拍，条件不可跨夜外推",
                                    trials: trials)
        lensProfileCount = entries.count
        showToast("已保存到镜头档案（\(lens)）", kind: .success)
        appendLog("镜头档案新增一条：\(lens)，\(trials.count) 个候选")
    }

    func adoptTrial(_ candidate: TrialCandidate) {
        plan.exposureSeconds = candidate.exposureSeconds
        if let aperture = candidate.aperture { plan.aperture = aperture }
        presetStore.saveLastPlan(plan)
        appendLog("采用试拍参数：\(candidate.label)", level: .info)
        showToast("已采用 \(candidate.label)", kind: .success)
    }

    // MARK: - Shoot groups (S10-A)

    func setGroupEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].enabled = enabled
        persistGroups()
    }

    func setGroupFocusOffset(_ id: UUID, _ steps: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].focusOffsetSteps = steps
        persistGroups()
    }

    func updateGroupFromPlan(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].plan = plan
        persistGroups()
        appendLog("分组「\(groups[index].name)」已用当前计划更新")
    }

    func loadGroupPlan(_ group: ShootGroup) {
        plan = group.plan
        presetName = group.name
        appendLog("载入分组计划：\(group.name)")
    }

    func groupSummary(_ group: ShootGroup) -> String {
        let p = group.plan
        var parts: [String] = []
        let countText: String
        switch p.end {
        case .count(let count): countText = "\(count) 张"
        case .duration(let seconds): countText = CapturePlan.formatDuration(seconds)
        case .at: countText = "定时结束"
        case .manual: countText = "手动结束"
        }
        parts.append("\(CapturePlan.formatDuration(p.exposureSeconds)) × \(countText)")
        parts.append("ISO \(p.iso)")
        if let aperture = p.aperture {
            parts.append(String(format: "f/%.1f", aperture))
        }
        if group.focusOffsetSteps != 0 {
            parts.append(String(format: "对焦 %+d", group.focusOffsetSteps))
        }
        return parts.joined(separator: "   ")
    }

    func startGroupShoot() {
        guard let camera, !isRunning else { return }
        let runnable = groups.filter { $0.enabled }
        guard !runnable.isEmpty else {
            showToast("没有启用的分组", kind: .warning)
            return
        }
        groupRunning = true
        groupModeActive = true
        groupStopRequested = false
        groupTotals = GroupTotals()
        progress = SequenceProgress()
        let runID = UUID()
        currentRunID = runID
        qualityEngines.removeAll()
        quality.qualified = 0
        qualityTimeline.removeAll()
        stackedIDs.removeAll()
        suppressLive = false
        var netFocus = 0

        groupTask = Task { [weak self] in
            guard let self else { return }
            for (index, group) in runnable.enumerated() {
                if self.groupStopRequested || self.currentRunID != runID { break }
                if index > 0 {
                    self.groupTotals.exposed += self.progress.exposed
                    self.groupTotals.saved += self.progress.saved
                    self.groupTotals.failed += self.progress.failed
                    self.progress = SequenceProgress()
                    self.progress.phase = .waitingToStart
                    self.progress.message = "下一组：\(group.name)"
                }
                self.activeGroupName = group.name
                self.activeGroupIndex = self.groups.firstIndex(where: { $0.id == group.id })
                self.qualityEngines[group.name] = QualityEngine()
                self.quality.lastAction = ""
                self.appendLog("分组开始：\(group.name)")

                if group.focusOffsetSteps != 0 {
                    let direction: FocusDirection = group.focusOffsetSteps > 0 ? .one : .two
                    do {
                        try await camera.focusDrive(direction: direction,
                                                    steps: abs(group.focusOffsetSteps))
                        netFocus += group.focusOffsetSteps
                    } catch {
                        self.appendLog("分组对焦失败：\(error)", level: .warning)
                    }
                }

                let sequenceStart = (self.records.map { $0.sequence }.max() ?? -1) + 1
                let runner = SequenceRunner(camera: camera, plan: group.plan,
                                            sequenceStart: sequenceStart)
                self.runner = runner
                let events = await runner.events()
                await runner.start()
                for await event in events {
                    if self.currentRunID != runID { break }
                    self.handle(event)
                }
                if self.groupStopRequested { break }
            }

            if netFocus != 0 {
                let direction: FocusDirection = netFocus > 0 ? .two : .one
                try? await camera.focusDrive(direction: direction, steps: abs(netFocus))
            }

            self.groupTotals.exposed += self.progress.exposed
            self.groupTotals.saved += self.progress.saved
            self.groupTotals.failed += self.progress.failed
            self.runner = nil
            self.groupRunning = false
            self.activeGroupName = nil
            self.activeGroupIndex = nil
            self.suppressLive = false
            self.liveFrozen = false
            self.refreshLiveLoop()
            self.appendLog(self.groupStopRequested ? "分组拍摄已停止" : "分组拍摄结束")
        }
    }

    private func persistGroups() {
        presetStore.saveGroups(groups)
    }

    // MARK: - Presets

    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showToast("预设名不能为空", kind: .warning)
            return
        }
        presets = presetStore.upsert(name: name, plan: plan)
        showToast("已保存预设「\(name)」", kind: .success)
    }

    func loadPreset(_ preset: CapturePreset) {
        plan = preset.plan
        presetName = preset.name
        appendLog("载入预设「\(preset.name)」")
    }

    func deletePreset(_ preset: CapturePreset) {
        presets = presetStore.delete(id: preset.id)
    }

    // MARK: - Simulator controls

    func setSimulatorCondition(_ condition: SkyCondition) {
        simulatorCondition = condition
        simulator?.setCondition(condition)
        appendLog("模拟场景：\(condition.displayName)")
        if simulatorCondition == .noStars { showToast("模拟场景：无星", kind: .info) }
    }

    func setSimulatorFocus(_ position: Double) {
        simulatorFocusPosition = position
        simulator?.setFocus(position: position)
    }

    func resetSimulatorFocus() {
        simulator?.resetFocusToBest()
        simulatorFocusPosition = 500
    }

    func injectSimulatorFault(_ fault: SimulatorFault) {
        simulator?.faults.append(fault)
        appendLog("注入模拟故障")
    }

    // MARK: - Stacking

    func setStackMode(_ mode: StackMode) {
        guard stack.mode != mode else { return }
        stack.mode = mode
        stacker = nil
        trailStacker = nil
        stackedIDs.removeAll()
        stackImage = nil
        stack.accepted = 0
        stack.rejected = 0
        stack.coverage = 0
        stack.totalExposure = 0
        stack.maxGap = 0
        stack.gapCount = 0
        stack.shiftText = "—"
        stack.lastReason = nil
        appendLog(mode == .trails ? "叠加模式：星轨（最大值）" : "叠加模式：平均")
    }

    func toggleStacking(_ enabled: Bool) {
        stack.enabled = enabled
        stacker = nil
        trailStacker = nil
        stackedIDs.removeAll()
        stackImage = nil
        if enabled {
            appendLog("叠加已开启，下一张照片作为参考")
        } else {
            appendLog("叠加已关闭")
        }
    }

    func resetStack() {
        stacker = nil
        trailStacker = nil
        stackedIDs.removeAll()
        stackImage = nil
        let enabled = stack.enabled
        let mode = stack.mode
        stack = StackUIState(enabled: enabled)
        stack.mode = mode
        appendLog("叠加已重置")
    }

    // MARK: - Logs / toast

    func appendLog(_ text: String, level: LogEntry.Level = .info) {
        logs.append(LogEntry(level: level, text: text))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    func showToast(_ text: String, kind: ToastState.Kind) {
        let state = ToastState(kind: kind, text: text)
        toast = state
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if self?.toast?.id == state.id { self?.toast = nil }
        }
    }

    // MARK: - Formatting / geometry

    func formatCountdown(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    nonisolated static func nativeCropRect(for mode: AnalysisCropMode,
                               width: Int, height: Int) -> CGRect {
        switch mode {
        case .full:
            return CGRect(x: 0, y: 0, width: width, height: height)
        case .center:
            let w = min(width, max(200, Int(Double(width) * 0.4)))
            let h = min(height, max(150, Int(Double(height) * 0.4)))
            return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
        case .hundred:
            let w = min(width, 1600)
            let h = min(height, 1200)
            return CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
        case .corners:
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    nonisolated static func cornerCrops(width: Int, height: Int) -> [CGRect] {
        let w = min(width / 3, 700)
        let h = min(height / 3, 500)
        return [
            CGRect(x: 0, y: 0, width: w, height: h),
            CGRect(x: width - w, y: 0, width: w, height: h),
            CGRect(x: 0, y: height - h, width: w, height: h),
            CGRect(x: width - w, y: height - h, width: w, height: h)
        ]
    }

    nonisolated static func mosaic(_ images: [CGImage]) -> CGImage? {
        guard images.count == 4 else { return images.first }
        let cellW = images.map(\.width).max() ?? 0
        let cellH = images.map(\.height).max() ?? 0
        guard cellW > 0, cellH > 0,
              let ctx = CGContext(data: nil, width: cellW * 2, height: cellH * 2,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return images.first
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cellW * 2, height: cellH * 2))
        for (index, image) in images.enumerated() {
            let x = (index % 2) * cellW
            let y = (index < 2 ? cellH : 0)
            ctx.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
        }
        return ctx.makeImage()
    }

    nonisolated static func histogram(of image: LumaImage, bins: Int) -> [Double] {
        guard !image.pixels.isEmpty, bins > 0 else { return [] }
        var counts = [Double](repeating: 0, count: bins)
        let maxValue = Double(image.maxValue)
        let stride = max(1, image.pixels.count / 120_000)
        var i = 0
        while i < image.pixels.count {
            let normalized = min(1, max(0, Double(image.pixels[i]) / maxValue))
            let bin = min(bins - 1, Int(normalized * Double(bins)))
            counts[bin] += 1
            i += stride
        }
        let maxCount = counts.max() ?? 1
        return counts.map { $0 / maxCount }
    }
}
