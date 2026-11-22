import AstroFieldKit
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // The app bundle and `swift run` each carry their own copy of the icon.
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
        if let iconURL, let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)

        let env = ProcessInfo.processInfo.environment
        if let spec = env["ASTROFIELD_WINDOW_SIZE"] {
            let parts = spec.lowercased().split(separator: "x")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let window = NSApp.windows.first(where: { $0.isVisible }) {
                        window.setContentSize(NSSize(width: w, height: h))
                        window.center()
                    }
                }
            }
        }
        if let path = env["ASTROFIELD_SHOT_PATH"] {
            let delay = Double(env["ASTROFIELD_SHOT_DELAY"] ?? "3") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.capture(to: path)
                if env["ASTROFIELD_SHOT_EXIT"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            print("screenshot: no visible window")
            return
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("screenshot: no bitmap representation")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("screenshot saved: \(path) window=\(window.windowNumber)")
        }
    }
}

@main
struct AstroFieldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.palette, model.nightMode ? .night : .dark)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandMenu(L10n.text("拍摄")) {
                Button(model.isRunning ? (model.isPaused ? L10n.text("继续") : L10n.text("暂停")) : L10n.text("开始")) {
                    model.toggleStartPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button(L10n.text("停止")) { model.stopSequence() }
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button(L10n.text("试拍一张")) { model.captureOnce() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button(L10n.text("自动对焦")) { model.runAutoFocus() }
                    .keyboardShortcut("f", modifiers: [.command])
            }
            CommandMenu(L10n.text("视图")) {
                Toggle(L10n.text("九宫格"), isOn: $model.showGrid)
                    .keyboardShortcut("g", modifiers: [.command])
                Toggle(L10n.text("星点标记"), isOn: $model.showStarMarkers)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Toggle(L10n.text("夜间模式"), isOn: $model.nightMode)
                    .keyboardShortcut("n", modifiers: [.command])
                Toggle(L10n.text("右侧面板"), isOn: $model.rightPanelVisible)
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}
