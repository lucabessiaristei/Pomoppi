# Pomoppi settings overhaul + Windows task prompt — plan and status

This file is a self-contained handoff for the settings-window overhaul, in
the same spirit as `WINDOWS_PORT_PLAN.md` and `RELEASE_PLAN.md`. Read this
first for *why* things are the shape they are; `SPEC.md` §7 is the behavior
contract for the settings schema and window layout, §5 for the task-name
prompt.

It has three parts:

- **Part A (S0-S5)** — the settings window itself: tab map, copy, the
  regrouped General tab, the reset that doesn't actually reset, hint
  footers, Diary terminology.
- **Part B (T1-T3)** — the Windows task-name prompt. Part A makes
  `askForTaskName` visible and honest on Windows; Part B builds the thing
  it actually toggles, which has never existed there (`SPEC.md` §0b's
  parity ledger: "**None.** `startPause` starts the timer directly").
- **Part C (S6a-S6f)** — the in-app **Update** button: download, verify,
  install, relaunch, replacing today's passive "here's a link" notifier.
  It is really a follow-on to `RELEASE_PLAN.md`'s R5/R6 rather than to
  the settings overhaul, and lives here because the one surface it
  rewrites is the settings window's update footer, which Part A is
  already reshaping around it. Read `RELEASE_PLAN.md` first for why the
  checker exists at all and why it is hand-rolled.

**Status as of 2026-09-24: S0-S4 and T1-T2 are done (S1 in commit
`b092865`, shipped in the `1dcf97e` 0.3.0 bump; S2 in commit `1ec7af2`);
S5, T3 and S6a-S6f are not started.** `LOCALIZATION_PLAN.md` depends on this
file: S0 locks the copy, and nothing in L0's string-extraction sweep
should run against labels this plan is still about to rename — or
against the pile of new strings Part C adds.

## Locked decisions — do not re-derive or re-litigate these

- **Six tabs, reordered, with `Window` renamed `General`**: General,
  Rhythm, Appearance, Keys, Sound, Diary. `Window` was a grab-bag
  (widget layering + tray clicks + startup + updates + reset) that named
  only its first section; once it also holds Color scheme and (later)
  Language, "General" is what it is. General leads because it is the
  app-level tab, and because both platforms remember the last tab — so
  "which tab is first" only decides what a brand-new install opens on.
- **`Color scheme` moves from Appearance to General.** It governs
  Pomoppi's *own* windows' chrome, never the widget (the widget's colors
  are a manual ink/paper choice). Sitting under Appearance next to the
  ink/paper theme, it read as a widget setting and was tried as one.
- **No Play/replay control on the Sound tab** (S1, shipped). Selecting a
  chime previews it; that is the only preview affordance, on both
  platforms. Decided as final — do not re-add a demoted "Test" button.
- **Windows' `askForTaskName` toggle gets a real feature behind it, not a
  hidden control** (Part B). Hiding a per-platform subset of settings
  would be the first such divergence in this app and would make the two
  platforms' settings files mean different things.
- **Reset resets the running app**, not just the files on disk. The
  current implementation deletes the storage directory and asks the user
  to restart; anything that writes a setting afterwards resurrects the
  old values from memory (see S3). Going through `SettingsStore.reset()`
  + `SessionLogger.eraseAllSync()` is both correct and less code.
- **Every hint is a footer under its control, never a disclosure, never a
  tooltip.** `SPEC.md` §7's "nothing is behind a disclosure" rule already
  said this for settings; hints obey it too. macOS has `Form`'s `footer:`
  for free; Windows gets one `addHint` helper (S4) and uses it the same
  way.
- **`SPEC.md` is updated in the same phase as the behavior it
  describes**, not in a trailing docs sweep. S5 exists for the leftovers
  (README, parity-ledger rows that went stale for unrelated reasons), not
  as the place where this plan's own contract changes land.

## Target tab map

The one source of truth for S2-S5. S0's whole job is getting this into
`SPEC.md` §7's layout table; every later phase implements a row of it.
Labels are the exact strings to ship (macOS wording first, Windows
divergence noted inline where the platform noun differs).

| Tab | Section | Controls | Hint footer |
|---|---|---|---|
| **General** | Color scheme | Auto / Light / Dark (segmented) | "Applies to Pomoppi's own windows. The widget's colors are under Appearance." |
| | *(Language — added by `LOCALIZATION_PLAN.md` L3/L4, not by this plan)* | | |
| | Widget | Keep the widget on top of other windows; Pop to the front when a session ends | — |
| | Menu bar icon *(Windows: Tray icon)* | Swap the menu bar icon's left and right clicks | live: "Left-click raises the widget, right-click opens the menu." / swapped |
| | Startup | Open Pomoppi when I log in; Start without showing the widget | "Launch at login only registers when Pomoppi is running as an installed app. “Start hidden” applies the next time Pomoppi launches." |
| | Updates | Automatically check for updates | "Checks lucabessiaristei/Pomoppi on GitHub roughly once a day." |
| | Reset | **Reset Pomoppi…** | "Erases every setting and your whole session history, and puts Pomoppi back to how it shipped." |
| **Rhythm** | Focus | Default focus length | "Or click the clock on the widget." |
| | Breaks | Short break; Long break; Long break every N sessions | "Or click the dots on the widget." |
| | Automation | Start breaks automatically; Start the next focus automatically; Ask what I'm working on before each focus | live, on `askForTaskName`: logging on → "Session logging is on, so Pomoppi always asks — this setting only applies while logging is off."; logging off → "Pomoppi asks before each focus session. Leave it blank to skip." |
| **Appearance** | Roommate / Theme / Window edge / Background | unchanged | — |
| | Size & transparency | unchanged | "1× is very small — 104×128 physical pixels." |
| **Keys** | Global shortcuts | one recorder row per action | "These fire even while Pomoppi isn't the frontmost app. A shortcut needs a modifier; two actions can't share the same combo." |
| | | **Restore Default Shortcuts** | — |
| | While the widget is focused | static key list | "Fixed keys. They only fire while the widget window itself has focus." |
| **Sound** | *(unnamed)* | Play a chime when a session ends; Chime picker; ring length | "Selecting a chime plays it." |
| **Diary** | Session history | Record every session; History size; **Erase History…** | "Pomoppi's own record of every session, kept on this computer. Erasing it can't be undone." |
| | Export | Sessions recorded; Export Diary… | — |
| | Sync to folder | Diary folder; Choose…; Sync Now | — |

Renames this table encodes, in one list, because they are what
`LOCALIZATION_PLAN.md` must not race: `Window` → `General`;
`Reset to Defaults…` → `Reset Pomoppi…`; Keys' `Reset to Defaults` →
`Restore Default Shortcuts`; `Logging` → `Session history`; `Log
sessions` → `Record every session`; `Cache size` → `History size`;
`Erase Cached Sessions…` → `Erase History…`; `Sessions logged` →
`Sessions recorded`.

