import SwiftUI

/// AI 修复前的单帧预览：左边原画、右边修复后，拖动中间分隔线对比；满意再处理整段。
struct EnhancePreviewSheet: View {
    @ObservedObject var model: PlayerViewModel
    @State private var split: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI 暗光修复预览").font(.title3.bold())
            Text("当前画面的修复效果。拖动中间的分隔线对比（左：原画，右：修复后），调好强度再开始处理整段视频。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let preview = model.preview {
                compareView(preview)
                    .frame(minWidth: 560, minHeight: 315)
            }

            HStack {
                Text("修复强度")
                Slider(value: $model.aiStrength, in: 0.3...1, step: 0.05) { editing in
                    if !editing { model.renderPreview() }
                }
                Text("\(Int(model.aiStrength * 100))%").monospacedDigit().frame(width: 44)
                if model.previewRendering { ProgressView().controlSize(.small) }
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.closePreview() }
                    .keyboardShortcut(.cancelAction)
                Button("开始修复整段") { model.confirmPreview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.preview?.after == nil)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    private func compareView(_ preview: PlayerViewModel.EnhancePreview) -> some View {
        let aspect = CGFloat(preview.before.width) / CGFloat(max(preview.before.height, 1))
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Image(decorative: preview.after ?? preview.before, scale: 1)
                    .resizable()
                    .frame(width: w, height: h)
                Image(decorative: preview.before, scale: 1)
                    .resizable()
                    .frame(width: w, height: h)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: w * split)
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: h)
                    .shadow(radius: 2)
                    .offset(x: w * split - 1)
                label("原画").padding(8)
                label(preview.after == nil ? "计算中…" : "修复后")
                    .padding(8)
                    .frame(width: w, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(max(value.location.x / w, 0), 1)
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}
