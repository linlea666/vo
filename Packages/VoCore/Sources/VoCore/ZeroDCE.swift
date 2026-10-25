import Accelerate
import Foundation

/// Zero-DCE++ 暗光增强（本地 AI）。
///
/// 网络很小（约 1 万个参数），直接用 Accelerate 在 CPU 上推理，不需要转换模型：
/// 1. 把画面按整数倍区域平均缩小，估计每个像素的“提亮曲线”参数（7 层深度可分离卷积）
/// 2. 曲线参数双线性放大回原尺寸（align_corners）
/// 3. 逐像素迭代 8 次：x = x + r·(x² − x)
///
/// 图像统一用平面 CHW 的 Float 数组（R、G、B 三个平面，取值 0...1）。
/// 与 `scripts/export_zero_dce.py` 中的参考实现一一对应，测试会比对两者输出。
public final class ZeroDCE: @unchecked Sendable {
    public static let modelID = "zero-dce-pp"
    /// 算法版本：改动推理细节（下采样方式、迭代、平滑等）时递增，旧缓存自动失效
    public static let modelVersion = "1"

    struct Layer {
        let inChannels: Int
        let outChannels: Int
        let depthWeights: [Float]   // [C, 9]
        let depthBias: [Float]      // [C]
        let pointWeights: [Float]   // [O, C]
        let pointBias: [Float]      // [O]
    }

    static let layerShapes = [(3, 32), (32, 32), (32, 32), (32, 32), (64, 32), (64, 32), (64, 3)]
    private static let magic = Array("ZDCEPP01".utf8)

    let layers: [Layer]

    public enum LoadError: Error {
        case missingResource
        case badFormat
    }

    /// 读取打包在 VoCore 里的权重
    public convenience init() throws {
        guard let url = Bundle.module.url(forResource: "zero_dce_pp", withExtension: "bin") else {
            throw LoadError.missingResource
        }
        try self.init(weightsData: Data(contentsOf: url))
    }

    public init(weightsData data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > Self.magic.count, Array(bytes.prefix(Self.magic.count)) == Self.magic else {
            throw LoadError.badFormat
        }
        let floatCount = (bytes.count - Self.magic.count) / 4
        var floats = [Float](repeating: 0, count: floatCount)
        floats.withUnsafeMutableBytes { dst in
            dst.copyBytes(from: bytes[Self.magic.count..<(Self.magic.count + floatCount * 4)])
        }
        // 文件是小端，苹果芯片也是小端，无需转换

        var cursor = 0
        func take(_ n: Int) throws -> [Float] {
            guard cursor + n <= floats.count else { throw LoadError.badFormat }
            defer { cursor += n }
            return Array(floats[cursor..<(cursor + n)])
        }
        var layers: [Layer] = []
        for (cin, cout) in Self.layerShapes {
            layers.append(Layer(inChannels: cin, outChannels: cout,
                                depthWeights: try take(cin * 9), depthBias: try take(cin),
                                pointWeights: try take(cout * cin), pointBias: try take(cout)))
        }
        guard cursor == floats.count else { throw LoadError.badFormat }
        self.layers = layers
    }

    /// 根据画面尺寸选下采样倍数：让小图的长边约 160 像素（1080p → 12，与论文默认一致）
    public static func downsampleFactor(width: Int, height: Int) -> Int {
        max(1, Int((Double(max(width, height)) / 160).rounded()))
    }

    // MARK: - 曲线参数估计

    /// 输入：缩小后的画面 [3, h, w]；输出：曲线参数 [3, h, w]，取值 -1...1
    public func estimateCurves(_ input: [Float], height h: Int, width w: Int) -> [Float] {
        let n = h * w
        precondition(input.count == 3 * n)

        func layer(_ i: Int, _ x: [Float]) -> [Float] {
            let l = layers[i]
            let dw = Self.depthwise3x3(x, channels: l.inChannels, height: h, width: w,
                                       weights: l.depthWeights, bias: l.depthBias)
            return Self.pointwise(dw, inChannels: l.inChannels, outChannels: l.outChannels, pixels: n,
                                  weights: l.pointWeights, bias: l.pointBias)
        }

        let x1 = Self.relu(layer(0, input))
        let x2 = Self.relu(layer(1, x1))
        let x3 = Self.relu(layer(2, x2))
        let x4 = Self.relu(layer(3, x3))
        let x5 = Self.relu(layer(4, x3 + x4))
        let x6 = Self.relu(layer(5, x2 + x5))
        var out = layer(6, x1 + x6)
        var count = Int32(out.count)
        out.withUnsafeMutableBufferPointer { p in vvtanhf(p.baseAddress!, p.baseAddress!, &count) }
        return out
    }

