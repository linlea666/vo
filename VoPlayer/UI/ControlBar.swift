import SwiftUI

/// 底部控制条：播放、进度、循环、旋转、音量、倍速、修复面板
struct ControlBar: View {
    @ObservedObject var model: PlayerViewModel
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(PlayerViewModel.formatTime(scrubbing ? scrubValue : model.position))
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { scrubbing ? scrubValue : model.position },
                    set: { scrubValue = $0 }
                ), in: 0...max(model.duration, 0.1)) { editing in
                    if editing {
                        scrubValue = model.position
                        scrubbing = true
                    } else {
                        model.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
                Text(PlayerViewModel.formatTime(model.duration))
                    .monospacedDigit()
            }
            .font(.caption)

            HStack(spacing: 14) {
                iconButton("gobackward.5", "后退 5 秒 (←)") { model.seek(by: -5) }
                iconButton(model.isPaused ? "play.fill" : "pause.fill", "播放 / 暂停 (空格)") { model.togglePause() }
                    .font(.title2)
                iconButton("goforward.5", "前进 5 秒 (→)") { model.seek(by: 5) }

                Divider().frame(height: 18)

                iconButton("repeat.1", "单个循环 (⌘L)", active: model.loopMode == .file) { model.toggleFileLoop() }
                Button(action: model.cycleABLoop) {
                    Text(abLabel).font(.caption.bold()).frame(minWidth: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.abStart != nil ? Color.accentColor : .primary)
                .help("A-B 段循环：按一次设 A 点，再按设 B 点，第三次取消 (⌘B)")

                iconButton("rotate.left", "逆时针旋转 (⌘⇧R)") { model.rotate(clockwise: false) }
                iconButton("rotate.right", "顺时针旋转 (⌘R)") { model.rotate(clockwise: true) }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "水平翻转",
                           active: model.orientation.flipHorizontal) { model.toggleFlip(horizontal: true) }

                Spacer()

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { s in
                        Button(s == 1 ? "正常" : "\(s.formatted())×") { model.speed = s }
                    }
                } label: {
                    Text(model.speed == 1 ? "1×" : "\(model.speed.formatted())×").font(.caption.bold())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("播放速度")

                Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                Slider(value: $model.volume, in: 0...130).frame(width: 90)

                iconButton("wand.and.stars", "画面修复 (⌘E)", active: model.showEnhancePanel) {
                    model.showEnhancePanel.toggle()
                }
                iconButton("arrow.up.left.and.arrow.down.right", "全屏 (⌃⌘F)") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 900)
    }

    private var abLabel: String {
        if model.abEnd != nil { return "A-B ✓" }
        if model.abStart != nil { return "A-…" }
        return "A-B"
    }

    private func iconButton(_ symbol: String, _ help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : .primary)
        .help(help)
    }
}
