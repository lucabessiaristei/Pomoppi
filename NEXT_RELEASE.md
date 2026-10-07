# Next release — what's in it

Running list of what has landed on `main` since v0.5.0 (released
2026-10-07), so the release notes write themselves. Cut it with
`RELEASING.md`, then empty this file for the next one.

## Changes

- New last Settings tab, Pomoppi: version + What's new link, Updates and Reset (moved from General), and a Show in Finder/Explorer button for the data folder.
- Transfer (Pomoppi tab): move settings and pomodoro history to another computer, macOS or Windows, with no account or internet: a QR code, a copyable text code or a `.pomoppi` file; receiving reads a photo or screenshot of the QR, a pasted code or the file, and previews before importing.

## To verify

- **In-app update relaunch, end to end**, now that v0.4.0 is out: from an
  installed v0.3.5, Update to v0.4.0 must close, update and reopen the app
  on its own, on both platforms (Windows: a copy installed with its Setup).
- **First launch of 0.4.0 over an older log**: pre-0.4.0 entries are
  removed once and `sessions.json` gets `"version": 2`.
