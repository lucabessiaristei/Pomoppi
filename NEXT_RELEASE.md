# v0.4.0 — what's in it

Running list of what has landed on `main` since v0.3.5, so the release
notes write themselves. Cut it with `RELEASING.md`
(`node Scripts/set-version.js 0.4.0`), then empty this file for the next
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
- **Pomodoros, redesigned** (`SPEC.md` §5): a pomodoro is the whole cycle
  (N focus sessions, short breaks between, one long break) with one title
  for all of it. Skip counts a focus as done (its dot fills; logged as
  stopped early), skipping the last focus starts the long break, and the
  long break ending (or skipped) closes the pomodoro. Reset throws the
  current pomodoro away, log entries included. The widget's dots are
  display-only; the reset button is greyed out while idle.
- **Settings: the "Rhythm" tab is now "Pomodoro"**: Focus (length and
  "Focus sessions", which replaces "Long break every N sessions", same
  saved value), Breaks, Auto-start. The tray submenu is "Focus sessions".
- **The title prompt moved to Diary**: "Ask for a title when a pomodoro
  starts", only while recording sessions; the title is optional and Cancel
  doesn't start the timer.
- **The title prompt always shows Pomoppi's icon**, dev builds included.
- **Diary, redesigned** (`SPEC.md` §8b): Export writes the complete log as
  one file (Markdown, plain text, OpenDocument or JSON); Sync writes one
  short summary per pomodoro into `YYYY/MM/YYYY-MM-DD.md`. Both are
  localized. Old flat `YYYY-MM-DD.md` files from earlier syncs are left
  alone and can be deleted by hand. Sessions logged before this release carry no
  pomodoro id: on first launch they're deleted from the log, once, so
  Diary, Export and Sync start clean. From 0.4.0 on the log is versioned
  and nothing is deleted automatically again.
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
- Pomodoros: one title per pomodoro, skip counts the session, reset discards the pomodoro.
- "Focus sessions" setting replaces "Long break every N sessions".
- Session history from earlier versions is cleared once on update.
- Diary: export the full log as Markdown, text, OpenDocument or JSON; sync writes a daily summary per pomodoro in year/month folders.
- Updates now appear only once the installer for your platform is ready to download.
- macOS: the update installer opens above the widget.
- Windows: the task-name prompt shows Pomoppi's icon.
```
