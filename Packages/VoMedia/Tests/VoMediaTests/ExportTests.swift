import AVFoundation
import XCTest
@testable import VoMedia

/// 端到端导出测试：用 ffmpeg 命令行生成各种格式的 2 秒样片，跑完整导出，再用 AVFoundation 检查结果。
/// 机器上没有 ffmpeg 时跳过（CI 会先安装）。
final class ExportTests: XCTestCase {
    private static var workDir: URL!
    private static var ffmpeg: String?

    override class func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("vo-media-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let candidates = [ProcessInfo.processInfo.environment["FFMPEG_PATH"],
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        ffmpeg = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    /// 生成样片：320×180、25fps、2 秒、偏暗的测试图 + 440Hz 正弦音
    private func makeSample(_ name: String, video: [String], audio: [String]) throws -> URL {
        guard let ffmpeg = Self.ffmpeg else { throw XCTSkip("没有找到 ffmpeg，跳过端到端导出测试") }
        let url = Self.workDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-loglevel", "error",
                             "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=2,eq=brightness=-0.35",
                             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2",
                             "-shortest"] + video + audio + [url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg 生成 \(name) 失败（可能缺少编码器）：\(log)")
        }
        return url
    }

    private struct Checked {
        var width: Int
        var height: Int
        var duration: Double
        var hasAudio: Bool
        var reader: String
    }

    private func exportAndCheck(_ input: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> Checked {
        let source = try await ExportSourceFactory.open(input)
        let output = Self.workDir.appendingPathComponent("out-\(UUID().uuidString).mp4")
        let exporter = try LocalAIExporter(strength: 0.8)
        try await exporter.export(from: source, destination: output) { _ in }

        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1, "应有一条视频轨", file: file, line: line)
        let size = try await video[0].load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        return Checked(width: Int(size.width), height: Int(size.height), duration: duration,
                       hasAudio: !audio.isEmpty, reader: source.readerName)
    }

    func testMP4UsesAVFoundationAndKeepsAudio() async throws {
        let input = try makeSample("in.mp4", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"])
        let result = try await exportAndCheck(input)
        XCTAssertEqual(result.reader, "AVFoundation")
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 180)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
        XCTAssertTrue(result.hasAudio)
    }

    func testMKVViaFFmpeg() async throws {
        let input = try makeSample("in.mkv", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "libopus"])
        let result = try await exportAndCheck(input)
        XCTAssertEqual(result.reader, "FFmpeg")
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 180)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
        XCTAssertTrue(result.hasAudio)
    }

    func testWebMViaFFmpeg() async throws {
        let input = try makeSample("in.webm", video: ["-c:v", "libvpx-vp9", "-b:v", "300k"], audio: ["-c:a", "libopus"])
        let result = try await exportAndCheck(input)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
        XCTAssertTrue(result.hasAudio)
    }

    func testAVIViaFFmpeg() async throws {
        let input = try makeSample("in.avi", video: ["-c:v", "mpeg4", "-q:v", "5"], audio: ["-c:a", "libmp3lame"])
        let result = try await exportAndCheck(input)
        XCTAssertEqual(result.reader, "FFmpeg")
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
        XCTAssertTrue(result.hasAudio)
    }

    func testFLVViaFFmpeg() async throws {
        let input = try makeSample("in.flv", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"])
        let result = try await exportAndCheck(input)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
        XCTAssertTrue(result.hasAudio)
    }

    func testVideoWithoutAudio() async throws {
        let input = try makeSample("noaudio.mkv", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-an"])
        let result = try await exportAndCheck(input)
        XCTAssertFalse(result.hasAudio)
        XCTAssertEqual(result.duration, 2, accuracy: 0.3)
    }

    func testFFmpegReaderTimestampsAreIncreasing() throws {
        let input = try makeSample("in.mkv", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "libopus"])
        let source = try FFmpegSource(url: input)
        var last = -1.0
        var count = 0
        while let frame = try source.nextVideoFrame() {
            XCTAssertGreaterThan(frame.time.seconds, last)
            XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), 320)
            last = frame.time.seconds
            count += 1
        }
        XCTAssertEqual(count, 50, accuracy: 2)

        var samples = 0
        while let sample = try source.nextAudioSample() {
            samples += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(Double(samples) / 48_000, 2, accuracy: 0.15, "音频应重采样为 48kHz 且时长约 2 秒")
    }

    func testOutputIsBrighterThanDarkInput() async throws {
        let input = try makeSample("in.mp4", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"])
        let output = Self.workDir.appendingPathComponent("bright-\(UUID().uuidString).mp4")
        try await LocalAIExporter(strength: 1).export(source: input, destination: output) { _ in }
        let before = try await meanLuma(input)
        let after = try await meanLuma(output)
        XCTAssertGreaterThan(after, before + 0.05, "暗光修复后应明显变亮（前 \(before)，后 \(after)）")
    }

    func testCancelLeavesNoOutput() async throws {
        let input = try makeSample("in.mkv", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "libopus"])
        let output = Self.workDir.appendingPathComponent("cancel-\(UUID().uuidString).mp4")
        let exporter = try LocalAIExporter(strength: 1)
        exporter.cancel()
        do {
            try await exporter.export(source: input, destination: output) { _ in }
            XCTFail("取消后不应成功")
        } catch LocalAIExporter.ExportError.cancelled {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPauseAndResume() async throws {
        let input = try makeSample("in.mp4", video: ["-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"])
        let output = Self.workDir.appendingPathComponent("pause-\(UUID().uuidString).mp4")
        let exporter = try LocalAIExporter(strength: 1)
        exporter.pause()
        XCTAssertTrue(exporter.isPaused)
        Task {
            try await Task.sleep(nanoseconds: 500_000_000)
            exporter.resume()
        }
        let started = Date()
        try await exporter.export(source: input, destination: output) { _ in }
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.45, "暂停期间不应继续处理")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    private func meanLuma(_ url: URL) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum += 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])
        }
        return sum / Double(width * height) / 255
    }
}
