# Pomoppi

Kawaii pixel pomodoro widget for macOS — **Swift/AppKit + SwiftUI**, no
Electron, no npm runtime dependency. The Electron original this was rewritten
from is retired; its git history (pre-`main` branches) still has it if
there's ever a reason to look back, but nothing in this tree depends on it.

`SPEC.md` is the authoritative **behavior** contract — if code and spec
disagree, the spec wins. Read the section you're touching, not the whole
file. It was originally written for the Electron app, so some sections still
describe Electron-specific mechanics (IPC, `contextBridge`, npm packaging);
read those for the *intent*, not the literal API.

## Commands (run from the repo root)

```sh
swift build              # build (debug)
swift test                # run all three test targets
swift run PomoppiApp      # run
node Scripts/make-app.js  # assemble a real double-clickable Pomoppi.app (release build)
node Scripts/generate-sprites.js  # re-import art from Art/renderer/*.js, rewrites Sources/PomoppiSprites/Sprites.generated.swift
```

Dev-run settings live at `.dev-app-support/settings.json` (loose binary, no
bundle identifier). A real, installed `.app` build persists to
`~/Library/Application Support/Pomoppi/settings.json` — see
`AppDelegate.storageDir()`.

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
| `Sources/PomoppiApp/StartCoordinator.swift` | Centralizes the start flow (task-name prompt gating) |
| `Sources/PomoppiApp/PixelPreviews.swift`, `Color+Hex.swift` | SwiftUI preview helpers / hex color conversion |
| `Sources/PomoppiCore/` | Platform-agnostic core: `Timer.swift` (wall-clock pomodoro state machine), `Settings.swift` (load/validate/persist, no AppKit import), `Shortcuts.swift`, `ObsidianLogger.swift` |
| `Sources/PomoppiRender/` | Drawing: `PixelCanvas.swift` (the 1px drawing kit), `WidgetLayout.swift`, `WidgetAnimationController.swift`, `WidgetRenderer.swift` |
| `Sources/PomoppiSprites/Sprites.generated.swift` | **Generated** by `Scripts/generate-sprites.js` from `Art/renderer/sprites.js` / `friends.js` / `background.js` — never hand-edit |
| `Sources/PomoppiSprites/Digits.swift`, `WindowFrame.swift` | Hand-written glyph/frame data (not generated) |
| `Scripts/generate-sprites.js` | Node importer described above |
| `Scripts/make-app.js` | Builds a release `Pomoppi.app` bundle, hand-rolled: no packager, no Xcode project |
| `Art/renderer/sprites.js` | Hand-written icon/ZZZ/tray `0`/`1` grids, plus the wiring that pulls in `friends.js` — the top of the art-data tree `generate-sprites.js` reads |
| `Art/renderer/friends.js`, `background.js` | **Generated** by `Art/tools/import-friends.js` / `import-bgs.js` from `Art/import/**/*.aseprite` — never hand-edit |
| `Art/import/friends/*.aseprite`, `Art/import/bgs/*.aseprite` | The actual pixel-art source files, edited in Aseprite |
| `Art/tools/import-friends.js`, `import-bgs.js`, `import-tray.js` | Re-import from Aseprite (`node Art/tools/import-friends.js`, etc.) — requires Aseprite installed at `/Applications/Aseprite.app`, its CLI does the format decoding |
| `Art/tools/read-png.js` | Pure-Node PNG decoder shared by the importers above |
| `Art/tools/serve.js`, `editor.html` | Standalone browser pixel editor for the hand-written grids in `sprites.js` (`node Art/tools/serve.js`, then open `localhost:8173`) — not Aseprite-based, no build step |
| `Tests/` | `swift-testing`/XCTest-style suites mirroring `Sources/PomoppiCore`, `PomoppiRender`, `PomoppiSprites` |
| `assets/` | App icon sources (Icon Composer `.icon`, generated `.car`/`.icns`), read by `Scripts/make-app.js` |

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
- **Window layering** (`SPEC.md` §9b) — level is `'floating'`, driven only by
  `alwaysOnTop`; one `raise()` serves every caller.
- **`Sources/PomoppiSprites/Sprites.generated.swift` is generated** — hand
  edits are silently overwritten next time `Scripts/generate-sprites.js` runs.
  Edit the `.aseprite` source under `Art/import/` (or `Art/renderer/sprites.js`
  for non-pet art) and re-run the script instead.
- App is **accessory** (`NSApp.setActivationPolicy(.accessory)`, set in
  `applicationWillFinishLaunching` so no Dock icon ever flashes): no Dock
  icon, never owns the menu bar even when active.
- **`swiftSettings: [.swiftLanguageMode(.v5)]` on every target** — don't
  "fix" this by moving to strict concurrency; the caches/singletons here
  (sprite caches, `GlobalShortcutManager.shared`) are intentionally
  main-thread-only.
