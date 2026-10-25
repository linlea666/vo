import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample
import Libswscale
import VoCore

// FFmpeg 的错误码是函数式宏，Swift 导入不了，这里按定义手写。
private let ffErrorEOF: Int32 = -0x2046_4F45          // AVERROR_EOF = -MKTAG('E','O','F',' ')
private let ffErrorAgain: Int32 = -EAGAIN              // AVERROR(EAGAIN)
private let ffNoPTS = Int64.min                        // AV_NOPTS_VALUE
private let ffTimeBase = 1_000_000.0                   // AV_TIME_BASE

private func ffErrorString(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buffer, buffer.count)
    return String(cString: buffer)
}

/// 用 FFmpeg 读取任意格式（mkv / avi / flv / webm / ts / rmvb …）。
///
/// 视频和音频各开一个解封装上下文，分别在两个队列上读取，互不加锁。
final class FFmpegSource: ExportSource {
    let width: Int
    let height: Int
    let duration: Double
    let frameRate: Double
    let transform = CGAffineTransform.identity
    let estimatedBitRate: Double
    let audio: ExportAudioKind
    let readerName = "FFmpeg"

    private let video: FFmpegVideoReader
    private let audioReader: FFmpegAudioReader?

    init(url: URL) throws {
        video = try FFmpegVideoReader(url: url)
        width = video.width
        height = video.height
        duration = video.duration
        frameRate = video.frameRate
        estimatedBitRate = video.bitRate
        audioReader = try? FFmpegAudioReader(url: url)
        audio = audioReader == nil ? .none : .pcm
    }

    func nextVideoFrame() throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        try video.nextFrame()
    }

    func nextAudioSample() throws -> CMSampleBuffer? {
        try audioReader?.nextSample()
    }

    func cancel() {}
}

// MARK: - 公共：打开文件、找流、开解码器

private final class FFmpegStream {
    var format: UnsafeMutablePointer<AVFormatContext>?
    var codec: UnsafeMutablePointer<AVCodecContext>?
    let streamIndex: Int32
    let timeBase: AVRational
    /// 文件起始时间（秒），所有时间戳都减去它，保证从 0 开始
    let startTime: Double
    let stream: UnsafeMutablePointer<AVStream>
    private let packet: UnsafeMutablePointer<AVPacket>
    let frame: UnsafeMutablePointer<AVFrame>
    private var sentFlush = false

    init(url: URL, type: Libavutil.AVMediaType) throws {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let openResult = avformat_open_input(&ctx, url.path, nil, nil)
        guard openResult == 0, let opened = ctx else {
            throw ExportSourceError.cannotOpen(ffErrorString(openResult))
        }
        guard avformat_find_stream_info(opened, nil) >= 0 else {
            avformat_close_input(&ctx)
            throw ExportSourceError.cannotOpen("无法识别媒体信息")
        }

        var decoder: UnsafePointer<AVCodec>?
        let index = av_find_best_stream(opened, type, -1, -1, &decoder, 0)
        guard index >= 0, let decoder, let stream = opened.pointee.streams[Int(index)] else {
            avformat_close_input(&ctx)
            throw type == AVMEDIA_TYPE_VIDEO ? ExportSourceError.noVideoTrack
                                             : ExportSourceError.cannotOpen("没有音频")
        }
        // 只解封装需要的那一路，省时间
        for i in 0..<Int(opened.pointee.nb_streams) where i != Int(index) {
            opened.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL
        }

        var codecContext = avcodec_alloc_context3(decoder)
        guard let cc = codecContext else {
            avformat_close_input(&ctx)
            throw ExportSourceError.cannotOpen("无法创建解码器")
        }
        avcodec_parameters_to_context(cc, stream.pointee.codecpar)
        cc.pointee.thread_count = 0   // 自动多线程
        cc.pointee.pkt_timebase = stream.pointee.time_base
        let codecResult = avcodec_open2(cc, decoder, nil)
        guard codecResult == 0 else {
            avcodec_free_context(&codecContext)
            avformat_close_input(&ctx)
            throw ExportSourceError.cannotOpen("不支持的编码：\(ffErrorString(codecResult))")
        }

        format = opened
        codec = cc
        streamIndex = index
        self.stream = stream
        timeBase = stream.pointee.time_base
        startTime = opened.pointee.start_time == ffNoPTS ? 0 : Double(opened.pointee.start_time) / ffTimeBase
        packet = av_packet_alloc()
        frame = av_frame_alloc()
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&p)
        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
        avcodec_free_context(&codec)
        avformat_close_input(&format)
    }

    /// 解出下一帧到 `frame`；读完返回 false
    func decodeNext() throws -> Bool {
        while true {
            let received = avcodec_receive_frame(codec, frame)
            if received == 0 { return true }
            if received == ffErrorEOF { return false }
            guard received == ffErrorAgain else {
                throw ExportSourceError.decodeFailed(ffErrorString(received))
            }
            if sentFlush { return false }

            let read = av_read_frame(format, packet)
            if read < 0 {
                // 文件读完：送空包让解码器吐出缓存的帧
                avcodec_send_packet(codec, nil)
                sentFlush = true
                continue
            }
            defer { av_packet_unref(packet) }
            if packet.pointee.stream_index == streamIndex {
                // 个别坏包解不了就跳过，不中断整个导出
                _ = avcodec_send_packet(codec, packet)
            }
        }
    }

    /// 当前帧的时间（秒，从 0 开始）；没有时间戳时返回 nil
    var frameSeconds: Double? {
        let pts = frame.pointee.best_effort_timestamp
        guard pts != ffNoPTS else { return nil }
        return Double(pts) * av_q2d(timeBase) - startTime
    }
}

