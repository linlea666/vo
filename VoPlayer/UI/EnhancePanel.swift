import SwiftUI
import VoCore

/// 右侧“画面修复”面板：实时调整 + 本地 AI 修复
struct EnhancePanel: View {
    @ObservedObject var model: PlayerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                realTimeSection
                Divider()
                aiSection
                Divider()
                orientationSection
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 实时修复

    private var realTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("实时修复", subtitle: "播放时立即生效，不改原文件，免费")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 6) {
                ForEach(AdjustmentPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { model.applyPreset(preset) }
                        .buttonStyle(.bordered)
                        .tint(model.adjustments == preset.adjustments ? .accentColor : nil)
                }
            }

            slider("亮度", \.brightness, -100...100)
            slider("对比度", \.contrast, -100...100)
            slider("伽马（暗部提亮）", \.gamma, -100...100)
            slider("饱和度", \.saturation, -100...100)
            slider("降噪", \.denoise, 0...10)
            slider("锐化", \.sharpen, 0...10)

            HStack {
                Button("重置") { model.applyPreset(.none) }
                Spacer()
                Text("按住对比原画")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(model.compareOriginal ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 6))
                    .onLongPressGesture(minimumDuration: 0.01, pressing: { model.compareOriginal = $0 }, perform: {})
            }
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<VideoAdjustments, Int>,
                        _ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(model.adjustments[keyPath: keyPath])").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(model.adjustments[keyPath: keyPath]) },
                set: { model.adjustments[keyPath: keyPath] = Int($0.rounded()) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
        }
    }

    // MARK: 本地 AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AI 暗光修复（本地）",
                         subtitle: "Zero-DCE++ 模型在本机运行，免费、视频不上传。处理一次后保存为新文件，以后打开自动使用，不会重复处理。")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("修复强度").font(.caption)
                    Spacer()
                    Text("\(Int(model.aiStrength * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $model.aiStrength, in: 0.3...1, step: 0.05)
                    .disabled(model.exportJob != nil)
            }

            if let job = model.exportJob {
                ProgressView(value: job.fraction) {
                    Text("处理中 \(Int(job.fraction * 100))%").font(.caption)
                }
                Button("取消修复", role: .cancel) { model.cancelExport() }
            } else {
                Button {
                    model.startLocalAIEnhance()
                } label: {
                    Label(model.hasResultForCurrentRecipe ? "播放已修复版本" : "开始 AI 修复并保存",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sourceURL == nil)
            }

            Toggle("修复版保存到原视频旁边", isOn: $model.saveNextToSource)
                .font(.caption)
                .help("关闭时保存在 ~/Library/Application Support/VoPlayer/Enhanced")

            if !model.enhancedVersions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这个视频的修复版").font(.caption.bold())
                    ForEach(model.enhancedVersions, id: \.key) { entry in
                        HStack {
                            Text("强度 \(entry.recipe.parameters["strength"] ?? "-") · \(entry.updatedAt.formatted(date: .numeric, time: .shortened))")
                                .font(.caption)
                            Spacer()
                            Button {
                                model.deleteEnhanced(entry)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .help("删除这个修复版")
                        }
                    }
                    Button("在访达中显示") { model.revealEnhancedInFinder() }
                        .font(.caption)
                }
            }

            Text("提示：AI 修复适合昏暗、夜景、逆光的视频；目前支持 mp4 / mov / m4v。其他格式可先用上面的实时修复。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 方向

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("画面方向", subtitle: "当前旋转 \(model.orientation.rotation)°")
            HStack {
                Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                Button("水平翻转") { model.toggleFlip(horizontal: true) }
                Button("垂直翻转") { model.toggleFlip(horizontal: false) }
            }
            Button("恢复默认方向") { model.resetOrientation() }
                .font(.caption)
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
