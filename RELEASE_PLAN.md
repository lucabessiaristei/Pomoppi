# Pomoppi cross-platform release/update plan — status

This file is a self-contained handoff for the release/update plan, in the
same spirit as `WINDOWS_PORT_PLAN.md` for the Windows port. Read this
first for *why* things are the shape they are; `SPEC.md` §15 is the
behavior contract; `RELEASING.md` is the concrete checklist for actually
cutting a release.

**Status as of 2026-09-23: R0-R6 are all done, R7 (this phase) is the
final doc-only pass.** Both platforms build, package, and (once a real
release exists) distribute themselves through GitHub Releases, unsigned.
The update checker is live and shipped on both platforms. The repo
currently has **zero** GitHub releases — nothing has shipped end-to-end
through the real `release: published` path yet; see `RELEASING.md`.

## Locked decisions — do not re-derive or re-litigate these

- **GitHub Releases is the one distribution channel**, for both
  platforms — no separate download page, no CDN, no auto-update server.
- **Unsigned, for now (R2).** No Apple Developer Program enrollment, no
  Windows code-signing certificate. Deliberately deferred as a cost/
  friction tradeoff at this small a user count, not a technical blocker —
  see R2's own entry below and `SPEC.md` §15 for the reasoning in full.
  Revisitable the moment the audience or the Gatekeeper/SmartScreen
  friction (see `README.md`) justifies it.
- **Inno Setup for the Windows installer**, not MSIX/WiX/a hand-rolled
  `.exe` — `windows-latest` ships it preinstalled, and it's the smallest
  step up from "just a zip" that still gets a real per-user install with
  auto-close-on-upgrade (`CloseApplications=yes`).
