# v0.3.6 — what's in it

Running list of what has landed on `main` since v0.3.5, so the release
notes write themselves. Cut it with `RELEASING.md`
(`node Scripts/set-version.js 0.3.6`), then empty this file for the next
one.

## Changes

- **Updates are offered only when they can be installed.** A release is
  published a few minutes before CI attaches its installers; in that
  window the check used to report the update with no Update button and no
  way to check again. A newer release without this platform's installer
  now counts as "no update", so the Check button stays until the file is
  there (`308018a`, `SPEC.md` §15).
- **macOS: the installer opens above the widget.** While Installer.app is
  open for an update the floating widget drops to normal level, and goes
  back when it quits (`b34be6b`, `SPEC.md` §9b R1). Shipped in v0.3.5's
  code too, but untested there until now.
- **Windows: the task-name prompt shows Pomoppi's icon** instead of the
  generic window icon (`f1d86b2`).

## To verify before or right after release

- **In-app update relaunch, end to end.** From a local build set to 0.3.4
  (Windows: installed with its Setup, so `unins000.exe` sits next to the
  exe), Check → Update to v0.3.5: the app must close, update and reopen
  on its own on both platforms. The relaunch itself was verified with a
  hand-run installer; the full in-app loop wasn't yet, because v0.3.0's
  installers predate it. Revert with
  `git checkout Sources/PomoppiCore/Version.swift`.
- **macOS: widget below Installer.app**, with "Keep on top" on.

## Suggested release notes

```
- Updates now appear only once the installer for your platform is ready to download.
- macOS: the update installer opens above the widget.
- Windows: the task-name prompt shows Pomoppi's icon.
```
