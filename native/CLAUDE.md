# Pomoppi (native/Swift)

This is a from-scratch **Swift/AppKit + SwiftUI** rewrite of Pomoppi, living
entirely under `native/`. It is a separate build target from the Electron app
at the repo root — different language, different toolchain, different
package manifest — but it targets the **same behavior**, so `../SPEC.md`
(one directory up) is still the authoritative *behavior* contract for both
implementations: window layering, art direction, keyboard shortcuts, settings
schema, etc. Where `SPEC.md` talks about Electron-specific mechanics (IPC,
`contextBridge`, npm packaging), read it for the *intent*, not the literal
API — this codebase has no Electron and no npm runtime dependency at all.

The root `CLAUDE.md`/`README.md` describe only the legacy Electron app —
they don't apply here. This file is the native app's own contract; if it and
the root docs disagree about anything native-specific, this one wins.

## Commands (run from `native/`)

```sh
swift build              # build (debug)
swift test                # run all three test targets
swift run PomoppiApp      # run
node Scripts/make-app.js  # assemble a real double-clickable Pomoppi.app (release build)
node Scripts/generate-sprites.js  # re-import art from ../renderer/*.js, rewrites Sources/PomoppiSprites/Sprites.generated.swift
```

Dev-run settings live at `native/.dev-app-support/settings.json` (loose
binary, no bundle identifier). A real, installed `.app` build shares the
Electron app's real path, `~/Library/Application Support/Pomoppi/settings.json`
— see `AppDelegate.storageDir()`.

## File map

| File | What |
|---|---|
| `Package.swift` | SPM manifest. Tools-version 6.0 only for `.macOS(.v15)`; every target still opts back into Swift 5 language mode (this app's mutable caches/singletons are single-threaded, main-thread-only state) |
| `Sources/PomoppiApp/AppDelegate.swift` | App lifecycle, window/tray wiring, global shortcuts, login item, settings storage path |
| `Sources/PomoppiApp/PomoppiApp.swift` | SwiftUI `@main` entry — owns only the `Settings` scene; the rest of the lifecycle is AppKit via `NSApplicationDelegateAdaptor` |
| `Sources/PomoppiApp/SettingsOpener.swift` | Bridges AppKit → the SwiftUI `Settings` scene (see invariants below) |
| `Sources/PomoppiApp/SettingsView.swift` / `SettingsViewModel.swift` | Settings window content and its view model |
| `Sources/PomoppiApp/TrayController.swift` | Menu bar icon: menu, tray click behavior, live clock |
| `Sources/PomoppiApp/WidgetWindow.swift` / `WidgetPixelView.swift` | The floating pixel widget window and its hit-testing/drawing view |
| `Sources/PomoppiApp/GlobalShortcutManager.swift` | Registers/unregisters the OS-level hotkeys |
| `Sources/PomoppiApp/LoginItem.swift` | Launch-at-login registration |
| `Sources/PomoppiApp/PixelPreviews.swift`, `Color+Hex.swift` | SwiftUI preview helpers / hex color conversion |
| `Sources/PomoppiCore/` | Platform-agnostic core: `Timer.swift` (wall-clock pomodoro state machine), `Settings.swift` (load/validate/persist, no AppKit import), `Shortcuts.swift`, `ObsidianLogger.swift` |
| `Sources/PomoppiRender/` | Drawing: `PixelCanvas.swift` (the 1px drawing kit), `WidgetLayout.swift`, `WidgetAnimationController.swift`, `WidgetRenderer.swift` |
| `Sources/PomoppiSprites/Sprites.generated.swift` | **Generated** by `Scripts/generate-sprites.js` from the Electron app's `../renderer/sprites.js` / `friends.js` / `background.js` — never hand-edit. This is the one deliberate, one-way link back to the Electron tree: it stays the single source of art data so both apps render the same pets/icons |
| `Sources/PomoppiSprites/Digits.swift`, `WindowFrame.swift` | Hand-written glyph/frame data (not generated) |
| `Scripts/generate-sprites.js` | Node importer described above |
| `Scripts/make-app.js` | Builds a release `Pomoppi.app` bundle, hand-rolled like the Electron app's retired `tools/make-launcher.js` |
| `Tests/` | `swift-testing`/XCTest-style suites mirroring `Sources/PomoppiCore`, `PomoppiRender`, `PomoppiSprites` |

## Invariants that keep getting broken

- **Opening the Settings window never uses `sendAction(showSettingsWindow:)`
  directly.** macOS 14+ silently broke that trick: it still finds a
  responder and returns `true`, but no window opens. Both entry points (tray
  "Settings…" and the in-widget gear) must go through
  `AppDelegate.showSettingsWindow()`, which drives `SettingsOpenerModel` —
  an invisible, permanently off-screen `NSHostingView` whose sole job is
  giving a real SwiftUI view a `\.openSettings` environment action to call.
  If you add a third way to open Settings, route it through the same model;
  don't reach for `sendAction` again.
- **Window layering** (`SPEC.md` §9b, same rule as the Electron app) — level
  is `'floating'`, driven only by `alwaysOnTop`; one `raise()` serves every
  caller.
- **`Sources/PomoppiSprites/Sprites.generated.swift` is generated** — hand
  edits are silently overwritten next time `Scripts/generate-sprites.js` runs.
  Edit the `.aseprite` source under `../import/` (or `../renderer/sprites.js`
  for non-pet art) and re-run the script instead.
- App is **accessory** (`NSApp.setActivationPolicy(.accessory)`, set in
  `applicationWillFinishLaunching` so no Dock icon ever flashes): no Dock
  icon, never owns the menu bar even when active — same trade the Electron
  app makes, ported deliberately.
- **`swiftSettings: [.swiftLanguageMode(.v5)]` on every target** — don't
  "fix" this by moving to strict concurrency; the caches/singletons here
  (sprite caches, `GlobalShortcutManager.shared`) are intentionally
  main-thread-only.
