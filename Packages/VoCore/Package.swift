// swift-tools-version:5.9

import PackageDescription

// 与界面、播放内核无关的纯逻辑：视频指纹、修复结果缓存、画面调整参数。
// 单独成包，方便在 CI 里用 `swift test` 快速测试。
let package = Package(
    name: "VoCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoCore", targets: ["VoCore"]),
    ],
    targets: [
        .target(name: "VoCore", resources: [.copy("Resources/zero_dce_pp.bin")]),
        .testTarget(name: "VoCoreTests", dependencies: ["VoCore"],
                    resources: [.copy("Resources/zero_dce_reference.json")]),
    ]
)
