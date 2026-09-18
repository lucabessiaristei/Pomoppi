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

## Commands (run from the repo root, macOS host)

```sh
swift build              # build (debug)
swift test                # run all three test targets
swift run PomoppiApp      # run
node Scripts/make-app.js  # assemble a real double-clickable Pomoppi.app (release build)
node refresh-art          # re-import Aseprite art + rewrite Sources/PomoppiSprites/Sprites.generated.swift
node refresh-art --friends --rebuild  # --bgs / --icon too, alone or combined; --rebuild also rebuilds + reinstalls /Applications/Pomoppi.app
```

Dev-run settings live at `.dev-app-support/settings.json` (loose binary, no
bundle identifier). A real, installed `.app` build persists to
`~/Library/Application Support/Pomoppi/settings.json` — see
`AppDelegate.storageDir()`.

### Windows commands (run inside the VM only — see the invariant below)

```sh
ssh pomoppi-win                                  # from the Mac, into the VM
git pull <bundle> main                           # sync committed history in (see WINDOWS_PORT_PLAN.md's sync recipe)
call "<path from vswhere>\VC\Auxiliary\Build\vcvarsall.bat" arm64   # load the MSVC environment first — swift build's linker needs it
swift build                                      # debug build
swift test                                       # PomoppiCoreTests + PomoppiSpritesTests only
node Scripts\make-windows-app.js                 # release build + dist\Pomoppi-win\ + .zip
```

Settings persist to `%APPDATA%\Pomoppi\settings.json` (`AppStorage.swift`).
Anything touching the tray or global hotkeys needs the real interactive
session, not a plain SSH one — see `WINDOWS_PORT_PLAN.md`'s Phase W0
outcome for the Task Scheduler `/it` workaround and why.

## File map

Pomoppi is being ported to also run on Windows (see `WINDOWS_PORT_PLAN.md`
at the repo root) — the file map below is split into what's shared between
both platforms, what's macOS-only, and what's Windows-only.

### Shared

