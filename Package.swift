// swift-tools-version: 6.0
import PackageDescription

// Tools-version 6.0 only because `.macOS(.v15)` (needed for the settings
// window's `Tab(_:systemImage:content:)` API) isn't available in older
// PackageDescription versions. Every target still opts back into the Swift
// 5 language mode below — this app's mutable caches/singletons (sprite
// caches, the shortcut manager) are all single-threaded, main-thread-only
// state, so Swift 6's strict concurrency checking would be pure churn here,
// not a real safety improvement.
let swiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Pomoppi",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "PomoppiCore", swiftSettings: swiftSettings),
        .target(name: "PomoppiSprites", swiftSettings: swiftSettings),
        .target(name: "PomoppiRender", dependencies: ["PomoppiCore", "PomoppiSprites"], swiftSettings: swiftSettings),
        .executableTarget(name: "PomoppiApp", dependencies: ["PomoppiCore", "PomoppiRender"], swiftSettings: swiftSettings),
        .testTarget(name: "PomoppiCoreTests", dependencies: ["PomoppiCore"], swiftSettings: swiftSettings),
        .testTarget(name: "PomoppiSpritesTests", dependencies: ["PomoppiSprites"], swiftSettings: swiftSettings),
        .testTarget(name: "PomoppiRenderTests", dependencies: ["PomoppiRender"], swiftSettings: swiftSettings),
    ]
)
