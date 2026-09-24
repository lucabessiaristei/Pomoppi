# Pomoppi in-app update — plan and status

**Status as of 2026-09-24: S6a, S6b and S6d done.** S6a: `ReleaseAsset`/
`UpdatePlatform` in `UpdateChecker.swift`, `SHA256.swift`,
`UpdateInstallState.swift`, tests; green on the Mac and in the VM. S6b and
S6d: both installers relaunch Pomoppi after updating over a running copy,
verified by hand on the Mac and in the VM (see each phase's result below).
**Next: S6c and S6e**, the in-app side on each platform. **It ships as
v0.3.5** (`node Scripts/set-version.js 0.3.5` at release time, per
`RELEASING.md`).
v0.3.0 is released (first run of the `release: published` pipeline,
green on both platforms), so there is a real release to update to.
Build order: S6a, then (S6b, S6c) and (S6d, S6e) in parallel, each
platform's installer phase before its app phase, then S6f.
`LOCALIZATION_PLAN.md` comes after this: it adds user-facing strings the
L0 sweep has to see.


Today's update checker is notify-only: it finds a newer tag and opens the
GitHub release page in a browser (`SPEC.md` §15). Part C turns the General
tab's Updates row into a real **Update** button: it downloads the right
installer from the latest release, checks it, and launches it. From there
the platform's own installer does what it already does.

**Rescoped 2026-09-24, user decision.** The first design (swap the app
bundle in place on macOS so no password is ever asked, plus a new
`-mac.zip` asset, a `chown` in the pkg's postinstall, `ditto`/`codesign`
checks and a quarantine spike on an extracted bundle) is dropped. Standard
installer UI, **including the macOS password prompt on every update**, is
acceptable. The only goal is automating "go to GitHub, pick the right
file, download it, run it". The old design is in git history (`SETTINGS_PLAN.md`,
removed after v0.3.0) if it's ever wanted again. Don't reintroduce
any of it piecemeal.

## Locked decisions (S6) — do not re-derive