"Cache" is wrong and worth the churn: `sessions.json` is the only copy of
that data, not a disposable mirror of something else, and the Erase
confirmation reads as harmless while it is permanent.

## Part A — the settings window (S0-S5)

- **S0 — Lock the copy and the tab map. Doc-only, no code. ✅ DONE.**
  Rewrote `SPEC.md` §7's "Settings window layout" table from the map
  above (it previously documented the pre-rename 6 tabs and carried its
  own "this table is stale" apology); added the hint-footer rule next to
  the existing no-disclosure rule; noted the reorder. **Exit:** `SPEC.md`
  §7 matches the table above exactly, and `LOCALIZATION_PLAN.md`'s L0 is
  unblocked. Nothing builds differently.
- **S1 — Sound tab: preview on selection, no Play control. ✅ DONE**,
  commit `b092865` (in `1dcf97e`'s 0.3.0 bump), both platforms, landed
  concurrently with this plan being written. The Play/replay button is
  **gone**, not demoted: selecting a chime plays its focus-end sound
  (`SettingsView.swift`'s `SoundTab` `.onChange`;
  `SettingsWindow.swift`'s `addChimePicker`). The same commit ungated
  `ringSeconds` from `soundEnabled` (it governs the visual ring only,
  `SPEC.md` §4, updated there too), gave macOS's stepper a "Don't ring"
  label at 0, and fixed macOS's `ChimePlayer` layering two sounds on a
  fast re-select. Only the hint copy in the map above is still
  outstanding, and it rides along with S4.
- **S2 — Tabs: rename, reorder, regroup; move Color scheme; tab
  memory. ✅ DONE**, both platforms. The structural phase, no behavior
  change beyond where things live.
  - macOS `Sources/PomoppiApp/SettingsView.swift`: reorder the six
    `Tab(...)` entries (`:16-33`), rename `WindowTab` → `GeneralTab`
    (`:464`), move the `Color scheme` section out of `AppearanceTab`
    (`:244-252`) into it as the first section, split today's single
    Updates section into Updates + Reset, rename the reset button
    (`:491`) and the Keys reset button (`:696`). `@AppStorage("pomoppi.settingsTab")`'s
    default becomes `"general"` (`:11`) — an existing install carrying
    `"window"` no longer matches any tab, so `TabView` falls back to the
    first tab, which is the intended landing anyway.
  - Windows `Sources/PomoppiWindows/SettingsWindow.swift`: reorder
    `tabTitles` (`:490`), rename `buildWindowTab` → `buildGeneralTab`
    (`:2491`), move `addColorSchemePicker` out of `buildAppearanceTab`
    (`:1350-1352`) into it, same two renames.
  - **Re-key `createPage`'s dispatch from the title to the index**
    (`:1234`, `switch title { case "Rhythm": … case "Window": … }`).
    It currently decides which tab to build by comparing the *visible
    title string*, and an unmatched title silently falls through to
    `buildPlaceholder` — "Foo — coming in a later phase". That is a
    rename away from a blank tab today, and it is a hard blocker for
    `LOCALIZATION_PLAN.md`'s L4, where every title becomes translated
    text. Switch on the tab's index (or a small `enum Tab` with a
    `title` property), so the display string and the dispatch key stop
    being the same thing.
  - Tab memory (Windows): the settings window is destroyed on close, so
    the selected tab dies with it. Persist the index to
    `HKCU\Software\Pomoppi`, value `SettingsTab` — the Windows-idiomatic
    equivalent of macOS's `UserDefaults`-backed `@AppStorage`, written in
    `selectTab` (`:3221`) and read once in `setUpTabsAndPages` (`:769`).
    `Sources/PomoppiWindows/LoginItem.swift` already has the registry
    open/set/query dance to copy. Deliberately **not** a `PomoppiSettings`
    field: `SPEC.md` §7 says the selected tab is a per-viewer
    convenience, never part of the schema.
  - **Exit:** both platforms show General, Rhythm, Appearance, Keys,
    Sound, Diary in that order; Color scheme sits at the top of General
    and still drives the settings window's chrome live; Windows reopens
    on the tab it was left on, across a full app restart; `swift test`
    green; VM screenshot of the new General tab.
- **S3 — Make "Reset Pomoppi…" actually reset. ✅ DONE**, both
  platforms. Previously both platforms deleted the storage directory and
  told the user to restart (`SettingsViewModel.swift:41`,
  `SettingsWindow.swift:2560`). The running app kept its in-memory
  `PomoppiSettings`, so the next write of *any* setting re-persisted the
  old values over the fresh directory, and the next completed phase
  recreated `sessions.json` — a reset that silently un-reset itself if
  the user touched one more control.
  - Replace both with the two APIs that already exist and already
    propagate: `sessionLogger.eraseAllSync()` then
    `settingsStore.reset()`. `reset()` persists defaults and fires
    `onChange`, which both shells already wire to "re-apply widget
    window properties, re-register global shortcuts, re-apply the login
    item, re-apply update checking" (`AppDelegate.swift:78-83`,
    `main.swift:151-156`) — so the widget resizes, hotkeys rebind and the
    login item unregisters on the spot, with no restart.
  - macOS: `SettingsViewModel.resetToDefaults()` assigns
    `settings = settingsStore.reset()` so the `@Published` form redraws
    at defaults. Drop the now-unused `storageDir` dependency from the
    view model's init.
  - Windows: controls bake their values in at creation, so the window
    needs to be rebuilt. Add `SettingsWindow.rebuild()` — destroy the tab
    control, pages and footer, clear every dispatch array
    (`checkboxes`/`steppers`/`pushButtons`/`pickerCards`/…), then re-run
    `setUpTabsAndPages`/`createFooter`/`applyTheme` and reselect the
    remembered tab. **This mechanism is reused verbatim by
    `LOCALIZATION_PLAN.md`'s L4** (a language switch has the same
    "strings are baked in" problem), so build it as a general rebuild,
    not a reset-specific patch.
  - Confirmation copy on both platforms drops "Restart Pomoppi to start
    fresh" (no longer true) and keeps the destructive warning.
  - **Exit:** with the settings window open, reset flips every visible
    control back to defaults, shrinks a 4× widget back to 2×, and leaves
    `settings.json` at defaults *after* subsequently toggling an
    unrelated setting (the exact case that regressed before); session
    history reads 0 B. Verified on both platforms, Windows in the VM's
    interactive session.
