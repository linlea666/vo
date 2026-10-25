import Foundation

/// AI 清晰（实时）：播放时由 mpv 在显卡上运行 Anime4K 着色器，不改原文件。
///
/// - 去模糊：Anime4K Restore（Soft 版本，对真人素材更温和），修复模糊和压缩痕迹，任何尺寸都生效
/// - 放大：Anime4K x2 网络（真人实拍权重），只在窗口比视频大 1.2 倍以上时生效，适合低分辨率视频
public struct AIClarity: Codable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case off, low, medium, high

        /// 着色器文件名后缀：S / M / L
        var suffix: String? {
            switch self {
            case .off: return nil
            case .low: return "S"
            case .medium: return "M"
            case .high: return "L"
            }
        }

        public var title: String {
            switch self {
            case .off: return "关"
            case .low: return "轻"
            case .medium: return "中"
            case .high: return "强"
            }
        }
    }

    public var restore: Level
    public var upscale: Level

    public init(restore: Level = .off, upscale: Level = .off) {
        self.restore = restore
        self.upscale = upscale
    }

    public static let off = AIClarity()

    public var isOff: Bool { restore == .off && upscale == .off }

    /// 按顺序交给 mpv 的着色器文件名（位于 App 的 Resources/Shaders）
    public var shaderFiles: [String] {
        var files: [String] = []
        if !isOff { files.append("Clamp_Highlights.glsl") }   // 防止高光处出现振铃
        if let s = restore.suffix { files.append("Restore_Soft_\(s).glsl") }
        if let s = upscale.suffix { files.append("Upscale_RealLife_x2_\(s).glsl") }
        return files
    }
}