- **A hand-rolled update checker, not Sparkle/WinSparkle.** Both are
  real, mature frameworks, but both are also dependencies this codebase's
  "zero runtime dependencies" convention (`SPEC.md`'s own opening line)
  doesn't carry today, and the actual need is narrow: poll one GitHub
  endpoint, compare two version strings, show a link. `Sources/
  PomoppiCore/UpdateChecker.swift` is ~140 lines, Foundation-only, and
  shared verbatim by both platforms — see `SPEC.md` §15.
- **arm64-only CI on macOS** (`macos-26` runner, no universal binary) —
  no Intel Macs in the target group, same reasoning the Windows port's
  `WINDOWS_PORT_PLAN.md` already applied to its own ARM64-only VM.
  Windows CI stays x64 (`windows-latest`), matching real Windows
  hardware rather than the ARM64 dev VM the Windows port itself is built
  and tested on.
- **Both release workflows are release-only CI** (`workflow_dispatch` +
  `release: published`), never a per-commit gate — same shape as
  `WINDOWS_PORT_PLAN.md`'s own CI-descoping decision, for the same
  reason: this is a small, infrequent release cadence, not something
  worth gating every commit on.

## Full phase plan

- **R0 — Single-source the version number; get `main` onto GitHub for
  the first time. ✅ DONE**, commits `4d1a81f`, `c9d5bd2`. `main` was 50
  commits behind origin and got pushed for real. `Sources/PomoppiCore/
  Version.swift`'s `pomoppiVersion` became the one version source, read
  by regex via the new `Scripts/version.js`. Windows' `.rc` got a real
  `VERSIONINFO` block. Along the way, fixed a real bug blocking CI:
  `.github/workflows/windows.yml`'s Swift-toolchain version tag
  (`6.4-release` → `6.4.0-release`) — confirmed green afterward.
- **R1 — Unsigned macOS `.pkg` producer. ✅ DONE**, commit `9c02d6c`.
  `Scripts/make-pkg.js` (`pkgbuild`) plus `Scripts/pkg-scripts/
  postinstall` (kills a running instance before an in-place upgrade
  overwrites it). Verified structurally: the payload only ever touches
  `/Applications/Pomoppi.app`, never `~/Library/Application Support`.
- **R2 — Code signing (Apple Developer Program, Windows code-signing
  cert). ⏸️ DEFERRED, not done, not currently planned.** A deliberate
  cost/friction tradeoff at this small a user count — both programs are
  recurring costs that buy nothing the unsigned pipeline doesn't already
  do correctly, and both platforms already ship with real, documented
  friction steps for a recipient instead (`README.md`). Revisitable any
  time the audience or the friction justifies it; not a technical
  blocker on anything else in this plan.
- **R3 — macOS release CI + tag/version guard on both platforms. ✅
  DONE**, commit `ede5b6c`. New `.github/workflows/macos.yml`, mirroring
  `windows.yml`'s shape: `macos-26` runner, Xcode 26.6 pinned explicitly,
  arm64-only. New `Scripts/check-tag-version.js`, shared by **both**
  workflows, fails a `release: published` build if the git tag (minus a
  leading `v`) doesn't match `pomoppiVersion`.
- **R4 — Windows installer + single-instance guard. ✅ DONE**, commits
  `a144a50`, `3215e49`, `c1ed01d`. `Scripts/pomoppi.iss` (Inno Setup),
  `Scripts/make-windows-app.js --installer`, a named-mutex single-
  instance guard added to `Sources/PomoppiWindows/main.swift` (which also
  caught and fixed a real pre-existing double-launch bug independent of
  the installer work). Per-user install (`{autopf}\Pomoppi`, no UAC
  prompt needed), `CloseApplications=yes` for a silent auto-close-and-
  upgrade over a running instance — `AppMutex` was deliberately *not*
  used, since it only shows a blocking dialog with no auto-close
  capability; `CloseApplications`'s RestartManager integration is what
  actually does the work. Verified fully in the VM: fresh install,
  install-over-a-running-instance, settings preserved byte-identical,
  login-item path stable post-upgrade, clean uninstall.
- **R5 — Update-checker core. ✅ DONE**, commit `bc2abaa`. `Sources/
  PomoppiCore/UpdateChecker.swift`: `SemVer` (numeric comparison),
  `parseLatestRelease`/`isUpdateAvailable`/`checkForUpdate`, an injected
  `Fetch` transport so it's testable without a real network call, and
  `requestHeaders(appVersion:)`. Foundation-only, shared by both
  platforms. Targets `GET https://api.github.com/repos/
  lucabessiaristei/Pomoppi/releases/latest` — requires a `User-Agent`
  header (GitHub 403s without one), excludes drafts/prereleases
  automatically server-side, treats a 404 ("no releases yet") as "no
  update," never as an error.
- **R6a — Update checker, macOS side. ✅ DONE**, commit `ab342e4`.
  `checkForUpdates: Bool` (default `true`) added to the shared `Settings.
  swift`. New `Sources/PomoppiApp/AppUpdateChecker.swift` (real
  `URLSession` transport, ~10s-then-24h scheduling, no persisted state).
  Tray item ("Update available: `<tag>`") only when relevant. A settings-
  window footer below the tab view (idle/checking/up-to-date/update-
  available/failed). Window tab gained an "Updates" section: the toggle
  plus a "Reset to Defaults…" button — the in-app answer to "fresh
  install," replacing any installer-side fresh/update toggle since
  settings already live outside the install directory.
- **R6b — Update checker, Windows side. ✅ DONE**, commit `163144c`.
  Same feature, Win32-native. `Sources/PomoppiWindows/
  AppUpdateChecker.swift` uses `URLSession`/`FoundationNetworking` — a
  spike proved this works cleanly on Windows Swift, and `make-windows-
  app.js`'s `dumpbin` DLL walk auto-bundles `FoundationNetworking.dll`
  with zero script changes, no WinHTTP fallback needed. `URLSession`'s
  completion fires off the message-loop thread, marshaled back via
  `PostMessageW`/`WM_APP+2` rather than `DispatchQueue.main`. Tray item
  via `TrayController.swift`, settings footer carved into
  `SettingsWindow.swift` (grew the fixed window height 480→508px to fit
  it). Verified with real VM screenshots.
- **R7 — Final docs pass (this phase). ✅ DONE.** `SPEC.md` §15
  ("Versioning and updates") and a new `§0b` parity-ledger row for the
  update-check UI; `CLAUDE.md`'s file map caught up with every file R0-R6
  added; this file and `RELEASING.md` written; `Scripts/set-version.js`
  added (didn't exist before this phase); `README.md` gained an install
  section covering Gatekeeper/SmartScreen friction for both platforms;
  `WINDOWS_PORT_PLAN.md`'s stale "windows.yml has never been run" claim
  corrected (it has, repeatedly, via `workflow_dispatch` — just never yet
  via the real `release: published` path).

## What to do next

Nothing here is a numbered phase:

- **Actually cut the first real release** — see `RELEASING.md`. This
  repo has zero releases as of R7; the very next one is the first true
  end-to-end exercise of the `release: published` path on both
  workflows (only `workflow_dispatch` has been tested so far).
- **R2 (code signing) stays deferred**, revisit if/when it's worth the
  cost — see its own entry above.