- **S4 — Hint footers. ✅ DONE**, Windows only — macOS's own `Form`
  `footer:` side (several hints the map calls for — Reset, Sound, Diary's
  Session history, Rhythm's Automation/askForTaskName — don't exist in
  `SettingsView.swift` yet either) is **not** part of this pass; flagged
  as open below rather than folded into S5 silently.
  - Windows: added `addHint(_:in:x:y:width:trackForScroll:)` next to
    `addLabel` (`SettingsWindow.swift:3327`) — a `STATIC` with
    `SS_NOPREFIX` (mandatory: a bare `&` is eaten as a mnemonic, the bug
    W7 already hit), a second `HFONT` one point smaller than the default
    GUI font (`hintFont`, built once via `GetObjectW`/`CreateFontIndirectW`
    off the stock `DEFAULT_GUI_FONT`'s own `LOGFONTW`), and dimmed text.
    Height is measured, not guessed — `measuredHintHeight` reads
    `hintFont`'s own text extent and computes a word-wrap line count
    against `width`, capped at 3 lines — because a first pass using one
    flat height for every hint clipped the Keys tab's trailing hint clean
    off the bottom of the page; the per-call height is cached
    (`lastHintHeight`) for the call site's own `y +=` bookkeeping right
    after.
  - The dimming was the fiddly part: `handleCtlColor` (`:3869`) was
    **dark-mode-only and HWND-blind** — it returned early to
    `DefWindowProcW` whenever `isDarkMode` was false, and otherwise
    painted every `STATIC` the same color. Now it (a) runs in light mode
    too and (b) branches per control via a `hintLabels` HWND set
    (`:396`) and two text colors (`hintTextLightHex`/`hintTextDarkHex`),
    returning the matching background brush in each of the four
    combinations.
  - Appearance-page hint (`Size & transparency`'s) passes
    `trackForScroll: true` so it scrolls with the rest of the page.
  - Live hints: `reverseTrayClick`'s and `askForTaskName`'s both
    re-render on the *other* control's change — `setWindowText` alone
    from the owning checkbox's toggle handler (no separate
    `InvalidateRect`; matches this file's existing shortcut-recorder-button
    redraw idiom, `SetWindowTextW` already repaints on its own), plus a
    refresh from the Diary tab's `loggingEnabled` toggle (it is what
    overrides `askForTaskName`).
  - The `askForTaskName` hint was the point of this phase: with default
    settings (`loggingEnabled: true`, `askForTaskName: true`) the toggle
    is inert — logging forces the prompt and makes cancelling refuse to
    start (`SPEC.md` §5). That override was invisible on macOS and didn't
    exist at all on Windows before this; it's still invisible on macOS
    (see the note above — out of scope for this pass) but now shown and
    live on Windows.
  - Fitting the Keys tab's two new hints (its content was already at the
    old budget's ceiling with none) needed the settings window's own
    minimum content height to grow, `480` → `552`
    (`SettingsWindow.swift:542`, `clientHeight`); every other tab still
    has slack at the new size.
  - **Exit:** every hint in the map renders on Windows; toggling session
    logging on the Diary tab visibly changes the Rhythm tab's ask-for-task
    hint (verified live in the VM); no hint clips or overlaps at the
    default window size, light or dark (verified — General/Rhythm/Keys
    screenshotted both themes in the VM's interactive session); `swift
    build`/`swift test` green on both platforms. **Still open:** macOS's
    own `Form` `footer:` side for the hints this phase's map calls for
    that `SettingsView.swift` doesn't have yet (Reset, Sound, Diary's
    Session history, Rhythm's Automation/askForTaskName) — copy is
    already locked in the map above, so it's a `SettingsView.swift`-only
    follow-up, not a re-litigation.
- **S5 — Diary terminology + docs catch-up.** The renames in the map's
  Diary row, on both platforms and in `SPEC.md` §8/§8b (which call the
  session log a "cache" throughout), plus the leftovers this pass
  surfaces:
  - `README.md` is still Obsidian-era: its "Settings" table lists
    `Timer`/`Obsidian`/`Appearance`/`Keys`/`Sound` (five tabs, none of
    them current) and the prose above it documents vault paths, daily-note
    folders and a **Test log** button that no longer exist anywhere in
    the app.
  - `SPEC.md` §0b's "Settings chrome" row claims Windows' window is
    "fixed-size (560x480), non-resizable" — it gained `WS_THICKFRAME`,
    a real resize handler, a footer strip and a dark mode since that row
    was written.
  - **Exit:** no occurrence of "cache"/"cached" for session history in
    either UI or in `SPEC.md` §8/§8b; `README.md`'s settings table
    matches the tab map; the §0b row matches what ships.

## Part B — the Windows task-name prompt (T1-T3)

macOS's `Sources/PomoppiApp/StartCoordinator.swift` is the reference, and
it is 63 lines. The behavior to mirror, read off that file rather than
assumed:

- **Only a fresh focus session prompts.** `requestStart` returns early —
  plain `timer.start()` — unless `state.phase == .idle` *and*
  `timer.getTask().isEmpty`. Breaks are `.shortBreak`/`.longBreak`, a
  paused focus is `.focus`, so resuming anything never prompts, and a
  task set in advance is never asked for twice.
- **Two gates, one stricter than the other.** `askForTaskName` alone is
  the ordinary gate; `loggingEnabled` overrides it and makes the prompt
  mandatory, because a logged session with no task name is not a useful
  line to have recorded.
- **Cancel means different things per gate.** Optional prompt: cancel
  still starts the timer with no task. Mandatory prompt: cancel leaves
  the timer idle and starts nothing.
- **A non-empty answer goes to `timer.setTask(task)` before
  `timer.start()`**, trimmed of whitespace; an empty answer is not set at
  all. From there it is already wired: the task rides on `TimerState`,
  lands in `PhaseCompleteEvent.task`, and `main.swift:48`'s
  `onPhaseComplete` hands it to the shared `SessionLogger` — no
  Windows-side logging work is needed, only the name.

With shipped defaults (`loggingEnabled: true`, `askForTaskName: true`)
this means **every fresh focus start on Windows will require typing
something**, exactly as on macOS today. That is the intended contract,
not a side effect; S4's hint is what explains it.

### Design

- **Two new files, no shared abstraction.** `Sources/PomoppiWindows/StartCoordinator.swift`
  (the gate, ~25 lines, a deliberate duplicate of the macOS logic) and
  `Sources/PomoppiWindows/TaskPromptDialog.swift` (the Win32 modal).
  `Sources/PomoppiApp/` stays off-limits — CLAUDE.md's invariant, and the
  same call this port already made for tray clicks, picker previews and
  the login item.
- **One call site.** `WidgetInput.activateButton`'s `case "play"`
  (`WidgetInput.swift:223-231`) is the only place Windows starts an idle
  timer: the widget's play button, Space/Return, the tray menu's
  Start item (`TrayController.swift:136`) and the `startPause` global
  hotkey (`main.swift:87`) all already funnel through it. Change that one
  `timer.start()` to `StartCoordinator.requestStart(timer:settingsStore:owner:)`,
  which returns the resulting `TimerState`.
- **A hand-rolled modal, not `DialogBoxParamW`.** This codebase has no
  dialog templates or resource-file UI anywhere (`Pomoppi.rc` carries an
  icon and `VERSIONINFO`, nothing else); every window is a registered
  class plus a `WndProc`. The prompt follows that: `WS_POPUP | WS_CAPTION |
  WS_SYSMENU` (no resize, no minimize), owned by the widget's `hwnd` so it
  always sits above the always-on-top widget without asking for
  `WS_EX_TOPMOST` itself.
- **Contents**, top to bottom: a `STATIC` title — "What are you working
  on?"; a single-line `EDIT` (`ES_AUTOHSCROLL`, `WS_EX_CLIENTEDGE`) with
  an `EM_SETCUEBANNER` placeholder "Task or project name" (comctl32 v6,
  available — the manifest is wired since W8); a hint `STATIC` carrying
  the same two strings macOS uses ("Session logging is on, so this
  session needs a task name to log a useful line." / "Optional — leave
  blank to skip."); then **Start** (`BS_DEFPUSHBUTTON`) and **Cancel**.
  ~340×150 client, centred on the owner and clamped to the work area
  (`SPI_GETWORKAREA`) — the widget can sit hard against a screen edge.
- **Modality is the nested-loop kind**: `EnableWindow(owner, false)` (and
  the settings window too, if one is open), `ShowWindow` +
  `SetForegroundWindow`, then a local `GetMessageW`/`IsDialogMessageW`
  loop until the dialog signals a result — then **re-enable the owner
  before `DestroyWindow`**, or Windows hands activation to some other
  app's window instead of back to Pomoppi. `MessageBoxW` already blocks
  this app's message loop the same way (`confirmEraseSessionLog`,
  `confirmResetToDefaults`), so this is not a new shape of risk, just a
  hand-rolled one.
- **Keyboard**: intercept `VK_RETURN`/`VK_ESCAPE` in the loop, on
  `WM_KEYDOWN`, *before* `TranslateMessage`/`IsDialogMessageW` — a
  single-line `EDIT` beeps at a `WM_CHAR` carrying Return, and relying on
  `IsDialogMessageW`'s `DM_GETDEFID` path for a non-dialog class is the
  kind of thing that works until it doesn't. `IsDialogMessageW` still
  runs afterwards, for Tab navigation between the edit and the buttons.
- **Re-entrancy guard**: `WM_HOTKEY` is posted to the widget's `hwnd` and
  is still dispatched by the nested loop even while that window is
  disabled, so the `startPause` hotkey can re-enter `requestStart` and
  open a second prompt. A `static var isShowing` makes the second call a
  no-op that just calls `SetForegroundWindow` on the existing prompt.
- **Hidden widget**: the global hotkey can start a session while the
  widget is hidden (`startHidden`, or Escape). `GetWindowRect` on a
  hidden owner still returns its old rect, so centre on the primary work
  area instead when `IsWindowVisible(owner)` is false, and rely on the
  explicit `SetForegroundWindow` — nothing of Pomoppi's is foreground in
  that case.
- **Dark mode**: a light dialog out of a dark-themed app reads as broken.
  Extract `Sources/PomoppiWindows/WindowsTheme.swift` — the
  `SystemUsesLightTheme` registry read plus the two hex constants
  currently private to `SettingsWindow` (`resolveDarkMode`,
  `darkBackgroundHex`, `darkTextHex`) — and have both the dialog and
  `SettingsWindow` use it. Both files are Windows-side, so this needs no
  Mac-side edit and doesn't violate the no-shared-abstraction invariant.
- **Deliberately not in scope**: the `T` in-app key ("Name what you're
  working on", `SPEC.md` §13) — it is absent on macOS too (found in W9),
  and adding it here would make Windows the only platform with it.

### Phases

- **T1 — The dialog and the gate. ✅ DONE.** Both new files
  (`Sources/PomoppiWindows/StartCoordinator.swift`,
  `Sources/PomoppiWindows/TaskPromptDialog.swift`), the one-line call-site
  change in `WidgetInput.swift`'s `activateButton`'s `"play"` case, light
  mode only, centred on the owner. **Exit**, all five checked in the VM's
  interactive session (Task Scheduler `/it`):
  1. logging off + ask off → no prompt, timer starts (today's behavior,
     unregressed) — verified;
  2. logging off + ask on → prompt; Start with "writing docs" → timer
     runs, and `%APPDATA%\Pomoppi\sessions.json` carries
     `"task": "writing docs"` (verified via a same-shape logging-on run —
     see note below);
  3. logging off + ask on + Cancel → timer starts, `task` empty —
     verified;
  4. logging **on** + ask **off** → prompt appears anyway; Cancel → timer
     stays idle, nothing logged — verified;
  5. starting a break, and resuming a paused focus → no prompt either
     time — verified (a 1-minute focus — `focusMinutes` floors at 1 via
     `PomoppiSettings.clamp` — completed naturally, then pressing play
     dismissed the ring and started the break directly with no prompt;
     `sessions.json` recorded `"task": "resume test"`).

  Case 2 as literally written can't be verified standalone:
  `SessionLogger.logSession` bails out (`guard getSettings().loggingEnabled`)
  whenever logging is off, so nothing ever reaches `sessions.json` in that
  exact combination — confirmed dialog + Start-with-text behavior visually
  (screenshot) instead, and verified the typed-text → `sessions.json`
  path for real under case 5's logging-on run.

  One real automation-harness gotcha worth recording: cross-process
  `SetWindowText`/`WM_SETTEXT` sent from an external PowerShell verification
  script to the dialog's `EDIT` control reported success and even read
  back correctly via a cross-process `GetWindowText`, but never actually
  reached the control — confirmed by polling `GetWindowTextLengthW` from
  *inside* the dialog's own process, which saw it as empty the whole time.
  Real keystrokes (`SendKeys`) work correctly and are what a user's input
  actually looks like anyway; the dialog/gate code itself was never the
  bug. Not a T1 code change — a note for whoever automates this dialog
  next.
- **T2 — Chrome and edge cases. ✅ DONE.** Dark mode via the extracted
  `WindowsTheme.swift` (`resolveDarkMode`, `darkBackgroundHex`/
  `darkTextHex`, the `SystemUsesLightTheme` registry read, all pulled out
  of `SettingsWindow.swift`); cue banner; Return/Escape (intercepted on
  `WM_KEYDOWN` before `TranslateMessage`/`IsDialogMessageW`, since a
  single-line `EDIT` beeps on Return otherwise); Tab order across edit/
  Cancel/Start; work-area clamping via `SPI_GETWORKAREA`; the
  hidden-widget path (centers on the work area, relies on
  `SetForegroundWindow` since nothing of Pomoppi's is foreground then);
  the `isShowing` re-entrancy guard (`StartCoordinator.requestStart`
  checks it before ever calling `TaskPromptDialog.run`, so a second fast
  `startPause` press just re-focuses the existing prompt with no
  timer/task side effect); whitespace trimming (already correct from T1).
  Two real findings, not assumptions: `EM_SETCUEBANNER` needs `wParam=0`
  — the documented `fDrawFocused=1` form silently no-ops on this build;
  and `SetWindowTheme("DarkMode_Explorer")` has to run *before*
  `EM_SETCUEBANNER`, not after, or the `WM_THEMECHANGED` it posts resets
  the banner state. **Exit, all VM-verified with screenshots:** prompt
  background/text/edit/buttons match the settings window's dark mode;
  Return starts with no beep; Escape cancels; the `startPause` hotkey
  pressed twice in a row re-focuses one prompt instead of stacking two
  (`PomoppiTaskPromptClass` window count confirmed at exactly 1); a
  prompt raised while the widget is hidden appears centred on the work
  area with `GetForegroundWindow` matching the prompt's own `hwnd`; the
  widget keeps animating behind the modal (`GetMessageW`'s `nil` hwnd
  filter already covers this — the owner's `WM_TIMER` isn't gated on
  being enabled). **One piece not landed here:** `SettingsWindow.swift`
  itself switching to `WindowsTheme` (this phase's design also asked for
  that, "have both the dialog and `SettingsWindow` use it") — S4 landed
  concurrently in the same file and the two sets of edits were
  interleaved on disk in a way that wasn't safe to split into this
  commit. `SettingsWindow.swift` still carries its own private
  `darkBackgroundHex`/`darkTextHex`/`darkBackgroundBrush` and
  `resolveDarkMode()`; a follow-up should point it at `WindowsTheme`
  instead, now that S4 has settled.
- **T3 — Docs.** `SPEC.md` §5's "**Windows has no prompt at all**"
  paragraph and §0b's "Task-name prompt" ledger row both flip to the
  shipped behavior; `CLAUDE.md`'s Windows file map gains
  `StartCoordinator.swift`, `TaskPromptDialog.swift` and
  `WindowsTheme.swift`; `WINDOWS_PORT_PLAN.md`'s carried-forward
  task-name-prompt gap (its closing "What to do next", flagged since W3
  part 2) is marked closed with a pointer here. **Exit:** no document
  still describes Windows as prompt-less.

## Part C — the in-app Update button (S6a-S6f)

Today's update checker is notify-only: it finds a newer tag and opens the
GitHub release page in a browser (`SPEC.md` §15, "**passive and
notify-only** — it never downloads or installs anything"). Part C replaces
that with a button that downloads the right asset, checks it, installs it
and brings the app back.

`RELEASE_PLAN.md`'s rejection of Sparkle/WinSparkle **still stands and is
not reopened here**: no framework, no update server, no appcast, no silent
background auto-update, no separate helper binary to build and sign. What
this adds is a user-initiated download-and-run of an artifact the release
pipeline already produces — a different and much smaller thing.

### What the unsigned posture actually costs (read this before approving)

R2 (code signing) is deferred on both platforms, and that is not cosmetic
here. Four consequences, none of which this design papers over:

1. **The first self-update on macOS from any build shipped before S6b
   cannot be seamless.** `pkgbuild` lays the payload down as `root:wheel`
   — verified on this machine: `/Applications/Pomoppi.app` is
   `drwxr-xr-x root wheel`, inside a `/Applications` that is
   `drwxrwxr-x root admin`. An admin user can *rename* entries in
   `/Applications`, so the swap itself works, but cannot recursively
   delete a root-owned bundle afterwards. S6b fixes that going forward
   (a `chown` in the pkg's postinstall), which means: install 0.3.0 →
   the update to 0.4.0 goes through Installer.app with a password prompt
   → every update after that is seamless. That one-time step is real and
   worth telling the user about rather than discovering.
2. **The integrity check proves the bytes, not the author.** GitHub's
   releases API does expose a per-asset `digest` (verified live against
   the real API today — see S6a), so a truncated or corrupted download is
   catchable. But that digest arrives in the *same* HTTPS response as the
   download URL: it defends against a bad transfer, not against a
   compromised repo or account. Until R2, the trust root is exactly
   "TLS to api.github.com, plus that GitHub account's own security" — the
   same trust root the current notifier already has, except that the app
   now *runs* what comes back instead of handing it to a browser for the
   user to run. That escalation is small but real, and it is the
   strongest argument yet for un-deferring R2. Flagged, not hidden.
3. **macOS can never fully silently install a `.pkg`.** `installer -pkg`
   needs root; a background app cannot elevate without
   `AuthorizationExecuteWithPrivileges` (deprecated, and discouraged by
   Apple). The
   honest options are "replace the app bundle in place, which needs no
   elevation at all" or "hand the `.pkg` to Installer.app and let the OS
   ask for the password". This design does the first and falls back to
   the second — it never tries to fake the third.
4. **SmartScreen still flags the downloaded installer on Windows**, the
   same as a manual download. It does not block a `/VERYSILENT` run
   launched by an already-running local process, but this is unverified
   until S6d's VM run says so.

### Locked decisions (S6) — do not re-derive

- **Always user-initiated. No auto-download, no auto-install, no new
  settings field.** `checkForUpdates` stays the only knob in this area.
  The moment there is an "install updates automatically" toggle this is
  Sparkle with extra steps, and the whole reason R5/R6 were hand-rolled
  goes away. Checking stays background; downloading and installing never
  start without a click.
- **macOS installs by replacing the app bundle, not by running the
  `.pkg`.** The `.pkg` stays the first-install artifact and the fallback;
  a new `Pomoppi-<version>-mac.zip` asset is what the in-app path uses.
  This is the only path that delivers what was actually asked for (no
  password, automatic relaunch) — trade-off accepted: two install
  mechanisms now exist, so macOS's receipt database (`pkgutil
  --pkg-info`) reports a stale version after a self-update. Nothing reads
  it, and a later `.pkg` install still overwrites correctly.
- **Windows installs by running the existing Inno installer silently.**
  `Scripts/pomoppi.iss` already does per-user, no-UAC, auto-close-a-
  running-instance (`CloseApplications=yes`, R4-verified). Nothing about
  the installer's job changes; it gains exactly one `[Run]` line so a
  silent install relaunches the app.
- **The installer, not the app, owns the Windows relaunch.** The app is
  killed by RestartManager at a moment it does not control, so any
  "spawn a waiter that restarts me" scheme is a race by construction.
  Inno is already running, already knows when it finished, and already
  has a `[Run]` section.
- **`PomoppiCore` stays network-free.** It holds the pure parts — asset
  parsing/matching, SHA-256, the state enum — and nothing that opens a
  socket, exactly as `UpdateChecker.swift` was deliberately built with an
  injected `Fetch`. Each platform's own `UpdateInstaller.swift` owns its
  `URLSession` download. That duplicates ~40 lines of download plumbing
  and is the same call this port already made for tray clicks, picker
  previews and login items (CLAUDE.md's Windows invariant).
- **SHA-256 is hand-rolled into `PomoppiCore`, not CryptoKit + BCrypt.**
  One pure implementation both platforms share beats two platform crypto
  APIs, it matches `ZipWriter.swift`/`WAVFile.swift`'s from-scratch
  precedent, and it is a deterministic function with published NIST test
  vectors, so "is it correct" is answerable by a test rather than by
  trust. It is a hash, not a cipher — a bug fails an update, it does not
  open a hole.
- **Install state lives on `AppUpdateChecker`, never on the settings
  window.** Windows destroys the settings window on close; a download
  must survive closing and reopening it. The existing
  `@Published`/`onUpdate` plumbing already reaches both consumers (tray
  and footer) on both platforms, so the state rides along for free.
- **The footer is where updating happens.** Not a modal, not a new tab,
  not a separate window. It is already visible under every tab on both
  platforms and already owns every other update state. The tray item
  stops opening a browser and opens the settings window instead — one
  place owns the flow.

### Asset discovery (S6a)

`UpdateChecker.parseLatestRelease` (`Sources/PomoppiCore/UpdateChecker.swift:96-100`)
currently keeps only `tag_name`/`html_url`. It grows an `assets` array:

```swift
public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: URL   // browser_download_url
    public let size: Int          // bytes — drives a determinate progress bar
    public let sha256: String?    // from `digest`: "sha256:<hex>", nil when absent
}
```

Verified live against the real API today (`GET /repos/cli/cli/releases/latest`):
each asset carries `name`, `browser_download_url`, `size`, `state` and
**`digest`** (`sha256:f8bbc37f…`). `digest` is not documented as
guaranteed and is absent on assets uploaded before GitHub added it, so it
is optional here and the size check below is the floor.

Matching is prefix + suffix, case-insensitive, no version substring:

| Kind | Prefix | Suffix | Produced by |
|---|---|---|---|
| `.macAppZip` | `Pomoppi-` | `-mac.zip` | `Scripts/make-pkg.js` (new, S6b) |
| `.macPkg` | `Pomoppi-` | `.pkg` | `Scripts/make-pkg.js` |
| `.windowsSetup` | `Pomoppi-Setup-` | `.exe` | `Scripts/make-windows-app.js --installer` |

Deliberately **not** matched on the version inside the filename: the tag
already told us the version, and requiring the filename to agree would
break the first time a `v` prefix or a rename disagrees. Assets whose
`state` is not `"uploaded"` are skipped. CI uploads exactly one of each,
so a second match takes the first in API order.

`CheckResult` gains the asset:

```swift
case updateAvailable(tag: String, pageURL: URL, asset: ReleaseAsset?)
```

**`asset` being nil is normal, not an error.** `RELEASING.md` publishes
the release *first* and both workflows upload minutes later, so for that
window `/releases/latest` legitimately reports a newer tag with no assets
attached. The UI in that state is exactly today's behavior — "Update
available: `<tag>`" linking to the page — with no error and no broken
button. Every call site pattern-matching `.updateAvailable(let tag, _)`
(macOS `TrayController.swift:119`, `SettingsView.swift:134`; Windows
`TrayController.swift:322`, `SettingsWindow.swift:879`, `:903`) needs the
extra binding; that is the whole blast radius of the enum change.

### The state machine (shared vocabulary, `PomoppiCore`)

```
idle ─ check ─▶ checking ─▶ upToDate | checkFailed | updateAvailable
updateAvailable ─ [Update] ─▶ downloading(received, total)
                              ─▶ verifying ─▶ installing ─▶ relaunching ─▶ (process exits)
