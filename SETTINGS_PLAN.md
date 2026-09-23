# Pomoppi settings overhaul + Windows task prompt — plan and status

This file is a self-contained handoff for the settings-window overhaul, in
the same spirit as `WINDOWS_PORT_PLAN.md` and `RELEASE_PLAN.md`. Read this
first for *why* things are the shape they are; `SPEC.md` §7 is the behavior
contract for the settings schema and window layout, §5 for the task-name
prompt.

It has two parts:

- **Part A (S0-S5)** — the settings window itself: tab map, copy, the
  regrouped General tab, the reset that doesn't actually reset, hint
  footers, Diary terminology.
- **Part B (T1-T3)** — the Windows task-name prompt. Part A makes
  `askForTaskName` visible and honest on Windows; Part B builds the thing
  it actually toggles, which has never existed there (`SPEC.md` §0b's
  parity ledger: "**None.** `startPause` starts the timer directly").

**Status as of 2026-09-23: S0 and S1 are done (S1 in commit `b092865`,
shipped in the `1dcf97e` 0.3.0 bump); S2-S5 and T1-T3 are not started.**
`LOCALIZATION_PLAN.md` depends on this file: S0 locks the copy, and
nothing in L0's string-extraction sweep should run against labels this
plan is still about to rename.

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
- **S3 — Make "Reset Pomoppi…" actually reset.** Today both platforms
  delete the storage directory and tell the user to restart
  (`SettingsViewModel.swift:41`, `SettingsWindow.swift:2560`). The
  running app keeps its in-memory `PomoppiSettings`, so the next write of
  *any* setting re-persists the old values over the fresh directory, and
  the next completed phase recreates `sessions.json` — a reset that
  silently un-resets itself if the user touches one more control.
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
- **S4 — Hint footers.** macOS already has `Form`'s `footer:`; this is
  mostly a Windows mechanism plus the copy from the map above on both
  sides.
  - Windows: add `addHint(_:in:x:y:width:trackForScroll:)` next to
    `addLabel` (`SettingsWindow.swift:3085`) — a `STATIC` with
    `SS_NOPREFIX` (mandatory: a bare `&` is eaten as a mnemonic, the bug
    W7 already hit), a second `HFONT` one point smaller than the default
    GUI font, and dimmed text.
  - The dimming is the fiddly part: `handleCtlColor` (`:3556`) is
    **dark-mode-only and HWND-blind** — it returns early to
    `DefWindowProcW` whenever `isDarkMode` is false, and otherwise paints
    every `STATIC` the same color. Hints need it to (a) run in light mode
    too and (b) branch per control, so it grows a `hintLabels` HWND set
    and two text colors (dimmed light / dimmed dark), returning the
    matching background brush in each of the four combinations. Get this
    right once here; every later hint is then free.
  - Appearance-page hints must pass `trackForScroll: true` or they stay
    put while the rest of the page scrolls.
  - Live hints: `reverseTrayClick`'s (already live on macOS, new on
    Windows) and `askForTaskName`'s both re-render on the *other*
    control's change — on Windows that is `setWindowText` +
    `InvalidateRect` from the owning checkbox's toggle handler, plus a
    refresh when the Diary tab's logging toggle changes (it is what
    overrides `askForTaskName`).
  - The `askForTaskName` hint is the point of this phase: with default
    settings (`loggingEnabled: true`, `askForTaskName: true`) the toggle
    is inert — logging forces the prompt and makes cancelling refuse to
    start (`SPEC.md` §5). That override is currently invisible on macOS
    and doesn't exist at all on Windows until Part B.
  - **Exit:** every hint in the map renders on both platforms; toggling
    session logging on the Diary tab visibly changes the Rhythm tab's
    ask-for-task hint; no hint clips or overlaps at the default window
    size; VM screenshots of Rhythm and General.
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

- **T1 — The dialog and the gate.** Both new files, the one-line call-site
  change in `WidgetInput.swift`, light mode only, centred on the owner.
  **Exit**, all five checked in the VM's interactive session (Task
  Scheduler `/it` — a plain SSH session can't foreground a window, same
  Session 0 rule as the tray and hotkeys):
  1. logging off + ask off → no prompt, timer starts (today's behavior,
     unregressed);
  2. logging off + ask on → prompt; Start with "writing docs" → timer
     runs, and `%APPDATA%\Pomoppi\sessions.json` carries
     `"task": "writing docs"` after skipping the phase (the widget never
     draws the task, so the log is the only readback);
  3. logging off + ask on + Cancel → timer starts, `task` empty;
  4. logging **on** + ask **off** → prompt appears anyway; Cancel → timer
     stays idle, nothing logged;
  5. starting a break, and resuming a paused focus → no prompt either
     time.
- **T2 — Chrome and edge cases.** Dark mode via the extracted
  `WindowsTheme.swift`; cue banner; Return/Escape; Tab order; focus
  landing in the edit field; work-area clamping; the hidden-widget path;
  the `isShowing` re-entrancy guard; whitespace trimming. **Exit:**
  prompt matches the settings window's dark mode; Return starts with no
  beep; Escape cancels; the `startPause` hotkey pressed twice in a row
  re-focuses one prompt instead of stacking two; a prompt raised while
  the widget is hidden appears centred and focused; the widget keeps
  animating behind the modal (the nested loop still pumps its ~60fps
  `WM_TIMER`).
- **T3 — Docs.** `SPEC.md` §5's "**Windows has no prompt at all**"
  paragraph and §0b's "Task-name prompt" ledger row both flip to the
  shipped behavior; `CLAUDE.md`'s Windows file map gains
  `StartCoordinator.swift`, `TaskPromptDialog.swift` and
  `WindowsTheme.swift`; `WINDOWS_PORT_PLAN.md`'s carried-forward
  task-name-prompt gap (its closing "What to do next", flagged since W3
  part 2) is marked closed with a pointer here. **Exit:** no document
  still describes Windows as prompt-less.

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
4. **L0 → L5** — see `LOCALIZATION_PLAN.md`.

Part A plus Part B is a coherent release on its own; localization is
purely additive on top and can slip to the release after without leaving
anything half-built.
