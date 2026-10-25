import XCTest
@testable import VoCore

final class VideoFingerprintTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testSameContentDifferentNameGivesSameFingerprint() throws {
        let bytes = (0..<10_000).map { UInt8($0 % 251) }
        let a = try write(bytes, name: "a.mp4")
        let b = try write(bytes, name: "renamed.mkv")
        XCTAssertEqual(try VideoFingerprint.compute(for: a, sampleSize: 1024),
                       try VideoFingerprint.compute(for: b, sampleSize: 1024))
    }

    func testChangeInAnySampledRegionChangesFingerprint() throws {
        let bytes = (0..<10_000).map { UInt8($0 % 251) }
        let original = try VideoFingerprint.compute(for: write(bytes, name: "o"), sampleSize: 1024)
        for index in [10, 5_000, 9_990] {
            var changed = bytes
            changed[index] ^= 0xFF
            let fp = try VideoFingerprint.compute(for: write(changed, name: "c\(index)"), sampleSize: 1024)
            XCTAssertNotEqual(fp, original, "修改第 \(index) 字节后指纹应变化")
        }
    }

    func testSmallFileIsHashedEntirely() throws {
        // 文件小于 3 个取样块时整个读取，末尾的改动也必须能识别出来
        let bytes = [UInt8](repeating: 7, count: 2_500)
        var changed = bytes
        changed[2_000] = 8
        XCTAssertNotEqual(try VideoFingerprint.compute(for: write(bytes, name: "s1"), sampleSize: 1024),
                          try VideoFingerprint.compute(for: write(changed, name: "s2"), sampleSize: 1024))
    }

    func testSampleRanges() {
        XCTAssertEqual(VideoFingerprint.sampleRanges(fileSize: 100, sampleSize: 40).map(\.offset), [0])
        XCTAssertEqual(VideoFingerprint.sampleRanges(fileSize: 100, sampleSize: 40).map(\.length), [100])
        let ranges = VideoFingerprint.sampleRanges(fileSize: 1_000, sampleSize: 100)
        XCTAssertEqual(ranges.map(\.offset), [0, 450, 900])
        XCTAssertEqual(ranges.map(\.length), [100, 100, 100])
    }

    func testFingerprintHasVersionPrefix() throws {
        let fp = try VideoFingerprint.compute(for: write([1, 2, 3], name: "v"))
        XCTAssertTrue(fp.hasPrefix("v1-"))
    }
}

final class EnhanceRecipeTests: XCTestCase {
    func testCacheKeyIgnoresParameterOrder() {
        let a = EnhanceRecipe(method: .localAI, model: "zero-dce-pp", modelVersion: "1",
                              parameters: ["strength": "0.8", "scale": "1"])
        var b = EnhanceRecipe(method: .localAI, model: "zero-dce-pp", modelVersion: "1")
        b.parameters["scale"] = "1"
        b.parameters["strength"] = "0.8"
        XCTAssertEqual(a.cacheKey(fingerprint: "fp"), b.cacheKey(fingerprint: "fp"))
    }

    func testCacheKeyChangesWithAnyInput() {
        let base = EnhanceRecipe(method: .localAI, model: "zero-dce-pp", modelVersion: "1", parameters: ["s": "1"])
        let key = base.cacheKey(fingerprint: "fp")
        XCTAssertNotEqual(key, base.cacheKey(fingerprint: "fp2"))
        var v = base; v.modelVersion = "2"
        XCTAssertNotEqual(key, v.cacheKey(fingerprint: "fp"))
        var m = base; m.method = .cloudAI
        XCTAssertNotEqual(key, m.cacheKey(fingerprint: "fp"))
        var p = base; p.parameters["s"] = "2"
        XCTAssertNotEqual(key, p.cacheKey(fingerprint: "fp"))
    }
}