// MARK: - 视频

final class FFmpegVideoReader {
    let width: Int
    let height: Int
    let duration: Double
    let frameRate: Double
    let bitRate: Double

    private let stream: FFmpegStream
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var swsKey: (Int32, Int32, Int32) = (0, 0, -1)
    private var lastTime: Double = -1
    private var framesOut = 0

    init(url: URL) throws {
        stream = try FFmpegStream(url: url, type: AVMEDIA_TYPE_VIDEO)
        let par = stream.stream.pointee.codecpar.pointee
        width = Int(par.width)
        height = Int(par.height)
        guard width > 0, height > 0 else { throw ExportSourceError.noVideoTrack }

        let rate = stream.stream.pointee.avg_frame_rate
        let fallback = stream.stream.pointee.r_frame_rate
        let fps = rate.den > 0 && rate.num > 0 ? av_q2d(rate) : (fallback.den > 0 ? av_q2d(fallback) : 30)
        frameRate = fps.isFinite && fps > 0 && fps < 1000 ? fps : 30

        let fmt = stream.format!.pointee
        if stream.stream.pointee.duration != ffNoPTS, stream.stream.pointee.duration > 0 {
            duration = Double(stream.stream.pointee.duration) * av_q2d(stream.timeBase)
        } else if fmt.duration != ffNoPTS, fmt.duration > 0 {
            duration = Double(fmt.duration) / ffTimeBase
        } else {
            duration = 0
        }
        bitRate = Double(par.bit_rate > 0 ? par.bit_rate : fmt.bit_rate)
    }

    deinit {
        sws_freeContext(sws)
    }

    func nextFrame() throws -> (buffer: CVPixelBuffer, time: CMTime)? {
        guard try stream.decodeNext() else { return nil }
        let frame = stream.frame
        let w = frame.pointee.width, h = frame.pointee.height

        guard let buffer = PixelBufferConversion.makeBGRABuffer(width: Int(w), height: Int(h)) else {
            throw ExportSourceError.decodeFailed("无法分配画面缓冲")
        }
        try convert(frame, into: buffer)

        // 时间戳：缺失或不递增时按帧率补齐（写入端要求严格递增）
        var seconds = stream.frameSeconds ?? (Double(framesOut) / frameRate)
        seconds = max(seconds, 0)
        if seconds <= lastTime { seconds = lastTime + 1 / (frameRate * 4) }
        lastTime = seconds
        framesOut += 1
        return (buffer, CMTime(seconds: seconds, preferredTimescale: 90_000))
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, into buffer: CVPixelBuffer) throws {
        let w = frame.pointee.width, h = frame.pointee.height, fmt = frame.pointee.format
        if sws == nil || swsKey != (w, h, fmt) {
            sws_freeContext(sws)
            // 2 = SWS_BILINEAR（FFmpeg 8 把标志改成了枚举，直接用数值兼容各版本）
            sws = sws_getContext(w, h, AVPixelFormat(rawValue: fmt), w, h, AV_PIX_FMT_BGRA, 2, nil, nil, nil)
            guard sws != nil else { throw ExportSourceError.decodeFailed("不支持的像素格式 \(fmt)") }
            swsKey = (w, h, fmt)
            // 色彩矩阵：标清 BT.601，高清 BT.709；范围按视频标注
            let colorspace = frame.pointee.colorspace
            let useBT709 = colorspace == AVCOL_SPC_BT709 || (colorspace == AVCOL_SPC_UNSPECIFIED && h >= 720)
            let coefficients = sws_getCoefficients(useBT709 ? SWS_CS_ITU709 : SWS_CS_ITU601)
            let fullRange: Int32 = frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
            sws_setColorspaceDetails(sws, coefficients, fullRange, coefficients, 1, 0, 1 << 16, 1 << 16)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ExportSourceError.decodeFailed("无法写入画面缓冲")
        }

        var srcData = withUnsafeBytes(of: frame.pointee.data) { Array($0.bindMemory(to: UnsafePointer<UInt8>?.self)) }
        var srcStride = withUnsafeBytes(of: frame.pointee.linesize) { Array($0.bindMemory(to: Int32.self)) }
        var dstData: [UnsafeMutablePointer<UInt8>?] = [base.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
        var dstStride: [Int32] = [Int32(CVPixelBufferGetBytesPerRow(buffer)), 0, 0, 0]
        let rows = sws_scale(sws, &srcData, &srcStride, 0, h, &dstData, &dstStride)
        guard rows == h else { throw ExportSourceError.decodeFailed("画面转换失败") }
    }
}

// MARK: - 音频（统一转成 48kHz 立体声 Float32，交给 AVAssetWriter 编码成 AAC）

final class FFmpegAudioReader {
    static let sampleRate: Int32 = 48_000
    static let channels: Int32 = 2