any step ─ failure ─▶ installFailed(reason) ─▶ [Try again] [Open release page]
```

Per-state UI, both platforms, in the footer:

| State | Footer reads | Controls |
|---|---|---|
| `updateAvailable` + asset | `Pomoppi 0.3.0 · Update available: v0.4.0` | **Update**, Release notes |
| `updateAvailable`, no asset | `Pomoppi 0.3.0 · Update available: v0.4.0` | Release notes *(today's behavior)* |
| `downloading` | `Downloading… 3.2 MB of 8.1 MB` | progress bar, Cancel |
| `verifying` | `Verifying…` | — |
| `installing` | `Installing…` | — |
| `relaunching` | `Restarting Pomoppi…` | — |
| `installFailed` | `Update failed — <one clause>` | Try again, Open release page |

Progress is determinate off the API's `size` field rather than
`Content-Length` (which GitHub's asset redirect may not carry);
`Content-Length`, when present, is only cross-checked. **If Windows'
`URLSessionDownloadDelegate` progress callbacks turn out not to fire
under `FoundationNetworking` (S6e spikes this), the Windows bar becomes
`PBS_MARQUEE` and the label drops the byte counts** — the design degrades
to indeterminate rather than losing the state.

Failure copy is one clause, never an error code: "couldn't download",
"the download didn't match its checksum", "couldn't install". Both
failure paths always offer **Open release page**, so the user is never
stuck with a dead button — that is the fallback requirement, satisfied
structurally rather than by a special case.

**One guard before installing:** if a session is running or paused
(`timer.getState().phase != .idle`), confirm first — "A focus session is
in progress. Pomoppi will close to finish updating." / Update now /
Cancel. An in-progress session is never logged (`SessionLogger` only
writes on phase completion), so quitting mid-focus silently loses it.
`NSAlert` on macOS, `MessageBoxW` on Windows — both are already the
idiom (`confirmEraseSessionLog`).

### macOS install path

1. Download `Pomoppi-<version>-mac.zip` into a same-volume scratch
   directory obtained from
   `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)`
   — Foundation's own API for exactly this, which removes any
   cross-device-rename guesswork.
2. Verify: byte count equals the API's `size` exactly, and SHA-256
   matches `digest` when present.
3. Extract with `ditto -x -k`, **not** `unzip` — the bundle is ad-hoc
   codesigned (confirmed: `Signature=adhoc`, `flags=0x2(adhoc)`) and
   `ditto` is what preserves the sealed resources and xattrs. Sanity-check
   the result with `codesign --verify` before going near the live bundle.
4. Swap: rename the existing bundle aside within its own parent
   directory, move the new one into place, then delete the old one. Try
   `FileManager.removeItem` first; on failure (the root-owned case above)
   `FileManager.trashItem`; if that fails too, leave it and say nothing —
   a stale bundle in the Trash is not worth an error dialog.
5. Relaunch: spawn `/bin/sh -c 'while kill -0 <pid> 2>/dev/null; do sleep 0.2; done; sleep 0.5; open -a "<path>"'`
   detached, then `NSApp.terminate(nil)`. `/bin/sh` is Apple-signed and
   always present, so this needs no helper binary of our own — the only
   reason to build one would be signing it, which R2 defers anyway.

**Why swapping a running app's bundle is safe here specifically:** every
sprite and sound is compiled into the binary
(`Sprites.generated.swift`, `Sounds.generated.swift`), and the only
bundle resources are the icon and `Info.plist`, both already loaded by
the time the window exists. The running process keeps its mapped
executable. **This is an invariant not to break** — the day someone adds
a lazily-loaded bundle resource, this assumption goes with it.

**Quarantine — spiked, not assumed.** A file downloaded with `URLSession`
from a loose binary on this machine gets **no `com.apple.quarantine`**,
only `com.apple.provenance` (which is not what Gatekeeper's
unidentified-developer block keys off). `Scripts/make-app.js`'s
`Info.plist` sets no `LSFileQuarantineEnabled`, so the app bundle should
behave the same. The remaining unknown is *inheritance*: a Pomoppi.app
that is itself quarantined may propagate it to what it writes. S6b
re-runs the spike from inside a real installed bundle and, if quarantine
does appear, the fix is one `xattr -d -r com.apple.quarantine` on our own
freshly-extracted copy before the swap.

**Fallback ladder, in order:** in-place swap → download the `.pkg` and
`NSWorkspace.shared.open` it (Installer.app's own GUI and password
prompt; the existing `postinstall` `pkill -x Pomoppi` still handles the
running instance) → open the release page.

### Windows install path

1. Download `Pomoppi-Setup-<version>.exe` to `%TEMP%` — never the install
   directory, which is about to be overwritten. Verify size + digest the
   same way.
2. `ShellExecuteW(nil, "open", path, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=\"%TEMP%\\Pomoppi-update.log\"", nil, SW_SHOWNORMAL)`.
   The log is not optional: a silent install has no UI, so it is the only
   way a failure is ever diagnosable. A return value ≤ 32 is a launch
   failure → fall back to the release page.
3. Hand off and do nothing else. RestartManager closes the app
   (`CloseApplications=yes`); the app's only job between step 2 and being
   killed is showing "Installing…".
4. Relaunch via one new line in `Scripts/pomoppi.iss`, leaving the
   existing interactive entry untouched:

   ```
   [Run]
   Filename: "{app}\{#MyAppExeName}"; Description: "Launch Pomoppi now"; Flags: nowait postinstall skipifsilent
   Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: WizardSilent
   ```

   Today's entry is `skipifsilent`, so a silent install deliberately
   launches nothing — which is correct for an admin deploying it and
   wrong for a self-update. Gating the second entry on `WizardSilent`
   keeps both behaviors without a custom command-line flag.

**Not every Windows install can self-update.** `Pomoppi-win.zip` is also
a shipped asset, and a copy running from an unzipped folder was never
installed by Inno — running the setup would install a *second* copy into
`%LOCALAPPDATA%\Programs\Pomoppi` and leave the original stale. Detect it
by comparing the running executable's directory against Inno's own
`InstallLocation` under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{EC3E39B4-1C22-4A15-A54C-769ACA07A1C8}_is1`;
on a mismatch, skip the in-app path and open the release page.

