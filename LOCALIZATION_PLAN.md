# Pomoppi localization — plan and status

A self-contained handoff for making Pomoppi speak more than English. Read
this first for *why* things are the shape they are; once L5 lands,
`SPEC.md` §16 is the behavior contract.

**Status as of 2026-09-24: L0 in progress.** Infrastructure is in:
`PomoppiStrings` target + `PomoppiStringsTests` (Package.swift edit
approved by the user), `refresh-strings.js`, `Localization.swift`,
`Localization/en.json`. The extraction sweep is running: macOS shell
first, then Windows reusing the same keys (one key per string and
meaning, no per-platform duplicates).

**Roster confirmed 2026-09-24:** English (source), Italian, Spanish,
French, German (`en`, `it`, `es`, `fr`, `de`). Each file carries a
`language.name` key with the language's own name.

## Locked decisions — do not re-derive or re-litigate these

- **A generated Swift string catalog, not `.lproj`/`NSLocalizedString`/
  `String(localized:)`.** One mechanism has to serve both platforms:
  swift-corelibs-foundation's bundle localization on Windows is not
  something to bet the UI on, and neither `Scripts/make-app.js` nor
  `Scripts/make-windows-app.js` has a resource-copying step to hang
  `.lproj` directories off — both are hand-rolled assemblers. A generated
  catalog is also exactly the convention this repo already runs on
  (`Sprites.generated.swift`, `Sounds.generated.swift`, each produced by a
  `node refresh-*` command that also regex-syncs a roster array into
  `Settings.swift`), and it keeps the "zero runtime dependencies" line
  intact. **Trade-off accepted:** no OS plural rules, no `stringsdict`;
  the three count-carrying strings in the app get explicit keys instead.
- **Language is a section inside General, next to Color scheme — not a
  seventh tab.** A tab holding one control, sitting beside five dense
  ones, misrepresents the hierarchy; and the setting belongs with the
  other app-level chrome settings it sits next to. This supersedes the
  original "add a Language tab" instinct.
- **English is the source language and the runtime fallback.** A missing
  key renders English rather than a key name or an empty control, and
  `refresh-strings.js` fails loudly on a translation file that is missing
  keys — so a half-translated language can ship without ever showing a
  blank label, and never silently.
- **Placeholders are positional `{0}`/`{1}`, not printf.** Translators can
  reorder them, and nothing in the app can crash on a mismatched format
  specifier. Substitution is a plain string replace in `Localization.swift`.
- **Diary file content is never localized.** `DiaryExporter`'s
  `## Pomodoros` heading and its `- HH:MM–HH:MM (Nm) — task` lines are a
  *file format*, and sync is idempotent by comparing each day file's
  content (`SPEC.md` §8b) — translating them would make every
  previously-synced file read as changed and rewrite the user's whole
  diary folder on a language switch. Fixed, English, permanently. Same
  for `sessions.json`'s `phase` values.
- **`PomoppiCore` gains no dependency on the strings module.**
  `Shortcuts.swift`'s `ShortcutAction.label`/`hint` stay exactly as they
  are; the two shells look them up by action id
  (`shortcut.<id>.label`) and fall back to the struct's own English when
  a key is absent. Same reasoning that keeps `Settings.swift` free of any
  `PomoppiSprites` dependency today.
- **The OS language is passed in by the shell, never read inside the
  strings module.** macOS reads `Locale.preferredLanguages`, Windows
  `GetUserDefaultLocaleName` (WinSDK), and both hand the result to
  `Localization.configure(systemLanguage:)` at startup — so the module
  stays Foundation-only and testable with no platform seam.

## What gets added

| File | What |
|---|---|
| `Localization/en.json` | Source of truth for English. Flat `key → string`, hand-edited. Keys are dotted and structural: `general.tab`, `general.reset.button`, `rhythm.askForTask.hint.loggingOn`, `prompt.task.title`, `tray.start`. |
| `Localization/it.json`, … | One per language, same key set. |
| `refresh-strings.js` (repo root) | `node refresh-strings` — validates every non-English file against `en.json` (missing keys are an error, extra keys a warning), regex-syncs `PomoppiSettings.languageIDs` into `Sources/PomoppiCore/Settings.swift` exactly the way `refresh-sounds.js`'s `syncIDs()` syncs `chimeIDs`, then always rewrites the generated Swift last. |
| `Sources/PomoppiStrings/Strings.generated.swift` | **Generated** — never hand-edit. `languageIDs`, per-language display names (each in its *own* language: "English", "Italiano"), and the `[languageID: [key: String]]` table. |
| `Sources/PomoppiStrings/Localization.swift` | Hand-written runtime: `configure(systemLanguage:)`, `apply(setting:)`, `t(_:)`, `t(_:_:)`. ~60 lines, no platform import. |
| `Tests/PomoppiStringsTests/` | Every language has every English key; every `{n}` placeholder in a translation exists in its English source; fallback returns English for an unknown key. |

`Sources/PomoppiStrings/` is a new SPM target, so `Package.swift` — a
contract file — needs a target plus a dependency line in both the
macOS and the `#if os(Windows)` branch, and in `PomoppiApp`/
`PomoppiWindows`. **Propose that edit and get an explicit go-ahead as the
first step of L0**, don't fold it in silently.

