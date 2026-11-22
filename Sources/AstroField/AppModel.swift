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
        case .last: return L10n.text("最后一张")
        case .compare: return L10n.text("对比")
        case .stack: return L10n.text("叠加")
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
        case .full: return L10n.text("全图")
        case .center: return L10n.text("中心")
        case .corners: return L10n.text("四角")
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

enum LiveZoom: Int, CaseIterable, Identifiable {
    case x1 = 1
    case x2 = 2
    case x4 = 4

    var id: Int { rawValue }
    var displayName: String { "\(rawValue)×" }
}

enum StackMode: String, CaseIterable, Identifiable {
    case mean
    case trails

    var id: String { rawValue }
    var displayName: String { self == .mean ? L10n.text("平均叠加") : L10n.text("星轨") }
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

struct AutoExposureUIState {
    var isRunning = false
    var step = 0
    var message = ""
    var samples: [AutoExposureSample] = []
    var result: AutoExposureResult?
}

struct SessionStackUIState {
    var isRunning = false
    var processed = 0
    var total = 0
    var message = ""
    var summary: SessionStackSummary?
    var exportURL: URL?
}

private final class AutoFocusLengthBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    private var sequence = 0

    init(focalLengthMM: Double?) {
        value = focalLengthMM
    }

    var focalLength: Double? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func updateFocalLength(_ focal: Double) {
        lock.lock(); value = focal; lock.unlock()
    }

    func nextSequence() -> Int {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        return -3000 - sequence
    }
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
    @Published var liveAssistEnabled = false
    @Published var liveZoom: LiveZoom = .x1
    @Published var liveStars: [DetectedStar] = []
    @Published var liveFWHM: Double?
    @Published var liveHistogram: [Double] = []
    @Published var liveClipFraction: Double = 0
    @Published var liveStretch = LiveViewStretchSettings.default
    @Published var liveStretchStats: LiveViewStretchStats?
    @Published var keepAlive = true
    @Published var findStarMode = false
    @Published var findStarStatus = ""
    @Published var findStarFocusMessage = ""
    @Published var liveBrightestStar: DetectedStar?
    @Published var finderTestFrameShown = false
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
    @Published var autoExposure = AutoExposureUIState()
    @Published var sessionStack = SessionStackUIState()
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
    @Published var activeGroup: ShootGroup?
    @Published var activeGroupIndex: Int?
    @Published var trialCandidates: [TrialCandidate] = []
    @Published var isTrialRunning = false
    @Published var meteorCandidates: [MeteorCandidate] = []
    @Published var meteorScanning = false
    @Published var focusBracketRunning = false
    @Published var lensProfileCount = 0

    // Dark calibration
    @Published var darkMetas: [MasterDarkMeta] = []
    @Published var darkEnabled = false
    @Published var darkCollecting = false
    @Published var darkProgress = 0
    @Published var darkTarget = 8
    @Published var darkStatus = ""
    @Published var cameraScreenOff = false

    // Session recording
    @Published var sessionInfo: SessionInfo?
    @Published var sessionFrameCount = 0
    @Published var sessionLastExport: URL?
    @Published var panelScrollTarget: String?

    // MARK: - Private state

    private(set) var camera: CameraDevice?
    private var simulator: SimulatorCamera?
    private var runner: SequenceRunner?
    private var runnerTask: Task<Void, Never>?
    private var currentRunID: UUID?
    private var liveTask: Task<Void, Never>?
    private var liveViewStarted = false
    private var liveAnalysisBusy = false
    private var lastLiveAnalysis = Date.distantPast
    private var lastLiveErrorText = ""
    private var lastLiveErrorAt = Date.distantPast
    private var suppressLive = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    private var activityToken: NSObjectProtocol?
    private var finderSavedSettings: ExposureSettings?
    private var finderSavedAssist = false
    private var finderModeStartedAt = Date.distantPast
    private var finderZeroFrames = 0
    private var finderTestAttempted = false
    private var finderTestRunning = false
    private var pendingRestore: ExposureSettings?
    private var analysisChain: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var groupTask: Task<Void, Never>?
    private var groupStopRequested = false
    private let focusCancel = CancelFlag()
    private let autoCancel = CancelFlag()
    private var autoTask: Task<Void, Never>?
    private var stacker: LiveStacker?
    private var trailStacker: StarTrailStacker?
    private var stackedIDs: Set<UUID> = []
    private var qualityEngines: [String: QualityEngine] = [:]
    private var ticker: Timer?
    private var sequenceCounter = 0
    private var userPinnedSelection = false
    private let presetStore = PresetStore()
    private let lensStore = LensProfileStore()
    private let darkLibrary: DarkLibrary
    private let sessionStore: SessionStore
    private var sidecarByFrameID: [UUID: FrameSidecar] = [:]
    private var sessionWriteChain: Task<Void, Never>?
    private var darkRunID: UUID?

    // MARK: - Init

