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
// build` — there's no real cross-compilation yet, so this #if is a host
// check, not a target check. PomoppiRender is now shared/buildable on
// both platforms (Phase W2 stripped CoreGraphics
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
// PomoppiStrings (the generated UI string catalog, LOCALIZATION_PLAN.md) is
// shared: both shells depend on it, PomoppiCore deliberately doesn't.
#if os(Windows)
let targets: [Target] = [
    .target(name: "PomoppiCore", swiftSettings: swiftSettings),
    .target(name: "PomoppiSprites", swiftSettings: swiftSettings),
    .target(name: "PomoppiRender", dependencies: ["PomoppiCore", "PomoppiSprites"], swiftSettings: swiftSettings),
    .target(name: "PomoppiStrings", swiftSettings: swiftSettings),
    // winmm isn't in MSVC's default link set (unlike kernel32/user32/gdi32/...)
    // — PlaySoundW (ChimePlayer.swift) needs it linked explicitly.
    .executableTarget(name: "PomoppiWindows", dependencies: ["PomoppiCore", "PomoppiRender", "PomoppiSprites", "PomoppiStrings"], exclude: ["Pomoppi.exe.manifest", "Pomoppi.rc"], swiftSettings: swiftSettings, linkerSettings: [.linkedLibrary("winmm")]),
    .testTarget(name: "PomoppiCoreTests", dependencies: ["PomoppiCore", "PomoppiStrings"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiSpritesTests", dependencies: ["PomoppiSprites"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiStringsTests", dependencies: ["PomoppiStrings"], swiftSettings: swiftSettings),
]
#else
let targets: [Target] = [
    .target(name: "PomoppiCore", swiftSettings: swiftSettings),
    .target(name: "PomoppiSprites", swiftSettings: swiftSettings),
    .target(name: "PomoppiRender", dependencies: ["PomoppiCore", "PomoppiSprites"], swiftSettings: swiftSettings),
    .target(name: "PomoppiStrings", swiftSettings: swiftSettings),
    .executableTarget(name: "PomoppiApp", dependencies: ["PomoppiCore", "PomoppiRender", "PomoppiStrings"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiCoreTests", dependencies: ["PomoppiCore", "PomoppiStrings"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiSpritesTests", dependencies: ["PomoppiSprites"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiRenderTests", dependencies: ["PomoppiRender"], swiftSettings: swiftSettings),
    .testTarget(name: "PomoppiStringsTests", dependencies: ["PomoppiStrings"], swiftSettings: swiftSettings),
]
#endif

let package = Package(
    name: "Pomoppi",
    platforms: [.macOS(.v15)],
    targets: targets
)