## Full phase plan

- **L0 — Catalog infrastructure + the extraction sweep. English only, no
  visible change.** Build
  `Localization/en.json` by walking every user-facing literal in
  `Sources/PomoppiApp/` and `Sources/PomoppiWindows/` — settings window,
  tray menu and tooltip, `MessageBoxW` confirmations, update-footer
  states, the task prompt — then route each call site through
  `L.t("…")`. **Exit:** `swift build` on both platforms, `swift test`
  green, and both apps render byte-identically to before (the English
  table is the same strings); `node refresh-strings` is idempotent on a
  clean tree.
- **L1 — The `language` setting and the reload mechanism. Still English
  only.** `language: String = "system"` added to `PomoppiSettings` as a
  defaulted trailing init parameter (the same pattern
  `reverseTrayClick`/`chime`/`checkForUpdates` each used —
  `CodingKeys`/`init(from:)`/`defaults`/`clampInPlace` all updated, with
  clamping falling back to `"system"`); `Localization.configure` called
  from `AppDelegate.applicationDidFinishLaunching` and `main.swift`;
  `settingsStore.onChange` re-applies it on both platforms (both already
  route every settings change through one closure —
  `AppDelegate.swift:78`, `main.swift:151`). **Exit:** flipping
  `"language"` by hand in `settings.json` and relaunching changes nothing
  visible yet (there is one language), but `L.current` reflects it;
  `SettingsTests` covers the default, the missing-key fallback and an
  unknown value clamping back to `"system"`.
- **L2 — Translation content.** `Localization/it.json` (plus whatever
  else the roster ends up being), reviewed as *copy*, not as a
  string-by-string transliteration — the English here is deliberately
  conversational ("Ask what I'm working on before each focus", "Pop to
  the front when a session ends") and a literal translation reads like a
  manual. **Exit:** `node refresh-strings` passes with zero missing keys;
  a native reader has read the whole file top to bottom.
- **L3 — macOS UI: Language control in General.** A `Picker` in the
  General tab's new Language section, directly under Color scheme:
  "System" plus one row per language in its own language. SwiftUI needs
  nothing else — every view already reads through `viewModel.settings`,
  so the `@Published` change re-evaluates every `L.t(…)` in the form.
  The tray menu needs nothing either: `TrayController.buildMenu()`
  (`TrayController.swift:108`) constructs a fresh `NSMenu` per open off
  live timer/settings state, so it picks the new language up on its next
  click — same as Windows' freshly-rebuilt-per-open menu (Phase W4). The
  menu-bar clock and tooltip are refreshed on a timer and follow on their
  own.
  **Exit:** switching language relabels the whole settings window
  live, without reopening it; the tray menu and its tooltip follow; the
  choice survives a relaunch; "System" tracks the OS language.
- **L4 — Windows UI: Language control in General.** Same section, an
  owner-drawn segmented picker if the roster stays at 2-3 entries, a
  `COMBOBOX` beyond that. Win32 bakes a control's text in at creation, so
  a language change rebuilds the settings window — **reuse
  `SettingsWindow.rebuild()`**, which exists for exactly this reason (the
  reset button has the same problem), and
  reselect the remembered tab afterwards so the window doesn't jump back
  to General. **Hard dependency on S2's other half**: `createPage`
  currently picks which tab to build by `switch`-ing on the tab's
  *visible title* and falls through to a "coming in a later phase"
  placeholder when nothing matches — translate the titles before S2
  re-keys that dispatch to an index and every tab in every non-English
  language comes up blank. The tray menu is already rebuilt per open (Phase W4), so it
  needs nothing. **Exit:** switching language rebuilds the window in
  place on the same tab, tray menu and tooltip follow on their next
  refresh, choice survives a relaunch — VM screenshots per language, in
  the interactive session.
- **L5 — Layout pass + docs.** Italian and most other languages run
  20-35% longer than English, and Windows lays every control out at an
  absolute position: walk every tab at every language, widening labels
  (`measureTextWidth` already exists) and checking that nothing clips,
  overlaps or pushes a page past its scroll extent; on macOS check the
  segmented pickers, which truncate rather than wrap. Then `SPEC.md` §16
  ("Localization"), a §0b parity-ledger row for anything that ends up
  divergent (e.g. macOS relabels live where Windows rebuilds the window),
  `CLAUDE.md`'s file map (shared table: `Localization/`,
  `refresh-strings.js`, `Sources/PomoppiStrings/`, plus a
  "**generated** — never hand-edit" invariant line for
  `Strings.generated.swift` alongside the two that are already there), and
  `README.md`'s commands block. **Exit:** every tab legible in every
  language on both platforms; no doc still describes Pomoppi as
  English-only.

## What to do next

1. **L0 → L5** here, in order. L0 and L1 are mechanical and can be
   delegated; L2 needs a human reader; L4 depends on S3's rebuild; L5 is
   the only phase that needs every language present.

Nothing in this plan blocks a release: Pomoppi ships English-only today
and stays shippable at every phase boundary here — L0/L1 are invisible,
and L3/L4 each add a working control for whatever languages exist at that
point.