- **An update never triggers Gatekeeper or SmartScreen.** Only the first
  install does: the user downloads it with a browser, so it's quarantined
  (macOS `com.apple.quarantine`, Windows' Mark of the Web) and unsigned,
  and the one-time "Open Anyway" / "Run anyway" step is unavoidable without
  code signing (R2, `SPEC.md` §15). Every update after that must go through
  with no such prompt and no trip to System Settings. Two layers make that
  hold:
  - The app downloads with `URLSession`, which marks nothing: a
    non-sandboxed app without `LSFileQuarantineEnabled` writes no
    quarantine xattr, and nothing writes a `Zone.Identifier` on Windows.
    Files the installer then lays down aren't quarantined either, so the
    relaunched app opens clean.
  - Safety net, not optional: **after the checksum passes and before
    opening the installer**, the app strips the markers from its own
    download anyway — `removexattr(path, "com.apple.quarantine", 0)` on
    macOS, `DeleteFileW("<path>:Zone.Identifier")` on Windows (both no-ops
    when absent). This keeps the guarantee from resting on an OS default
    Apple or Microsoft could change. It's safe because it only ever touches
    a file whose SHA-256 just matched the release's own `digest`; a
    download without a `digest` gets the size check only, and still gets
    the strip (same trust root as the notifier, see the integrity point
    below).

- **User-initiated only.** No auto-download, no auto-install, no new
  setting. `checkForUpdates` stays the only knob; checking stays
  background, downloading and installing never start without a click.
  The rejection of Sparkle/WinSparkle still stands.
- **Each platform runs its existing release installer.** macOS opens the
  `.pkg` in Installer.app (`NSWorkspace.shared.open`); Windows runs the
  Inno Setup `.exe` with `/SILENT` (a progress window, no wizard pages, no
  questions). No bundle swapping, no extra release assets, no helper
  binary.
- **`PomoppiCore` stays network-free.** It holds asset parsing/matching,
  SHA-256 and the state enum; each platform's own `UpdateInstaller.swift`
  owns its `URLSession` download (same injected-transport split as
  `UpdateChecker.swift`, and the same small-duplication call the Windows
  port always makes).
- **SHA-256 is hand-rolled in `PomoppiCore`** (`SHA256.swift`), one pure
  implementation for both platforms, tested against the NIST vectors, same
  from-scratch precedent as `ZipWriter.swift`/`WAVFile.swift`.
- **Install state lives on `AppUpdateChecker`, never on the settings
  window.** Windows destroys the settings window on close; a download must
  survive closing and reopening it.
- **The Updates row in General is where updating happens**, on both
  platforms. No modal, no new window. The tray's "Update available" item
  stops opening a browser and opens the settings window instead: on macOS
  through `AppDelegate.showSettingsWindow()` (CLAUDE.md's first invariant,
  never `sendAction`), on Windows through `onOpenSettingsRequested`.
- **The integrity check proves the bytes, not the author.** GitHub's
  per-asset `digest` catches a truncated or corrupted download, but it
  arrives in the same HTTPS response as the URL. Until R2 (signing) the
  trust root is "TLS to api.github.com plus that GitHub account", the same
  as today's notifier, except the app now launches what it downloaded.
  State this in `SPEC.md` §15 (S6f), don't hide it.
- **A running session is confirmed first.** If `timer.getState().phase !=
  .idle`: "A session is in progress. Pomoppi will close to finish
  updating." / Update now / Cancel (`NSAlert` / `MessageBoxW`). A session
  cut short is never logged, so quitting mid-focus would silently lose it.

## Assets (S6a)

`UpdateChecker.parseLatestRelease` grows an `assets` array:

```swift
public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: URL   // browser_download_url
    public let size: Int          // drives a determinate progress bar
    public let sha256: String?    // from `digest` ("sha256:<hex>"), nil when absent
}
```

`CheckResult.updateAvailable` gains `asset: ReleaseAsset?` (the one for the
running platform). Every `.updateAvailable(let tag, _)` pattern match on
both platforms needs the extra binding; that is the whole blast radius.

Matching is by prefix and extension, case-insensitive, skipping assets
whose `state` isn't `"uploaded"`, first match in API order:

| Platform | Name starts with | Ends with |
|---|---|---|
| macOS | `Pomoppi-` | `.pkg` |
| Windows | `Pomoppi-Setup-` | `.exe` |

The extension already tells the platforms apart, so the `_macOS` /
`_Windows` suffixes (added after 0.3.0, for humans) are deliberately not
required: 0.3.0's own `Pomoppi-0.3.0.pkg` / `Pomoppi-Setup-0.3.0.exe`
match too, which is what makes testing possible before another release
exists (see "Testing" below).

**`asset == nil` is normal, not an error.** A release is published first
and CI uploads its assets minutes later, so for that window
`/releases/latest` reports a newer tag with nothing attached. The row then
shows exactly today's behavior (link to the release page).

## States and the Updates row

```
idle ─ check ─▶ checking ─▶ upToDate | checkFailed | updateAvailable
updateAvailable ─ [Update] ─▶ downloading(received, total) ─▶ verifying ─▶ installerOpened
any step ─ failure ─▶ installFailed(reason) ─▶ [Try again] [Open release page]
```

| State | Row reads | Controls |
|---|---|---|
| `updateAvailable` + asset | `Update available: v0.4.0` | **Update**, Release notes |
| `updateAvailable`, no asset | `Update available: v0.4.0` | Release notes (today's behavior) |
| `downloading` | `Downloading… 3.2 MB of 8.1 MB` | progress bar, Cancel |
| `verifying` | `Verifying…` | — |
| `installerOpened` | macOS: `Installer opened. Follow its steps.` / Windows: `Installing…` | — |
| `installFailed` | `Update failed: <one clause>` | Try again, Open release page |

Progress comes from the API's `size`, not `Content-Length`. Failure copy is
one clause, never an error code ("couldn't download", "the download didn't
match its checksum", "couldn't start the installer"), and always offers
**Open release page**, so the user is never stuck.

## macOS path

1. Download the `.pkg` into a fresh temporary directory.
2. Verify: byte count equals `size`, SHA-256 equals `digest` when present.
3. Strip `com.apple.quarantine` from the verified `.pkg` (the safety net
   above).
4. `NSWorkspace.shared.open(pkgURL)`: Installer.app shows its own UI and
   asks for the password, and no Gatekeeper dialog. Pomoppi keeps
   running; if the user cancels the installer, nothing changed.
5. The pkg's `postinstall` already runs `pkill -x Pomoppi`. It gains the
   relaunch: `launchctl asuser <console uid> open -a /Applications/Pomoppi.app`
   (R1 considered and dropped it as unverified; S6b verifies it).

An earlier spike from a loose binary saw no `com.apple.quarantine` on a
`URLSession` download (only `com.apple.provenance`, which doesn't gate
launching). S6b re-checks from inside the installed app and records the
answer; the strip in step 3 makes the result not matter.

## Windows path

1. Download `Pomoppi-Setup-*.exe` to `%TEMP%` (never the install folder,
   which is about to be overwritten). Verify the same way, then delete any
   `Zone.Identifier` stream (the safety net above), so SmartScreen has
   nothing to flag.
2. `ShellExecuteW(nil, "open", path, "/SILENT /SUPPRESSMSGBOXES /NORESTART /LOG=\"%TEMP%\\Pomoppi-update.log\"", nil, SW_SHOWNORMAL)`.
   A return value ≤ 32 is a launch failure, so fall back to the release page.
   The log is the only way a silent install's failure is diagnosable.
3. RestartManager closes the app (`CloseApplications=yes`, R4-verified).
4. Relaunch comes from one new line in `Scripts/pomoppi.iss`; the existing
   interactive entry stays as is:
   ```
   [Run]
   Filename: "{app}\{#MyAppExeName}"; Description: "Launch Pomoppi now"; Flags: nowait postinstall skipifsilent
   Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: WizardSilent
   ```

**Copies not installed by Inno can't self-update.** 0.3.0 also shipped
`Pomoppi-win.zip` (dropped from releases since); a copy running from an
unzipped folder would get a *second* install in
`%LOCALAPPDATA%\Programs\Pomoppi` and stay stale itself. Compare the
running exe's directory with `InstallLocation` under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{EC3E39B4-1C22-4A15-A54C-769ACA07A1C8}_is1`;
on a mismatch, offer only the release page.

## Phases

- **S6a — Core. Shared, pure, no UI, no networking.** `ReleaseAsset`,
  assets decoding, platform matching, the extra `CheckResult` value,
  `SHA256.swift`, the `UpdateInstallState` enum; both platforms' pattern
  matches updated. Use a captured, trimmed real `/releases/latest`
  response as the test fixture (v0.3.0's assets carry `digest`). **Exit:**
  `swift test` green with cases for asset present / absent / wrong
  platform / `state != "uploaded"` / `digest` missing, plus SHA-256 against
  the NIST vectors and `shasum -a 256` of a real file; `swift build` green
  on the Mac **and in the VM** (shared code).
- **S6b — macOS installer side. No app code.** The postinstall relaunch
  line, and the Gatekeeper check. **Exit:** installing the `.pkg` over a
  running Pomoppi relaunches it by itself, with no Gatekeeper dialog for
  the relaunched app; whether a `URLSession` download from inside the
  installed app carries `com.apple.quarantine` is recorded here; and a
  `.pkg` deliberately quarantined (`xattr -w com.apple.quarantine ...`)
  then stripped opens in Installer.app with no Gatekeeper dialog and no
  System Settings step, proving the safety net.
  **Result (✅ 2026-09-24):** manual tests on the Mac all passed. The only
  noise was four `write: Permission denied` lines from `pkgbuild` on a
  macOS 27 beta / Xcode beta host; the release CI (macOS 26, Xcode 26.6)
  doesn't print them and the package is fine.
- **S6c — macOS in-app update.** `Sources/PomoppiApp/UpdateInstaller.swift`
  (download with progress, verify, open), owned by `AppUpdateChecker`;
  `UpdateStatusRow` in `SettingsView.swift` grows the state table; the tray
  item opens Settings. **Exit:** Update downloads with a moving bar,
  verifies, opens Installer.app with only its password prompt (no
  Gatekeeper dialog, no System Settings step, before or after), and after
  installing the new version is running; Cancel mid-download changes nothing; a corrupted digest shows
  the checksum failure plus a working release-page link; a mid-session
  update asks first.
- **S6d — Windows installer side. VM only, no app code.** The second
  `[Run]` line. **Exit**, in the VM's interactive session (Task Scheduler
  `/it`, see `WINDOWS_VM.md`): with Pomoppi running,
  `Pomoppi-Setup-<new>.exe /SILENT /SUPPRESSMSGBOXES /NORESTART /LOG=...`
  shows only a progress window, closes the running instance, and Pomoppi
  comes back by itself on the new version; the interactive installer still
  shows its "Launch Pomoppi now" checkbox; settings and the login item
  survive; the setup launched with a `Zone.Identifier` stream deliberately
  added and then deleted shows no SmartScreen dialog. **If `CloseApplications` prompts in silent mode, or
  `WizardSilent` doesn't fire, stop and report.**
  **Result (✅ 2026-09-24):** with the Inno-installed copy running,
  `/SILENT /SUPPRESSMSGBOXES /NORESTART /LOG=...` showed only a progress
  window; the log shows RestartManager finding and closing Pomoppi, no
  reboot needed, and the `WizardSilent` `[Run]` entry relaunching it. Two
  things that looked like failures and weren't: a copy running from
  `dist\Pomoppi-win\` is not closed (RestartManager only sees processes
  using files in the install folder, which is also why S6e offers only the
  release page to non-installed copies), and an installer built before the
  `[Run]` line existed obviously doesn't relaunch. The installer also gained
  a desktop-shortcut task (checked by default, remembered across silent
  updates). Run these tests from the VM's own desktop, not over SSH; Task
  Scheduler isn't needed for them.
- **S6e — Windows in-app update.**
  `Sources/PomoppiWindows/UpdateInstaller.swift`; the General tab's Updates
  row gains a hidden-by-default `msctls_progress32` and a second button; the
  tray item opens Settings. Throttle progress repaints to ~10/s. **Spike
  first:** whether `URLSessionDownloadDelegate` progress fires under
  `FoundationNetworking`; if not, the bar goes `PBS_MARQUEE` and the byte
  counts drop. **Exit:** same list as S6c in the VM (no SmartScreen dialog
  at any point), plus the download survives closing and reopening the
  settings window, and a copy run from an unzipped folder offers only the
  release page.
- **S6f — Docs.** `SPEC.md` §15's "passive and notify-only" paragraph
  rewritten (what's downloaded, what the check does and doesn't prove, the
  per-platform install/relaunch, "no auto-install, ever"), §0b's parity
  row, `CLAUDE.md` file map (`SHA256.swift`,
  both `UpdateInstaller.swift`), `README.md` ("updates are in-app from
  here on"). **Exit:** no document still calls the checker notify-only.

## Testing without cutting a release

`/releases/latest` ignores pre-releases, so a pre-release can't exercise
this. Instead, build locally with a lower version (`node
Scripts/set-version.js 0.2.9`, **never committed**): that build sees the
published v0.3.0 as newer and updates to it using 0.3.0's real assets.
Put the version back (`git checkout Sources/PomoppiCore/Version.swift`)
before committing anything.

## Not in scope, deliberately

- **Silent/passwordless install on macOS**, bundle swapping (the dropped
  first design, above).
- **Delta updates, "skip this version", rollback**: more machinery than
  what they save; the release page always has the previous version.
- **Signing (R2)**: still deferred. Its cost is the integrity caveat above
  and the one-time Gatekeeper / SmartScreen step on a first install.
