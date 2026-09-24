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
node refresh-sounds       # re-import chime WAV packs + rewrite Sources/PomoppiSprites/Sounds.generated.swift
```

Dev-run settings live at `.dev-app-support/settings.json` (loose binary, no
bundle identifier). A real, installed `.app` build persists to
`~/Library/Application Support/Pomoppi/settings.json` — see
`AppDelegate.storageDir()`.

### Windows commands (run inside the VM only — see the invariant below)

```sh
ssh pomoppi-win                                  # from the Mac, into the VM
git fetch <bundle> main && git reset --hard FETCH_HEAD   # sync committed history in (see WINDOWS_VM.md)
call "<path from vswhere>\VC\Auxiliary\Build\vcvarsall.bat" arm64   # load the MSVC environment first — swift build's linker needs it
swift build                                      # debug build
swift test                                       # PomoppiCoreTests + PomoppiSpritesTests only
node Scripts\make-windows-app.js --installer     # release build + dist\Pomoppi-win\ + Setup .exe
```

Settings persist to `%APPDATA%\Pomoppi\settings.json` (`AppStorage.swift`).
Anything touching the tray or global hotkeys needs the real interactive
session, not a plain SSH one — see `WINDOWS_VM.md` for the Task Scheduler
`/it` workaround and why.

## File map

Pomoppi runs on macOS and Windows. The file map below is split into what's
shared between both platforms, what's macOS-only, and what's Windows-only.

Open plan: `LOCALIZATION_PLAN.md`. `NEXT_RELEASE.md` lists what has landed
since the last release (and what still needs verifying before the next). `WINDOWS_VM.md` is how to build and test
the Windows app; `RELEASING.md` is the release checklist. Finished plans
were removed; their history is in git.

### Shared

| File | What |
|---|---|
| `Package.swift` | SPM manifest. Tools-version 6.0 only for `.macOS(.v15)`; every target still opts back into Swift 5 language mode (this app's mutable caches/singletons are single-threaded, main-thread-only state). On a Windows host the manifest evaluates to a different, smaller target set — `PomoppiCore`/`PomoppiSprites`/`PomoppiRender`/`PomoppiWindows` (executable) + `PomoppiCoreTests`/`PomoppiSpritesTests` (no `PomoppiRenderTests`: one test still reads `CGImage` directly, unguarded, and no `PomoppiApp`) — see the `#if os(Windows)` in the file itself |
| `Scripts/version.js` | `readVersion(repoRoot)` — regex-reads `pomoppiVersion` out of `Sources/PomoppiCore/Version.swift`, shared by `make-app.js`, `make-windows-app.js`, `make-pkg.js` and `check-tag-version.js` so none of them carries its own copy of that regex |
| `Scripts/set-version.js` | `node Scripts/set-version.js 0.3.0` — the one supported way to bump `pomoppiVersion` in `Version.swift`, rather than hand-editing that Swift file; see `RELEASING.md` for the checklist this is step one of |
| `Scripts/check-tag-version.js` | Release-workflow guard, shared by both `.github/workflows/*.yml` (via a `RELEASE_TAG` env var): fails a `release: published` build if the git tag (minus a leading `v`) doesn't match `pomoppiVersion` in `Version.swift` |
| `Sources/PomoppiCore/` | Platform-agnostic core: `Timer.swift` (wall-clock pomodoro state machine), `Settings.swift` (load/validate/persist, no AppKit import), `Shortcuts.swift`, `SessionLogger.swift` (session history as a single local JSON file — replaced `ObsidianLogger.swift` in the 2026-09-19 redesign; see `SPEC.md` §8), `DiaryExporter.swift` (the Diary tab: groups `SessionLogger`'s log into pomodoros, exports the complete log as one `.md`/`.txt`/`.odt`/`.json` file, and syncs one summarized Markdown file per day into `<folder>/YYYY/MM/`; text comes through an injected `DiaryText`, since Core can't import `PomoppiStrings`; `SPEC.md` §8b), `ODTWriter.swift` (minimal OpenDocument text writer for that export), `ZipWriter.swift` (from-scratch stored-entries-only ZIP writer, entries in the order given, which ODT's `mimetype`-first rule needs), `WAVFile.swift` (a minimal WAV/RIFF header writer — macOS's `ChimePlayer.swift` builds a playable WAV image from `GeneratedSounds`' raw PCM bytes through it for `AVAudioPlayer`; Windows' own `ChimePlayer.swift` plays the same raw PCM directly via `waveOut`, no WAV image needed; `SPEC.md` §4) |
| `Sources/PomoppiCore/Version.swift` | `pomoppiVersion` — the single source of truth for the app's version number, regex-read by `Scripts/version.js` and rewritten in place only by `Scripts/set-version.js` (`SPEC.md` §15) |
| `Sources/PomoppiCore/UpdateChecker.swift` | Cross-platform "is a newer release available" logic: `SemVer` (numeric, per-component comparison, tolerant of a leading `v`), `parseLatestRelease`/`isUpdateAvailable`/`checkForUpdate`, and `requestHeaders(appVersion:)` — Foundation-only and transport-agnostic (an injected `Fetch` closure), so it's exercisable without a real network call; the actual `GET .../releases/latest` request is each platform's own `AppUpdateChecker.swift`. Also `ReleaseAsset`/`UpdatePlatform`: the release's assets, matched per platform by name prefix + extension, with `verify(downloadedFileAt:)` (size + SHA-256 digest) (`SPEC.md` §15) |
| `Sources/PomoppiCore/SHA256.swift` | Hand-rolled SHA-256 (NIST-vector tested), what `ReleaseAsset.verify` checks an update download against; same from-scratch precedent as `ZipWriter.swift` |
| `Sources/PomoppiCore/UpdateInstallState.swift` | The in-app update's state enum (idle/downloading/verifying/installerOpened/failed) both platforms' Updates rows render |
| `Sources/PomoppiSprites/Sprites.generated.swift` | **Generated** by `refresh-art.js` from `Art/renderer/sprites.js` / `friends.js` / `background.js` — never hand-edit |
| `Sources/PomoppiSprites/Sounds.generated.swift` | **Generated** by `refresh-sounds.js` from `Sounds/import/chimes/*/focus-end.wav`/`break-end.wav` — never hand-edit |
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
| `Sources/PomoppiApp/ChimePlayer.swift` | Chime playback: one persistent, cached `AVAudioPlayer(data:)` per pack+sound over a WAV image built from `GeneratedSounds` via `WAVFile` (`stop()`/`currentTime = 0`/`play()` on replay, rather than a fresh player dropped after one play); owned by `AppDelegate`, reused by `SettingsViewModel` so selecting a chime on the Sound tab previews it (`SPEC.md` §4) |
| `Sources/PomoppiApp/AppUpdateChecker.swift` | Owned by `AppDelegate`: the real `URLSession` transport `UpdateChecker.swift` was built against, plus scheduling (~10s after launch, then every 24h, only while `settings.checkForUpdates` is on) and the manual "Check for updates" path the General tab's Updates row drives. Owns the `UpdateInstaller` and its published `installState`, so a download outlives the settings window. No persisted state across launches (`SPEC.md` §15) |
| `Sources/PomoppiApp/UpdateInstaller.swift` | In-app update: downloads the release `.pkg` into `~/Library/Caches/Pomoppi/Updates` (reused while it verifies, pruned at launch once installed), verifies it, strips `com.apple.quarantine`, opens it in Installer.app, and drops the widget's level while Installer.app runs (`SPEC.md` §15, §9b) |
| `Sources/PomoppiApp/TrayController.swift` | Menu bar icon: menu, tray click behavior, live clock |
| `Sources/PomoppiApp/WidgetWindow.swift` / `WidgetPixelView.swift` | The floating pixel widget window and its hit-testing/drawing view |
| `Sources/PomoppiApp/GlobalShortcutManager.swift` | Registers/unregisters the OS-level hotkeys |
| `Sources/PomoppiApp/LoginItem.swift` | Launch-at-login registration |
| `Sources/PomoppiApp/StartCoordinator.swift` | Centralizes the start flow (task-name prompt gating) |
| `Sources/PomoppiApp/PixelPreviews.swift`, `Color+Hex.swift` | SwiftUI preview helpers / hex color conversion |
| `Scripts/make-app.js` | Builds a release `Pomoppi.app` bundle, hand-rolled: no packager, no Xcode project |
| `Scripts/make-pkg.js` | Unsigned `.pkg` producer via `pkgbuild`: builds a release `Pomoppi.app` into a scratch staging dir (reusing `make-app.js`'s own build/assemble logic, just pointed elsewhere), reads the bundle identifier back out of its `Info.plist` rather than hardcoding a copy, writes `dist/Pomoppi-<version>_macOS.pkg`. No `productsign`, no notarization — deliberately unsigned for now (`SPEC.md` §15) |
| `Scripts/pkg-scripts/postinstall` | `pkgbuild --scripts` hook: `pkill -x Pomoppi` right after the payload lands, so installing over a running instance doesn't leave the old process fighting the new build for file handles, then relaunches the new build as the logged-in user (`launchctl asuser`) if one was running |
| `.github/workflows/macos.yml` | Release-only CI (`workflow_dispatch` + `release: published`, never a per-commit gate), mirrors `windows.yml`'s shape: pinned `macos-26` runner + explicit Xcode 26.6 selection, arm64-only (no Intel Macs in the target group), builds the unsigned `.pkg` via `Scripts/make-pkg.js` and uploads it as a release asset when triggered by an actual release |
| `assets/` | App icon sources (Icon Composer `.icon`, generated `.car`/`.icns`), read by `Scripts/make-app.js` |
| `refresh-art.js` | The one art command, at the repo root so it's `node refresh-art`: re-imports `.aseprite` sources into `Art/renderer/*.js` (`--all` default, or any combination of `--friends`/`--bgs`/`--icon`), then always rewrites `Sprites.generated.swift` last, then `Scripts/make-app.js` too if `--rebuild` is passed — the real release build + reinstall to `/Applications/Pomoppi.app`, not just a debug `swift build`. Thin orchestrator over the `Art/tools/import-*.js` modules below, which stay independently runnable |
| `Art/renderer/sprites.js` | Hand-written icon/ZZZ/tray `0`/`1` grids, plus the wiring that pulls in `friends.js` — the top of the art-data tree `refresh-art.js` reads |
| `Art/renderer/friends.js`, `background.js` | **Generated** by `Art/tools/import-friends.js` / `import-bgs.js` from `Art/import/friends/*_ok.aseprite` / `Art/import/bgs/*_ok.aseprite` — never hand-edit |
| `Art/import/friends/*_ok.aseprite`, `Art/import/bgs/*_ok.aseprite`, `Art/import/icon/*.aseprite` | The actual pixel-art source files, edited in Aseprite. `friends/` and `bgs/` are auto-scanned and both need the `_ok` suffix to go live (`Foo_ok.aseprite`) — draft art can sit in the same folder as plain `Foo.aseprite` with no `_ok` and stays invisible (not imported, not in Settings) until renamed; `refresh-art.js` also adds/removes it from `PomoppiCore/Settings.swift`'s `friendIDs`/`backgroundIDs` to match, nothing to register by hand. `bg-template.aseprite` (a starting point, not a background) is excluded for free this way — it has no `_ok`. `icon/` holds the single menu-bar animation source, no suffix needed |
| `Art/tools/import-friends.js`, `import-bgs.js`, `import-tray.js` | Each exports an `import*()` function `refresh-art.js` calls, and still runs standalone (`node Art/tools/import-friends.js`, etc.) — requires Aseprite installed at `/Applications/Aseprite.app`, its CLI does the format decoding |
| `Art/tools/read-png.js` | Pure-Node PNG decoder shared by the importers above |
| `Art/tools/serve.js`, `editor.html` | Standalone browser pixel editor for the hand-written grids in `sprites.js` (`node Art/tools/serve.js`, then open `localhost:8173`) — not Aseprite-based, no build step |
| `refresh-sounds.js` | The one sound command, at the repo root so it's `node refresh-sounds`: re-imports `Sounds/import/chimes/*/` WAV packs (`Sounds/tools/import-chimes.js`), syncs `PomoppiCore/Settings.swift`'s `chimeIDs` the same regex-rewrite way `refresh-art.js` syncs `friendIDs`/`backgroundIDs`, then always rewrites `Sounds.generated.swift` last |
| `Sounds/tools/synthesize-chimes.js` | Synthesizes all four chime packs (`classic`/`chord`/`jingle`/`soft`) from scratch into `Sounds/import/chimes/<id>/{focus-end,break-end}.wav` — `node Sounds/tools/synthesize-chimes.js`, re-run any time, always overwrites |
| `Sounds/tools/import-chimes.js` | Scans `Sounds/import/chimes/*/` for complete packs (both `focus-end.wav` and `break-end.wav`), validates 16-bit/mono/44100Hz, returns `{chimeIDs, chimes}` for `refresh-sounds.js` |
| `Sounds/tools/wav.js` | Minimal dependency-free WAV (RIFF/PCM) encode/decode, shared by `synthesize-chimes.js` and `import-chimes.js` — the JS-side counterpart to `PomoppiCore/WAVFile.swift` |
| `Sounds/import/chimes/<id>/` | The actual chime WAV pairs (`focus-end.wav`/`break-end.wav`) per pack id, written by `synthesize-chimes.js` — not hand-recorded |

### Windows

| File | What |
|---|---|
| `Sources/PomoppiWindows/main.swift` | Real startup wiring (superseded the Phase W1 skeleton in W3 part 2): builds `SettingsStore`/`PomodoroTimer`/`WidgetWindow`/`TrayController`/`GlobalShortcutManager`, wires global-shortcut handlers and the login item, then the `GetMessageW`/`TranslateMessage`/`DispatchMessageW` loop |
| `Sources/PomoppiWindows/WidgetWindow.swift` / `WidgetInput.swift` | The layered popup widget window (`WS_POPUP \| WS_EX_LAYERED \| WS_EX_TOOLWINDOW`, `UpdateLayeredWindow` at ~60fps via `PixelCanvas+GDI`) and its hit-testing/drag/keyboard input, porting `WidgetPixelView`'s logic verbatim onto Win32's `WndProc` |
| `Sources/PomoppiWindows/TrayController.swift` | `Shell_NotifyIcon` tray icon + context menu, `reverseTrayClick`-aware clicks, light/dark taskbar-aware icon tinting (no `NSImage.isTemplate` equivalent on Win32, so this reads `SystemUsesLightTheme` from the registry itself) |
| `Sources/PomoppiWindows/SettingsWindow.swift` | The settings window: `SysTabControl32` with the same 6 tabs as macOS, hand-laid-out raw controls per tab (steppers, checkboxes, the Keys tab's shortcut recorder, the Appearance tab's owner-drawn picker/theme/color/scale/opacity controls; every page scrolls with its own native `WS_VSCROLL` bar, so only the width has a floor). By far the largest file in this port |
| `Sources/PomoppiWindows/ChimePlayer.swift` | Chime playback: direct `waveOut` (not `PlaySoundW` — its own internal buffer never resets between calls, so only the first play of a multi-note chime ever played in full) over `GeneratedSounds`' raw PCM, held in a never-freed `UnsafeMutablePointer<UInt8>` per pack+sound for the process's life; one `WAVEFORMATEX` device opened once and kept open, one reused `WAVEHDR` reset/unprepared unconditionally at the top of every play(); owned by `main.swift`, passed into `SettingsWindow.show(...)` so selecting a chime on the Sound tab previews it (`SPEC.md` §4) |
| `Sources/PomoppiWindows/AppUpdateChecker.swift` | Same shape as the macOS file, over `URLSession`/`FoundationNetworking` (proved to work cleanly on Windows Swift; `make-windows-app.js`'s `dumpbin` DLL walk auto-bundles `FoundationNetworking.dll` with zero script changes needed). `URLSession`'s completion fires off the message-loop thread, marshaled back onto it via `PostMessageW`/`WM_APP+2` rather than `DispatchQueue.main` (`SPEC.md` §15) |
| `Sources/PomoppiWindows/UpdateInstaller.swift` | In-app update: downloads the Setup `.exe` to `%TEMP%`, verifies it, deletes its `Zone.Identifier` stream, runs it with `/SILENT /SUPPRESSMSGBOXES /NORESTART`; Inno closes and relaunches Pomoppi. `isRunningInstalledCopy` (`unins000.exe` next to the exe) gates it: other copies get the release page |
| `Sources/PomoppiWindows/AppearancePreviews.swift` | Appearance tab's picker-card preview rendering (friend/frame-style/background cards, theme-preset swatches) — mirrors `Sources/PomoppiApp/PixelPreviews.swift`'s logic fresh rather than sharing it, since that file is off-limits for this port |
| `Sources/PomoppiWindows/GlobalShortcutManager.swift` | `RegisterHotKey`/`WM_HOTKEY`/`MOD_NOREPEAT`, tied to the widget's own `hwnd` rather than process-wide like Carbon |
| `Sources/PomoppiWindows/LoginItem.swift` | Launch-at-login via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (not `SMAppService` — there's no bundle identifier concept to register against on Windows) |
| `Sources/PomoppiWindows/AppStorage.swift` | `storageDir() -> URL` via `SHGetKnownFolderPath(FOLDERID_RoamingAppData)`, this platform's `AppDelegate.storageDir()` equivalent |
| `Sources/PomoppiWindows/StartCoordinator.swift` | Task-name prompt gate (~25 lines, a deliberate duplicate of `StartCoordinator.swift`'s macOS logic) — checks `askForTaskName`/`loggingEnabled` and calls `TaskPromptDialog.run` only when a fresh focus session needs prompting; the one call site is `WidgetInput.activateButton`'s `"play"` case |
| `Sources/PomoppiWindows/TaskPromptDialog.swift` | Win32 modal dialog for the task-name prompt: `WS_POPUP \| WS_CAPTION \| WS_SYSMENU`, owned by the widget so it always sits above it without needing `WS_EX_TOPMOST`; contents are a title static, a single-line edit with cue banner, a hint static (toggled live based on `loggingEnabled`), and Start/Cancel buttons; keyboard handling intercepts Return/Escape on `WM_KEYDOWN` before `IsDialogMessageW` to avoid a beep; re-entrancy is guarded by `isShowing` |
| `Sources/PomoppiWindows/WindowsTheme.swift` | Extracted theme/dark-mode logic (`SystemUsesLightTheme` registry read, `resolveDarkMode()`, dark-mode hex constants `darkBackgroundHex`/`darkTextHex`); shared by both `TaskPromptDialog.swift` (for consistent modal chrome) and `SettingsWindow.swift` |
| `Sources/PomoppiWindows/Pomoppi.exe.manifest` | Win32 application manifest (Common Controls v6 + per-monitor-v2 DPI awareness) — wired in as of Phase W8, shipped as an external side-by-side manifest (`Pomoppi.exe.manifest` next to `Pomoppi.exe`) rather than linker-embedded |
| `Scripts/make-windows-app.js` | Builds a release binary and assembles `dist/Pomoppi-win/` (what the installer packs) — this platform's `Scripts/make-app.js` equivalent. Runs on Windows only (locates MSVC via `vswhere.exe`, needs `-products *` to see a Build-Tools-only install). Its `--installer` flag additionally compiles `Scripts/pomoppi.iss` into `dist/Pomoppi-Setup-<version>_Windows.exe` |
| `Scripts/pomoppi.iss` | Inno Setup script: per-user install (`{autopf}\Pomoppi`, no UAC), `CloseApplications=yes` for a silent auto-close-and-upgrade over a running instance (a `WizardSilent` `[Run]` entry relaunches it after an in-app `/SILENT` update) (`AppMutex` deliberately not used — it only blocks with a dialog, no auto-close capability; `CloseApplications`'s RestartManager integration is what does the real work). Compiled by `Scripts/make-windows-app.js --installer` via `ISCC.exe` (`SPEC.md` §15) |
| `.github/workflows/windows.yml` | Release-only CI (`workflow_dispatch` + `release: published`, never a per-commit gate) producing x64 release artifacts via `make-windows-app.js --installer` on a `windows-latest` runner — the Inno Setup `Pomoppi-Setup-*.exe`, attached to the release. Verified end to end by the v0.3.0 release (`release: published`, both platforms green) |

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
  the Windows VM** (`ssh pomoppi-win`, see `WINDOWS_VM.md`), never on
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
- **Session logging (`SessionLogger.swift`, `SPEC.md` §8) is wired
  identically on both platforms as of 2026-09-19** — this used to be a
  macOS-only feature (writing Obsidian markdown) with Windows carrying a
  placeholder tab; that's done and shouldn't regress. Don't reintroduce a
  vault/folder/heading concept — the whole point of the redesign was
  dropping that.
- **The Diary tab (`DiaryExporter.swift`, `SPEC.md` §8b): Export and Sync
  are two different outputs since 2026-09-24**, not one shape through one
  code path. Export = the complete log in one file the user picks the
  format of (`.md`/`.txt`/`.odt`/`.json`); Sync = one summarized block per
  pomodoro in `<folder>/YYYY/MM/YYYY-MM-DD.md`, files Pomoppi fully owns and
  regenerates. Both group by pomodoro (`pomodoroStart` in the log, inferred
  for older entries). Sync stays idempotent and full-log: no cursor, no
  `diaryLastSyncedCount`, and it never deletes (old flat `<dateKey>.md`
  files stay). Diary text is localized through `DiaryText`; don't make
  `PomoppiCore` import `PomoppiStrings` to get it.
- **A pomodoro is the whole cycle** (`SPEC.md` §5): its task is one title for
  every focus in it, the widget dots are display-only, skip fills a dot,
  and reset discards the pomodoro *and its log entries*
  (`SessionLogger.discardPomodoro`). Don't reintroduce a per-focus task or
  click-to-set dots.