| File | What |
|---|---|
| `Package.swift` | SPM manifest. Tools-version 6.0 only for `.macOS(.v15)`; every target still opts back into Swift 5 language mode (this app's mutable caches/singletons are single-threaded, main-thread-only state). On a Windows host the manifest evaluates to a different, smaller target set — `PomoppiCore`/`PomoppiSprites`/`PomoppiRender`/`PomoppiWindows` (executable) + `PomoppiCoreTests`/`PomoppiSpritesTests` (no `PomoppiRenderTests`: one test still reads `CGImage` directly, unguarded, and no `PomoppiApp`) — see the `#if os(Windows)` in the file itself |
| `Sources/PomoppiCore/` | Platform-agnostic core: `Timer.swift` (wall-clock pomodoro state machine), `Settings.swift` (load/validate/persist, no AppKit import), `Shortcuts.swift`, `ObsidianLogger.swift` |
| `Sources/PomoppiSprites/Sprites.generated.swift` | **Generated** by `refresh-art.js` from `Art/renderer/sprites.js` / `friends.js` / `background.js` — never hand-edit |
| `Sources/PomoppiSprites/Digits.swift`, `WindowFrame.swift` | Hand-written glyph/frame data (not generated) |
| `Sources/PomoppiRender/` | Drawing: `PixelCanvas.swift` (the 1px drawing kit, a plain byte buffer with no platform import), `WidgetLayout.swift`, `WidgetAnimationController.swift`, `WidgetRenderer.swift` — all Windows-buildable since Phase W3. The CoreGraphics dependency (`makeImage() -> CGImage?`) lives in `PixelCanvas+CoreGraphics.swift` (macOS); Windows gets two of its own adapters, `PixelCanvas+GDI.swift` (the layered-window/owner-draw blit path, Phase W3/W7) and `PixelCanvas+GDIIcon.swift` (`HICON` for the tray, Phase W4) |
| `Tests/` | `swift-testing`/XCTest-style suites mirroring `Sources/PomoppiCore`, `PomoppiRender`, `PomoppiSprites` |

### macOS

| File | What |
|---|---|
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
| `Scripts/make-app.js` | Builds a release `Pomoppi.app` bundle, hand-rolled: no packager, no Xcode project |
| `assets/` | App icon sources (Icon Composer `.icon`, generated `.car`/`.icns`), read by `Scripts/make-app.js` |
| `refresh-art.js` | The one art command, at the repo root so it's `node refresh-art`: re-imports `.aseprite` sources into `Art/renderer/*.js` (`--all` default, or any combination of `--friends`/`--bgs`/`--icon`), then always rewrites `Sprites.generated.swift` last, then `Scripts/make-app.js` too if `--rebuild` is passed — the real release build + reinstall to `/Applications/Pomoppi.app`, not just a debug `swift build`. Thin orchestrator over the `Art/tools/import-*.js` modules below, which stay independently runnable |
| `Art/renderer/sprites.js` | Hand-written icon/ZZZ/tray `0`/`1` grids, plus the wiring that pulls in `friends.js` — the top of the art-data tree `refresh-art.js` reads |
| `Art/renderer/friends.js`, `background.js` | **Generated** by `Art/tools/import-friends.js` / `import-bgs.js` from `Art/import/friends/*_ok.aseprite` / `Art/import/bgs/*_ok.aseprite` — never hand-edit |
| `Art/import/friends/*_ok.aseprite`, `Art/import/bgs/*_ok.aseprite`, `Art/import/icon/*.aseprite` | The actual pixel-art source files, edited in Aseprite. `friends/` and `bgs/` are auto-scanned and both need the `_ok` suffix to go live (`Foo_ok.aseprite`) — draft art can sit in the same folder as plain `Foo.aseprite` with no `_ok` and stays invisible (not imported, not in Settings) until renamed; `refresh-art.js` also adds/removes it from `PomoppiCore/Settings.swift`'s `friendIDs`/`backgroundIDs` to match, nothing to register by hand. `bg-template.aseprite` (a starting point, not a background) is excluded for free this way — it has no `_ok`. `icon/` holds the single menu-bar animation source, no suffix needed |
| `Art/tools/import-friends.js`, `import-bgs.js`, `import-tray.js` | Each exports an `import*()` function `refresh-art.js` calls, and still runs standalone (`node Art/tools/import-friends.js`, etc.) — requires Aseprite installed at `/Applications/Aseprite.app`, its CLI does the format decoding |
| `Art/tools/read-png.js` | Pure-Node PNG decoder shared by the importers above |
| `Art/tools/serve.js`, `editor.html` | Standalone browser pixel editor for the hand-written grids in `sprites.js` (`node Art/tools/serve.js`, then open `localhost:8173`) — not Aseprite-based, no build step |

### Windows

| File | What |
|---|---|
| `Sources/PomoppiWindows/main.swift` | Real startup wiring (superseded the Phase W1 skeleton in W3 part 2): builds `SettingsStore`/`PomodoroTimer`/`WidgetWindow`/`TrayController`/`GlobalShortcutManager`, wires global-shortcut handlers and the login item, then the `GetMessageW`/`TranslateMessage`/`DispatchMessageW` loop |
| `Sources/PomoppiWindows/WidgetWindow.swift` / `WidgetInput.swift` | The layered popup widget window (`WS_POPUP \| WS_EX_LAYERED \| WS_EX_TOOLWINDOW`, `UpdateLayeredWindow` at ~60fps via `PixelCanvas+GDI`) and its hit-testing/drag/keyboard input, porting `WidgetPixelView`'s logic verbatim onto Win32's `WndProc` |
| `Sources/PomoppiWindows/TrayController.swift` | `Shell_NotifyIcon` tray icon + context menu, `reverseTrayClick`-aware clicks, light/dark taskbar-aware icon tinting (no `NSImage.isTemplate` equivalent on Win32, so this reads `SystemUsesLightTheme` from the registry itself) |
| `Sources/PomoppiWindows/SettingsWindow.swift` | The settings window: `SysTabControl32` with the same 6 tabs as macOS, hand-laid-out raw controls per tab (steppers, checkboxes, the Keys tab's shortcut recorder, the Appearance tab's owner-drawn picker/theme/color/scale/opacity controls with its own `WS_VSCROLL` scrolling). By far the largest file in this port — see `WINDOWS_PORT_PLAN.md`'s W6/W7 entries for how it grew phase by phase |
| `Sources/PomoppiWindows/AppearancePreviews.swift` | Appearance tab's picker-card preview rendering (friend/frame-style/background cards, theme-preset swatches) — mirrors `Sources/PomoppiApp/PixelPreviews.swift`'s logic fresh rather than sharing it, since that file is off-limits for this port |
| `Sources/PomoppiWindows/GlobalShortcutManager.swift` | `RegisterHotKey`/`WM_HOTKEY`/`MOD_NOREPEAT`, tied to the widget's own `hwnd` rather than process-wide like Carbon |
| `Sources/PomoppiWindows/LoginItem.swift` | Launch-at-login via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (not `SMAppService` — there's no bundle identifier concept to register against on Windows) |
| `Sources/PomoppiWindows/AppStorage.swift` | `storageDir() -> URL` via `SHGetKnownFolderPath(FOLDERID_RoamingAppData)`, this platform's `AppDelegate.storageDir()` equivalent |
| `Sources/PomoppiWindows/Pomoppi.exe.manifest` | Win32 application manifest (Common Controls v6 + per-monitor-v2 DPI awareness) — wired in as of Phase W8, shipped as an external side-by-side manifest (`Pomoppi.exe.manifest` next to `Pomoppi.exe`) rather than linker-embedded |
| `Scripts/make-windows-app.js` | Builds a release binary and assembles `dist/Pomoppi-win/` + `dist/Pomoppi-win.zip` — this platform's `Scripts/make-app.js` equivalent. Runs on Windows only (locates MSVC via `vswhere.exe`, needs `-products *` to see a Build-Tools-only install) |
| `.github/workflows/windows.yml` | Release-only CI (`workflow_dispatch` + `release: published`, never a per-commit gate) producing x64 release artifacts via `make-windows-app.js` on a `windows-latest` runner |

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
  edits are silently overwritten next time `refresh-art.js` runs. Edit the
  `.aseprite` source under `Art/import/` (or `Art/renderer/sprites.js` for
  non-pet art) and re-run the script instead.
- App is **accessory** (`NSApp.setActivationPolicy(.accessory)`, set in
  `applicationWillFinishLaunching` so no Dock icon ever flashes): no Dock
  icon, never owns the menu bar even when active.
- **`swiftSettings: [.swiftLanguageMode(.v5)]` on every target** — don't
  "fix" this by moving to strict concurrency; the caches/singletons here
  (sprite caches, `GlobalShortcutManager.shared`) are intentionally
  main-thread-only.
- **The Windows app (`Sources/PomoppiWindows/`) only ever builds/runs inside
  the Windows VM** (`ssh pomoppi-win`, see `WINDOWS_PORT_PLAN.md`), never on
  the macOS host — `swift build` on the Mac never compiles it (Swift can't
  cross-compile from macOS to Windows). A Windows-side compile error is
  invisible on the host until it's actually built in the VM.
- **`Sources/PomoppiApp/` is off-limits for the Windows port** — the one
  exception (`reverseTrayClick`, Phase W2b) is long since merged and closed;
  don't reach for a second one. Any new Windows-side behavior gets its own
  file under `Sources/PomoppiWindows/`, even when the logic is conceptually
  identical to something `Sources/PomoppiApp/` already does — this port has
  consistently duplicated small amounts of logic (tray click handling,
  picker-card previews, login-item registration) rather than extracting a
  shared abstraction that would require touching the Mac side to add.
- **Don't build a Windows Obsidian tab or call `ObsidianLogger` from
  `Sources/PomoppiWindows/`.** The logger itself lives in shared
  `PomoppiCore` and builds/tests fine on Windows, but session logging is
  slated for a redesign into a platform-agnostic JSON format before any
  Windows UI for it gets built — building one now means redoing it shortly
  after. The Obsidian tab stays the Phase-W6 placeholder until that
  redesign lands.