    // MARK: - 整帧增强

    /// 对整帧做增强（原地修改 `image`，[3, H, W]，0...1）。
    /// - Parameters:
    ///   - curves: 外部传入的曲线参数（例如做了时间平滑的），为 nil 时现场估计
    /// - Returns: 本帧使用的曲线参数（缩小尺寸），供下一帧做时间平滑
    @discardableResult
    public func enhance(_ image: inout [Float], height: Int, width: Int, factor: Int,
                        curves: [Float]? = nil) -> [Float] {
        let (lh, lw) = Self.lowResSize(height: height, width: width, factor: factor)
        let lowCurves = curves ?? estimateCurves(
            Self.downsampleArea(image, channels: 3, height: height, width: width, factor: factor),
            height: lh, width: lw)
        let r = Self.upsampleBilinearAlignCorners(lowCurves, channels: 3, fromHeight: lh, fromWidth: lw,
                                                  toHeight: height, toWidth: width)
        Self.applyCurves(&image, r)
        return lowCurves
    }

    /// 视频逐帧用：估计曲线 → 时间平滑 → 增强 → 按强度与原图混合。
    /// - Parameter strength: 0 = 原图，1 = 完整增强
    public func enhanceFrame(_ image: inout [Float], height: Int, width: Int, factor: Int,
                             smoother: inout CurveSmoother, strength: Float = 1) {
        let (lh, lw) = Self.lowResSize(height: height, width: width, factor: factor)
        let raw = estimateCurves(Self.downsampleArea(image, channels: 3, height: height, width: width, factor: factor),
                                 height: lh, width: lw)
        let curves = smoother.smooth(raw)
        let clampedStrength = min(max(strength, 0), 1)
        guard clampedStrength < 1 else {
            enhance(&image, height: height, width: width, factor: factor, curves: curves)
            return
        }
        let original = image
        enhance(&image, height: height, width: width, factor: factor, curves: curves)
        // image = original + s·(enhanced − original)
        var s = clampedStrength
        let n = vDSP_Length(image.count)
        image.withUnsafeMutableBufferPointer { p in
            vDSP_vintb(original, 1, p.baseAddress!, 1, &s, p.baseAddress!, 1, n)
        }
    }

    public static func lowResSize(height: Int, width: Int, factor: Int) -> (Int, Int) {
        ((height + factor - 1) / factor, (width + factor - 1) / factor)
    }

    // MARK: - 基础算子（internal，便于测试）

