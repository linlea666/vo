import Foundation

/// 按视频记忆的设置（画面调整、方向），以视频指纹为键，下次打开自动恢复。
public struct VideoSettings: Codable, Equatable, Sendable {
    public var adjustments: VideoAdjustments
    public var orientation: VideoOrientation
    /// 是否默认播放修复版
    public var preferEnhanced: Bool

    public init(adjustments: VideoAdjustments = .identity, orientation: VideoOrientation = VideoOrientation(),
                preferEnhanced: Bool = true) {
        self.adjustments = adjustments
        self.orientation = orientation
        self.preferEnhanced = preferEnhanced
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
