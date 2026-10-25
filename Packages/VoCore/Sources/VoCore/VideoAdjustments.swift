import Foundation

/// 实时画面调整（播放时生效，不改原文件）。
///
/// 亮度/对比度/伽马/饱和度对应 mpv 的同名属性（取值 -100...100，在 GPU 上处理）；
/// 降噪、锐化、翻转通过 mpv 的 `vf`（libavfilter）实现。
public struct VideoAdjustments: Codable, Equatable, Sendable {
    public var brightness: Int = 0
    public var contrast: Int = 0
    public var gamma: Int = 0
    public var saturation: Int = 0
    /// 降噪强度 0...10（hqdn3d）
    public var denoise: Int = 0
    /// 锐化强度 0...10（unsharp）
    public var sharpen: Int = 0

    public init(brightness: Int = 0, contrast: Int = 0, gamma: Int = 0, saturation: Int = 0,
                denoise: Int = 0, sharpen: Int = 0) {
        self.brightness = brightness
        self.contrast = contrast
        self.gamma = gamma
        self.saturation = saturation
        self.denoise = denoise
        self.sharpen = sharpen
    }

    public static let identity = VideoAdjustments()

    public var isIdentity: Bool { self == .identity }

    /// 把每一项限制在合法范围内（读取旧数据或手动输入时防越界）
    public func clamped() -> VideoAdjustments {
        func c(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
        return VideoAdjustments(brightness: c(brightness, -100, 100), contrast: c(contrast, -100, 100),
                                gamma: c(gamma, -100, 100), saturation: c(saturation, -100, 100),
                                denoise: c(denoise, 0, 10), sharpen: c(sharpen, 0, 10))
    }

    /// 交给 mpv 的属性值
    public var mpvProperties: [(name: String, value: Int)] {
        let v = clamped()
        return [("brightness", v.brightness), ("contrast", v.contrast),
                ("gamma", v.gamma), ("saturation", v.saturation)]
    }

    /// libavfilter 滤镜（不含翻转），按 降噪 → 锐化 的顺序
    public var lavfiFilters: [String] {
        let v = clamped()
        var filters: [String] = []
        if v.denoise > 0 {
            // hqdn3d=亮度空间:色度空间:亮度时间:色度时间
            let s = Double(v.denoise)
            filters.append("hqdn3d=\(fmt(s * 0.8)):\(fmt(s * 0.6)):\(fmt(s * 1.2)):\(fmt(s * 0.9))")
        }
        if v.sharpen > 0 {
            // unsharp=亮度矩阵宽:高:强度（强度 0.15 ~ 1.5）
            filters.append("unsharp=5:5:\(fmt(Double(v.sharpen) * 0.15))")
        }
        return filters
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// 预设
public enum AdjustmentPreset: String, CaseIterable, Codable, Sendable {
    case none
    /// 昏暗修复：提伽马和亮度、略加对比与饱和，配合降噪压住暗部噪点
    case lowLight
    /// 强力昏暗修复：非常暗的夜景、室内
    case veryDark
    /// 清晰：轻降噪 + 锐化
    case sharpen
    /// 鲜艳
    case vivid

    public var adjustments: VideoAdjustments {
        switch self {
        case .none: return .identity
        case .lowLight: return VideoAdjustments(brightness: 6, contrast: 8, gamma: 30, saturation: 10, denoise: 3)
        case .veryDark: return VideoAdjustments(brightness: 12, contrast: 12, gamma: 55, saturation: 15, denoise: 5)
        case .sharpen: return VideoAdjustments(denoise: 1, sharpen: 4)
        case .vivid: return VideoAdjustments(contrast: 10, saturation: 25)
        }
    }

    public var title: String {
        switch self {
        case .none: return "原画"
        case .lowLight: return "昏暗修复"
        case .veryDark: return "强力提亮"
        case .sharpen: return "清晰"
        case .vivid: return "鲜艳"
        }
    }
}

/// 画面方向：旋转 + 翻转
public struct VideoOrientation: Codable, Equatable, Sendable {
    /// 顺时针角度，只取 0 / 90 / 180 / 270
    public private(set) var rotation: Int = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public init(rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.rotation = Self.normalize(rotation)
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public mutating func rotateClockwise() { rotation = Self.normalize(rotation + 90) }
    public mutating func rotateCounterClockwise() { rotation = Self.normalize(rotation - 90) }

    static func normalize(_ degrees: Int) -> Int {
        let snapped = Int((Double(degrees) / 90).rounded()) * 90
        return ((snapped % 360) + 360) % 360
    }

    public var lavfiFilters: [String] {
        var filters: [String] = []
        if flipHorizontal { filters.append("hflip") }
        if flipVertical { filters.append("vflip") }
        return filters
    }
}

/// 生成 mpv 的 `vf` 字符串；没有滤镜时返回空串（清空滤镜）。
public enum MPVFilterChain {
    public static func vf(adjustments: VideoAdjustments, orientation: VideoOrientation) -> String {
        let filters = adjustments.lavfiFilters + orientation.lavfiFilters
        guard !filters.isEmpty else { return "" }
        return "lavfi=[\(filters.joined(separator: ","))]"
    }
}