### Phases

- **S6a — Core: assets, matching, SHA-256, state enum. Shared, pure, no
  UI, no networking.** `Sources/PomoppiCore/UpdateChecker.swift` gains
  `ReleaseAsset`, assets decoding, `matchAsset(_:kind:)` and the third
  `CheckResult.updateAvailable` associated value; new
  `Sources/PomoppiCore/SHA256.swift`; new `UpdateInstallState` enum. Both
  platforms' pattern matches updated mechanically (5 sites, listed
  above). **Capture a real trimmed `/releases/latest` response with
  assets as a test fixture** rather than hand-writing the JSON — the
  field set is real data, not something to guess at. **Exit:** `swift
  test` green with new cases for an asset present / absent / wrong
  platform / `state != "uploaded"` / `digest` missing, plus SHA-256
  against the NIST vectors for `""` and `"abc"` **and** against
  `shasum -a 256` of a real file; `swift build` green on the Mac and in
  the VM (this is shared-target code, so a Windows compile error here is
  invisible on the host — CLAUDE.md's standing invariant). Nothing
  user-visible changes.
- **S6b — macOS packaging + the quarantine spike. No app code.**
  `Scripts/make-pkg.js` also emits `dist/Pomoppi-<version>-mac.zip` via
  `ditto -c -k --keepParent` from the same staged bundle it already
  builds (~6 lines); `.github/workflows/macos.yml` uploads it alongside
  the `.pkg`. `Scripts/pkg-scripts/postinstall` gains two things: a
  `chown -R <console uid>:staff` of the installed bundle so every future
  install is user-owned and swappable without elevation, and the
  `launchctl asuser <console uid> open -a /Applications/Pomoppi.app`
  auto-relaunch that R1 considered and dropped as unverified — **verify
  it now**, since it is what makes the `.pkg` fallback path relaunch too.
  **Exit:** a local `node Scripts/make-pkg.js` produces both artifacts;
  installing the `.pkg` over a running instance leaves
  `/Applications/Pomoppi.app` owned by the logged-in user (not
  `root:wheel`) and relaunches the app by itself; `ditto -x -k` of the
  zip yields a bundle that passes `codesign --verify`; and the
  quarantine spike re-run **from inside that installed bundle** reports
  whether `com.apple.quarantine` appears on a `URLSession` download
  (recorded in this file either way, since S6c's design depends on the
  answer).
- **S6c — macOS in-app update.** New
  `Sources/PomoppiApp/UpdateInstaller.swift` (download with progress,
  verify, extract, swap, relaunch), owned by `AppUpdateChecker` so the
  tray and footer both see its state through the plumbing that already
  exists. `SettingsView.swift`'s `UpdateFooter` (`:110-172`) grows the
  state table above; `TrayController.handleOpenUpdatePage` (`:246-249`)
  becomes "open the settings window" and must go through
  `AppDelegate.showSettingsWindow()` — **not** `sendAction`, CLAUDE.md's
  first invariant, and this is exactly the "third way to open Settings"
  it warns about. **Exit:** against a real pre-release cut for the
  purpose, clicking Update downloads with a moving determinate bar,
  verifies, swaps and relaunches into the new version with **no password
  prompt and no Installer.app**; `About`/footer shows the new version
  after relaunch; settings and `sessions.json` survive byte-identical;
  Cancel mid-download leaves the installed app untouched; a deliberately
  corrupted digest produces "the download didn't match its checksum"
  plus a working Open release page; a release with no `-mac.zip` asset
  falls back to the `.pkg` path and, failing that, the page; starting an
  update mid-focus-session shows the confirmation first.
- **S6d — Windows installer side. VM only, no app code.** The second
  `[Run]` line in `Scripts/pomoppi.iss`. **Exit**, all in the VM's
  interactive session (a plain SSH session cannot host the tray or
  foreground a window — `WINDOWS_PORT_PLAN.md`'s Phase W0 Task Scheduler
  `/it` workaround): with Pomoppi running, `Pomoppi-Setup-<new>.exe
  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=...` **completes with no
  visible UI and no prompt of any kind**, the log shows RestartManager
  closing the running instance, and Pomoppi comes back by itself on the
  new version; the same installer run interactively still shows the
  finish page with its "Launch Pomoppi now" checkbox exactly as before;
  settings under `%APPDATA%\Pomoppi` and the login-item registration both
  survive. **If `CloseApplications` turns out to prompt in silent mode,
  or `Check: WizardSilent` does not fire, stop and report** — both are
  assumptions this phase exists to test, and S6e is built on them.
- **S6e — Windows in-app update.** New
  `Sources/PomoppiWindows/UpdateInstaller.swift`; the footer
  (`SettingsWindow.swift:839-937`, `createFooter`/`repositionFooter`/
  `refreshUpdateFooter`) gains a hidden-by-default `msctls_progress32`
  child and a second contextual button, with `refreshUpdateFooter`
  staying the single show/hide/relayout point it already is — grow
  `footerHeight` (`:504`) from 28 to 34 only if one row genuinely cannot
  hold it. `TrayController.swift`'s `.openUpdatePage` (`:44`, `:155-157`,
  `:322-323`) opens the settings window via
  `window.onOpenSettingsRequested?()` instead of a browser. **Throttle
  progress notifications to ~10/second**: `AppUpdateChecker.onUpdate` is
  a single closure driving real `InvalidateRect` work on the message
  loop, and a per-chunk callback would hammer it. **Spike first, in the
  VM:** whether `URLSessionDownloadDelegate`'s `didWriteData` fires at
  all under `FoundationNetworking` — same shape of unknown R6b's
  transport spike already had, and the marquee fallback above depends on
  the answer. **Exit:** same list as S6c, in the VM's interactive
  session, plus: the download survives closing and reopening the settings
  window mid-flight (the reopened footer shows live progress, proving the
  state lives on `AppUpdateChecker` and not the window); a copy running
  from an unzipped `Pomoppi-win.zip` offers the release page instead of
  an in-app install; VM screenshots of the downloading and failed states.
