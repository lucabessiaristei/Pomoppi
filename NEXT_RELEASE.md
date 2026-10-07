# Next release — what's in it

Running list of what has landed on `main` since v0.7.0 (released
2026-10-08), so the release notes write themselves. Cut it with
`RELEASING.md`, then empty this file for the next one.

## Changes

(nothing yet)

## To verify

- **Feedback on Windows 11 with no email app set up**: the "No email app
  set up" line shows instead of the button (no Store dialog). And with
  new Outlook / classic Outlook / webmail in a browser as the handler.
- **In-app update relaunch, end to end**, now that v0.4.0 is out: from an
  installed v0.3.5, Update to v0.4.0 must close, update and reopen the app
  on its own, on both platforms (Windows: a copy installed with its Setup).
- **First launch of 0.4.0 over an older log**: pre-0.4.0 entries are
  removed once and `sessions.json` gets `"version": 2`.
