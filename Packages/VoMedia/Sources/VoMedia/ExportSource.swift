import AVFoundation
import CoreVideo
import Foundation

/// 导出时的输入：按顺序吐出视频帧（32BGRA）和音频样本。
///
/// 视频和音频会在两个队列上分别读取，所以实现要保证两条读取路径互不干扰。
public protocol ExportSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// 秒
    var duration: Double { get }
    var frameRate: Double { get }
    /// 画面方向（手机竖拍等），写入时原样保留
    var transform: CGAffineTransform { get }
    /// 原视频码率（bit/s），0 表示未知
    var estimatedBitRate: Double { get }
    var audio: ExportAudioKind { get }
    /// 读取方式说明（日志、界面用）
    var readerName: String { get }

    /// 下一帧画面；读完返回 nil
    func nextVideoFrame() throws -> (buffer: CVPixelBuffer, time: CMTime)?
    /// 下一段音频；读完返回 nil
    func nextAudioSample() throws -> CMSampleBuffer?
    func cancel()
}

public enum ExportAudioKind {
    case none
    /// 压缩音频原样复制（AVFoundation 读取 mp4/mov 时）
    case passthrough(formatHint: CMFormatDescription?)
    /// 已解码的 PCM（48kHz 立体声 Float32），写入时编码为 AAC
    case pcm
}

public enum ExportSourceError: LocalizedError {
    case noVideoTrack
    case cannotOpen(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件里没有视频画面。"
        case .cannotOpen(let detail): return "无法读取这个视频：\(detail)"
        case .decodeFailed(let detail): return "解码失败：\(detail)"
        }
    }
}

public enum ExportSourceFactory {
    /// 先试 AVFoundation（mp4/mov/m4v，系统硬件解码、音轨可原样复制），不行再用 FFmpeg。
    public static func open(_ url: URL) async throws -> ExportSource {
        if let source = try? await AVFoundationSource.open(url) {
            return source
        }
        return try FFmpegSource(url: url)
    }
}

// MARK: - AVFoundation

final class AVFoundationSource: ExportSource {
    let width: Int
    let height: Int
    let duration: Double
    let frameRate: Double
    let transform: CGAffineTransform
    let estimatedBitRate: Double
    let audio: ExportAudioKind
    let readerName = "AVFoundation"

    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let audioOutput: AVAssetReaderTrackOutput?

    private init(reader: AVAssetReader, videoOutput: AVAssetReaderTrackOutput, audioOutput: AVAssetReaderTrackOutput?,
                 audio: ExportAudioKind, width: Int, height: Int, duration: Double, frameRate: Double,
                 transform: CGAffineTransform, bitRate: Double) {
        self.reader = reader
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.audio = audio
        self.width = width
        self.height = height
        self.duration = duration
        self.frameRate = frameRate
        self.transform = transform
        self.estimatedBitRate = bitRate
    }

    static func open(_ url: URL) async throws -> AVFoundationSource {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportSourceError.noVideoTrack
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let (size, transform, fps, dataRate) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate)
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportSourceError.cannotOpen("无法读取视频轨") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audio = ExportAudioKind.none
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                let hint = (try? await audioTrack.load(.formatDescriptions))?.first
                audio = .passthrough(formatHint: hint)
            }
        }

        // 能开始读取才算 AVFoundation 支持；否则交给 FFmpeg
        guard reader.startReading() else {
            throw ExportSourceError.cannotOpen(reader.error?.localizedDescription ?? "")
        }
        return AVFoundationSource(reader: reader, videoOutput: videoOutput, audioOutput: audioOutput, audio: audio,
                                  width: Int(size.width), height: Int(size.height), duration: duration,
                                  frameRate: Double(fps > 0 ? fps : 30), transform: transform,
                                  bitRate: Double(dataRate))
    }

    func nextVideoFrame() throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        while let sample = videoOutput.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                return (buffer, CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        if reader.status == .failed {
            throw ExportSourceError.decodeFailed(reader.error?.localizedDescription ?? "")
        }
        return nil
    }

    func nextAudioSample() throws -> CMSampleBuffer? {
        guard let audioOutput else { return nil }
        if let sample = audioOutput.copyNextSampleBuffer() { return sample }
        if reader.status == .failed {
            throw ExportSourceError.decodeFailed(reader.error?.localizedDescription ?? "")
        }
        return nil
    }

    func cancel() {
        reader.cancelReading()
    }
}
