import Foundation

/// 修复结果库：记录每个视频已经修好的版本，避免重复处理、重复花 AI 额度。
///
/// 索引是一个 JSON 文件（条目不多，够用且好排查），修复后的视频存放在
/// `<根目录>/Enhanced/<缓存键>.mp4`，也可以由调用方指定其他输出位置。
public final class EnhancementCache: @unchecked Sendable {
    public enum Status: String, Codable, Sendable {
        /// 已提交（云端任务已拿到任务 ID，尚未下载完成）
        case submitted
        /// 处理中（本地导出进行中）
        case processing
        /// 完成，输出文件可用
        case completed
        case failed
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var key: String
        public var fingerprint: String
        public var recipe: EnhanceRecipe
        public var sourcePath: String
        public var outputPath: String
        public var status: Status
        /// 云端任务 ID：提交后立刻记下，断网/退出后重开继续取结果，不重复提交
        public var remoteJobID: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var errorMessage: String?

        public var outputURL: URL { URL(fileURLWithPath: outputPath) }
    }

    private struct Index: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    public let rootDirectory: URL
    public var enhancedDirectory: URL { rootDirectory.appendingPathComponent("Enhanced", isDirectory: true) }
    private var indexURL: URL { rootDirectory.appendingPathComponent("index.json") }

    private let lock = NSLock()
    private var index: Index
    private let fileManager = FileManager.default

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try fileManager.createDirectory(at: rootDirectory.appendingPathComponent("Enhanced", isDirectory: true),
                                        withIntermediateDirectories: true)
        let indexURL = rootDirectory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL) {
            // 索引损坏时不崩溃：备份旧文件后从空索引开始
            if let decoded = try? Self.decoder.decode(Index.self, from: data) {
                index = decoded
            } else {
                let backup = rootDirectory.appendingPathComponent("index.corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: indexURL, to: backup)
                index = Index()
            }
        } else {
            index = Index()
        }
    }

    /// 默认位置：~/Library/Application Support/VoPlayer
    public static func defaultRootDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("VoPlayer", isDirectory: true)
    }

    /// 某个配方默认的输出位置
    public func defaultOutputURL(forKey key: String) -> URL {
        enhancedDirectory.appendingPathComponent("\(key).mp4")
    }

    // MARK: - 查询

    public func entry(forKey key: String) -> Entry? {
        lock.locked { index.entries[key] }
    }

    /// 这个配方有没有可直接用的结果（状态完成且文件还在）。
    public func completedEntry(fingerprint: String, recipe: EnhanceRecipe) -> Entry? {
        guard let entry = entry(forKey: recipe.cacheKey(fingerprint: fingerprint)),
              entry.status == .completed,
              fileManager.fileExists(atPath: entry.outputPath) else { return nil }
        return entry
    }

    /// 某个视频所有可用的修复版，新的在前。
    public func completedEntries(fingerprint: String) -> [Entry] {
        let all = lock.locked { Array(index.entries.values) }
        return all
            .filter { $0.fingerprint == fingerprint && $0.status == .completed && fileManager.fileExists(atPath: $0.outputPath) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 已提交但还没下载完的云端任务（重开软件时用来续取结果）。
    public func pendingRemoteEntries() -> [Entry] {
        lock.locked { Array(index.entries.values) }
            .filter { $0.status == .submitted && $0.remoteJobID != nil }
    }

    public var allEntries: [Entry] {
        lock.locked { Array(index.entries.values) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 修复结果占用的总空间（字节）
    public func totalOutputBytes() -> Int64 {
        allEntries.reduce(0) { sum, entry in
            let size = (try? fileManager.attributesOfItem(atPath: entry.outputPath)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    // MARK: - 写入

    /// 开始一次修复：登记条目（状态 processing / submitted），返回条目。
    @discardableResult
    public func begin(fingerprint: String, recipe: EnhanceRecipe, sourceURL: URL,
                      outputURL: URL? = nil, status: Status = .processing,
                      remoteJobID: String? = nil, now: Date = Date()) throws -> Entry {
        let key = recipe.cacheKey(fingerprint: fingerprint)
        let entry = Entry(key: key, fingerprint: fingerprint, recipe: recipe,
                          sourcePath: sourceURL.path,
                          outputPath: (outputURL ?? defaultOutputURL(forKey: key)).path,
                          status: status, remoteJobID: remoteJobID,
                          createdAt: now, updatedAt: now, errorMessage: nil)
        try mutate { $0.entries[key] = entry }
        return entry
    }

    public func update(key: String, now: Date = Date(), _ change: (inout Entry) -> Void) throws {
        try mutate { index in
            guard var entry = index.entries[key] else { return }
            change(&entry)
            entry.updatedAt = now
            index.entries[key] = entry
        }
    }

    public func markCompleted(key: String) throws {
        try update(key: key) { $0.status = .completed; $0.errorMessage = nil }
    }

    public func markFailed(key: String, message: String) throws {
        try update(key: key) { $0.status = .failed; $0.errorMessage = message }
    }

    /// 删除条目，连同输出文件一起删。
    public func remove(key: String) throws {
        var removed: Entry?
        try mutate { removed = $0.entries.removeValue(forKey: key) }
        if let removed, fileManager.fileExists(atPath: removed.outputPath) {
            try fileManager.removeItem(atPath: removed.outputPath)
        }
    }

    /// 清掉已登记但输出文件已丢失的“完成”条目，以及中途中断的本地任务。
    public func pruneMissingOutputs() throws {
        try mutate { index in
            index.entries = index.entries.filter { _, entry in
                switch entry.status {
                case .completed: return fileManager.fileExists(atPath: entry.outputPath)
                case .processing: return false
                case .submitted, .failed: return true
                }
            }
        }
    }

    // MARK: - 内部

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func mutate(_ body: (inout Index) -> Void) throws {
        try lock.locked {
            body(&index)
            let data = try Self.encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        }
    }
}

extension NSLock {
    /// 自带实现，避免依赖较新系统才有的 `withLock`。
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
