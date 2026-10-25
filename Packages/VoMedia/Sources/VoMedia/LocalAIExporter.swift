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
                                    smoother: &state.smoother)
                    }
                } catch {
                    state.error = error
                    continue
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

        if let audioInput {
            let audioState = FrameState(started: Date())
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
                        audioInput.append(sample)
                    } catch {
                        // 音频出错不影响画面：放弃剩余音频
                        audioState.error = error
                    }
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if isCancelled || state.error != nil {
            source.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            if isCancelled { throw ExportError.cancelled }
            throw state.error!
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

    /// 回调在后台队列执行，可变状态放进引用类型（每个实例只在一个队列上写）
    private final class FrameState: @unchecked Sendable {
        let started: Date
        var smoother = CurveSmoother()
        var framesDone = 0
        var pausedSeconds: TimeInterval = 0
        var error: Error?
        var finished = false
        init(started: Date) { self.started = started }
    }

    private func finish(_ input: AVAssetWriterInput, state: FrameState, group: DispatchGroup) {
        guard !state.finished else { return }
        state.finished = true
        input.markAsFinished()
        group.leave()
    }

    private func process(_ source: CVPixelBuffer, time: CMTime, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                         factor: Int, smoother: inout CurveSmoother) throws {
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
            throw ExportError.writerFailed("写入画面失败")
        }
    }
}