    private let stream: FFmpegStream
    private var swr: OpaquePointer?
    private var samplesOut: Int64 = 0
    private var startSeconds: Double?
    private var drained = false
    private let formatDescription: CMAudioFormatDescription

    init(url: URL) throws {
        stream = try FFmpegStream(url: url, type: AVMEDIA_TYPE_AUDIO)
        let codec = stream.codec!

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, Self.channels)
        defer { av_channel_layout_uninit(&outLayout) }
        var inLayout = codec.pointee.ch_layout
        if inLayout.nb_channels == 0 {
            av_channel_layout_default(&inLayout, 2)
        }
        var resampler: OpaquePointer?
        let result = swr_alloc_set_opts2(&resampler, &outLayout, AV_SAMPLE_FMT_FLT, Self.sampleRate,
                                         &inLayout, codec.pointee.sample_fmt, codec.pointee.sample_rate, 0, nil)
        guard result >= 0, resampler != nil, swr_init(resampler) >= 0 else {
            swr_free(&resampler)
            throw ExportSourceError.cannotOpen("无法转换音频")
        }
        swr = resampler

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * Self.channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * Self.channels), mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &description)
        guard let description else { throw ExportSourceError.cannotOpen("无法创建音频格式") }
        formatDescription = description
    }

    deinit {
        swr_free(&swr)
    }

    func nextSample() throws -> CMSampleBuffer? {
        while true {
            if drained { return nil }
            let gotFrame = try stream.decodeNext()
            let frame = stream.frame
            let inCount = gotFrame ? frame.pointee.nb_samples : 0
            if startSeconds == nil, gotFrame {
                startSeconds = max(stream.frameSeconds ?? 0, 0)
            }

            let capacity = Int(swr_get_out_samples(swr, inCount)) + 256
            var pcm = [Float](repeating: 0, count: capacity * Int(Self.channels))
            let converted: Int32 = pcm.withUnsafeMutableBytes { raw in
                var out: [UnsafeMutablePointer<UInt8>?] = [raw.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                if gotFrame {
                    let input = UnsafeRawPointer(frame.pointee.extended_data)!
                        .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                    return swr_convert(swr, &out, Int32(capacity), input, inCount)
                }
                return swr_convert(swr, &out, Int32(capacity), nil, 0)   // 读完：取出重采样缓存
            }
            if !gotFrame { drained = true }
            guard converted > 0 else { continue }
            return try makeSampleBuffer(pcm, frames: Int(converted))
        }
    }

    private func makeSampleBuffer(_ pcm: [Float], frames: Int) throws -> CMSampleBuffer {
        let bytes = frames * Int(Self.channels) * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        guard let block else { throw ExportSourceError.decodeFailed("无法分配音频缓冲") }
        pcm.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: bytes)
        }
        // 时间按样本数连续累加，避免音频时间戳抖动造成的爆音或空隙
        let start = CMTime(seconds: startSeconds ?? 0, preferredTimescale: CMTimeScale(Self.sampleRate))
        let pts = CMTimeAdd(start, CMTime(value: samplesOut, timescale: CMTimeScale(Self.sampleRate)))
        samplesOut += Int64(frames)

        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw ExportSourceError.decodeFailed("音频封装失败 \(status)") }
        return sample
    }
}
