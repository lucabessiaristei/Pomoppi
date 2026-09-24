# Next release — what's in it

Running list of what has landed on `main` since v0.4.0 (released
2026-09-24), so the release notes write themselves. Cut it with
`RELEASING.md`, then empty this file for the next one.

## Changes

(nothing yet)

## To verify

- **In-app update relaunch, end to end**, now that v0.4.0 is out: from an
  installed v0.3.5, Update to v0.4.0 must close, update and reopen the app
  on its own, on both platforms (Windows: a copy installed with its Setup).
- **First launch of 0.4.0 over an older log**: pre-0.4.0 entries are
  removed once and `sessions.json` gets `"version": 2`.
- **L5 layout pass** (`LOCALIZATION_PLAN.md`): every tab in every language,
  Windows widths first; native reads of es/fr/de.
