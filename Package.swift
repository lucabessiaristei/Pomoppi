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
// Phase W1), so this #if is a host check, not a target check. PomoppiRender
// is now shared/buildable on both platforms (Phase W2 stripped CoreGraphics
// out of its internal storage; its one CG-dependent file,
// PixelCanvas+CoreGraphics.swift, is guarded by its own
// `#if canImport(CoreGraphics)` and is simply inert on Windows —
// WidgetRenderer.swift's own CG-dependent import/draw() got the same
// treatment for the same reason). PomoppiRenderTests stays out of the
// Windows branch for now, though: it still exercises
// WidgetRenderer.draw() -> CGImage? and reads .width/.height straight off
// the CGImage, which doesn't exist on Windows at all — running that test
// target there needs that test guarded or split out first, which is out of
// scope for this phase. PomoppiApp (the macOS AppKit/SwiftUI shell) stays
// out of the Windows branch too, unrelated to any of the above.
#if os(Windows)
let targets: [Target] = [
    .target(name: "PomoppiCore", swiftSettings: swiftSettings),
    .target(name: "PomoppiSprites", swiftSettings: swiftSettings),
    .target(name: "PomoppiRender", dependencies: ["PomoppiCore", "PomoppiSprites"], swiftSettings: swiftSettings),
    .executableTarget(name: "PomoppiWindows", dependencies: ["PomoppiCore", "PomoppiRender", "PomoppiSprites"], exclude: ["Pomoppi.exe.manifest"], swiftSettings: swiftSettings),
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