    init() {
        let env = ProcessInfo.processInfo.environment
        let darkDirectory = env["ASTROFIELD_DARK_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        let sessionRoot = env["ASTROFIELD_SESSION_ROOT"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
        darkLibrary = DarkLibrary(directory: darkDirectory)
        sessionStore = SessionStore(root: sessionRoot)
        darkMetas = darkLibrary.all()
        presets = presetStore.load()
        if let last = presetStore.lastPlan() {
            plan = last
        }
        let storedGroups = presetStore.loadGroups()
        if !storedGroups.isEmpty {
            groups = storedGroups
        }
        nightMode = env["ASTROFIELD_NIGHT"] == "1"
        lensProfileCount = lensStore.load().count
        observePowerEvents()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        appendLog(L10n.text("AstroField 启动，默认使用模拟相机"))
        let demo = env["ASTROFIELD_DEMO"]
        if demo == "disconnected" { return }
        if env["ASTROFIELD_SOURCE"] == "nikon" {
            Task {
                await connect(.nikon)
                await runDemoIfNeeded(demo)
            }
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

    /// Power events are recorded next to ICC errors so a dropped session can
    /// be correlated with display or system sleep on the next hardware run.
    private func observePowerEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, String, LogEntry.Level)] = [
            (NSWorkspace.screensDidSleepNotification, L10n.text("显示休眠"), .info),
            (NSWorkspace.screensDidWakeNotification, L10n.text("显示唤醒"), .info),
            (NSWorkspace.willSleepNotification, L10n.text("系统休眠"), .warning),
            (NSWorkspace.didWakeNotification, L10n.text("系统唤醒"), .info)
        ]
        for (name, text, level) in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.appendLog(text, level: level)
                }
            }
        }
    }

    private func runDemoIfNeeded(_ name: String?) async {        guard let name, name != "idle", name != "disconnected" else { return }
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
        case "focusassist":
            setLiveAssist(true)
            setLiveZoom(.x2)
            plan.start = .delay(seconds: 300)
            startSequence()
        case "findstar":
            plan.exposureSeconds = 1
            plan.iso = 1600
            try? await Task.sleep(nanoseconds: 600_000_000)
            enterFindStarMode()
            panelScrollTarget = "viewfinder"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            panelScrollTarget = "viewfinder"
        case "findstarblack":
            setSimulatorCondition(.noStars)
            plan.exposureSeconds = 1
            plan.iso = 1600
            try? await Task.sleep(nanoseconds: 600_000_000)
            enterFindStarMode()
            panelScrollTarget = "viewfinder"
            try? await Task.sleep(nanoseconds: 13_000_000_000)
            panelScrollTarget = "viewfinder"
        case "findstarfocus":
            plan.exposureSeconds = 1
            plan.iso = 1600
            try? await Task.sleep(nanoseconds: 600_000_000)
            enterFindStarMode()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            focusBrightestStar()
            panelScrollTarget = "viewfinder"
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            panelScrollTarget = "viewfinder"
        case "nikonshot":
            plan.exposureSeconds = 1
            plan.iso = 800
            await waitUntil({ !self.focus.isRunning }, timeout: 120)
            captureOnce()
            try? await Task.sleep(nanoseconds: 18_000_000_000)
        case "nikonaf":
            runAutoFocus()
            await waitUntil({ !self.focus.isRunning }, timeout: 120)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        case "nikonseq":
            plan.start = .immediate
            plan.exposureSeconds = 1
            plan.iso = 800
            plan.interval = .afterExposure(seconds: 2)
            plan.end = .count(3)
            startSequence()
            await waitUntil({
                self.progress.phase == .finished
                    || self.progress.phase == .stopped
                    || self.progress.phase == .failed
            }, timeout: 180)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            exportSessionReport()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        case "nikondark":
            plan.exposureSeconds = 1
            plan.iso = 800
            darkTarget = 2
            collectDarks()
            await waitUntil({ !self.darkCollecting }, timeout: 180)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        case "nikonscreen":
            setCameraScreen(off: true)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        case "nikonscreenon":
            setCameraScreen(off: false)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        case "auto":
            plan.exposureSeconds = 8
            plan.iso = 1600
            plan.aperture = 2.8
            plan.focalLengthMM = nil
            runAutoExposure()
            await waitUntil({ !self.autoExposure.isRunning }, timeout: 90)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            panelScrollTarget = "auto"
        case "autostack":
            plan.exposureSeconds = 1.0
            plan.iso = 1600
            var group = ShootGroup.defaults()[0]
            group.plan.exposureSeconds = 1.0
            group.plan.iso = 1600
            group.plan.interval = .afterExposure(seconds: 0.1)
            group.plan.end = .count(3)
            groups = [group]
            startGroupShoot()
            await waitUntil({ !self.groupRunning }, timeout: 60)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            stackSession()
            await waitUntil({ !self.sessionStack.isRunning }, timeout: 120)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            panelScrollTarget = "session"
        case "dark":
            plan.exposureSeconds = 0.5
            plan.iso = 1600
            darkTarget = 2
            collectDarks()
            await waitUntil({ !self.darkCollecting }, timeout: 30)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            captureOnce()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            panelScrollTarget = "dark"
        case "fullchain":
            setSimulatorFocus(380)
            plan.exposureSeconds = 0.5
            plan.iso = 1600
            darkTarget = 3
            collectDarks()
            await waitUntil({ !self.darkCollecting }, timeout: 30)
            var sky = ShootGroup.defaults()[0]
            sky.plan.exposureSeconds = 0.5
            sky.plan.iso = 1600
            sky.plan.interval = .afterExposure(seconds: 0.1)
            sky.plan.end = .count(2)
            var ground = ShootGroup.defaults()[1]
            ground.plan.exposureSeconds = 0.5
            ground.plan.iso = 1600
            ground.plan.interval = .afterExposure(seconds: 0.1)
            ground.plan.end = .count(1)
            ground.focusOffsetSteps = 40
            groups = [sky, ground]
            toggleStacking(true)
            startGroupShoot()
            await waitUntil({ !self.groupRunning }, timeout: 40)
            runAutoFocus()
            await waitUntil({ !self.focus.isRunning }, timeout: 40)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            exportStackImage()
            exportSessionReport()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            panelScrollTarget = "session"
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
            simulator?.faults.append(.failNextCapture(L10n.text("演示：模拟曝光失败")))
            captureOnce()
        default:
            break
        }
    }

    /// Bounded wait used by demos so a slow simulation never captures mid-state.
    private func waitUntil(_ condition: () -> Bool, timeout: Double) async {
        var waited = 0.0
        while !condition() && waited < timeout {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
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

    var canNudgeFocus: Bool {
        guard status.state.isConnected,
              status.capabilities.contains(.manualFocusDrive),
              !findStarMode else { return false }
        switch progress.phase {
        case .exposing, .stopping: return false
        default: return true
        }
    }

    var planIssues: [String] {
        ScheduleCalculator.preflight(plan: plan)
    }

    var sourceLabel: String {
        switch sourceKind {
        case .simulator: return L10n.text("模拟")
        case .playback: return L10n.text("回放")
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
            if let liveImage, liveZoom.rawValue > 1 {
                return ImageCrop.centerCrop(liveImage, zoom: liveZoom.rawValue)
            }
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
            return liveImage == nil ? L10n.text("无画面") : sourceLabel
        case .last:
            if let record = selectedRecord { return record.displayName }
            return L10n.text("无照片")
        case .stack:
            return L10n.text("叠加 %@ 张", stack.accepted)
        case .compare:
            return L10n.text("对比")
        }
    }

    var countdownText: String {
        if let end = progress.exposureEnd, end > now {
            return L10n.text("曝光 ") + formatCountdown(end.timeIntervalSince(now))
        }
        if let next = progress.nextStart, next > now {
            return L10n.text("下一张 ") + formatCountdown(next.timeIntervalSince(now))
        }
        switch progress.phase {
        case .paused: return L10n.text("已暂停")
        case .finished: return L10n.text("已完成")
        case .stopped: return L10n.text("已停止")
        case .failed: return progress.message.isEmpty ? L10n.text("失败") : progress.message
        case .idle: return L10n.text("待机")
        default: return "—"
        }
    }

    var connectionColor: Color {
        switch status.state {
        case .connected, .recovered: return .white.opacity(0.85)
        case .busy: return Palette.dark.amber
        case .connecting, .reconnecting: return Palette.dark.amber
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
            let cam = NikonCamera()
            cam.setLiveStretch(liveStretch)
            cam.onSessionLost = { [weak self] reason in
                Task { @MainActor in
                    self?.handleSessionLost(reason)
                }
            }
            cam.onDiagnostic = { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(L10n.text("ICC：%@", line), level: .warning)
                }
            }
            device = cam
        }
        camera = device
        device.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                // The reconnect loop owns the status text while it runs.
                if self.reconnectTask != nil, !status.state.isConnected { return }
                if case .recovered = self.status.state, case .connected = status.state {
                    return
                }
                self.status = status
                self.updateActivity()
                if case .error(let message) = status.state, self.reconnectTask == nil {
                    self.appendLog(L10n.text("相机错误：%@", message), level: .error)
                }
            }
        }
        do {
            try await device.connect()
            status = device.status
            appendLog(L10n.text("已连接 %@（%@）", device.status.model, kind.displayName))
            updateActivity()
            refreshLiveLoop()
        } catch {
            let message = NikonCamera.connectionMessage(for: error)
            status = CameraStatus(state: .error(message),
                                  model: kind.displayName, capabilities: [],
                                  notes: [L10n.text("连接失败")])
            appendLog(L10n.text("连接失败：%@", error), level: .error)
            showToast(L10n.text("连接失败：%@", message), kind: .error)
        }
        isConnecting = false
    }

    private func teardownCamera() async {
        reconnectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        focusCancel.set()
        autoCancel.set()
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
        liveStretchStats = nil
        findStarMode = false
        findStarStatus = ""
        findStarFocusMessage = ""
        liveBrightestStar = nil
        finderTestAttempted = true
        finderTestRunning = false
        finderTestFrameShown = false
        finderSavedSettings = nil
        finderZeroFrames = 0
        pendingRestore = nil
        stacker = nil
        stackImage = nil
        stack = StackUIState()
        sessionStore.endSession()
        sessionInfo = nil
        sessionFrameCount = 0
        sidecarByFrameID.removeAll()
        cameraScreenOff = false
        status = CameraStatus(state: .disconnected, model: "—", capabilities: [])
        updateActivity()
    }

    func disconnect() {
        Task { await teardownCamera() }
    }

    func choosePlaybackDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("使用此目录")
        panel.message = L10n.text("选择包含 NEF / JPEG 样本的目录")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await connect(.playback, playbackDirectory: url) }
        }
    }

    // MARK: - Live view

    func setLiveAssist(_ enabled: Bool) {
        if findStarMode && !enabled { return }
        liveAssistEnabled = enabled
        if !enabled {
            liveStars = []
            liveBrightestStar = nil
            liveFWHM = nil
            liveHistogram = []
            liveClipFraction = 0
            liveZoom = .x1
        }
    }

    func setLiveZoom(_ zoom: LiveZoom) {
        liveZoom = zoom
    }

    // MARK: - Find stars

    var supportsLiveStretch: Bool {
        sourceKind != .playback && status.capabilities.contains(.liveView)
    }

    var canUseFindStarMode: Bool {
        guard status.state.isConnected, sourceKind != .playback else { return false }
        return !isRunning && !focus.isRunning && !darkCollecting && !isSingleShot
            && !groupRunning && !autoExposure.isRunning && !finderTestRunning
    }

    var canFocusBrightestStar: Bool {
        findStarMode && status.state.isConnected
            && status.capabilities.contains(.manualFocusDrive)
            && liveBrightestStar != nil && !focus.isRunning && !finderTestRunning
    }

    func toggleFindStarMode() {
        if findStarMode {
            exitFindStarMode()
        } else {
            enterFindStarMode()
        }
    }

    func enterFindStarMode() {
        guard let camera, canUseFindStarMode else {
            showToast(L10n.text("当前状态不能进入找星模式"), kind: .warning)
            return
        }
        finderSavedSettings = plan.settings
        finderSavedAssist = liveAssistEnabled
        finderModeStartedAt = Date()
        finderZeroFrames = 0
        finderTestAttempted = false
        finderTestRunning = false
        finderTestFrameShown = false
        liveBrightestStar = nil
        findStarFocusMessage = ""
        findStarMode = true
        liveAssistEnabled = true
        liveZoom = .x1
        if monitorMode != .live { monitorMode = .live }
        findStarStatus = L10n.text("临时 ISO 12800，寻找星点…")
        var boosted = plan.settings
        boosted.iso = 12800
        Task {
            do {
                try await camera.apply(boosted)
                appendLog(L10n.text("找星模式：临时 ISO 12800"), level: .info)
                refreshLiveLoop()
            } catch {
                findStarStatus = L10n.text("设置 ISO 失败：%@", error)
                appendLog(L10n.text("找星模式设置失败：%@", error), level: .error)
                exitFindStarMode()
            }
        }
    }

    func exitFindStarMode() {
        guard findStarMode else { return }
        findStarMode = false
        findStarStatus = ""
        findStarFocusMessage = ""
        liveBrightestStar = nil
        finderTestAttempted = true
        finderTestFrameShown = false
        liveAssistEnabled = finderSavedAssist
        let saved = finderSavedSettings ?? plan.settings
        finderSavedSettings = nil
        guard let camera, status.state.isConnected else {
            pendingRestore = saved
            return
        }
        Task {
            do {
                try await camera.apply(saved)
                appendLog(L10n.text("找星模式退出，已恢复拍摄设置"), level: .info)
            } catch {
                pendingRestore = saved
                appendLog(L10n.text("恢复拍摄设置失败：%@", error), level: .warning)
            }
            refreshLiveLoop()
        }
    }

    func focusBrightestStar() {
        guard let camera, let star = liveBrightestStar, canFocusBrightestStar else { return }
        focusCancel.clear()
        findStarFocusMessage = L10n.text("对焦中…")
        focus = FocusUIState(isRunning: true, samples: [], message: L10n.text("对焦最亮星…"),
                             result: nil, currentFWHM: nil)
        let isSimulator = sourceKind == .simulator
        // A narrow window around the star keeps the search on that star; the
        // camera itself is never moved, only the lens is driven.
        let region = CGRect(x: min(max(0, star.x - 0.10), 0.70),
                            y: min(max(0, star.y - 0.12), 0.70),
                            width: 0.20, height: 0.24)
        focusTask = Task { [weak self] in
            guard let self else { return }
            do {
                suppressLive = true
                liveTask?.cancel()
                liveTask = nil
                if !liveViewStarted {
                    try await camera.startLiveView()
                    liveViewStarted = true
                }
                let cancelFlag = focusCancel
                let probe = ClosureFocusProbe(
                    measure: {
                        if isSimulator,
                           let sim = camera as? SimulatorCamera,
                           let luma = try? await sim.liveLumaPreview() {
                            return StarDetector.measureFast(in: luma, region: region)
                        }
                        if let frame = try await camera.livePreview(),
                           let luma = LumaImage.from(cgImage: frame.image) {
                            return StarDetector.measureFast(in: luma, region: region)
                        }
                        return FocusMeasurement(medianFWHM: 0, starCount: 0,
                                                medianEccentricity: 0)
                    },
                    move: { signed in
                        let direction: FocusDirection = signed > 0 ? .one : .two
                        try await camera.focusDrive(direction: direction, steps: abs(signed))
                    })
                var config = FocusSearchConfig()
                config.minStars = 1
                config.coarseStep = 20
                config.fineStep = 4
                config.maxCoarseMovesPerDirection = 6
                config.verifySamples = 3
                config.minImprovement = 0.04
                let result = await FocusSearcher().run(
                    probe: probe,
                    config: config,
                    onSample: { sample in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.focus.samples.append(sample)
                            self.focus.currentFWHM = sample.measurement.medianFWHM
                            self.focus.message = String(format: L10n.text("步数 %+d，FWHM %.2f"),
                                                        sample.relativeSteps,
                                                        sample.measurement.medianFWHM)
                        }
                    },
                    shouldCancel: { cancelFlag.isSet })
                focus.isRunning = false
                focus.result = result
                focus.message = result.message
                findStarStatus = result.status == .confirmed
                    ? String(format: L10n.text("最亮星已对焦，FWHM %.2f"), result.best?.medianFWHM ?? 0)
                    : L10n.text("最亮星对焦未确认：%@", result.message)
                findStarFocusMessage = result.status == .confirmed
                    ? String(format: L10n.text("已对焦  FWHM %.2f"), result.best?.medianFWHM ?? 0)
                    : L10n.text("未确认：%@", result.message)
                appendLog(L10n.text("找星对焦：%@", result.message),
                          level: result.status == .confirmed ? .info : .warning)
                suppressLive = false
                refreshLiveLoop()
            } catch {
                focus.isRunning = false
                focus.message = L10n.text("对焦失败：%@", error)
                findStarStatus = L10n.text("最亮星对焦失败：%@", error)
                findStarFocusMessage = L10n.text("失败：%@", error)
                appendLog(focus.message, level: .error)
                suppressLive = false
                refreshLiveLoop()
            }
        }
    }

    private func maybeAnalyzeLiveFrame(_ image: CGImage) {
        guard liveAssistEnabled || findStarMode, !liveAnalysisBusy,
              Date().timeIntervalSince(lastLiveAnalysis) > 0.45 else { return }
        liveAnalysisBusy = true
        lastLiveAnalysis = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var stars: [DetectedStar] = []
            var fwhm: Double?
            var histogram: [Double] = []
            var clip = 0.0
            if let luma = LumaImage.from(cgImage: image) {
                let small = luma.downsampled(maxWidth: 700)
                stars = StarDetector.detect(in: small, maxStars: 60).map { star in
                    var copy = star
                    copy.x = star.x / Double(small.width)
                    copy.y = star.y / Double(small.height)
                    return copy
                }
                fwhm = StarDetector.measureFast(
                    in: luma,
                    region: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)).medianFWHM
                histogram = AppModel.histogram(of: small, bins: 48)
                let stride = max(1, luma.pixels.count / 60_000)
                let threshold = luma.maxValue * 0.98
                var clipped = 0
                var sampled = 0
                var i = 0
                while i < luma.pixels.count {
                    if luma.pixels[i] >= threshold { clipped += 1 }
                    sampled += 1
                    i += stride
                }
                clip = sampled > 0 ? Double(clipped) / Double(sampled) : 0
            }
            await MainActor.run {
                if self.liveAssistEnabled || self.findStarMode {
                    self.liveStars = stars
                    self.liveBrightestStar = stars.max { $0.peak < $1.peak }
                    self.liveFWHM = fwhm
                    self.liveHistogram = histogram
                    self.liveClipFraction = clip
                }
                self.considerFinderTestFrame(stars: stars)
                self.liveAnalysisBusy = false
            }
        }
    }

    /// When LiveView stays starless in find mode, fall back to one short JPEG
    /// exposure. It is decoded, stretched and discarded; no session record.
    private func considerFinderTestFrame(stars: [DetectedStar]) {
        guard findStarMode, !finderTestRunning else { return }
        if stars.isEmpty {
            finderZeroFrames += 1
            findStarStatus = L10n.text("未检测到星点")
            guard !finderTestAttempted,
                  finderZeroFrames >= 3,
                  Date().timeIntervalSince(finderModeStartedAt) > 2.5 else { return }
            finderTestAttempted = true
            captureFinderTestFrame()
        } else {
            finderZeroFrames = 0
            findStarStatus = L10n.text("检测到 %@ 颗星", stars.count)
        }
    }

    private func captureFinderTestFrame() {
        guard let camera, findStarMode, !finderTestRunning else { return }
        finderTestRunning = true
        findStarStatus = L10n.text("测试帧：2 s / ISO 12800 / JPEG")
        suppressLive = true
        liveTask?.cancel()
        liveTask = nil
        liveViewStarted = false
        let saved = finderSavedSettings ?? plan.settings
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw: CGImage
                let luma: LumaImage
                if let nikon = camera as? NikonCamera {
                    let frame = try await nikon.captureFinderFrame(iso: 12800, exposureSeconds: 2)
                    raw = frame.image
                    luma = frame.luma
                } else {
                    var test = saved
                    test.iso = 12800
                    test.exposureSeconds = 2
                    test.compression = .jpegFine
                    try await camera.apply(test)
                    let record = try await camera.capture(sequence: -1)
                    guard let analysis = record.analysisLuma
                        ?? record.preview.flatMap({ LumaImage.from(cgImage: $0) }) else {
                        throw CameraError.io(L10n.text("测试帧解码失败"))
                    }
                    let displaySource = analysis.downsampled(maxWidth: 2200)
                    guard let preview = displaySource.displayImage(low: 0,
                                                                   high: max(1, displaySource.maxValue),
                                                                   gamma: 1)
                        ?? record.preview
                        ?? analysis.displayImage() else {
                        throw CameraError.io(L10n.text("测试帧预览失败"))
                    }
                    luma = analysis
                    raw = preview
                }
                if self.findStarMode {
                    let small = luma.downsampled(maxWidth: 1000)
                    let stars = StarDetector.detect(in: small, maxStars: 80).map { star -> DetectedStar in
                        var copy = star
                        copy.x = star.x / Double(small.width)
                        copy.y = star.y / Double(small.height)
                        return copy
                    }
                    self.liveStars = stars
                    self.liveBrightestStar = stars.max { $0.peak < $1.peak }
                    if let display = LiveViewStretch.stretch(raw, settings: self.liveStretch) {
                        self.liveImage = display.image
                        self.liveStretchStats = display.stats
                    } else {
                        self.liveImage = raw
                    }
                    self.finderTestFrameShown = true
                    self.findStarStatus = stars.isEmpty
                        ? L10n.text("测试帧：未检测到星点")
                        : L10n.text("测试帧：检测到 %@ 颗星", stars.count)
                    self.appendLog(L10n.text("找星测试帧：%@ 颗星", stars.count),
                                   level: stars.isEmpty ? .warning : .info)
                }
            } catch {
                findStarStatus = L10n.text("测试帧失败：%@", error)
                appendLog(L10n.text("找星测试帧失败：%@", error), level: .error)
            }
            if self.status.state.isConnected {
                do {
                    try await camera.apply(saved)
                } catch {
                    self.pendingRestore = saved
                    self.appendLog(L10n.text("测试帧后恢复设置失败：%@", error), level: .warning)
                }
            } else {
                self.pendingRestore = saved
            }
            if self.findStarMode {
                // Hold the test frame long enough to be seen, then resume live.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            self.suppressLive = false
            self.finderTestRunning = false
            if self.status.state.isConnected { self.refreshLiveLoop() }
        }
    }

    func refreshLiveLoop() {
        liveTask?.cancel()
        liveTask = nil
        guard let camera, status.state.isConnected,
              status.capabilities.contains(.liveView),
              monitorMode == .live, !suppressLive else { return }
        let nikonPacing = sourceKind == .nikon
        liveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.monitorMode != .live || self.suppressLive { break }
                let frameStart = Date()
                do {
                    if !self.liveViewStarted {
                        try await camera.startLiveView()
                        self.liveViewStarted = true
                    }
                    if let frame = try await camera.livePreview() {
                        guard !Task.isCancelled else { break }
                        self.liveImage = frame.displayImage ?? frame.image
                        self.liveSequence = frame.sequence
                        self.liveStretchStats = frame.stretchStats
                        self.finderTestFrameShown = false
                        self.lastLiveErrorText = ""
                        self.maybeAnalyzeLiveFrame(frame.image)
                    }
                } catch {
                    if Task.isCancelled { break }
                    if self.isSessionLoss(error), self.sourceKind == .nikon {
                        self.liveViewStarted = false
                        self.handleSessionLost(String(describing: error))
                        break
                    }
                    self.logLiveError(error)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                if nikonPacing {
                    let remaining = 1.0 / 15.0 - Date().timeIntervalSince(frameStart)
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 70_000_000)
                }
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

    // MARK: - Display stretch and activity

    func setLiveStretchEnabled(_ enabled: Bool) {
        liveStretch.enabled = enabled
        camera?.setLiveStretch(liveStretch)
    }

    func setLiveStretchGain(_ gain: Double) {
        liveStretch.gainSigma = gain
        camera?.setLiveStretch(liveStretch)
    }

    func setLiveStretchBlack(_ black: Double) {
        liveStretch.blackSigma = black
        camera?.setLiveStretch(liveStretch)
    }

    func setKeepAlive(_ enabled: Bool) {
        keepAlive = enabled
        updateActivity()
    }

    /// Prevents App Nap while a Nikon session is live. Display sleep is still
    /// allowed; the point is to keep the LiveView polling loop at full rate.
    private func updateActivity() {
        let active: Bool
        switch status.state {
        case .connected, .busy, .recovered, .reconnecting:
            active = true
        default:
            active = false
        }
        let should = sourceKind == .nikon && keepAlive && active
        if should, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: L10n.text("AstroField Nikon 会话取景与拍摄"))
        } else if !should, let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - ICC reconnect

    private func handleSessionLost(_ reason: String) {
        guard sourceKind == .nikon, camera is NikonCamera, !isConnecting else { return }
        guard reconnectTask == nil else { return }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        focusCancel.set()
        autoCancel.set()
        liveTask?.cancel()
        liveTask = nil
        liveViewStarted = false
        liveStretchStats = nil
        if isRunning && !isPaused { pauseSequence() }
        let base = status
        status = CameraStatus(state: .reconnecting(attempt: 0,
                                                   maxAttempts: ReconnectPolicy.default.maxAttempts),
                              model: base.model,
                              firmware: base.firmware,
                              lens: base.lens,
                              batteryPercent: base.batteryPercent,
                              capabilities: base.capabilities,
                              notes: [L10n.text("ICC 会话断开：%@", reason)])
        if findStarMode { exitFindStarMode() }
        appendLog(L10n.text("ICC 会话断开：%@", reason), level: .error)
        updateActivity()
        guard let cam = camera as? NikonCamera else { return }
        reconnectTask = Task { [weak self] in
            await self?.runReconnect(cam, generation: generation)
        }
    }

    private func runReconnect(_ cam: NikonCamera, generation: Int) async {
        let policy = ReconnectPolicy.default
        var lastError = L10n.text("未知错误")
        for attempt in 1...policy.maxAttempts {
            guard generation == reconnectGeneration, !Task.isCancelled else { return }
            status.state = .reconnecting(attempt: attempt, maxAttempts: policy.maxAttempts)
            if let delay = policy.delay(beforeAttempt: attempt) {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard generation == reconnectGeneration, !Task.isCancelled else { return }
            do {
                try await cam.reconnect()
                guard generation == reconnectGeneration else { return }
                var recovered = cam.status
                recovered.state = .recovered
                recovered.notes = [L10n.text("ICC 会话已恢复")]
                status = recovered
                liveViewStarted = false
                lastLiveErrorText = ""
                appendLog(L10n.text("ICC 会话已恢复"), level: .info)
                showToast(L10n.text("相机连接已恢复"), kind: .success)
                if let restore = pendingRestore {
                    pendingRestore = nil
                    try? await cam.apply(restore)
                }
                updateActivity()
                reconnectTask = nil
                refreshLiveLoop()
                let token = generation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self, token == self.reconnectGeneration,
                          case .recovered = self.status.state else { return }
                    self.status.state = .connected
                }
                return
            } catch {
                lastError = NikonCamera.connectionMessage(for: error)
                appendLog(L10n.text("重连失败 %@/%@：%@", attempt, policy.maxAttempts, lastError),
                          level: .warning)
            }
        }
        guard generation == reconnectGeneration else { return }
        var failed = status
        failed.state = .error(L10n.text("ICC 重连失败"))
        failed.notes = [L10n.text("已停止重试：%@", lastError)]
        status = failed
        appendLog(L10n.text("ICC 重连失败，停止重试：%@", lastError), level: .error)
        showToast(L10n.text("相机重连失败：%@", lastError), kind: .error)
        reconnectTask = nil
        updateActivity()
    }

    private func isSessionLoss(_ error: Error) -> Bool {
        if let icc = error as? ICCError {
            switch icc {
            case .notConnected, .noCamera, .sessionFailed, .transport:
                return true
            default:
                return false
            }
        }
        if let camError = error as? CameraError, case .disconnected = camError {
            return true
        }
        let text = String(describing: error).lowercased()
        return text.contains("session not open")
            || text.contains("no icc camera")
            || text.contains("session failed")
            || text.contains("transport error")
    }

    private func logLiveError(_ error: Error) {
        let text = String(describing: error)
        guard text != lastLiveErrorText
                || Date().timeIntervalSince(lastLiveErrorAt) > 5 else { return }
        lastLiveErrorText = text
        lastLiveErrorAt = Date()
        appendLog(L10n.text("取景错误：%@", text), level: .warning)
    }

    // MARK: - Sequence

    func startSequence() {
        guard !findStarMode else {
            showToast(L10n.text("先退出找星模式"), kind: .warning)
            return
        }
        guard let camera, runner == nil, !groupRunning, !focus.isRunning else { return }
        beginSessionForNewRun()
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
        appendLog(L10n.text("开始计划：%@", plan.summary))

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
            if let group = activeGroup {
                annotated.note = (record.note ?? "") + L10n.text("，分组 %@", group.displayName)
                annotated.qualityGroup = group.name
            }
            addRecord(annotated, role: .light)
            enqueueAnalysis(annotated)
        case .failed(let index, let message):
            appendLog(L10n.text("第 %@ 张失败：%@", index + 1, message), level: .error)
        case .finished(let progress):
            self.progress = progress
            appendLog(L10n.text("计划结束：%@", progress.message), level: progress.phase == .failed ? .error : .info)
            presetStore.saveLastPlan(plan)
        }
    }

    func captureOnce() {
        guard !findStarMode else {
            showToast(L10n.text("先退出找星模式"), kind: .warning)
            return
        }
        guard let camera, !isSingleShot, !isRunning, !darkCollecting, !focus.isRunning else { return }
        ensureSession()
        isSingleShot = true
        let settings = plan.settings
        Task {
            defer { isSingleShot = false }
            do {
                try await camera.apply(settings)
                sequenceCounter += 1
                let record = try await camera.capture(sequence: sequenceCounter)
                addRecord(record, role: .trial)
                enqueueAnalysis(record)
                appendLog(L10n.text("试拍完成：%@", record.displayName))
            } catch {
                appendLog(L10n.text("试拍失败：%@", error), level: .error)
                showToast(L10n.text("试拍失败：%@", error), kind: .error)
            }
        }
    }

    // MARK: - Records & analysis

    private func addRecord(_ record: ImageRecord, role: SessionRole = .light) {
        records.append(record)
        sequenceCounter = max(sequenceCounter, record.sequence)
        if !userPinnedSelection { selectedID = record.id }
        pruneLuma()
        persistFrame(record, role: role)
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
        let library = darkLibrary
        let darkEnabled = self.darkEnabled
        analysisChain = Task.detached(priority: .utility) { [weak self] in
            await prior?.value
            guard let self else { return }
            var updated = record
            var luma = updated.analysisLuma
            if luma == nil, let url = updated.fileURL {
                luma = ImageLoader.luma(url: url, maxWidth: 2200)
                updated.analysisLuma = luma
                if updated.preview == nil {
                    updated.preview = ImageLoader.preview(url: url, maxWidth: 1800)
                }
            }
            if updated.metrics == nil, let luma {
                var working = luma
                if darkEnabled,
                   let meta = library.match(iso: record.settings.iso,
                                            exposureSeconds: record.settings.exposureSeconds,
                                            source: record.source,
                                            width: luma.width, height: luma.height),
                   let master = library.load(meta: meta) {
                    working = DarkSubtraction.subtract(master, from: luma)
                    updated.darkApplied = Self.darkLabel(meta)
                    updated.preview = working.downsampled(maxWidth: 1200).displayImage()
                    updated.thumbnail = working.downsampledMax(maxWidth: 140).displayImage()
                }
                updated.analysisLuma = working
                updated.metrics = FrameAnalyzer.metrics(working)
            }
            if updated.thumbnail == nil, let luma = updated.analysisLuma {
                updated.thumbnail = luma.downsampledMax(maxWidth: 140).displayImage()
            }
            await MainActor.run {
                self.finishAnalysis(updated)
            }
        }
    }

    nonisolated private static func darkLabel(_ meta: MasterDarkMeta) -> String {
        String(format: L10n.text("暗场 ISO %d / %@ / %d 帧"), meta.iso,
               CapturePlan.formatDuration(meta.exposureSeconds), meta.frameCount)
    }

    private func finishAnalysis(_ record: ImageRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].metrics = record.metrics
        if record.darkApplied != nil {
            // Dark-corrected preview replaces the raw filmstrip image.
            records[index].preview = record.preview ?? records[index].preview
            records[index].thumbnail = record.thumbnail ?? records[index].thumbnail
        } else {
            records[index].preview = records[index].preview ?? record.preview
            records[index].thumbnail = records[index].thumbnail ?? record.thumbnail
        }
        records[index].analysisLuma = record.analysisLuma ?? records[index].analysisLuma
        records[index].darkApplied = record.darkApplied ?? records[index].darkApplied
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
                    showToast(text + L10n.text("，已暂停"), kind: .warning)
                }
            }
            if let target = quality.qualifiedTarget, quality.qualified >= target {
                pauseSequence()
                showToast(L10n.text("合格 %@ 张，已暂停", target), kind: .success)
                quality.qualifiedTarget = nil
            }
        }
        if selectedID == record.id {
            refreshAnalysisView()
        }
        updateSidecar(for: records[index])
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
                appendLog(L10n.text("星轨参考帧已建立"))
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
            appendLog(L10n.text("叠加参考帧已建立"))
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
            analysisNote = L10n.text("正在载入 %@…", record.displayName)
            loadAnalysis(for: record)
        }
    }

    private func loadAnalysis(for record: ImageRecord) {
        guard let url = record.fileURL else { return }
        let mode = analysisCrop
        let nativeWidth = record.width
        let nativeHeight = record.height
        let library = darkLibrary
        let darkEnabled = self.darkEnabled
        Task.detached(priority: .userInitiated) { [weak self] in
            var luma: LumaImage?
            var preview: CGImage?
            if mode == .full {
                luma = ImageLoader.luma(url: url, maxWidth: 1600)
                if let raw = luma, darkEnabled,
                   let meta = library.match(iso: record.settings.iso,
                                            exposureSeconds: record.settings.exposureSeconds,
                                            source: record.source,
                                            width: raw.width, height: raw.height),
                   let master = library.load(meta: meta) {
                    luma = DarkSubtraction.subtract(master, from: raw)
                }
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
                    self.analysisNote = L10n.text("无法解码该文件的分析数据")
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
            analysisNote = L10n.text("全图 %@×%@", source.width, source.height)
            histogram = AppModel.histogram(of: small, bins: 64)
        case .center:
            let rect = AppModel.nativeCropRect(for: .center,
                                               width: source.width, height: source.height)
            if let crop = source.cropped(x: Int(rect.minX), y: Int(rect.minY),
                                         width: Int(rect.width), height: Int(rect.height)) {
                analysisPreview = crop.displayImage()
                analysisMeasurement = StarDetector.measure(in: crop)
                analysisStars = normalized(StarDetector.detect(in: crop, maxStars: 100), in: crop)
                analysisNote = L10n.text("中心裁切 %@×%@", crop.width, crop.height)
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
                analysisNote = L10n.text("1:1 裁切 %@×%@ 像素", crop.width, crop.height)
                histogram = AppModel.histogram(of: crop, bins: 64)
            }
        case .corners:
            let labels = [L10n.text("左上"), L10n.text("右上"), L10n.text("左下"), L10n.text("右下")]
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
            analysisNote = L10n.text("四角裁切，各 %@px", rects.first.map { Int($0.width) } ?? 0)
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
                appendLog(L10n.text("手动对焦：%@ %@ 步", direction == .one ? L10n.text("方向 1") : L10n.text("方向 2"), steps))
            } catch {
                showToast(L10n.text("对焦失败：%@", error), kind: .error)
            }
        }
    }

    func runAutoFocus() {
        guard !findStarMode else {
            showToast(L10n.text("退出找星模式后再运行自动对焦"), kind: .warning)
            return
        }
        guard let camera, !focus.isRunning else { return }
        guard status.capabilities.contains(.manualFocusDrive) else {
            showToast(L10n.text("当前设备不支持电子对焦"), kind: .warning)
            return
        }
        focusCancel.clear()
        focus = FocusUIState(isRunning: true, samples: [], message: L10n.text("准备对焦…"),
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
                            self.focus.message = String(format: L10n.text("步数 %+d，FWHM %.2f"),
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
                self.focus.message = L10n.text("对焦失败：%@", error)
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
        appendLog(L10n.text("自动对焦：%@", result.message),
                  level: result.status == .confirmed ? .info : .warning)
        // Verification capture at the real shooting settings.
        Task {
            do {
                try await camera.apply(settings)
                sequenceCounter += 1000
                let record = try await camera.capture(sequence: sequenceCounter)
                var verified = record
                verified.note = (record.note ?? "") + L10n.text("，对焦验证")
                addRecord(verified, role: .focusVerify)
                enqueueAnalysis(verified)
            } catch {
                appendLog(L10n.text("对焦验证拍摄失败：%@", error), level: .warning)
            }
            suppressLive = false
            refreshLiveLoop()
        }
    }

    // MARK: - Focus bracket

    func runFocusBracket() {
        guard let camera, !isRunning, !focusBracketRunning, !findStarMode else { return }
        guard status.state.isConnected,
              status.capabilities.contains(.manualFocusDrive) else {
            showToast(L10n.text("当前设备不支持电子对焦"), kind: .warning)
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
                    annotated.note = (record.note ?? "") + String(format: L10n.text("，焦点包围 %+d 步"), offset)
                    addRecord(annotated, role: .focusBracket)
                    enqueueAnalysis(annotated)
                }
                if moved != 0 {
                    let direction: FocusDirection = moved > 0 ? .two : .one
                    try await camera.focusDrive(direction: direction, steps: abs(moved))
                }
                appendLog(L10n.text("焦点包围完成：−40 / 0 / +40 步，已回到起始位置"))
                showToast(L10n.text("焦点包围完成（3 张）"), kind: .success)
            } catch {
                appendLog(L10n.text("焦点包围失败：%@", error), level: .error)
                showToast(L10n.text("焦点包围失败：%@", error), kind: .error)
            }
        }
    }

    // MARK: - Trials

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
        guard !findStarMode else {
            showToast(L10n.text("先退出找星模式"), kind: .warning)
            return
        }
        isTrialRunning = true
        trialCandidates = []
        ensureSession()
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
                    // Trial frames do not enter the filmstrip, but they are real
                    // captures and get a session sidecar with their metrics.
                    var persisted = record
                    persisted.metrics = metrics
                    persistFrame(persisted, role: .trial)
                } catch {
                    appendLog(L10n.text("试拍 %@ 失败：%@", label, error), level: .warning)
                }
            }
            try? await camera.apply(original)
            markRecommendedTrial()
            appendLog(L10n.text("参数试拍完成：%@ 个候选", trialCandidates.count))
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
                self.appendLog(L10n.text("发现 %@ 条疑似流星轨迹，可在照片中查看", found.count),
                               level: found.isEmpty ? .info : .warning)
            }
        }
    }

    func saveLensProfile() {
        guard !trialCandidates.isEmpty else {
            showToast(L10n.text("还没有试拍候选"), kind: .warning)
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
        let lens = status.lens ?? (sourceKind == .simulator ? "SIM 35mm f/2.8" : L10n.text("未记录镜头"))
        let entries = lensStore.add(lensName: lens,
                                    cameraModel: status.model,
                                    iso: plan.iso,
                                    note: L10n.text("本组试拍的镜头和曝光设置"),
                                    trials: trials)
        lensProfileCount = entries.count
        showToast(L10n.text("已保存到镜头档案（%@）", lens), kind: .success)
        appendLog(L10n.text("镜头档案新增一条：%@，%@ 个候选", lens, trials.count))
    }

    func adoptTrial(_ candidate: TrialCandidate) {
        plan.exposureSeconds = candidate.exposureSeconds
        if let aperture = candidate.aperture { plan.aperture = aperture }
        presetStore.saveLastPlan(plan)
        appendLog(L10n.text("采用试拍参数：%@", candidate.label), level: .info)
        showToast(L10n.text("已采用 %@", candidate.label), kind: .success)
    }

    // MARK: - Shoot groups

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
        appendLog(L10n.text("分组「%@」已用当前计划更新", groups[index].displayName))
    }

    func loadGroupPlan(_ group: ShootGroup) {
        plan = group.plan
        presetName = group.displayName
        appendLog(L10n.text("载入分组计划：%@", group.displayName))
    }

    func groupSummary(_ group: ShootGroup) -> String {
        let p = group.plan
        var parts: [String] = []
        let countText: String
        switch p.end {
        case .count(let count): countText = L10n.text("%@ 张", count)
        case .duration(let seconds): countText = CapturePlan.formatDuration(seconds)
        case .at: countText = L10n.text("定时结束")
        case .manual: countText = L10n.text("手动结束")
        }
        parts.append("\(CapturePlan.formatDuration(p.exposureSeconds)) × \(countText)")
        parts.append("ISO \(p.iso)")
        if let aperture = p.aperture {
            parts.append(String(format: "f/%.1f", aperture))
        }
        if group.focusOffsetSteps != 0 {
            parts.append(String(format: L10n.text("对焦 %+d"), group.focusOffsetSteps))
        }
        return parts.joined(separator: "   ")
    }

    func startGroupShoot() {
        guard let camera, !isRunning, !findStarMode else { return }
        let runnable = groups.filter { $0.enabled }
        guard !runnable.isEmpty else {
            showToast(L10n.text("没有启用的分组"), kind: .warning)
            return
        }
        beginSessionForNewRun()
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
                    self.progress.message = L10n.text("下一组：%@", group.displayName)
                }
                self.activeGroup = group
                self.activeGroupIndex = self.groups.firstIndex(where: { $0.id == group.id })
                self.qualityEngines[group.name] = QualityEngine()
                self.quality.lastAction = ""
                self.appendLog(L10n.text("分组开始：%@", group.displayName))

                if group.focusOffsetSteps != 0 {
                    let direction: FocusDirection = group.focusOffsetSteps > 0 ? .one : .two
                    do {
                        try await camera.focusDrive(direction: direction,
                                                    steps: abs(group.focusOffsetSteps))
                        netFocus += group.focusOffsetSteps
                    } catch {
                        self.appendLog(L10n.text("分组对焦失败：%@", error), level: .warning)
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
            self.activeGroup = nil
            self.activeGroupIndex = nil
            self.suppressLive = false
            self.liveFrozen = false
            self.refreshLiveLoop()
            self.appendLog(self.groupStopRequested ? L10n.text("分组拍摄已停止") : L10n.text("分组拍摄结束"))
        }
    }

    private func persistGroups() {
        presetStore.saveGroups(groups)
    }

    // MARK: - Star-field auto exposure

    var canRunAutoExposure: Bool {
        status.state.isConnected && !isRunning && !darkCollecting && !isSingleShot
            && !focus.isRunning && !isTrialRunning && !focusBracketRunning
            && !autoExposure.isRunning && !findStarMode
    }

    func runAutoExposure() {
        guard let camera, canRunAutoExposure else {
            showToast(L10n.text("当前状态不能运行自动曝光"), kind: .warning)
            return
        }
        let initial = plan.settings
        let box = AutoFocusLengthBox(focalLengthMM: plan.focalLengthMM)
        let cancel = autoCancel
        cancel.clear()
        autoExposure = AutoExposureUIState(isRunning: true, step: 0,
                                           message: L10n.text("准备"), samples: [], result: nil)
        suppressLive = true
        liveTask?.cancel()
        liveTask = nil
        appendLog(L10n.text("星空自动曝光：开始"))
        let runner = AutoExposureRunner()
        autoTask = Task { [weak self] in
            guard let self else { return }
            let probe: @Sendable (ExposureSettings) async throws -> AutoExposureSample = { settings in
                if cancel.isSet { throw CameraError.unsupported(L10n.text("已取消")) }
                try await camera.apply(settings)
                let record = try await camera.capture(sequence: box.nextSequence())
                if box.focalLength == nil, let url = record.fileURL,
                   let metadata = ImageLoader.metadata(url: url),
                   let focal = metadata.focalLengthMM, focal > 0 {
                    box.updateFocalLength(focal)
                }
                var luma = record.analysisLuma
                if luma == nil, let url = record.fileURL {
                    luma = ImageLoader.luma(url: url, maxWidth: 2200)
                }
                guard let luma else { throw CameraError.captureFailed(L10n.text("无像素")) }
                return AutoExposureSample(settings: settings,
                                          metrics: FrameAnalyzer.metrics(luma),
                                          maxValue: luma.maxValue)
            }
            let result = await runner.run(
                initial: initial,
                focalLengthMM: box.focalLength,
                probe: probe,
                onStep: { sample in
                    await MainActor.run {
                        self.autoExposure.samples.append(sample)
                        self.autoExposure.step += 1
                        self.autoExposure.message = String(
                            format: L10n.text("第 %d 步：ISO %d，%@，背景 %.0f，星点 %d，偏心 %.2f"),
                            self.autoExposure.step, sample.settings.iso,
                            CapturePlan.formatDuration(sample.settings.exposureSeconds),
                            sample.metrics.background, sample.metrics.starCount,
                            sample.metrics.medianEccentricity)
                    }
                })
            await MainActor.run {
                self.finishAutoExposure(result, focalLength: box.focalLength)
            }
        }
    }

    func cancelAutoExposure() {
        autoCancel.set()
        autoExposure.message = L10n.text("正在取消…")
    }

    private func finishAutoExposure(_ result: AutoExposureResult, focalLength: Double?) {
        autoExposure.isRunning = false
        autoExposure.result = result
        autoExposure.message = result.message
        if let focalLength { plan.focalLengthMM = focalLength }
        if result.status.isRecommended {
            plan.iso = result.settings.iso
            plan.exposureSeconds = result.settings.exposureSeconds
            if let aperture = result.settings.aperture { plan.aperture = aperture }
            presetStore.saveLastPlan(plan)
            appendLog(L10n.text("自动曝光已写回：%@", result.message))
            showToast(L10n.text("自动曝光：ISO %@ / %@", plan.iso, CapturePlan.formatDuration(plan.exposureSeconds)),
                      kind: .success)
            if let camera {
                Task { try? await camera.apply(result.settings) }
            }
        } else {
            appendLog(L10n.text("自动曝光未确认：%@", result.status.displayText), level: .warning)
            showToast(L10n.text("自动曝光未确认：%@", result.status.displayText), kind: .warning)
        }
        suppressLive = false
        refreshLiveLoop()
    }

    // MARK: - Dark calibration

    var canCollectDarks: Bool {
        status.state.isConnected && sourceKind != .playback
            && !isRunning && !darkCollecting && !isSingleShot
            && !focus.isRunning && !isTrialRunning && !focusBracketRunning
            && !findStarMode
    }

    var darkSummary: String {
        guard let meta = darkMetas.first else { return L10n.text("尚未采集") }
        return String(format: L10n.text("ISO %d / %@ / %d 帧"), meta.iso,
                      CapturePlan.formatDuration(meta.exposureSeconds), meta.frameCount)
    }

    func collectDarks() {
        guard let camera, canCollectDarks else {
            showToast(L10n.text("当前状态不能采集暗场"), kind: .warning)
            return
        }
        let settings = ExposureSettings(iso: plan.iso,
                                        exposureSeconds: plan.exposureSeconds,
                                        aperture: plan.aperture,
                                        compression: .raw)
        let target = max(1, min(32, darkTarget))
        let source = imageSourceForSession
        let runID = UUID()
        let library = darkLibrary
        darkRunID = runID
        darkCollecting = true
        darkProgress = 0
        darkStatus = L10n.text("准备")
        suppressLive = true
        liveTask?.cancel()
        liveTask = nil
        simulator?.setLensCovered(true)
        appendLog(L10n.text("暗场采集：盖住镜头盖，%@ 张，ISO %@，%@", target, settings.iso, CapturePlan.formatDuration(settings.exposureSeconds)))
        showToast(L10n.text("暗场采集：盖住镜头盖，%@ 张", target), kind: .info)

        Task { [weak self] in
            guard let self else { return }
            let accumulator = DarkAccumulator()
            do {
                try await camera.apply(settings)
                for index in 0..<target {
                    if self.darkRunID != runID { break }
                    self.darkStatus = L10n.text("曝光 %@/%@", index + 1, target)
                    let record = try await camera.capture(sequence: -1000 - index)
                    let luma: LumaImage?
                    if let analysis = record.analysisLuma {
                        luma = analysis
                    } else if let url = record.fileURL {
                        luma = ImageLoader.luma(url: url, maxWidth: 2200)
                    } else {
                        luma = nil
                    }
                    guard let luma else { throw CameraError.downloadFailed(L10n.text("暗场帧无像素")) }
                    try accumulator.add(luma, settings: settings)
                    self.darkProgress = index + 1
                }
                // Median/MAD over a full frame is O(n log n); keep it off the
                // main actor together with the master write.
                let saved = try await Task.detached(priority: .userInitiated) {
                    guard let master = accumulator.build(settings: settings, source: source) else {
                        throw CameraError.captureFailed(L10n.text("暗场累加失败"))
                    }
                    return try library.save(master)
                }.value
                self.darkMetas = library.all()
                if saved.isUsable {
                    self.darkEnabled = true
                    self.darkStatus = String(format: L10n.text("完成：ISO %d / %@ / %d 帧"), saved.iso,
                                             CapturePlan.formatDuration(saved.exposureSeconds),
                                             saved.frameCount)
                    self.appendLog(L10n.text("暗场库新增：%@", self.darkStatus))
                    self.showToast(L10n.text("暗场完成（%@ 帧）", saved.frameCount), kind: .success)
                } else {
                    self.darkEnabled = false
                    self.darkStatus = String(format: L10n.text("分布异常：ISO %d / %@ / %d 帧，未启用"),
                                             saved.iso,
                                             CapturePlan.formatDuration(saved.exposureSeconds),
                                             saved.frameCount)
                    self.appendLog(L10n.text("暗场分布异常，未启用：Core Image 解码的 NEF 暗场不可靠"),
                                   level: .warning)
                    self.showToast(L10n.text("暗场已保存。像素分布异常，已跳过这组暗场"), kind: .warning)
                }
                self.resetQualityAfterDarkChange()
            } catch {
                self.darkStatus = L10n.text("失败")
                self.appendLog(L10n.text("暗场采集失败：%@", error), level: .error)
                self.showToast(L10n.text("暗场采集失败：%@", error), kind: .error)
            }
            self.simulator?.setLensCovered(false)
            try? await camera.apply(self.plan.settings)
            self.darkCollecting = false
            self.darkRunID = nil
            self.suppressLive = false
            self.refreshLiveLoop()
        }
    }

    func setDarkEnabled(_ enabled: Bool) {
        guard darkEnabled != enabled else { return }
        darkEnabled = enabled
        resetQualityAfterDarkChange()
        appendLog(enabled ? L10n.text("暗场减除已启用") : L10n.text("暗场减除已关闭"))
    }

    func refreshDarks() {
        darkMetas = darkLibrary.all()
    }

    func deleteDark(_ meta: MasterDarkMeta) {
        guard darkLibrary.delete(id: meta.id) else { return }
        darkMetas = darkLibrary.all()
        appendLog(L10n.text("已删除暗场 ISO %@ / %@", meta.iso, CapturePlan.formatDuration(meta.exposureSeconds)))
    }

    private func resetQualityAfterDarkChange() {
        qualityEngines.removeAll()
        qualityTimeline.removeAll()
        quality.qualified = 0
    }

    private var imageSourceForSession: ImageSource {
        switch sourceKind {
        case .simulator: return .simulator
        case .playback: return .playback
        case .nikon: return .nikon
        }
    }

    // MARK: - Camera screen

    var canControlCameraScreen: Bool {
        status.state.isConnected && status.capabilities.contains(.monitorControl)
    }

    func setCameraScreen(off: Bool) {
        guard let camera, canControlCameraScreen else {
            showToast(L10n.text("当前设备不支持关屏控制"), kind: .warning)
            return
        }
        Task {
            do {
                try await camera.setScreen(on: !off)
                cameraScreenOff = off
                appendLog(off ? L10n.text("已请求关闭相机屏") : L10n.text("已请求打开相机屏"))
                showToast(off ? L10n.text("已请求关屏") : L10n.text("已请求开屏"), kind: .info)
            } catch {
                appendLog(L10n.text("相机屏控制失败：%@", error), level: .warning)
                showToast(L10n.text("相机屏控制失败：%@", error), kind: .error)
            }
        }
    }

    // MARK: - Session

    var canExportStack: Bool {
        guard sessionInfo != nil else { return false }
        if stack.mode == .trails { return trailStacker != nil }
        return stacker != nil
    }

    var canStackSession: Bool {
        sessionInfo != nil && sessionFrameCount >= 2 && !sessionStack.isRunning
            && !isRunning && !darkCollecting && !autoExposure.isRunning
    }

    private func beginSessionForNewRun() {
        do {
            let info = try sessionStore.beginSession()
            sessionInfo = info
            sidecarByFrameID.removeAll()
            sessionFrameCount = 0
            appendLog(L10n.text("会话目录：%@", info.directory.path))
        } catch {
            sessionInfo = nil
            sidecarByFrameID.removeAll()
            sessionFrameCount = 0
            appendLog(L10n.text("会话目录创建失败：%@", error), level: .error)
            showToast(L10n.text("会话目录创建失败，照片不会写入会话"), kind: .error)
        }
    }

    private func ensureSession() {
        if sessionInfo == nil { beginSessionForNewRun() }
    }

    private func persistFrame(_ record: ImageRecord, role: SessionRole) {
        guard let session = sessionInfo else { return }
        var sidecar = FrameSidecar(frameID: record.id,
                                   sessionID: session.id,
                                   sequence: record.sequence,
                                   timestamp: record.timestamp,
                                   role: role,
                                   source: record.source,
                                   originalPath: record.fileURL?.path,
                                   settings: record.settings,
                                   width: record.width,
                                   height: record.height,
                                   metrics: record.metrics.map { MetricsSnapshot($0) },
                                   verdict: record.verdict.map { VerdictSnapshot($0) },
                                   qualityGroup: record.qualityGroup,
                                   note: record.note,
                                   darkApplied: record.darkApplied != nil)
        let luma = record.analysisLuma
        let isSimulator = record.source == .simulator
        let store = sessionStore
        let frameID = record.id
        sidecarByFrameID[record.id] = sidecar
        enqueueSessionWrite { [weak self] in
            let written: FrameSidecar
            if isSimulator, let luma {
                written = try store.writeTIFFFrame(luma, sidecar: sidecar)
            } else {
                try store.writeSidecar(sidecar)
                written = sidecar
            }
            await MainActor.run {
                guard let self else { return }
                self.sidecarByFrameID[frameID] = written
                self.sessionFrameCount += 1
            }
        }
    }

    private func updateSidecar(for record: ImageRecord) {
        guard var sidecar = sidecarByFrameID[record.id] else { return }
        sidecar.metrics = record.metrics.map { MetricsSnapshot($0) }
        sidecar.verdict = record.verdict.map { VerdictSnapshot($0) }
        sidecar.qualityGroup = record.qualityGroup
        sidecar.note = record.note
        sidecar.darkApplied = record.darkApplied != nil
        sidecar.width = record.width
        sidecar.height = record.height
        sidecarByFrameID[record.id] = sidecar
        let store = sessionStore
        enqueueSessionWrite {
            try store.writeSidecar(sidecar)
        }
    }

    private func enqueueSessionWrite(_ operation: @escaping @Sendable () async throws -> Void) {
        let prior = sessionWriteChain
        sessionWriteChain = Task.detached(priority: .utility) { [weak self] in
            await prior?.value
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    self?.appendLog(L10n.text("会话写入失败：%@", error), level: .warning)
                }
            }
        }
    }

    func exportStackImage() {
        guard sessionInfo != nil else {
            showToast(L10n.text("先开始一次拍摄"), kind: .warning)
            return
        }
        let image: LumaImage?
        if stack.mode == .trails {
            image = trailStacker?.current()
        } else {
            image = stacker?.currentMean()
        }
        guard let image else {
            showToast(L10n.text("还没有可导出的叠加图"), kind: .warning)
            return
        }
        let name = stack.mode == .trails ? "stack-trails" : "stack-mean"
        let isTrails = stack.mode == .trails
        let store = sessionStore
        enqueueSessionWrite { [weak self] in
            let urls = try store.exportStack(image, name: name)
            await MainActor.run {
                guard let self else { return }
                self.sessionLastExport = urls.tiff
                self.appendLog(L10n.text("已导出%@：%@", isTrails ? L10n.text("星轨") : L10n.text("叠加"), urls.tiff.lastPathComponent))
                self.showToast(L10n.text("已导出 %@", urls.tiff.lastPathComponent), kind: .success)
            }
        }
    }

    func exportSessionReport() {
        guard sessionInfo != nil else {
            showToast(L10n.text("先开始一次拍摄"), kind: .warning)
            return
        }
        let store = sessionStore
        enqueueSessionWrite { [weak self] in
            let urls = try store.writeReport()
            await MainActor.run {
                guard let self else { return }
                self.sessionLastExport = urls.json
                self.appendLog(L10n.text("会话报告：%@", urls.json.lastPathComponent))
                self.showToast(L10n.text("报告已写入会话目录"), kind: .success)
            }
        }
    }

    func revealSession() {
        guard let directory = sessionInfo?.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// Star-align every light frame in the current session, average them, and
    /// export the result as auto-stack.tif/png.
    func stackSession() {
        guard let session = sessionInfo else {
            showToast(L10n.text("先开始一次拍摄"), kind: .warning)
            return
        }
        guard canStackSession else { return }
        let store = sessionStore
        let directory = session.directory
        let library = darkLibrary
        let darkEnabled = self.darkEnabled
        sessionStack = SessionStackUIState(isRunning: true, processed: 0, total: 0,
                                           message: L10n.text("读取会话…"))
        appendLog(L10n.text("自动叠加：读取会话 %@", session.name))
        Task.detached(priority: .userInitiated) { [weak self] in
            let frames = store.frames(in: directory).filter { $0.role == .light }
            guard frames.count >= 2 else {
                await MainActor.run {
                    self?.finishStack(error: L10n.text("会话里的亮场帧太少（%@）", frames.count))
                }
                return
            }
            await MainActor.run {
                self?.sessionStack.total = frames.count
                self?.sessionStack.message = L10n.text("解码 0/%@", frames.count)
            }
            let stacker = SessionStacker(maxWidth: 2_000)
            var processed = 0
            var decodeFailures = 0
            for sidecar in frames {
                let url: URL?
                if let name = sidecar.fileName {
                    url = directory.appendingPathComponent(name)
                } else if let path = sidecar.originalPath {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = nil
                }
                if let url, var luma = ImageLoader.luma(url: url, maxWidth: 2_000) {
                    if darkEnabled,
                       let meta = library.match(iso: sidecar.settings.iso,
                                                exposureSeconds: sidecar.settings.exposureSeconds,
                                                source: sidecar.source,
                                                width: luma.width, height: luma.height),
                       let master = library.load(meta: meta) {
                        luma = DarkSubtraction.subtract(master, from: luma)
                    }
                    stacker.add(luma)
                } else {
                    decodeFailures += 1
                }
                processed += 1
                await MainActor.run {
                    self?.sessionStack.processed = processed
                    self?.sessionStack.message = L10n.text("解码 %@/%@", processed, frames.count)
                }
            }
            guard let result = stacker.result() else {
                await MainActor.run { self?.finishStack(error: L10n.text("没有可叠加的帧")) }
                return
            }
            do {
                let urls = try store.exportStack(result.image, name: "auto-stack")
                await MainActor.run {
                    guard let self else { return }
                    self.sessionStack.isRunning = false
                    self.sessionStack.summary = result.summary
                    self.sessionStack.exportURL = urls.tiff
                    var message = String(format: L10n.text("叠加 %d 张，拒绝 %d 张，覆盖 %.0f%%"),
                                         result.summary.accepted,
                                         result.summary.rejected,
                                         result.summary.coverage * 100)
                    if decodeFailures > 0 {
                        message += L10n.text("，解码失败 %@", decodeFailures)
                    }
                    if !result.summary.reasonText.isEmpty {
                        message += L10n.text("（%@）", result.summary.reasonText)
                    }
                    self.sessionStack.message = message
                    self.appendLog(L10n.text("自动叠加：%@", message))
                    self.showToast(L10n.text("已导出 %@", urls.tiff.lastPathComponent), kind: .success)
                }
            } catch {
                await MainActor.run { self?.finishStack(error: L10n.text("导出失败：%@", error)) }
            }
        }
    }

    private func finishStack(error: String) {
        sessionStack.isRunning = false
        sessionStack.message = error
        appendLog(L10n.text("自动叠加失败：%@", error), level: .warning)
        showToast(L10n.text("自动叠加失败：%@", error), kind: .warning)
    }

    // MARK: - Presets

    func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showToast(L10n.text("先给预设起个名字"), kind: .warning)
            return
        }
        presets = presetStore.upsert(name: name, plan: plan)
        showToast(L10n.text("已保存预设「%@」", name), kind: .success)
    }

    func loadPreset(_ preset: CapturePreset) {
        plan = preset.plan
        presetName = preset.name
        appendLog(L10n.text("载入预设「%@」", preset.name))
    }

    func deletePreset(_ preset: CapturePreset) {
        presets = presetStore.delete(id: preset.id)
    }

    // MARK: - Simulator controls

    func setSimulatorCondition(_ condition: SkyCondition) {
        simulatorCondition = condition
        simulator?.setCondition(condition)
        appendLog(L10n.text("模拟场景：%@", condition.displayName))
        if simulatorCondition == .noStars { showToast(L10n.text("模拟场景：无星"), kind: .info) }
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
        appendLog(L10n.text("注入模拟故障"))
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
        appendLog(mode == .trails ? L10n.text("叠加模式：星轨（最大值）") : L10n.text("叠加模式：平均"))
    }

    func toggleStacking(_ enabled: Bool) {
        stack.enabled = enabled
        stacker = nil
        trailStacker = nil
        stackedIDs.removeAll()
        stackImage = nil
        if enabled {
            appendLog(L10n.text("叠加已开启，下一张照片作为参考"))
        } else {
            appendLog(L10n.text("叠加已关闭"))
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
        appendLog(L10n.text("叠加已重置"))
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
