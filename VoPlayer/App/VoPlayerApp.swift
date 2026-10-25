import AppKit
import SwiftUI

@main
struct VoPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = PlayerViewModel.shared

    var body: some Scene {
        Window("Vo Player", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 1100, height: 680)
        .commands { PlayerCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 启动完成前收到的“用 Vo Player 打开”请求
    private var pendingURL: URL?
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        if let url = pendingURL {
            pendingURL = nil
            Task { @MainActor in PlayerViewModel.shared.open(url) }
        }
    }

    /// 在访达中双击视频、拖到程序坞图标、“打开方式”
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if launched {
            Task { @MainActor in PlayerViewModel.shared.open(url) }
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerViewModel.shared.shutdown() }
    }
}

struct PlayerCommands: Commands {
    @ObservedObject var model: PlayerViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { model.showOpenPanel() }
                .keyboardShortcut("o")
        }

        CommandMenu("播放") {
            Button(model.isPaused ? "播放" : "暂停") { model.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("后退 5 秒") { model.seek(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("前进 5 秒") { model.seek(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("后退 30 秒") { model.seek(by: -30) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("前进 30 秒") { model.seek(by: 30) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("上一帧") { model.frameStep(forward: false) }
                .keyboardShortcut(",", modifiers: [])
            Button("下一帧") { model.frameStep(forward: true) }
                .keyboardShortcut(".", modifiers: [])
            Divider()
            Button("音量 +") { model.adjustVolume(by: 10) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("音量 −") { model.adjustVolume(by: -10) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Divider()
            Button(model.loopMode == .file ? "关闭单个循环" : "单个循环") { model.toggleFileLoop() }
                .keyboardShortcut("l")
            Button("A-B 段循环") { model.cycleABLoop() }
                .keyboardShortcut("b")
            Divider()
            Button("截图到桌面") { model.screenshot() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandMenu("画面") {
            Button("顺时针旋转 90°") { model.rotate(clockwise: true) }
                .keyboardShortcut("r")
            Button("逆时针旋转 90°") { model.rotate(clockwise: false) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("水平翻转") { model.toggleFlip(horizontal: true) }
            Button("垂直翻转") { model.toggleFlip(horizontal: false) }
            Button("恢复默认方向") { model.resetOrientation() }
            Divider()
            Button(model.showEnhancePanel ? "隐藏画面修复面板" : "画面修复面板") { model.showEnhancePanel.toggle() }
                .keyboardShortcut("e")
            Button("昏暗修复（实时）") { model.applyPreset(.lowLight) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("强力提亮（实时）") { model.applyPreset(.veryDark) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("恢复原画") { model.applyPreset(.none) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button("AI 暗光修复并保存") { model.startLocalAIEnhance() }
            Button(model.playingEnhanced ? "切换到原片" : "切换到修复版") {
                model.setPlayingEnhanced(!model.playingEnhanced)
            }
            .keyboardShortcut("t")
            .disabled(model.enhancedVersions.isEmpty)
        }
    }
}
