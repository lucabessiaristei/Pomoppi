# Next release — what's in it

Running list of what has landed on `main` since v0.4.0 (released
2026-09-24), so the release notes write themselves. Cut it with
`RELEASING.md`, then empty this file for the next one.

## Changes

- **Recent titles in the title prompt**: under the field, up to 5 titles
  from past pomodoros (newest first, deduped ignoring case) as link-style
  rows; clicking one fills the field. Nothing shows when the log has no
  titles (`SPEC.md` §5).
- **Update alert at launch**: when the first check after launch finds a
  newer release, an alert offers Update / Later (with a note that a running
  session will be interrupted); Update opens Settings on General and starts
  the update. Windows copies not installed with Setup get "Open release
  page". Only that first check asks, once per launch (`SPEC.md` §15).
- **The widget-keys list no longer shows `T` and `P`**, which did nothing;
  the dead `snapshot` shortcut is gone from the shortcut table (a leftover
  entry in an old `settings.json` is ignored) (`SPEC.md` §13, §14).

## To verify

- **In-app update relaunch, end to end**, now that v0.4.0 is out: from an
  installed v0.3.5, Update to v0.4.0 must close, update and reopen the app
  on its own, on both platforms (Windows: a copy installed with its Setup).
- **First launch of 0.4.0 over an older log**: pre-0.4.0 entries are
  removed once and `sessions.json` gets `"version": 2`.
- **L5 layout pass** (`LOCALIZATION_PLAN.md`): every tab in every language,
  Windows widths first; native reads of es/fr/de.
