import CoreGraphics
import CoreVideo
import Foundation

/// BGRA 像素缓冲 ⇄ 平面 RGB 浮点（CHW，0...1）。
public enum PixelBufferConversion {
    public enum ConversionError: Error {
        case unsupportedFormat(OSType)
        case sizeMismatch
    }

    /// 读取 32BGRA 像素缓冲，返回 [R 平面, G 平面, B 平面]。
    public static func planarRGB(from buffer: CVPixelBuffer) throws -> (pixels: [Float], width: Int, height: Int) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA else { throw ConversionError.unsupportedFormat(format) }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ConversionError.sizeMismatch }

        let plane = width * height
        var out = [Float](repeating: 0, count: 3 * plane)
        let scale: Float = 1 / 255
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                let o = y * width
                for x in 0..<width {
                    let p = row + x * 4
                    dst[o + x] = Float(p[2]) * scale              // R
                    dst[plane + o + x] = Float(p[1]) * scale      // G
                    dst[2 * plane + o + x] = Float(p[0]) * scale  // B
                }
            }
        }
        return (out, width, height)
    }

    /// 把平面 RGB 写回 32BGRA 像素缓冲（超出 0...1 的值会被截断，Alpha 置 255）。
    public static func write(_ pixels: [Float], width: Int, height: Int, to buffer: CVPixelBuffer) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA else { throw ConversionError.unsupportedFormat(format) }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              pixels.count == 3 * width * height else { throw ConversionError.sizeMismatch }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ConversionError.sizeMismatch }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let plane = width * height

        @inline(__always) func byte(_ v: Float) -> UInt8 {
            UInt8(min(max(v * 255 + 0.5, 0), 255))
        }

        pixels.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                let o = y * width
                for x in 0..<width {
                    let p = row + x * 4
                    p[0] = byte(src[2 * plane + o + x])
                    p[1] = byte(src[plane + o + x])
                    p[2] = byte(src[o + x])
                    p[3] = 255
                }
            }
        }
    }

    public static func makeBGRABuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &buffer)
        return buffer
    }

    // MARK: - CGImage（预览用）

    /// 把图片转成平面 RGB（0...1）。
    public static func planarRGB(from image: CGImage) -> (pixels: [Float], width: Int, height: Int)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let plane = width * height
        var out = [Float](repeating: 0, count: 3 * plane)
        let scale: Float = 1 / 255
        for i in 0..<plane {
            out[i] = Float(rgba[i * 4]) * scale
            out[plane + i] = Float(rgba[i * 4 + 1]) * scale
            out[2 * plane + i] = Float(rgba[i * 4 + 2]) * scale
        }
        return (out, width, height)
    }

    /// 平面 RGB（0...1）转成图片（超出范围的值截断）。
    public static func makeCGImage(_ pixels: [Float], width: Int, height: Int) -> CGImage? {
        let plane = width * height
        guard plane > 0, pixels.count == 3 * plane else { return nil }
        var rgba = [UInt8](repeating: 255, count: plane * 4)
        func byte(_ v: Float) -> UInt8 { UInt8(min(max(v * 255 + 0.5, 0), 255)) }
        for i in 0..<plane {
            rgba[i * 4] = byte(pixels[i])
            rgba[i * 4 + 1] = byte(pixels[plane + i])
            rgba[i * 4 + 2] = byte(pixels[2 * plane + i])
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
