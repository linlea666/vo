import CryptoKit
import Foundation

/// 一次“修复”的完整配方：用什么方式、什么模型版本、什么参数。
/// 同一个视频 + 同一个配方 = 同一个缓存键，已经修过就不再重修。
public struct EnhanceRecipe: Codable, Hashable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// 本地 AI（Core ML，跑在神经网络引擎上，免费）
        case localAI = "local-ai"
        /// 云端 AI（花额度）
        case cloudAI = "cloud-ai"
    }

    public var method: Method
    /// 模型标识，例如 "zero-dce-pp"、"replicate:<model>"
    public var model: String
    /// 模型或算法版本；升级算法后改版本号，旧结果就不会被误用
    public var modelVersion: String
    /// 其他参数（强度、输出分辨率等），按键排序参与缓存键
    public var parameters: [String: String]

    public init(method: Method, model: String, modelVersion: String, parameters: [String: String] = [:]) {
        self.method = method
        self.model = model
        self.modelVersion = modelVersion
        self.parameters = parameters
    }

    /// 稳定的文字描述，参数按键排序，保证同样的配方得到同样的键。
    public var canonicalDescription: String {
        let params = parameters.keys.sorted().map { "\($0)=\(parameters[$0]!)" }.joined(separator: "&")
        return "\(method.rawValue)|\(model)|\(modelVersion)|\(params)"
    }

    public func cacheKey(fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data("\(fingerprint)|\(canonicalDescription)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
