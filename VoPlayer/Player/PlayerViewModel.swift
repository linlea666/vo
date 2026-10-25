import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoCore
import VoMedia

/// 播放器的全部状态与操作，界面只读写这里。
@MainActor
final class PlayerViewModel: ObservableObject {
    static let shared = PlayerViewModel()

    enum LoopMode: String {
        case off, file, ab
    }

    struct ExportJob {
        var fraction: Double = 0
        var remainingSeconds: Double?
        var fileName: String
        var isPaused = false
    }

    /// 导出前的单帧预览（左右对比）
    struct EnhancePreview {
        var before: CGImage
        var after: CGImage?
    }

    // MARK: 播放状态

    let playerView = MPVPlayerView(frame: .zero)
    @Published private(set) var sourceURL: URL?
    @Published private(set) var fingerprint: String?
    @Published private(set) var isPaused = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var volume: Double = 100 { didSet { playerView.setDouble("volume", volume) } }
    @Published var speed: Double = 1 { didSet { playerView.setDouble("speed", speed) } }

    // MARK: 循环

    @Published private(set) var loopMode: LoopMode = .off
    @Published private(set) var abStart: Double?
    @Published private(set) var abEnd: Double?

    // MARK: 画面

    @Published var adjustments = VideoAdjustments.identity {
        didSet { applyVideoFilters(); saveSettings() }
    }
    @Published private(set) var orientation = VideoOrientation()
    /// AI 清晰（实时，Anime4K 着色器）
    @Published var clarity = AIClarity.off {
        didSet { applyShaders(); saveSettings() }
    }
    /// 按住“对比原画”时临时关闭画面调整
    @Published var compareOriginal = false { didSet { applyVideoFilters(); applyShaders() } }
    @Published var showEnhancePanel = false

    // MARK: 修复版

    @Published private(set) var enhancedVersions: [EnhancementCache.Entry] = []
    @Published private(set) var playingEnhanced = false
    @Published private(set) var exportJob: ExportJob?
    @Published var aiStrength: Double = 0.8
    @Published private(set) var preview: EnhancePreview?
    @Published private(set) var previewRendering = false
    @Published var message: String?

    let cache: EnhancementCache?
    private let settingsStore = VideoSettingsStore()
    private var settings = VideoSettings.default
    private var restoringSettings = false
    private var currentHwdec = ""
    private var exporter: LocalAIExporter?
    private var previewPixels: (pixels: [Float], width: Int, height: Int)?
    private var previewToken = UUID()
    private var appliedShaders: [String] = []
    private var openToken = UUID()

    /// 保存到原视频旁边（xxx_修复版.mp4），否则存放在应用的缓存目录
    @Published var saveNextToSource = UserDefaults.standard.bool(forKey: "saveNextToSource") {
        didSet { UserDefaults.standard.set(saveNextToSource, forKey: "saveNextToSource") }
    }

    private init() {
        cache = try? EnhancementCache(rootDirectory: EnhancementCache.defaultRootDirectory())
        try? cache?.pruneMissingOutputs()
        playerView.delegate = self
        applyVideoFilters()
    }

    // MARK: - 打开文件

