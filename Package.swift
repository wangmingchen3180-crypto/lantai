// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexPulse",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CodexPulse",
            path: "Sources/CodexPulse",
            publicHeadersPath: ".",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
