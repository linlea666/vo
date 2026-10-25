import SwiftUI
import VoCore

/// 偏好设置：修复结果管理
struct SettingsView: View {
    @ObservedObject var model: PlayerViewModel
    @State private var entries: [EnhancementCache.Entry] = []
    @State private var totalBytes: Int64 = 0
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("修复结果") {
                Toggle("修复版保存到原视频旁边", isOn: $model.saveNextToSource)
                LabeledContent("已保存的修复版", value: "\(entries.filter { $0.status == .completed }.count) 个")
                LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                HStack {
                    Button("在访达中打开缓存目录") {
                        if let dir = model.cache?.enhancedDirectory { NSWorkspace.shared.open(dir) }
                    }
                    Spacer()
                    Button("清空全部修复版…", role: .destructive) { confirmClear = true }
                        .disabled(entries.isEmpty)
                }
            }

            Section("列表") {
                if entries.isEmpty {
                    Text("还没有修复过的视频").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.key) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: entry.sourcePath).lastPathComponent)
                            Text("\(statusText(entry)) · 强度 \(entry.recipe.parameters["strength"] ?? "-") · \(entry.updatedAt.formatted(date: .numeric, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.deleteEnhanced(entry)
                            reload()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .onAppear(perform: reload)
        .confirmationDialog("删除全部修复版？", isPresented: $confirmClear) {
            Button("全部删除", role: .destructive) {
                model.clearAllEnhanced()
                reload()
            }
        } message: {
            Text("修复后的视频文件会被删除，原视频不受影响。")
        }
    }

    private func reload() {
        entries = model.cache?.allEntries ?? []
        totalBytes = model.cache?.totalOutputBytes() ?? 0
    }

    private func statusText(_ entry: EnhancementCache.Entry) -> String {
        switch entry.status {
        case .completed: return "已完成"
        case .processing: return "处理中"
        case .submitted: return "已提交"
        case .failed: return "失败"
        }
    }
}
