import CoreVideo
import XCTest
@testable import VoCore

final class ZeroDCETests: XCTestCase {
    private struct Reference: Decodable {
        let height: Int
        let width: Int
        let factor: Int
        let curves_shape: [Int]
        let curves: [Float]
        let output: [Float]
    }

    /// 与 scripts/export_zero_dce.py 中的 fixture_input 公式一致
    static func fixtureInput(height h: Int, width w: Int) -> [Float] {
        var x = [Float](repeating: 0, count: 3 * h * w)
        for c in 0..<3 {
            for i in 0..<h {
                for j in 0..<w {
                    x[(c * h + i) * w + j] = Float(0.02 + 0.3 * (Double((i * 7 + j * 13 + c * 29) % 97) / 97.0))
                }
            }
        }
        return x
    }

    private func loadReference() throws -> Reference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zero_dce_reference", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testMatchesPythonReference() throws {
        let ref = try loadReference()
        let model = try ZeroDCE()
        var image = Self.fixtureInput(height: ref.height, width: ref.width)

        let curves = model.enhance(&image, height: ref.height, width: ref.width, factor: ref.factor)

        XCTAssertEqual(curves.count, ref.curves.count)
        let curveError = zip(curves, ref.curves).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(curveError, 1e-4, "曲线参数与参考实现不一致")

        XCTAssertEqual(image.count, ref.output.count)
        let outputError = zip(image, ref.output).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(outputError, 1e-4, "增强结果与参考实现不一致")
    }

    func testBrightensDarkImage() throws {
        let model = try ZeroDCE()
        let (h, w) = (36, 64)
        var image = Self.fixtureInput(height: h, width: w).map { $0 * 0.3 }
        let before = image.reduce(0, +) / Float(image.count)
        model.enhance(&image, height: h, width: w, factor: 4)
        let after = image.reduce(0, +) / Float(image.count)
        XCTAssertGreaterThan(after, before * 1.5)
    }

    func testRejectsBadWeights() {
        XCTAssertThrowsError(try ZeroDCE(weightsData: Data("nope".utf8)))
        XCTAssertThrowsError(try ZeroDCE(weightsData: Data("ZDCEPP01".utf8) + Data(count: 12)))
    }

    func testDownsampleAreaHandlesPartialBlocks() {
        // 1 通道 3×5，倍数 2 → 2×3；右边、下边的不完整块只平均实际像素
        let x: [Float] = [1, 2, 3, 4, 5,
                          6, 7, 8, 9, 10,
                          11, 12, 13, 14, 15]
        let out = ZeroDCE.downsampleArea(x, channels: 1, height: 3, width: 5, factor: 2)
        XCTAssertEqual(out, [4, 6, 7.5, 11.5, 13.5, 15])
    }

    func testUpsampleAlignCornersKeepsCorners() {
        let x: [Float] = [0, 1,
                          2, 3]
        let out = ZeroDCE.upsampleBilinearAlignCorners(x, channels: 1, fromHeight: 2, fromWidth: 2,
                                                       toHeight: 3, toWidth: 3)
        XCTAssertEqual(out, [0, 0.5, 1, 1, 1.5, 2, 2, 2.5, 3])
    }

    func testDownsampleFactor() {
        XCTAssertEqual(ZeroDCE.downsampleFactor(width: 1920, height: 1080), 12)
        XCTAssertEqual(ZeroDCE.downsampleFactor(width: 3840, height: 2160), 24)
        XCTAssertEqual(ZeroDCE.downsampleFactor(width: 100, height: 80), 1)
    }

    func testCurveSmoother() {
        var smoother = CurveSmoother(smoothing: 0.5)
        XCTAssertEqual(smoother.smooth([1, 1]), [1, 1])
        XCTAssertEqual(smoother.smooth([0, 0]), [0.5, 0.5])
        smoother.reset()
        XCTAssertEqual(smoother.smooth([0, 0]), [0, 0])
    }
}

