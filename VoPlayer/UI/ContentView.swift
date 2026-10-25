import SwiftUI
import UniformTypeIdentifiers
import VoCore

struct PlayerContainer: NSViewRepresentable {
    let playerView: MPVPlayerView

    func makeNSView(context: Context) -> MPVPlayerView { playerView }
    func updateNSView(_ nsView: MPVPlayerView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: PlayerViewModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerContainer(playerView: model.playerView)
                    .opacity(model.sourceURL == nil ? 0 : 1)

                if model.sourceURL == nil {
                    EmptyStateView(dropTargeted: dropTargeted) { model.showOpenPanel() }
                }

                VStack(spacing: 8) {
                    if model.sourceURL != nil {
                        EnhancedBanner(model: model)
                    }
                    if let message = model.message {
                        ToastView(text: message) { model.message = nil }
                    }
                    Spacer()
                    if model.sourceURL != nil && (controlsVisible || model.isPaused) {
                        ControlBar(model: model)
                            .transition(.opacity)
                    }
                }
                .padding(12)
            }
            .onContinuousHover { phase in
                if case .active = phase { showControlsTemporarily() }
            }
            .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.open(url) } }
                }
                return true
            }

            if model.showEnhancePanel {
                Divider()
                EnhancePanel(model: model)
                    .frame(width: 300)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "Vo Player")
        .onChange(of: model.message) { message in
            guard message != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if model.message == message { model.message = nil }
            }
        }
    }

    private func showControlsTemporarily() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { controlsVisible = false }
        }
    }
}

private struct EmptyStateView: View {
    let dropTargeted: Bool
    let open: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("把视频拖到这里，或按 ⌘O 打开")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("打开视频…", action: open)
                .keyboardShortcut(.defaultAction)
            Text("支持 mp4、mov、mkv、avi、flv、webm、wmv、ts、rmvb 等")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(dropTargeted ? Color.accentColor : Color.gray.opacity(0.4),
                          style: StrokeStyle(lineWidth: 2, dash: [8])))
        .foregroundStyle(.white)
    }
}

/// 顶部：已有修复版时提示并可切换
private struct EnhancedBanner: View {
    @ObservedObject var model: PlayerViewModel

    var body: some View {
        if let job = model.exportJob {
            HStack(spacing: 10) {
                ProgressView(value: job.fraction).frame(width: 160)
                Text("AI 修复中 \(Int(job.fraction * 100))%" + remaining(job.remainingSeconds))
                    .font(.callout)
                Button("取消") { model.cancelExport() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        } else if !model.enhancedVersions.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                Text(model.playingEnhanced ? "正在播放修复版" : "这个视频已有修复版")
                    .font(.callout)
                Picker("", selection: Binding(get: { model.playingEnhanced },
                                              set: { model.setPlayingEnhanced($0) })) {
                    Text("原片").tag(false)
                    Text("修复版").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func remaining(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        return "，约剩 \(PlayerViewModel.formatTime(seconds))"
    }
}

private struct ToastView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .onTapGesture(perform: dismiss)
    }
}
