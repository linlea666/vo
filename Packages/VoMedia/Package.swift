// swift-tools-version:5.9

import PackageDescription

// 媒体处理：AI 修复导出（读取 → 增强 → 编码）。
// AVFoundation 能读的格式走 AVFoundation；mkv / avi / flv / webm 等用 MPVKit 自带的 FFmpeg 读取。
let package = Package(
    name: "VoMedia",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoMedia", targets: ["VoMedia"]),
    ],
    dependencies: [
        .package(path: "../VoCore"),
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.0.0"),
    ],
    targets: [
        .target(name: "VoMedia", dependencies: [
            "VoCore",
            .product(name: "MPVKit", package: "MPVKit"),
        ]),
        .testTarget(name: "VoMediaTests", dependencies: ["VoMedia", "VoCore"]),
    ]
)
