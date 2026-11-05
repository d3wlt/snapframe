// swift-tools-version:6.0
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Snapframe",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SnapframeCore", swiftSettings: swift6),
        .executableTarget(name: "Snapframe", dependencies: ["SnapframeCore"], swiftSettings: swift6),
        // Renders the README screenshots offscreen: `swift run SnapframeScreenshots [outdir]`.
        .executableTarget(name: "SnapframeScreenshots", dependencies: ["SnapframeCore"], swiftSettings: swift6),
        // Plain executable test runner: the Command Line Tools here lack a usable XCTest/Swift Testing.
        // Run with `swift run SnapframeSelfTest`.
        .executableTarget(name: "SnapframeSelfTest", dependencies: ["SnapframeCore"], path: "Tests/SnapframeSelfTest",
                          swiftSettings: swift6),
    ]
)
