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

// Package.swift is evaluated separately on whichever host runs `swift
// build` — there's no real cross-compilation yet (see WINDOWS_PORT_PLAN.md
// Phase W1), so this #if is a host check, not a target check. On Windows,
// PomoppiRender/PomoppiApp/PomoppiRenderTests stay out of the manifest
// entirely: PomoppiRender still has a live `import CoreGraphics` (fixed in
// Phase W2), so a Windows host can't build it. PomoppiCore and
// PomoppiSprites are Foundation-only and fully portable already.
#if os(Windows)
let targets: [Target] = [
    .target(name: "PomoppiCore", swiftSettings: swiftSettings),
    .target(name: "PomoppiSprites", swiftSettings: swiftSettings),
    .executableTarget(name: "PomoppiWindows", dependencies: ["PomoppiCore"], exclude: ["Pomoppi.exe.manifest"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiCoreTests", dependencies: ["PomoppiCore"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiSpritesTests", dependencies: ["PomoppiSprites"], swiftSettings: swiftSettings),
]
#else
let targets: [Target] = [
    .target(name: "PomoppiCore", swiftSettings: swiftSettings),
    .target(name: "PomoppiSprites", swiftSettings: swiftSettings),
    .target(name: "PomoppiRender", dependencies: ["PomoppiCore", "PomoppiSprites"], swiftSettings: swiftSettings),
    .executableTarget(name: "PomoppiApp", dependencies: ["PomoppiCore", "PomoppiRender"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiCoreTests", dependencies: ["PomoppiCore"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiSpritesTests", dependencies: ["PomoppiSprites"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiRenderTests", dependencies: ["PomoppiRender"], swiftSettings: swiftSettings),
]
#endif

let package = Package(
    name: "Pomoppi",
    platforms: [.macOS(.v15)],
    targets: targets
)
