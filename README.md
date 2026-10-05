# Pomoppi

ポモっぴ: a pixel pomodoro widget for macOS and Windows, with a virtual pet that
**deteriorates because you are productive**. It does your tasks for you and
suffers for it. You get the finished pomodoros and the pet gets the
consequences. It's a spin-off of **Habitsuu**, the habit tracker these creatures
come from.

It's native Swift on both platforms, with no Electron and no runtime
dependencies.

## Install

Download the file for your platform from the
[latest release](https://github.com/lucabessiaristei/Pomoppi/releases/latest).
The installers are unsigned, so the first launch shows a warning:

- **macOS** (`Pomoppi-<version>_macOS.pkg`): right-click it in Finder, choose
  **Open**, then click **Open** again. Alternatively, go to **System Settings →
  Privacy & Security → Open Anyway**. Pomoppi lives in the menu bar and has no
  Dock icon.
- **Windows** (`Pomoppi-Setup-<version>_Windows.exe`): click **More info →
  Run anyway**. It's a per-user install, so no admin prompt appears. Pomoppi
  lives in the system tray.

After that, updates install from inside the app: **Settings → General →
Updates → Update**. Pomoppi verifies the download against GitHub's published
size and SHA-256 before it runs it.

## Privacy

Pomoppi never listens for connections, sends no telemetry and has no accounts.
It only makes outbound requests to GitHub, and only for updates:

- It checks `api.github.com/repos/lucabessiaristei/Pomoppi/releases/latest`
  about 10 s after launch and every 24 h after that. You can turn this off with
  **Check for updates** in Settings → General.
- It downloads the installer that response lists, but only when you click
  **Update**.

Your settings and session history stay in `~/Library/Application Support/Pomoppi/`
on macOS and `%APPDATA%\Pomoppi\` on Windows.

## Using it

- A **pomodoro** is a whole cycle: a few focus sessions with short breaks
  between them, then a long break. The dots show how many focus sessions are
  done.
- The buttons are **↺** reset (throws away the current pomodoro), **▶/⏸**,
  **⏭** skip, and **♥** settings. While the timer is idle, **− / +** next to the
  clock change the focus length.
- Drag anywhere to move the widget. When a timer ends, Pomoppi comes to the
  front and chimes.
- Global shortcuts work from any app and can be rebound in Settings:
  <kbd>⌥⇧Space</kbd> start/pause, <kbd>⌥⇧K</kbd> skip, <kbd>⌥⇧R</kbd> reset,
  <kbd>⌥⇧P</kbd> show/hide. On Windows, <kbd>⌥</kbd> is <kbd>Alt</kbd>.
- **Diary**: pomodoros are logged locally. You can export them as
  Markdown/text/ODT/JSON, or sync one Markdown file per day into a folder, such
  as an Obsidian vault.

Pets, window edges, backgrounds, chimes and the language
(en/de/es/fr/it) are all under **Settings**.

## Building

```sh
swift build && swift test   # macOS
swift run PomoppiApp        # run a dev build
node Scripts/make-app.js    # install a release build to /Applications
```

The Windows app builds only on Windows (`WINDOWS_VM.md`). The developer docs
are `CLAUDE.md` for commands, file map and art pipeline, `SPEC.md` for behavior,
and `RELEASING.md` for releases.