    static func downsampleArea(_ x: [Float], channels: Int, height h: Int, width w: Int, factor f: Int) -> [Float] {
        let (lh, lw) = lowResSize(height: h, width: w, factor: f)
        var out = [Float](repeating: 0, count: channels * lh * lw)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for c in 0..<channels {
                    let plane = c * h * w
                    for i in 0..<lh {
                        let y0 = i * f, y1 = min(y0 + f, h)
                        for j in 0..<lw {
                            let x0 = j * f, x1 = min(x0 + f, w)
                            var sum: Float = 0
                            for y in y0..<y1 {
                                let row = plane + y * w
                                for xx in x0..<x1 { sum += src[row + xx] }
                            }
                            dst[(c * lh + i) * lw + j] = sum / Float((y1 - y0) * (x1 - x0))
                        }
                    }
                }
            }
        }
        return out
    }

    /// 3×3 深度卷积，四周补零（与 PyTorch padding=1 相同，互相关不翻转核）
    static func depthwise3x3(_ x: [Float], channels: Int, height h: Int, width w: Int,
                             weights: [Float], bias: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: channels * h * w)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for c in 0..<channels {
                    let plane = c * h * w
                    let k = Array(weights[(c * 9)..<(c * 9 + 9)])
                    let b = bias[c]
                    for i in 0..<h {
                        for j in 0..<w {
                            var sum = b
                            for dy in 0..<3 {
                                let y = i + dy - 1
                                if y < 0 || y >= h { continue }
                                let row = plane + y * w
                                for dx in 0..<3 {
                                    let xx = j + dx - 1
                                    if xx < 0 || xx >= w { continue }
                                    sum += k[dy * 3 + dx] * src[row + xx]
                                }
                            }
                            dst[plane + i * w + j] = sum
                        }
                    }
                }
            }
        }
        return out
    }

    /// 1×1 卷积 = 矩阵乘法：[O, C] × [C, N] + bias
    static func pointwise(_ x: [Float], inChannels: Int, outChannels: Int, pixels: Int,
                          weights: [Float], bias: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: outChannels * pixels)
        vDSP_mmul(weights, 1, x, 1, &out, 1, vDSP_Length(outChannels), vDSP_Length(pixels), vDSP_Length(inChannels))
        out.withUnsafeMutableBufferPointer { p in
            for o in 0..<outChannels {
                var b = bias[o]
                let row = p.baseAddress! + o * pixels
                vDSP_vsadd(row, 1, &b, row, 1, vDSP_Length(pixels))
            }
        }
        return out
    }

    static func relu(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var zero: Float = 0
        vDSP_vthr(x, 1, &zero, &out, 1, vDSP_Length(x.count))
        return out
    }

    static func upsampleBilinearAlignCorners(_ x: [Float], channels: Int, fromHeight lh: Int, fromWidth lw: Int,
                                             toHeight h: Int, toWidth w: Int) -> [Float] {
        func coords(_ nOut: Int, _ nIn: Int) -> (i0: [Int], i1: [Int], frac: [Float]) {
            var i0 = [Int](repeating: 0, count: nOut), i1 = i0, frac = [Float](repeating: 0, count: nOut)
            guard nOut > 1, nIn > 1 else { return (i0, i1, frac) }
            let scale = Double(nIn - 1) / Double(nOut - 1)
            for k in 0..<nOut {
                let pos = Double(k) * scale
                let base = min(Int(pos.rounded(.down)), nIn - 1)
                i0[k] = base
                i1[k] = min(base + 1, nIn - 1)
                frac[k] = Float(pos - Double(base))
            }
            return (i0, i1, frac)
        }
        let ys = coords(h, lh), xs = coords(w, lw)
        var out = [Float](repeating: 0, count: channels * h * w)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for c in 0..<channels {
                    let inPlane = c * lh * lw, outPlane = c * h * w
                    for i in 0..<h {
                        let r0 = inPlane + ys.i0[i] * lw, r1 = inPlane + ys.i1[i] * lw
                        let fy = ys.frac[i]
                        for j in 0..<w {
                            let fx = xs.frac[j], a = xs.i0[j], b = xs.i1[j]
                            let top = src[r0 + a] * (1 - fx) + src[r0 + b] * fx
                            let bottom = src[r1 + a] * (1 - fx) + src[r1 + b] * fx
                            dst[outPlane + i * w + j] = top * (1 - fy) + bottom * fy
                        }
                    }
                }
            }
        }
        return out
    }

    /// x = x + r·(x² − x)，迭代 8 次
    static func applyCurves(_ x: inout [Float], _ r: [Float]) {
        precondition(x.count == r.count)
        let n = vDSP_Length(x.count)
        var t = [Float](repeating: 0, count: x.count)
        var minusOne: Float = -1
        r.withUnsafeBufferPointer { rp in
            x.withUnsafeMutableBufferPointer { xp in
                t.withUnsafeMutableBufferPointer { tp in
                    let r = rp.baseAddress!, x = xp.baseAddress!, t = tp.baseAddress!
                    for _ in 0..<8 {
                        vDSP_vsadd(x, 1, &minusOne, t, 1, n)  // t = x - 1
                        vDSP_vmul(t, 1, x, 1, t, 1, n)        // t = x·(x - 1) = x² - x
                        vDSP_vma(r, 1, t, 1, x, 1, x, 1, n)   // x = r·t + x
                    }
                }
            }
        }
    }
}

/// 视频逐帧增强时的时间平滑：曲线参数做指数滑动平均，减少画面闪烁。
public struct CurveSmoother: Sendable {
    /// 0 = 不平滑；越接近 1 越平稳（但光线变化时跟得越慢）
    public var smoothing: Float
    private var previous: [Float]?

    public init(smoothing: Float = 0.6) {
        self.smoothing = smoothing
    }

    public mutating func reset() { previous = nil }

    public mutating func smooth(_ curves: [Float]) -> [Float] {
        guard smoothing > 0, let prev = previous, prev.count == curves.count else {
            previous = curves
            return curves
        }
        var out = [Float](repeating: 0, count: curves.count)
        // out = prev·s + curves·(1 - s)
        var s = smoothing, oneMinus = 1 - smoothing
        let n = vDSP_Length(out.count)
        out.withUnsafeMutableBufferPointer { op in
            let o = op.baseAddress!
            vDSP_vsmul(prev, 1, &s, o, 1, n)
            vDSP_vsma(curves, 1, &oneMinus, o, 1, o, 1, n)
        }
        previous = out
        return out
    }
}
