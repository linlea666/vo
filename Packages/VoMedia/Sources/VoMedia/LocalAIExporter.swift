import AVFoundation
import Foundation
import VoCore

/// 本地 AI 修复导出：逐帧读取 → Zero-DCE++ 暗光增强 → 编码为 HEVC 的 mp4。
///
/// - 读取：mp4/mov/m4v 走 AVFoundation（音轨原样复制），其他格式走 FFmpeg（音频转码为 AAC）
/// - 先写临时文件，全部成功后再移动到目标位置，中途取消或失败不留半成品
/// - 支持暂停 / 继续 / 取消
public final class LocalAIExporter: @unchecked Sendable {
    public enum ExportError: LocalizedError {
        case writerFailed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .writerFailed(let detail): return "写入修复后的视频失败：\(detail)"
            case .cancelled: return "已取消。"
            }
        }
    }

    public struct Progress: Sendable {
        public var fraction: Double
        public var framesDone: Int
        /// 预计剩余秒数（不含暂停时间）
        public var remainingSeconds: Double?
        public var isPaused: Bool
    }

    private let model: ZeroDCE
    private let strength: Float
    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false

    public init(strength: Float) throws {
        self.model = try ZeroDCE()
        self.strength = strength
    }

    // MARK: - 控制

    public func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func pause() {
        condition.lock(); paused = true; condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return paused
    }

    private var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    /// 暂停时阻塞当前队列，返回暂停了多少秒
    private func waitWhilePaused() -> TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        guard paused else { return 0 }
        let start = Date()
        while paused && !cancelled { condition.wait() }
        return Date().timeIntervalSince(start)
    }

    // MARK: - 导出

    public func export(source url: URL, destination: URL,
                       progress: @escaping @Sendable (Progress) -> Void) async throws {
        let source = try await ExportSourceFactory.open(url)
        try await export(from: source, destination: destination, progress: progress)
    }

    func export(from source: ExportSource, destination: URL,
                progress: @escaping @Sendable (Progress) -> Void) async throws {
        let width = source.width, height = source.height

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-enhance-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        let bitRate = max(Int(source.estimatedBitRate * 1.2),
                          Int(Double(width * height) * source.frameRate * 0.08), 2_000_000)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.transform = source.transform     // 保留手机竖拍等方向信息
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw ExportError.writerFailed("无法添加视频轨。") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        switch source.audio {
        case .none:
            break
        case .passthrough(let hint):
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            if writer.canAdd(input) { audioInput = input }
        case .pcm:
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            if writer.canAdd(input) { audioInput = input }
        }
        if let audioInput {
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
        }

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let factor = ZeroDCE.downsampleFactor(width: width, height: height)
        let totalFrames = max(1, Int(source.duration * source.frameRate))
        let state = FrameState(started: Date())

        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "vo.export.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "vo.export.audio", qos: .userInitiated)

        // 视频与音频各自在 ready 时写入，避免 AVAssetWriter 等待交错时互相卡死
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while videoInput.isReadyForMoreMediaData {
                state.pausedSeconds += waitWhilePaused()
                if isCancelled || state.error != nil {
                    finish(videoInput, state: state, group: group)
                    return
                }
                do {
                    guard let frame = try source.nextVideoFrame() else {
                        finish(videoInput, state: state, group: group)
                        return
                    }
                    try autoreleasepool {
                        try process(frame.buffer, time: frame.time, adaptor: adaptor, factor: factor,
                                    smoother: &state.smoother, writer: writer)
                    }
                } catch {
                    // 出错立即结束：写入端失败后不会再回调，不能等下一轮
                    state.error = error
                    finish(videoInput, state: state, group: group)
                    return
                }
                state.framesDone += 1
                if state.framesDone % 5 == 0 {
                    let fraction = min(Double(state.framesDone) / Double(totalFrames), 0.999)
                    let elapsed = Date().timeIntervalSince(state.started) - state.pausedSeconds
                    let remaining = fraction > 0.01 ? elapsed / fraction * (1 - fraction) : nil
                    progress(Progress(fraction: fraction, framesDone: state.framesDone,
                                      remainingSeconds: remaining, isPaused: false))
                }
            }
        }

        let audioState = FrameState(started: Date())
        if let audioInput {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
                while audioInput.isReadyForMoreMediaData {
                    if isCancelled || state.error != nil || audioState.error != nil {
                        finish(audioInput, state: audioState, group: group)
                        return
                    }
                    do {
                        guard let sample = try source.nextAudioSample() else {
                            finish(audioInput, state: audioState, group: group)
                            return
                        }
                        if !audioInput.append(sample) {
                            audioState.error = ExportError.writerFailed(
                                "写入音频失败：\(writer.error?.localizedDescription ?? "")")
                            finish(audioInput, state: audioState, group: group)
                            return
                        }
                    } catch {
                        // 音频解码出错不影响画面：放弃剩余音频
                        audioState.error = error
                        finish(audioInput, state: audioState, group: group)
                        return
                    }
                }
            }
        }

        // 看门狗：写入端一旦失败就不会再回调，主动结束两路，避免永远等待
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 0.5, repeating: 0.5)
        watchdog.setEventHandler { [self] in
            guard writer.status == .failed || writer.status == .cancelled else { return }
            let failure = ExportError.writerFailed(writer.error?.localizedDescription ?? "写入中断")
            finish(videoInput, state: state, group: group, error: failure)
            if let audioInput { finish(audioInput, state: audioState, group: group, error: failure) }
        }
        watchdog.resume()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        watchdog.cancel()

        if state.error == nil, let audioError = audioState.error, writer.status == .failed {
            state.error = audioError
        }
        if isCancelled || state.error != nil || writer.status == .failed {
            source.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            if isCancelled { throw ExportError.cancelled }
            throw state.error ?? ExportError.writerFailed(writer.error?.localizedDescription ?? "未知错误")
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "未知错误")
        }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        progress(Progress(fraction: 1, framesDone: state.framesDone, remainingSeconds: 0, isPaused: false))
    }

    /// 回调在后台队列执行，可变状态放进引用类型（处理数据只在各自队列上写；结束标记加锁，看门狗也会调用）
    private final class FrameState: @unchecked Sendable {
        let started: Date
        var smoother = CurveSmoother()
        var framesDone = 0
        var pausedSeconds: TimeInterval = 0
        var error: Error?
        private var finished = false
        private let lock = NSLock()
        init(started: Date) { self.started = started }

        /// 只有第一次调用返回 true
        func markFinished(error: Error?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            if let error, self.error == nil { self.error = error }
            return true
        }
    }

    private func finish(_ input: AVAssetWriterInput, state: FrameState, group: DispatchGroup, error: Error? = nil) {
        guard state.markFinished(error: error) else { return }
        input.markAsFinished()
        group.leave()
    }

    private func process(_ source: CVPixelBuffer, time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                         factor: Int, smoother: inout CurveSmoother, writer: AVAssetWriter) throws {
        let converted = try PixelBufferConversion.planarRGB(from: source)
        var pixels = converted.pixels
        let width = converted.width, height = converted.height
        model.enhanceFrame(&pixels, height: height, width: width, factor: factor,
                           smoother: &smoother, strength: strength)

        var output: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        }
        guard let output = output ?? PixelBufferConversion.makeBGRABuffer(width: width, height: height) else {
            throw ExportError.writerFailed("无法分配画面缓冲。")
        }
        try PixelBufferConversion.write(pixels, width: width, height: height, to: output)
        guard adaptor.append(output, withPresentationTime: time) else {
            throw ExportError.writerFailed("写入画面失败：\(writer.error?.localizedDescription ?? "")")
        }
    }
}
