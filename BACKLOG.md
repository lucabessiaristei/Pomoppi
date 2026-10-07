# Backlog

Work that isn't done yet and ideas that were deliberately left for later,
gathered from finished plans (the plans themselves are in git history:
`LOCALIZATION_PLAN.md`, `TRANSFER_PLAN.md`). Nothing here blocks a release.
When something here gets picked up, it gets its own plan (or goes straight
in, if small) and leaves this file.

## Localization (left over from the localization plan)

All five languages (en, it, es, fr, de) ship and switch live; what's left:

- **Layout pass:** every Settings tab, the Diary viewer and the Transfer
  window in every language, Windows widths first (Windows lays controls
  out at absolute positions; Italian and German run 20–35% longer than
  English). On macOS check the segmented pickers, which truncate instead
  of wrapping. Exit: nothing clips, overlaps or runs past its scroll extent.
- **Native read** of the es, fr and de catalogs (they were machine drafts;
  only Italian has had a human read).
- **Docs:** a `SPEC.md` "Localization" section (the `language` setting,
  `system` fallback, live relabel on macOS vs window rebuild on Windows,
  the "no sentence ends with a period" copy rule), a §0b parity-ledger row
  for that macOS/Windows difference, `CLAUDE.md` file-map rows for
  `Localization/`, `refresh-strings.js` and `Sources/PomoppiStrings/`
  plus a "generated, never hand-edit" invariant for
  `Strings.generated.swift`, and `README.md`'s commands block
  (`node refresh-strings`).

## Transfer (left over from the transfer plan)

Only ever one QR (decided 2026-10-07): a payload too big for one code
travels as the text code or the `.pomoppi` file, never as several QRs.

- **Partial codes:** send only the log since a date, for when the whole
  history no longer fits one QR.
- **Phone app** that reads and writes the same format (`SPEC.md` §16 is
  complete enough to implement it from).
- **Webcam scanning** on the desktop, once there's a phone app to show a
  code from.
- **Windows drag hover:** the drop zone doesn't highlight while a file is
  dragged over it (needs an OLE `IDropTarget` instead of `WM_DROPFILES`).
- **Windows Open file… filter labels** are English literals, like the save
  dialogs' (`TransferWindow.swift`).
