import CryptoKit
import Foundation

/// 视频指纹：识别“同一个视频”，与文件名、所在位置无关。
///
/// 只读文件头、中、尾各一段（默认 4MB）再加上文件大小做 SHA-256，
/// 几 GB 的文件也是毫秒级；改名、移动后指纹不变，内容变了指纹就变。
public enum VideoFingerprint {
    public static let version = "v1"
    public static let defaultSampleSize = 4 * 1024 * 1024

    public static func compute(for url: URL, sampleSize: Int = defaultSampleSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        for range in sampleRanges(fileSize: size, sampleSize: UInt64(sampleSize)) {
            try handle.seek(toOffset: range.offset)
            if let data = try handle.read(upToCount: Int(range.length)) {
                hasher.update(data: data)
            }
        }

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(version)-\(hex)"
    }

    /// 取样区间：小文件整个读；大文件取头、中、尾三段，互不重叠。
    static func sampleRanges(fileSize: UInt64, sampleSize: UInt64) -> [(offset: UInt64, length: UInt64)] {
        guard fileSize > sampleSize * 3 else { return [(0, fileSize)] }
        let middle = fileSize / 2 - sampleSize / 2
        return [(0, sampleSize), (middle, sampleSize), (fileSize - sampleSize, sampleSize)]
    }
}
