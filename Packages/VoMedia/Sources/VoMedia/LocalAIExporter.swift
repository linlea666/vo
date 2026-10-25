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
        case encoderStalled
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .writerFailed(let detail): return "写入修复后的视频失败：\(detail)"
            case .encoderStalled: return "视频编码器长时间无响应，已停止。请重试，或重启电脑后再试。"
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

    /// 多久没有写出新画面就判定编码器卡住（暂停时不计）
    public var stallTimeout: TimeInterval = 30

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
        debugLog?("writer started \(width)x\(height) via \(source.readerName)")

        // 单独一个工作线程：按时间戳交替写视频和音频，轮询 isReadyForMoreMediaData。
        // 不用 requestMediaDataWhenReady 的跨队列回调——那种写法在写入端停止回调时无法收尾。
        let job = WriteJob(source: source, writer: writer, videoInput: videoInput, audioInput: audioInput,
                           adaptor: adaptor, factor: ZeroDCE.downsampleFactor(width: width, height: height),
                           totalFrames: max(1, Int(source.duration * source.frameRate)), progress: progress)
        let outcome: Result<Int, Error> = await withCheckedContinuation { continuation in
            let thread = Thread { [self] in
                continuation.resume(returning: Result { try runWriteLoop(job) })
            }
            thread.name = "vo.export"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        let framesDone: Int
        switch outcome {
        case .success(let frames):
            framesDone = frames
        case .failure(let error):
            debugLog?("write loop failed: \(error)")
            source.cancel()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        debugLog?("finishing (\(framesDone) frames)")
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
        debugLog?("done")
        progress(Progress(fraction: 1, framesDone: framesDone, remainingSeconds: 0, isPaused: false))
    }

    /// 调试日志（测试里打开，便于在 CI 上定位问题）
    public var debugLog: ((String) -> Void)?

    private struct WriteJob {
        let source: ExportSource
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let factor: Int
        let totalFrames: Int
        let progress: @Sendable (Progress) -> Void
    }

    /// 写入主循环，返回写出的帧数。
    private func runWriteLoop(_ job: WriteJob) throws -> Int {
        var smoother = CurveSmoother()
        var framesDone = 0
        var videoDone = false
        var audioDone = job.audioInput == nil
        var lastVideoTime = 0.0
        var lastAudioTime = 0.0
        let started = Date()
        var pausedSeconds: TimeInterval = 0
        var lastProgress = Date()

        while !(videoDone && audioDone) {
            let paused = waitWhilePaused()
            if paused > 0 {
                pausedSeconds += paused
                lastProgress = Date()
            }
            if isCancelled { throw ExportError.cancelled }
            if job.writer.status == .failed {
                throw ExportError.writerFailed(job.writer.error?.localizedDescription ?? "写入中断")
            }

            var didWork = false

            // 视频：处理一帧
            if !videoDone, job.videoInput.isReadyForMoreMediaData {
                if let frame = try job.source.nextVideoFrame() {
                    try autoreleasepool {
                        try process(frame.buffer, time: frame.time, adaptor: job.adaptor, factor: job.factor,
                                    smoother: &smoother, writer: job.writer)
                    }
                    framesDone += 1
                    lastVideoTime = frame.time.seconds
                    if framesDone == 1 { debugLog?("first frame written") }
                    if framesDone % 5 == 0 {
                        let fraction = min(Double(framesDone) / Double(job.totalFrames), 0.999)
                        let elapsed = Date().timeIntervalSince(started) - pausedSeconds
                        let remaining = fraction > 0.01 ? elapsed / fraction * (1 - fraction) : nil
                        job.progress(Progress(fraction: fraction, framesDone: framesDone,
                                              remainingSeconds: remaining, isPaused: false))
                    }
                } else {
                    job.videoInput.markAsFinished()
                    videoDone = true
                    debugLog?("video finished (\(framesDone) frames)")
                }
                didWork = true
            }

            // 音频：最多领先视频 1 秒，避免一路写太多而让写入端等待另一路
            if !audioDone, let audioInput = job.audioInput, audioInput.isReadyForMoreMediaData,
               videoDone || lastAudioTime <= lastVideoTime + 1 {
                do {
                    if let sample = try job.source.nextAudioSample() {
                        guard audioInput.append(sample) else {
                            throw ExportError.writerFailed(
                                "写入音频失败：\(job.writer.error?.localizedDescription ?? "")")
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let duration = CMSampleBufferGetDuration(sample)
                        lastAudioTime = (duration.isValid ? CMTimeAdd(pts, duration) : pts).seconds
                    } else {
                        audioInput.markAsFinished()
                        audioDone = true
                        debugLog?("audio finished")
                    }
                } catch let error as ExportError {
                    throw error
                } catch {
                    // 音频解码出错不影响画面：放弃剩余音频
                    debugLog?("audio decode error, dropping audio: \(error)")
                    audioInput.markAsFinished()
                    audioDone = true
                }
                didWork = true
            }

            if didWork { lastProgress = Date() }
            if !didWork {
                if Date().timeIntervalSince(lastProgress) > stallTimeout {
                    debugLog?("stalled: videoReady=\(job.videoInput.isReadyForMoreMediaData) audioReady=\(job.audioInput?.isReadyForMoreMediaData ?? false) status=\(job.writer.status.rawValue)")
                    throw ExportError.encoderStalled
                }
                usleep(2_000)
            }
        }
        return framesDone
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