- **S6f — Docs.** `SPEC.md` §15's "**passive and notify-only**"
  paragraph is now false and is rewritten in full — what gets downloaded,
  what is verified and what that verification does and does not prove
  (the point 2 above, in the spec's own words), the per-platform install
  and relaunch mechanics, and the explicit "no auto-install, ever, and no
  setting for it" contract. §0b's update-check parity row follows.
  `RELEASE_PLAN.md` gets a pointer here (it currently closes with "the
  update checker is passive"), and its R2 entry gains a line noting that
  in-app installation strengthens the case for signing.
  `RELEASING.md` gains the asset-upload race: an update-checking client
  can see a published release before its assets finish uploading, which
  is one more reason to cut a pre-release first. `CLAUDE.md`'s file map
  gains `SHA256.swift` and both `UpdateInstaller.swift`s. `README.md`'s
  install section notes that updating is in-app from here on. **Exit:**
  no document still describes the update checker as notify-only.

### Not in scope, deliberately

- **Delta/patch updates.** The downloads are ~2 MB on macOS and ~17 MB on
  Windows (measured against the 0.2.0 artifacts currently in `dist/`); a
  binary-diff format would be more machinery than the thing it saves.
- **A "skip this version" setting.** `RELEASE_PLAN.md` already locked "no
  persisted update state across launches," and nothing here needs it.
- **Rollback.** If a new version is bad, the release page has the old
  one. A rollback UI implies keeping the previous bundle around, which
  implies managing it.
- **Signing (R2).** Still deferred, still revisitable — see the four
  consequences above, which are the honest cost of that deferral and the
  one thing the user should weigh before approving Part C.

## What to do next

Build order across all three plans, with the dependencies that force it:

1. **S0** — doc-only, unblocks both this plan's copy work and
   `LOCALIZATION_PLAN.md`'s L0.
2. **S2 → S3 → S4 → S5** — in order. S3 builds the Windows
   settings-window rebuild that L4 reuses; S4's ask-for-task hint
   describes behavior Part B is about to give Windows.
3. **T1 → T2 → T3** — can run in parallel with S4/S5 if two agents are
   working (disjoint files: T touches `WidgetInput.swift`, `main.swift`
   and new files; S4/S5 touch `SettingsWindow.swift`/`SettingsView.swift`),
   but must finish before `LOCALIZATION_PLAN.md`'s L0 — the prompt adds
   user-facing strings that the extraction sweep has to see.
4. **S6a → (S6b → S6c) ‖ (S6d → S6e) → S6f** — after S5, because S3
   builds the Windows `SettingsWindow.rebuild()` that has to know about
   the footer's new children, and S4 is the last phase to churn that
   file. S6a is shared-core and gates everything else in Part C; the two
   platform legs are independent of each other after it and can run in
   parallel (disjoint files, one agent each), but **each platform's
   packaging phase must land before its app phase** — S6c cannot be
   verified without S6b's zip asset existing, and S6e is built on
   assumptions only S6d's VM run can confirm. Like Part B, all of it must
   finish before `LOCALIZATION_PLAN.md`'s L0: Part C adds a whole state
   machine's worth of user-facing strings.
5. **L0 → L5** — see `LOCALIZATION_PLAN.md`.

Part A plus Part B is a coherent release on its own, and Part C wants a
real release to exist before it can be verified end to end (S6c/S6e both
test against an actual published pre-release) — so **cut the first
release after Part B**, per `RELEASING.md`, and build Part C against it.
Localization is purely additive on top of all three and can slip to the
release after without leaving anything half-built.
