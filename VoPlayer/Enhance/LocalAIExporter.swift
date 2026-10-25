import AVFoundation
import Foundation
import VoCore

/// 本地 AI 修复导出：逐帧读取 → Zero-DCE++ 暗光增强 → 编码为 HEVC 的 mp4，音轨原样复制。
///
/// 先写到临时文件，全部成功后再移动到目标位置，中途取消或失败不会留下半成品。
final class LocalAIExporter: @unchecked Sendable {
    enum ExportError: LocalizedError {
        case noVideoTrack
        case unsupportedSource(String)
        case writerFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "这个文件里没有视频画面。"
            case .unsupportedSource(let detail):
                return "本地 AI 修复暂不支持这个格式（目前支持 mp4 / mov / m4v）。\(detail)"
            case .writerFailed(let detail): return "写入修复后的视频失败：\(detail)"
            case .cancelled: return "已取消。"
            }
        }
    }

    struct Progress: Sendable {
        var fraction: Double
        var framesDone: Int
        /// 预计剩余秒数
        var remainingSeconds: Double?
    }

    private let model: ZeroDCE
    private let strength: Float
    private let lock = NSLock()
    private var cancelled = false

    init(strength: Float) throws {
        self.model = try ZeroDCE()
        self.strength = strength
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func export(source: URL, destination: URL, progress: @escaping @Sendable (Progress) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let (naturalSize, transform, frameRate, dataRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        let duration = try await asset.load(.duration).seconds
        let width = Int(naturalSize.width), height = Int(naturalSize.height)

        // 读取
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.unsupportedSource(error.localizedDescription)
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.unsupportedSource("无法读取视频轨。") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioFormatHint: CMFormatDescription?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                audioFormatHint = (try? await audioTrack.load(.formatDescriptions))?.first
            }
        }

        // 写入（临时文件）
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vo-enhance-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
        let bitRate = max(Int(dataRate * 1.2), 4_000_000)
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
        videoInput.transform = transform          // 保留手机竖拍等方向信息
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw ExportError.writerFailed("无法添加视频轨。") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatHint)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                // 容器不接受原音轨编码时放弃音轨复制（极少见），画面照常导出
                audioOutput = nil
            }
        }

        guard reader.startReading() else {
            throw ExportError.unsupportedSource(reader.error?.localizedDescription ?? "")
        }
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let factor = ZeroDCE.downsampleFactor(width: width, height: height)
        let totalFrames = max(1, Int(duration * Double(frameRate > 0 ? frameRate : 30)))
        let started = Date()
        // 回调在后台队列执行，可变状态放进引用类型里（只在视频队列上读写）
        let state = FrameState()

        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "vo.export.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "vo.export.audio", qos: .userInitiated)

        // 视频与音频必须交替写入，各自在 ready 时写，避免 AVAssetWriter 互相等待卡死
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
            while videoInput.isReadyForMoreMediaData {
                if isCancelled || state.error != nil {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                do {
                    try autoreleasepool {
                        try process(sample, adaptor: adaptor, factor: factor, smoother: &state.smoother)
                    }
                } catch {
                    state.error = error
                    continue
                }
                state.framesDone += 1
                let framesDone = state.framesDone
                if framesDone % 5 == 0 {
                    let fraction = min(Double(framesDone) / Double(totalFrames), 0.999)
                    let elapsed = Date().timeIntervalSince(started)
                    let remaining = fraction > 0.01 ? elapsed / fraction * (1 - fraction) : nil
                    progress(Progress(fraction: fraction, framesDone: framesDone, remainingSeconds: remaining))
                }
            }
        }

        if let audioInput, let audioOutput {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
                while audioInput.isReadyForMoreMediaData {
                    if isCancelled {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    audioInput.append(sample)
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if isCancelled || state.error != nil || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tempURL)
            if isCancelled { throw ExportError.cancelled }
            if let frameError = state.error { throw frameError }
            throw ExportError.unsupportedSource(reader.error?.localizedDescription ?? "")
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
        progress(Progress(fraction: 1, framesDone: state.framesDone, remainingSeconds: 0))
    }

    private final class FrameState: @unchecked Sendable {
        var smoother = CurveSmoother()
        var framesDone = 0
        var error: Error?
    }

    private func process(_ sample: CMSampleBuffer, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                         factor: Int, smoother: inout CurveSmoother) throws {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)

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
            throw ExportError.writerFailed(adaptor.assetWriterInput.description)
        }
    }
}
