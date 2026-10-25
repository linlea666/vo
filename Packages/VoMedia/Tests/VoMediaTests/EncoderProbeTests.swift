import AVFoundation
import XCTest

/// 诊断用：检查当前机器上哪些“编码格式 × 像素格式”组合能正常写出视频。
/// CI 虚拟机没有硬件编码/缩放器，结果写进日志，便于判断导出卡住的原因；本测试不做断言。
final class EncoderProbeTests: XCTestCase {
    private func probe(codec: AVVideoCodecType, pixelFormat: OSType, name: String) async -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let result: String = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var done = false
            func complete(_ text: String) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                continuation.resume(returning: text)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { complete("TIMEOUT") }
            DispatchQueue.global().async {
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
                    ])
                    input.expectsMediaDataInRealTime = false
                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
                    ])
                    writer.add(input)
                    guard writer.startWriting() else {
                        return complete("startWriting failed: \(writer.error?.localizedDescription ?? "")")
                    }
                    writer.startSession(atSourceTime: .zero)
                    var frame = 0
                    while frame < 10 {
                        if writer.status == .failed { return complete("failed: \(writer.error?.localizedDescription ?? "")") }
                        guard input.isReadyForMoreMediaData else { usleep(10_000); continue }
                        var buffer: CVPixelBuffer?
                        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
                        guard let buffer else { return complete("no pixel buffer") }
                        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25)) else {
                            return complete("append failed: \(writer.error?.localizedDescription ?? "")")
                        }
                        frame += 1
                    }
                    input.markAsFinished()
                    writer.finishWriting {
                        complete(writer.status == .completed ? "OK" : "finish failed: \(writer.error?.localizedDescription ?? "")")
                    }
                } catch {
                    complete("error: \(error.localizedDescription)")
                }
            }
        }
        print("[encoder-probe] \(name): \(result)")
        return result
    }

    func testProbeEncoders() async {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = await probe(codec: .h264, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, name: "H.264 + NV12")
        _ = await probe(codec: .h264, pixelFormat: kCVPixelFormatType_32BGRA, name: "H.264 + BGRA")
        _ = await probe(codec: .hevc, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, name: "HEVC + NV12")
        _ = await probe(codec: .hevc, pixelFormat: kCVPixelFormatType_32BGRA, name: "HEVC + BGRA")
    }
}
