// swift-tools-version:6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Snapframe",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SnapframeCore", swiftSettings: swift5),
        .executableTarget(name: "Snapframe", dependencies: ["SnapframeCore"], swiftSettings: swift5),
        // Renders the README screenshots offscreen: `swift run SnapframeScreenshots [outdir]`.
        .executableTarget(name: "SnapframeScreenshots", dependencies: ["SnapframeCore"], swiftSettings: swift5),
        // Plain executable test runner: the Command Line Tools here lack a usable XCTest/Swift Testing.
        // Run with `swift run SnapframeSelfTest`.
        .executableTarget(name: "SnapframeSelfTest", dependencies: ["SnapframeCore"], path: "Tests/SnapframeSelfTest",
                          swiftSettings: swift5),
    ]
)
