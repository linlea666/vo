import Foundation

/// 按视频记忆的设置（画面调整、方向），以视频指纹为键，下次打开自动恢复。
public struct VideoSettings: Codable, Equatable, Sendable {
    public var adjustments: VideoAdjustments
    public var orientation: VideoOrientation
    /// 是否默认播放修复版
    public var preferEnhanced: Bool
    public var clarity: AIClarity

    public init(adjustments: VideoAdjustments = .identity, orientation: VideoOrientation = VideoOrientation(),
                preferEnhanced: Bool = true, clarity: AIClarity = .off) {
        self.adjustments = adjustments
        self.orientation = orientation
        self.preferEnhanced = preferEnhanced
        self.clarity = clarity
    }

    private enum CodingKeys: String, CodingKey {
        case adjustments, orientation, preferEnhanced, clarity
    }

    /// 字段缺失时用默认值（兼容旧版本保存的设置，新增字段不会让旧数据整个失效）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try c.decodeIfPresent(VideoAdjustments.self, forKey: .adjustments) ?? .identity
        orientation = try c.decodeIfPresent(VideoOrientation.self, forKey: .orientation) ?? VideoOrientation()
        preferEnhanced = try c.decodeIfPresent(Bool.self, forKey: .preferEnhanced) ?? true
        clarity = try c.decodeIfPresent(AIClarity.self, forKey: .clarity) ?? .off
    }

    public static let `default` = VideoSettings()
}

public final class VideoSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "videoSettings."
    private let indexKey = "videoSettings.recent"
    /// 最多记住多少个视频，超出后丢弃最久没打开的
    public let capacity: Int

    public init(defaults: UserDefaults = .standard, capacity: Int = 500) {
        self.defaults = defaults
        self.capacity = capacity
    }

    public func settings(for fingerprint: String) -> VideoSettings? {
        guard let data = defaults.data(forKey: prefix + fingerprint) else { return nil }
        return try? JSONDecoder().decode(VideoSettings.self, from: data)
    }

    public func save(_ settings: VideoSettings, for fingerprint: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: prefix + fingerprint)

        var recent = defaults.stringArray(forKey: indexKey) ?? []
        recent.removeAll { $0 == fingerprint }
        recent.insert(fingerprint, at: 0)
        if recent.count > capacity {
            for stale in recent[capacity...] {
                defaults.removeObject(forKey: prefix + stale)
            }
            recent = Array(recent.prefix(capacity))
        }
        defaults.set(recent, forKey: indexKey)
    }
}