    static let supportedExtensions = ["mp4", "m4v", "mov", "mkv", "avi", "flv", "webm", "wmv", "ts", "m2ts",
                                      "mts", "mpg", "mpeg", "3gp", "rmvb", "rm", "vob", "ogv", "asf", "f4v"]

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.movie, .audiovisualContent]
        types += Self.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        let token = UUID()
        openToken = token
        sourceURL = url
        fingerprint = nil
        enhancedVersions = []
        playingEnhanced = false
        position = 0
        duration = 0
        clearABLoop()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        // 先算指纹（只读头中尾几 MB，很快），再决定播原片还是修复版
        Task.detached(priority: .userInitiated) {
            let fp = try? VideoFingerprint.compute(for: url)
            await self.finishOpening(url: url, fingerprint: fp, token: token)
        }
    }

    private func finishOpening(url: URL, fingerprint fp: String?, token: UUID) {
        guard token == openToken else { return }
        fingerprint = fp

        restoringSettings = true
        settings = fp.flatMap { settingsStore.settings(for: $0) } ?? .default
        adjustments = settings.adjustments
        orientation = settings.orientation
        clarity = settings.clarity
        restoringSettings = false
        applyVideoFilters()
        applyShaders()

        refreshEnhancedVersions()
        if settings.preferEnhanced, let best = enhancedVersions.first {
            playingEnhanced = true
            playerView.loadFile(best.outputURL)
            message = "已自动播放修复版（可在顶部切换回原片）"
        } else {
            playerView.loadFile(url)
        }
        playerView.setFlag("pause", false)
    }

    private func refreshEnhancedVersions() {
        guard let fingerprint, let cache else {
            enhancedVersions = []
            return
        }
        enhancedVersions = cache.completedEntries(fingerprint: fingerprint)
    }

    // MARK: - 播放控制

    func togglePause() {
        guard sourceURL != nil else { return showOpenPanel() }
        if !isPaused {
            playerView.setFlag("pause", true)
        } else {
            // 播到结尾后再按播放，从头开始
            if duration > 0, position >= duration - 0.2 { seek(to: 0) }
            playerView.setFlag("pause", false)
        }
    }

    func seek(to seconds: Double) {
        playerView.command("seek", [String(format: "%.3f", max(0, seconds)), "absolute"])
    }

    func seek(by seconds: Double) {
        playerView.command("seek", [String(format: "%.3f", seconds), "relative"])
    }

    func frameStep(forward: Bool) {
        playerView.command(forward ? "frame-step" : "frame-back-step")
    }

    func screenshot() {
        playerView.command("screenshot")
        message = "截图已保存到桌面"
    }

    func adjustVolume(by delta: Double) {
        volume = min(max(volume + delta, 0), 130)
    }

    // MARK: - 循环

    func toggleFileLoop() {
        setLoopMode(loopMode == .file ? .off : .file)
    }

    /// A-B 循环：第一次按记下 A，第二次记下 B 并开始循环，第三次取消
    func cycleABLoop() {
        let position = currentTime
        if abStart == nil {
            abStart = position
            message = "已设置 A 点 \(Self.formatTime(position))，再按一次设置 B 点"
        } else if abEnd == nil {
            let a = abStart!
            guard position > a + 0.2 else {
                message = "B 点需要在 A 点之后"
                return
            }
            abEnd = position
            playerView.setDouble("ab-loop-a", a)
            playerView.setDouble("ab-loop-b", position)
            loopMode = .ab
            message = "A-B 循环：\(Self.formatTime(a)) → \(Self.formatTime(position))"
        } else {
            clearABLoop()
            setLoopMode(.off)
            message = "已取消 A-B 循环"
        }
    }

    private func clearABLoop() {
        abStart = nil
        abEnd = nil
        playerView.setString("ab-loop-a", "no")
        playerView.setString("ab-loop-b", "no")
        if loopMode == .ab { loopMode = .off }
    }

    private func setLoopMode(_ mode: LoopMode) {
        if mode != .ab { clearABLoop() }
        loopMode = mode
        playerView.setString("loop-file", mode == .file ? "inf" : "no")
    }

    // MARK: - 旋转、翻转

    func rotate(clockwise: Bool) {
        clockwise ? orientation.rotateClockwise() : orientation.rotateCounterClockwise()
        orientationChanged()
    }

    func toggleFlip(horizontal: Bool) {
        if horizontal { orientation.flipHorizontal.toggle() } else { orientation.flipVertical.toggle() }
        orientationChanged()
    }

    func resetOrientation() {
        orientation = VideoOrientation()
        orientationChanged()
    }

    private func orientationChanged() {
        applyVideoFilters()
        saveSettings()
    }

    // MARK: - 画面调整

    func applyPreset(_ preset: AdjustmentPreset) {
        adjustments = preset.adjustments
    }

    private func applyVideoFilters() {
        guard !restoringSettings else { return }
        let active = compareOriginal ? VideoAdjustments.identity : adjustments
        for property in active.mpvProperties {
            playerView.setInt(property.name, property.value)
        }
        let vf = MPVFilterChain.vf(adjustments: active, orientation: orientation)
        // 软件滤镜需要把硬解后的画面拷回内存；没有滤镜时用零拷贝硬解，更省电
        let hwdec = vf.isEmpty ? "videotoolbox" : "videotoolbox-copy"
        if hwdec != currentHwdec {
            playerView.setString("hwdec", hwdec)
            currentHwdec = hwdec
        }
        playerView.setString("vf", vf)
        playerView.setInt("video-rotate", orientation.rotation)
    }

    /// 着色器文件在 App 的 Resources/Shaders 里
    private static let shaderDirectory = Bundle.main.resourceURL?.appendingPathComponent("Shaders", isDirectory: true)

    private func applyShaders() {
        guard !restoringSettings else { return }
        let files = compareOriginal ? [] : clarity.shaderFiles
        guard files != appliedShaders else { return }
        appliedShaders = files
        playerView.command("change-list", ["glsl-shaders", "clr", ""])
        guard let dir = Self.shaderDirectory else { return }
        for file in files {
            let path = dir.appendingPathComponent(file).path
            if FileManager.default.fileExists(atPath: path) {
                playerView.command("change-list", ["glsl-shaders", "append", path])
            } else {
                NSLog("[VoPlayer] 缺少着色器 %@", path)
            }
        }
    }

    private func saveSettings() {
        guard !restoringSettings, let fingerprint else { return }
        settings.adjustments = adjustments
        settings.orientation = orientation
        settings.clarity = clarity
        settingsStore.save(settings, for: fingerprint)
    }

    // MARK: - 原片 / 修复版切换

    func setPlayingEnhanced(_ enhanced: Bool) {
        guard let source = sourceURL else { return }
        let target = enhanced ? enhancedVersions.first?.outputURL : source
        guard let target, enhanced != playingEnhanced else { return }
        let resumeAt = currentTime
        let wasPaused = isPaused
        playingEnhanced = enhanced
        playerView.loadFile(target, startAt: resumeAt)
        playerView.setFlag("pause", wasPaused)
        settings.preferEnhanced = enhanced
        saveSettings()
    }

    // MARK: - 本地 AI 修复

    var currentRecipe: EnhanceRecipe {
        EnhanceRecipe(method: .localAI, model: ZeroDCE.modelID, modelVersion: ZeroDCE.modelVersion,
                      parameters: ["strength": String(format: "%.2f", aiStrength)])
    }

    /// 这个视频用当前参数是否已经修过
    var hasResultForCurrentRecipe: Bool {
        guard let fingerprint, let cache else { return false }
        return cache.completedEntry(fingerprint: fingerprint, recipe: currentRecipe) != nil
    }

    func startLocalAIEnhance() {
        guard exportJob == nil else { return }
        guard let source = sourceURL, let fingerprint, let cache else {
            message = sourceURL == nil ? "请先打开一个视频" : "正在识别视频，请稍候再试"
            return
        }
        let recipe = currentRecipe

        // 同一视频、同一参数已经修过：直接用，不重复处理
        if cache.completedEntry(fingerprint: fingerprint, recipe: recipe) != nil {
            refreshEnhancedVersions()
            message = "这个视频已经用相同参数修复过，直接播放修复版"
            playingEnhanced = false
            setPlayingEnhanced(true)
            return
        }

        let destination: URL
        let key = recipe.cacheKey(fingerprint: fingerprint)
        if saveNextToSource, FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path) {
            let name = source.deletingPathExtension().lastPathComponent + "_修复版_\(key.prefix(6)).mp4"
            destination = source.deletingLastPathComponent().appendingPathComponent(name)
        } else {
            destination = cache.defaultOutputURL(forKey: key)
        }

        let exporter: LocalAIExporter
        do {
            exporter = try LocalAIExporter(strength: Float(aiStrength))
            try cache.begin(fingerprint: fingerprint, recipe: recipe, sourceURL: source, outputURL: destination)
        } catch {
            message = "无法开始修复：\(error.localizedDescription)"
            return
        }
        self.exporter = exporter
        exportJob = ExportJob(fileName: source.lastPathComponent)

        Task.detached(priority: .utility) {
            do {
                try await exporter.export(source: source, destination: destination) { progress in
                    Task { @MainActor in
                        self.exportJob?.fraction = progress.fraction
                        if !(self.exportJob?.isPaused ?? false) {
                            self.exportJob?.remainingSeconds = progress.remainingSeconds
                        }
                    }
                }
                try cache.markCompleted(key: key)
                await self.exportFinished(fingerprint: fingerprint, error: nil)
            } catch {
                if case LocalAIExporter.ExportError.cancelled = error {
                    try? cache.remove(key: key)
                } else {
                    try? cache.markFailed(key: key, message: error.localizedDescription)
                }
                await self.exportFinished(fingerprint: fingerprint, error: error)
            }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    func togglePauseExport() {
        guard let exporter, exportJob != nil else { return }
        if exporter.isPaused {
            exporter.resume()
            exportJob?.isPaused = false
        } else {
            exporter.pause()
            exportJob?.isPaused = true
        }
    }

    // MARK: - 修复前预览一帧

    /// “开始 AI 修复”按钮：已修过就直接播放，否则先截当前画面做预览，确认后再处理整段
    func requestLocalAIEnhance() {
        guard exportJob == nil else { return }
        guard sourceURL != nil, fingerprint != nil else {
            message = sourceURL == nil ? "请先打开一个视频" : "正在识别视频，请稍候再试"
            return
        }
        if hasResultForCurrentRecipe {
            startLocalAIEnhance()
            return
        }
        if playingEnhanced {
            message = "请先切换到原片，再预览 AI 修复效果"
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vo-preview-\(UUID().uuidString).png")
        // video：只截视频画面本身（不含字幕、实时调色和着色器），和导出时处理的画面一致
        playerView.command("screenshot-to-file", [url.path, "video"])
        defer { try? FileManager.default.removeItem(at: url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let planar = PixelBufferConversion.planarRGB(from: image) else {
            message = "截取当前画面失败，直接开始修复"
            startLocalAIEnhance()
            return
        }
        previewPixels = planar
        preview = EnhancePreview(before: image, after: nil)
        renderPreview()
    }

    /// 按当前强度重新计算预览（拖动强度滑块时调用）
    func renderPreview() {
        guard let input = previewPixels, preview != nil else { return }
        let token = UUID()
        previewToken = token
        previewRendering = true
        let strength = Float(aiStrength)
        Task.detached(priority: .userInitiated) {
            var pixels = input.pixels
            var smoother = CurveSmoother(smoothing: 0)
            if let model = try? ZeroDCE() {
                let factor = ZeroDCE.downsampleFactor(width: input.width, height: input.height)
                model.enhanceFrame(&pixels, height: input.height, width: input.width, factor: factor,
                                   smoother: &smoother, strength: strength)
            }
            let image = PixelBufferConversion.makeCGImage(pixels, width: input.width, height: input.height)
            await MainActor.run {
                guard token == self.previewToken else { return }
                self.preview?.after = image
                self.previewRendering = false
            }
        }
    }

    func confirmPreview() {
        closePreview()
        startLocalAIEnhance()
    }

    func closePreview() {
        preview = nil
        previewPixels = nil
        previewRendering = false
    }

    private func exportFinished(fingerprint finishedFingerprint: String, error: Error?) {
        exportJob = nil
        exporter = nil
        if let error {
            message = error.localizedDescription
            return
        }
        // 用户可能已经换了视频，只有还在看同一个视频时才自动切换
        guard finishedFingerprint == fingerprint else {
            message = "修复完成，下次打开该视频会自动播放修复版"
            return
        }
        refreshEnhancedVersions()
        message = "修复完成，已切换到修复版"
        playingEnhanced = false
        setPlayingEnhanced(true)
    }

    func revealEnhancedInFinder() {
        guard let entry = enhancedVersions.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.outputURL])
    }

    func deleteEnhanced(_ entry: EnhancementCache.Entry) {
        if playingEnhanced, entry.key == enhancedVersions.first?.key {
            setPlayingEnhanced(false)
        }
        try? cache?.remove(key: entry.key)
        refreshEnhancedVersions()
        objectWillChange.send()
    }

    func clearAllEnhanced() {
        if playingEnhanced { setPlayingEnhanced(false) }
        for entry in cache?.allEntries ?? [] {
            try? cache?.remove(key: entry.key)
        }
        refreshEnhancedVersions()
        objectWillChange.send()
    }

    // MARK: - 工具

    /// 精确的当前时间（界面上的 position 为了省电做了节流）
    var currentTime: Double {
        playerView.getDouble("time-pos") ?? position
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    func shutdown() {
        exporter?.cancel()
        playerView.shutdown()
    }
}

extension PlayerViewModel: MPVPlayerViewDelegate {
    func mpvPropertyChanged(_ name: String, value: Any?) {
        switch name {
        case "time-pos":
            // 每帧都会回调，变化够大才刷新界面，避免整窗口高频重绘
            let new = value as? Double ?? 0
            if abs(new - position) >= 0.25 || new < position { position = new }
        case "duration": duration = value as? Double ?? 0
        case "pause": isPaused = value as? Bool ?? true
        default: break
        }
    }

    func mpvFileLoaded() {
        // 每次换文件后 mpv 会保留属性，但保险起见重新应用画面设置
        applyVideoFilters()
    }

    func mpvPlaybackEnded() {}
}
