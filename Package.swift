// swift-tools-version: 5.9
import PackageDescription

// 方案：拆 library target CodexPulseCore + executable CodexPulse + testTarget。
// Core = Sources/CodexPulse（模块实现）；App 入口 / AppDelegate / 内联自测在 Sources/CodexPulseApp。
// 自测与 AppDelegate 同属可执行目标，因 CPSelfTests 引用 AppDelegate；否则 Core 无法被
// testTarget 独立链接。build-app.sh 已同步编译两个目录（本机唯一可验证路径）。
// ⚠️ Package.swift / SPM 目标图未经 swift build / swift test 验证。

let package = Package(
    name: "CodexPulse",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CodexPulseCore", targets: ["CodexPulseCore"]),
        .executable(name: "CodexPulse", targets: ["CodexPulse"]),
    ],
    targets: [
        .target(
            name: "CodexPulseCore",
            path: "Sources/CodexPulse",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "CodexPulse",
            dependencies: ["CodexPulseCore"],
            path: "Sources/CodexPulseApp",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CodexPulseTests",
            dependencies: ["CodexPulseCore"],
            path: "Tests/CodexPulseTests",
            exclude: [
                "SyntaxCheck",
            ],
            resources: [
                .copy("Fixtures"),
            ],
            cSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