final class PixelBufferConversionTests: XCTestCase {
    func testRoundTripKeepsChannelOrder() throws {
        let (w, h) = (5, 3)
        let buffer = try XCTUnwrap(PixelBufferConversion.makeBGRABuffer(width: w, height: h))
        var pixels = [Float](repeating: 0, count: 3 * w * h)
        for i in 0..<(w * h) {
            pixels[i] = 1                       // R 全满
            pixels[w * h + i] = Float(i) / 20   // G 渐变
            pixels[2 * w * h + i] = 0           // B 为 0
        }
        try PixelBufferConversion.write(pixels, width: w, height: h, to: buffer)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let first = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([first[0], first[2], first[3]], [0, 255, 255], "内存顺序应为 B G R A")
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

        let back = try PixelBufferConversion.planarRGB(from: buffer)
        XCTAssertEqual(back.width, w)
        XCTAssertEqual(back.height, h)
        let maxError = zip(back.pixels, pixels).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxError, 0.5 / 255 + 1e-6)
    }

    func testWriteClampsOutOfRange() throws {
        let buffer = try XCTUnwrap(PixelBufferConversion.makeBGRABuffer(width: 1, height: 1))
        try PixelBufferConversion.write([2, -1, 0.5], width: 1, height: 1, to: buffer)
        let back = try PixelBufferConversion.planarRGB(from: buffer).pixels
        XCTAssertEqual(back[0], 1)
        XCTAssertEqual(back[1], 0)
        XCTAssertEqual(back[2], 128 / 255, accuracy: 1e-6)
    }
}

final class CGImageConversionTests: XCTestCase {
    func testCGImageRoundTrip() throws {
        let (w, h) = (4, 3)
        var pixels = [Float](repeating: 0, count: 3 * w * h)
        for i in 0..<(w * h) {
            pixels[i] = Float(i) / 12
            pixels[w * h + i] = 0.5
            pixels[2 * w * h + i] = 1 - Float(i) / 12
        }
        let image = try XCTUnwrap(PixelBufferConversion.makeCGImage(pixels, width: w, height: h))
        XCTAssertEqual(image.width, w)
        XCTAssertEqual(image.height, h)
        let back = try XCTUnwrap(PixelBufferConversion.planarRGB(from: image))
        let maxError = zip(back.pixels, pixels).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxError, 0.5 / 255 + 1e-6)
    }

    func testMakeCGImageRejectsWrongSize() {
        XCTAssertNil(PixelBufferConversion.makeCGImage([0, 0, 0], width: 2, height: 2))
    }
}

final class AIClarityTests: XCTestCase {
    func testShaderOrder() {
        XCTAssertEqual(AIClarity.off.shaderFiles, [])
        XCTAssertEqual(AIClarity(restore: .medium).shaderFiles,
                       ["Clamp_Highlights.glsl", "Restore_Soft_M.glsl"])
        XCTAssertEqual(AIClarity(restore: .low, upscale: .high).shaderFiles,
                       ["Clamp_Highlights.glsl", "Restore_Soft_S.glsl", "Upscale_RealLife_x2_L.glsl"])
    }

    /// 与打包的着色器文件名对得上
    func testShaderFilesExistInRepository() throws {
        let shaders = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VoPlayer/Resources/Shaders")
        for level in AIClarity.Level.allCases where level != .off {
            for file in AIClarity(restore: level, upscale: level).shaderFiles {
                XCTAssertTrue(FileManager.default.fileExists(atPath: shaders.appendingPathComponent(file).path),
                              "缺少着色器 \(file)")
            }
        }
    }

    func testOldSettingsWithoutClarityStillDecode() throws {
        let old = #"{"adjustments":{"brightness":5,"contrast":0,"gamma":30,"saturation":0,"denoise":3,"sharpen":0},"orientation":{"rotation":90,"flipHorizontal":false,"flipVertical":false},"preferEnhanced":false}"#
        let settings = try JSONDecoder().decode(VideoSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.adjustments.gamma, 30)
        XCTAssertEqual(settings.orientation.rotation, 90)
        XCTAssertFalse(settings.preferEnhanced)
        XCTAssertEqual(settings.clarity, .off)
    }
}