final class EnhancementCacheTests: XCTestCase {
    private var root: URL!
    private let recipe = EnhanceRecipe(method: .localAI, model: "zero-dce-pp", modelVersion: "1")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCompletedEntryRequiresCompletedStatusAndExistingFile() throws {
        let cache = try EnhancementCache(rootDirectory: root)
        let entry = try cache.begin(fingerprint: "fp", recipe: recipe, sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"))
        XCTAssertNil(cache.completedEntry(fingerprint: "fp", recipe: recipe), "处理中不算可用")

        try Data([0]).write(to: entry.outputURL)
        try cache.markCompleted(key: entry.key)
        XCTAssertEqual(cache.completedEntry(fingerprint: "fp", recipe: recipe)?.key, entry.key)

        try FileManager.default.removeItem(at: entry.outputURL)
        XCTAssertNil(cache.completedEntry(fingerprint: "fp", recipe: recipe), "文件被删后不算可用")
    }

    func testIndexPersistsAcrossInstances() throws {
        let entry: EnhancementCache.Entry
        do {
            let cache = try EnhancementCache(rootDirectory: root)
            entry = try cache.begin(fingerprint: "fp", recipe: recipe, sourceURL: URL(fileURLWithPath: "/a.mp4"))
            try Data([1, 2]).write(to: entry.outputURL)
            try cache.markCompleted(key: entry.key)
        }
        let reopened = try EnhancementCache(rootDirectory: root)
        XCTAssertEqual(reopened.completedEntries(fingerprint: "fp").map(\.key), [entry.key])
        XCTAssertEqual(reopened.totalOutputBytes(), 2)
    }

    func testRemoteJobIDIsKeptForResume() throws {
        let cloud = EnhanceRecipe(method: .cloudAI, model: "replicate:x", modelVersion: "abc")
        do {
            let cache = try EnhancementCache(rootDirectory: root)
            try cache.begin(fingerprint: "fp", recipe: cloud, sourceURL: URL(fileURLWithPath: "/a.mp4"),
                            status: .submitted, remoteJobID: "job-123")
        }
        let reopened = try EnhancementCache(rootDirectory: root)
        XCTAssertEqual(reopened.pendingRemoteEntries().map(\.remoteJobID), ["job-123"])
    }

    func testPruneDropsInterruptedLocalJobsAndMissingOutputs() throws {
        let cache = try EnhancementCache(rootDirectory: root)
        let processing = try cache.begin(fingerprint: "a", recipe: recipe, sourceURL: URL(fileURLWithPath: "/a"))
        let missing = try cache.begin(fingerprint: "b", recipe: recipe, sourceURL: URL(fileURLWithPath: "/b"))
        try cache.markCompleted(key: missing.key)
        let kept = try cache.begin(fingerprint: "c", recipe: recipe, sourceURL: URL(fileURLWithPath: "/c"))
        try Data([0]).write(to: kept.outputURL)
        try cache.markCompleted(key: kept.key)

        try cache.pruneMissingOutputs()
        XCTAssertNil(cache.entry(forKey: processing.key))
        XCTAssertNil(cache.entry(forKey: missing.key))
        XCTAssertNotNil(cache.entry(forKey: kept.key))
    }

    func testRemoveDeletesOutputFile() throws {
        let cache = try EnhancementCache(rootDirectory: root)
        let entry = try cache.begin(fingerprint: "fp", recipe: recipe, sourceURL: URL(fileURLWithPath: "/a"))
        try Data([0]).write(to: entry.outputURL)
        try cache.remove(key: entry.key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.outputPath))
        XCTAssertNil(cache.entry(forKey: entry.key))
    }

    func testCorruptIndexIsBackedUpNotFatal() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("index.json"))
        let cache = try EnhancementCache(rootDirectory: root)
        XCTAssertTrue(cache.allEntries.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("index.corrupt-") })
    }
}

final class VideoAdjustmentsTests: XCTestCase {
    func testIdentityProducesNoFilters() {
        XCTAssertEqual(MPVFilterChain.vf(adjustments: .identity, orientation: VideoOrientation()), "")
    }

    func testFilterChainOrderAndFormat() {
        let adj = VideoAdjustments(denoise: 5, sharpen: 2)
        let vf = MPVFilterChain.vf(adjustments: adj, orientation: VideoOrientation(flipHorizontal: true))
        XCTAssertEqual(vf, "lavfi=[hqdn3d=4.00:3.00:6.00:4.50,unsharp=5:5:0.30,hflip]")
    }

    func testClamping() {
        let adj = VideoAdjustments(brightness: 300, gamma: -300, denoise: 99, sharpen: -1).clamped()
        XCTAssertEqual(adj.brightness, 100)
        XCTAssertEqual(adj.gamma, -100)
        XCTAssertEqual(adj.denoise, 10)
        XCTAssertEqual(adj.sharpen, 0)
    }

    func testLowLightPresetBrightens() {
        let adj = AdjustmentPreset.lowLight.adjustments
        XCTAssertGreaterThan(adj.gamma, 0)
        XCTAssertGreaterThan(adj.denoise, 0)
    }

    func testRotationNormalization() {
        var o = VideoOrientation()
        o.rotateCounterClockwise()
        XCTAssertEqual(o.rotation, 270)
        for _ in 0..<5 { o.rotateClockwise() }
        XCTAssertEqual(o.rotation, 180)
        XCTAssertEqual(VideoOrientation(rotation: 450).rotation, 90)
        XCTAssertEqual(VideoOrientation(rotation: -90).rotation, 270)
    }
}

final class VideoSettingsStoreTests: XCTestCase {
    func testSaveLoadAndCapacity() {
        let suite = "vo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = VideoSettingsStore(defaults: defaults, capacity: 2)
        var s = VideoSettings.default
        s.adjustments = AdjustmentPreset.lowLight.adjustments
        store.save(s, for: "a")
        store.save(.default, for: "b")
        XCTAssertEqual(store.settings(for: "a"), s)

        store.save(.default, for: "c")
        XCTAssertNil(store.settings(for: "a"), "超出容量后最久未用的被丢弃")
        XCTAssertNotNil(store.settings(for: "b"))
        XCTAssertNotNil(store.settings(for: "c"))
    }
}
