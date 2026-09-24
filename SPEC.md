# Pomoppi — Build Spec

A very small kawaii pixel pomodoro widget for macOS. Electron. Black on white,
predominantly white. Everything on the widget is drawn as pixels on a canvas.

Authoritative. If code and spec disagree, the spec wins. Do not invent files,
dependencies, or features that are not listed here. **Zero runtime dependencies** —
Electron only. No npm packages at runtime.

This spec was originally written for, and implemented by, an Electron app;
that implementation has since been retired (its history is still in git, on
the branches that predate the rewrite). The **from-scratch Swift/AppKit
rewrite** that now lives at the repo root (see `CLAUDE.md`) is the sole
implementation and treats this document as its **behavior** contract —
window layering, art direction, shortcuts, settings schema, and so on. Some
sections still describe Electron-specific mechanics (IPC, `contextBridge`,
npm packaging) and bare file paths (`main.js`, `lib/`, `renderer/`,
`tools/`, `import/`) left over from that implementation; read those for the
intent, not the literal API or path — the current app has no Electron and no
npm runtime dependency.

---

## 0a. Platform scope tags

Pomoppi is being ported to also run on Windows (see `WINDOWS_PORT_PLAN.md`
at the repo root for the phase plan). Sections below get one of these tags,
placed right after the heading:

- **`[macOS]`** — macOS-only contract, no Windows equivalent (yet or ever).
- **`[windows]`** — Windows-only contract, no macOS equivalent.
- **`[divergent]`** — both platforms implement this, but the behavior
  differs; read the section for which platform is which.
- **`[legacy]`** — Electron-era mechanics kept for historical intent only,
  not literally implemented by either the macOS or Windows app.
- Untagged — **`[both]`**, identical contract on macOS and Windows.

**Tagging is complete as of Phase W9 (2026-09-19)** — every `##`/`###`
heading below carries its tag, and the parity ledger reflects real shipped
behavior on both platforms, not a plan. Where a tag or ledger row
describes a gap (Windows has no task-name prompt, no virtual-desktop
visibility, etc.), that's a genuine, known gap surfaced by this pass, not
something to silently "fix" as part of a future edit — check
`WINDOWS_PORT_PLAN.md` for whether any phase already owns it before
touching one.

## 0b. Parity ledger

One row per behavior that is known to diverge between the two platforms.
As of the 2026-09-19 session-log redesign, every remaining known gap is
listed here — every row reflects real, shipped behavior on both sides,
not a plan.

| Behavior | macOS | Windows |
|---|---|---|
| Tray click mapping | Left-click raises the widget, right-click opens the menu (§9), the standard convention as of Phase W2b — a `reverseTrayClick` toggle restores the original left=menu/right=raise mapping | Same convention, same `reverseTrayClick` setting, read at click time (Phase W4) |
| Tray clock | `tray.setTitle`, live `mm:ss` text next to the menu-bar icon, monospaced digits (§9) | No text slot in the notification area — the live `mm:ss` moves to a hover tooltip instead (Phase W4) |
| Settings chrome | SwiftUI `Settings` scene, standard titled, resizable window, native tab control, 6 tabs: General/Rhythm/Appearance/Keys/Sound/Diary (`SETTINGS_PLAN.md` S2) | `SysTabControl32` in a titled, user-resizable (`WS_THICKFRAME`) window: fixed minimum width 560, free height down to 240 (opens at 680, clamped to the screen) since every page scrolls with a native `WS_VSCROLL` bar; bold section headers and one shared label/control column standing in for `Form`'s grouped sections; same 6 tabs in the same order, same `SettingsStore`/validation — not a pixel match (Phase W6/W7) |
| Shortcut display text | Glyphs via `Shortcuts.display()`, e.g. `Alt+Shift+P` → `⌥⇧P` | Plain text via `Shortcuts.displayWindows()`, e.g. `Alt+Shift+P` (unchanged — Windows' own accelerator strings are already this shape) (Phase W5) |
| Storage path | Real bundle: `~/Library/Application Support/Pomoppi/settings.json`; loose dev binary: `.dev-app-support/settings.json` (see `AppDelegate.storageDir()`) | `%APPDATA%\Pomoppi\settings.json`, via `SHGetKnownFolderPath(FOLDERID_RoamingAppData)` (`AppStorage.swift`, Phase W3) |
| Launch-at-login mechanism | `SMAppService.mainApp` (macOS 13+), only meaningful from a real installed `.app` bundle (see `LoginItem.swift`) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` registry value (`LoginItem.swift`, Phase W5) |
| Task-name prompt | `NSAlert` via `StartCoordinator.swift`, on when `askForTaskName` or forced by `loggingEnabled` (§5) | Win32 modal via `TaskPromptDialog.swift`, same gate and behavior — part of the settings overhaul's Part B (see `SETTINGS_PLAN.md` T1–T3) |
| Chime playback | `AVAudioPlayer(data:)` (`ChimePlayer.swift`), one persistent player per pack+sound, built from `GeneratedSounds` via `WAVFile` (§4) | Direct `waveOut` (`ChimePlayer.swift`), one `WAVEFORMATEX` device opened for the process's life and one reused `WAVEHDR`, the raw PCM held in a never-freed buffer per pack+sound (§4) |
| SVG snapshot | **None.** Dropped in the native rewrite; the `snapshot` shortcut exists in `Shortcuts.swift` but has no handler (§14) | Same — the shortcut ID exists but is deliberately never registered (`main.swift`) |
| Virtual-desktop/Spaces visibility | `collectionBehavior = [.canJoinAllSpaces]` — the widget follows you across every Space (§9b, R2) | **Not implemented.** No equivalent call exists in `WidgetWindow.swift` — the widget is visible only on whichever virtual desktop it was created on. A real, undocumented-until-now gap; no phase has claimed it |
| Update check UI | A tray item ("Update available: `<tag>`", opens the release page) shown only when one exists, plus a version + "Check for Updates" button + status line inline in the General tab's Updates section, cycling idle/checking/up-to-date/update-available/failed (§15) | Same tray item via `TrayController.swift`; the General tab's Updates row is a plain child of that page (no separate footer strip) with the same five states, driven by a `WM_TIMER`-based auto-revert instead of SwiftUI state. Behavior (endpoint, cadence, states, opt-out) is identical on both — only the chrome differs, Win32 vs AppKit/SwiftUI rendering (§15) |

## 1. Art direction (non-negotiable) `[divergent]`

Palette/theming/pixel-art rules below are `[both]` — shared verbatim via
`PixelCanvas`/`GeneratedSprites`. The one real divergence: **the tray icon's
tinting mechanism.** macOS gets it for free (a template `NSImage`, tinted by
the system to match the menu bar — the note below). Windows has no such
mechanism, so `TrayController.swift` reads `SystemUsesLightTheme` from the
registry itself (re-checked every 500ms alongside its normal refresh) and
draws the icon black-on-light / white-on-dark by hand (a follow-up fix after
Phase W4, not part of W4 itself).

- Palette, and nothing else — **two colours**, `settings.inkColor` and
  `settings.paperColor`:
  - `--ink` — `#000000` by default
  - `--paper` — `#FFFFFF` by default
  - `--blush` — *derived*, ink mixed `55/255` into paper (`#C8C8C8` at the defaults)
  - `--mute` — *derived*, ink mixed `145/255` into paper (`#6E6E6E` at the defaults)
- The two greys are **mixed from the pair at render time, never stored**, so a
  theme can never be half-applied. Only the pair is persisted.
- Nothing anywhere hardcodes black or white. Every window — widget, settings,
  task prompt — reads the pair and paints from it; the settings and task pages
  set `--ink`/`--paper` on `:root` through the CSSOM (`style.setProperty`,
  which `style-src 'self'` permits — it is not an inline style attribute) and
  every rule is written against the tokens. The tray icon is exempt: it is a
  macOS **template image**, tinted by the system to match the menu bar.
- Ink and paper are never allowed to be equal — that would render a blank,
  unclickable widget — so the pair falls back to black-on-white if they match.
- Predominantly **paper**. Ink is for outlines, digits, and fills.
- Hard pixel edges everywhere: `image-rendering: pixelated`, never a blur,
  never a shadow, never a gradient, never a rounded corner smaller than the
  pixel grid, never an emoji as UI.
- The friends, digits and icons come from `renderer/sprites.js`. That file is
  **read-only art data** — consume it, never edit it, never restyle it.
- The pets are **the author's own Aseprite drawings**, imported verbatim by
  `tools/import-friends.js` into `renderer/friends.js`. Nothing generates, poses or
  retouches them. They are 32x32 line art: `'#'` ink, `'.'` clear, drawn
  facing left natively (relevant to `settings.petMovement`, §3).
- **Nothing synthesises, poses or retouches a pet.** Whatever the author drew
  is exactly what is drawn. A derived blink (flood-filling the enclosed paper
  in a face to "shut" the eyes) was tried and removed: it filled Onanippi's
  eyes with solid ink for 130ms at a time and read as a rendering fault, not as
  a blink. If a pet is to blink, the blink is a frame they drew.
- Pets carry **animation frames, not expressions**. Get one with
  `SPRITES.frame(friendId, frameIndex)` (wraps, and falls back safely on an
  unknown id); `SPRITES.frameCount(id)` says how many. A pet the author drew
  only once is given a derived squash frame so it can breathe —
  `SPRITES.FRIENDS[id].drawn` reports how many frames are genuinely theirs.
- `SPRITES.FRIEND_IDS` is display order; `SPRITES.FRIENDS[id].name` is the label.

## 2. Windows `[legacy]`

This table is the original Electron `BrowserWindow` config and is stale
against both native apps' actual numbers — kept for the *intent* (frameless/
transparent widget, single-instance settings and task UI), not the literal
sizes:

- **Widget**: logical canvas is `WidgetLayout.canvasWidth`/`canvasHeight` =
  118x132 (§3's own heading says 118x138 — also stale; code wins), scaled by
  `settings.scale` — 236x264 at the default 2×. Identical on both platforms,
  since both draw through the same shared `PixelCanvas`/`WidgetLayout`.
  Frameless/transparent/always-on-top/undraggable-from-taskbar all hold on
  both, achieved with platform-native mechanisms: `NSWindow`
  (`.borderless`, transparent, floating level) on macOS, `WS_POPUP |
  WS_EX_LAYERED | WS_EX_TOOLWINDOW` + `UpdateLayeredWindow` on Windows — not
  Electron's `frame`/`transparent`/`hasShadow` booleans, which no longer
  exist anywhere in this codebase.
- **Settings**: macOS is a resizable SwiftUI `Settings` scene
  (`minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 560`).
  Windows is a fixed, non-resizable `560x480` titled window
  (`SettingsWindow.clientWidth`/`clientHeight`). Both are single-instance,
  neither matches this table's `460x620`.
- **Task ("what are you working on?") prompt**: macOS implements this as a
  plain `NSAlert` (`StartCoordinator.swift`), not a custom frameless window
  — this table's `300x120` describes a window that no longer exists even on
  macOS. **Windows has no task-name prompt at all** — `startPause` starts
  the timer directly, a known, explicitly-flagged gap (see
  `WINDOWS_PORT_PLAN.md`'s W3/W5 notes) rather than a silent omission.

The widget must be a genuinely transparent window: macOS draws a rounded
rectangle behind an opaque frameless window, and the whole point of the pixel
frame in section 3 is that Pomoppi has its own hard-cornered outline. So:
`transparent: true`, `frame: false`, `hasShadow: false`, `backgroundColor:
'#00000000'`, and the page body stays transparent.

The widget canvas is **118 x 138 logical pixels** scaled by `settings.scale`
(default 2) -> 236 x 276. All layout below is in *logical* pixels. When `scale`
changes, the window resizes to `118 * scale` x `138 * scale`.

**The width stays even.** Every fixed-width piece of the layout is even —
frame 110, progress bar 68, button row 64, clock 38, pet 32 — so an even canvas
puts all of them exactly on the axis (x = 58.5, the seam between px 58 and 59).
An odd canvas would move the axis onto a pixel and knock all five half a pixel
off to rescue only the odd dot counts. Centre horizontally through one helper,
`centreX(w) = Math.floor((CANVAS_W - w) / 2)`, so an odd width always leans the
same way; never hand-tune a centred x.

The outer 4px on every side is a transparent margin. macOS clips a window's
corners with a squircle, which was shaving the corners off the drawn frame; the
margin keeps the frame inside the rounded region.

## 3. Widget layout (118 x 138 logical) `[both]`

Every rule below (frame geometry, hit-testing, roommate wandering) is
shared `PomoppiRender`/`PomoppiCore` code (`WidgetLayout`, `WindowFrame`,
`WidgetAnimationController`), used identically by both platforms'
input-handling files (`WidgetPixelView.swift` / `WidgetInput.swift` — the
latter explicitly ports the former's hit-testing verbatim). The "Dragging"
subsection's `pointerdown`/`setPointerCapture` references are Electron/
browser API names with no native equivalent (macOS uses AppKit
`mouseDown`/`mouseDragged`; Windows uses `WM_LBUTTONDOWN` + `SetCapture`) —
per this file's own preamble, read that subsection for the *contract* (the
&lt;3px click-vs-drag threshold), not the literal API.

Everything is 1 logical pixel thick. Nothing is drawn thicker except deliberate
solid fills (progress bar, filled cycle dots).

### The frame
Momo-style rectangles are out: the edge wobbles so the widget sits on the
desktop like a sticker. Do not compute it — call

```js
SPRITES.windowFrame(settings.frameStyle, 110, 130)
```

and draw the returned 110x130 grid **at offset (4, 4)**: `'#'` ink, `'w'` paper,
`'.'` left transparent. Styles are in `SPRITES.FRAME_STYLES` — `ziggy`, `scallopy` (rounded bumps,
default), `splotchy` and `wavey`. Render whatever is in that array; never assume how many there are.

The outline is a **rounded rectangle** (`FRAME_RADIUS`), and the motif is
parameterised by arc length along it, so the pattern wraps the corners instead
of being clipped at them. Inside/outside is decided analytically per pixel
rather than by tracing and flood-filling: a ragged style can cross itself, and a
self-crossing ring has no well-defined interior.

```
pet 32x32      centred, y=23   (this is a hit region)
time 7x11 @1x  centred (38 wide), y=62   (display only, not clickable)
clock steppers 5x5 - and +, y=65, x=25 / x=88 (idle only, flush with the bar)
cycle dots     y=78, 5x5 solid done / 5x5 ring pending, 2px gap, centred
progress bar   x=25, y=88, w=68, h=7, 1px ink border, fills as time is spent
buttons 13x13  y=100, at x=25, 43, 62, 80 (row box = the bar's, 25..92)
```

Only the **clock** carries `-`/`+` steppers. The dot row had a pair too and
lost them: the dots are click-to-set on their own, and the steppers put two
invisible hit regions on the ends of the row.

- Four buttons, left to right: `reset`, `play`/`pause`, `skip`, **heart**
  (settings). Reset and skip are separate buttons rather than one slot that
  swapped icon by phase — skip now ends whatever is running in either
  direction, so it has no reason to hide during focus.
- **`ICON_SIZE` is 13: an icon cell *is* a button box.** Icons draw at the box
  origin with no offset — there is no inset to keep in sync, and the editor
  grid is the thing that actually ships. Icons were 16x16 drawn at `box - 2`;
  that was a fudge and it is gone.
- Icon ink must stay within **cols/rows 1..11** — at most 11 wide and 11 tall.
  Row/col 0 and 12 are where the hover border draws and where the press
  inversion ends, so ink out there reads as merged with the box. The art as
  drawn sits at rows 2..10 and is 7-10 wide.
- **The row's bounding box is the progress bar's** — same x, same width — so the
  two read as one column. Four 13px boxes leave 16px of gap across 3 slots,
  which does not divide evenly, so do not fix a gap width: derive the positions
  by rounding the *running* offset,
  `x = BUTTON_ROW_X + i * BUTTON_SIZE + Math.round(i * slack / gaps)`. That puts
  every box on a whole pixel, pins the last one to the bar's right edge exactly,
  and spreads the remainder across the row rather than piling it at one end —
  here 5, 6, 5, symmetric about the axis. A fixed gap cannot hit both edges.
- The 13px box is odd so it has a true centre pixel, and the row is 68 wide, so
  the row still lands on the axis. The narrowest gap (5) still clears the
  2px-grown hit boxes.
- Hit-testing: `logical = Math.floor(clientPx / scale)`, boxes grown 2px.
- Hover: 1px ink border. Press: invert the box. **This applies to the two clock
  steppers too**, not only the bottom buttons: their box is 7x7 around the 5x5
  glyph.

### Direct manipulation
The widget is operated, not just watched:

| Region | Action |
|---|---|
| the pet | drag surface, see below — no click action |
| cycle dot *n* | `setLongBreakEvery(n + 1)`, clamped 2..10 |
| clock - / + | `setFocusDuration(+/- 60s)`, clamped 60..5400 — stepped off `settings.focusMinutes`, never off the displayed `remainingMs` |

The clock steppers are drawn whenever the timer is idle, not only on hover;
hover adds the 1px box like any other control. The time itself is not clickable.

**Roommate wandering** (Appearance tab in native; was the `settings.petMovement`
toggle in the archived Electron app — native has no such toggle anymore, this
is just how it behaves). While a focus session is actually running, the
roommate ambles instead of sitting at its centred rest position — mechanically,
not eased: it only moves when the friend's own sprite frame changes
(`friendFrameIndex()`), stepping `WANDER_STEP_PX` sideways and, each time,
setting `WANDER_STEP_HEIGHT_PX` up/down to whichever the *current pose index's
parity* says (even = up, odd = down) — not a flag that toggles once per step
independent of the frame, since the animation clock keeps running even while
not wandering (idle/paused/break) and a toggle would drift out of sync with
whatever pose is actually on screen by the time wandering resumes. Deriving it
from the pose index directly is self-correcting, so frame 0 of the walk cycle
always reads as "up" no matter how long a gap preceded it — the way an old
Tamagotchi's few-pixel walk cycle steps in lockstep with its pose changes
rather than sliding smoothly. Bounded to the progress bar's own x-span, inset
by `WANDER_EDGE_INSET` px on each side (5 by default — the one number to
change how close to the bar's own edges it gets), reversing direction at
either end. Friend art is drawn facing left natively (§1), so the sprite
mirrors left-right while walking right only — a plain string-reverse per row,
not a canvas transform — so it always visually faces the way it's walking.
Wandering only happens while `running` is true, and **a break is deliberately
exempt even while running**: `petPosition()` holds the pet at its centred rest
position for the whole break, cycling only its drowsy frames on the spot, same
as the widget always looked before wandering existed — asleep is not a time to
be pacing. **Idle holds it at rest** (no session has ever started, or one was
just reset — there's no "where it was" to return to). **Pausing, and a break,
freeze it exactly where it is instead**: the wander position/direction/
step-phase are untouched while `running` is false or the phase is a break, so
resuming — unpausing, or a break ending back into focus — continues the walk
from right there rather than snapping back to the start. The pet's hit region
(hover, drag-arm, §"Direct manipulation" above) tracks wherever it currently
is, not its rest position. **Pausing during a break freezes the Zzz's too** —
`zFrameIndex` only advances while `running`, so a paused nap holds on whichever
Zzz frame it was on rather than continuing to animate in the background.

### Dragging
Bind **pointer events only**. Registering mouse listeners as well double-fires
every press, because a real mouse emits `pointerdown` *and* `mousedown` for one
click. Use `e.screenX/screenY` for drag deltas — `clientX` is window-relative,
so the window chases itself and oscillates. Guard `setPointerCapture` in a
try/catch; it throws for a pointer id the browser no longer considers active.

**The pet is draggable too.** It is a 32x32 slab in the middle of a 118x138
widget, so excluding it left almost nothing to grab. A press on the pet arms
the drag like any empty pixel does; the 3px rule below is what still tells the
two apart, so press-and-drag moves the window and press-and-release is a
no-op — the pet used to cycle `friend` on release, and that was removed; pick
the pet in the settings window's Appearance tab instead (§7). Every other hit
region (steppers, dots, buttons) still blocks the drag.

There is **no overlay div above the canvas** — one would swallow the clicks the
hit regions need, and `-webkit-app-region: drag` cannot coexist with a surface
this interactive. Drag manually: on `mousedown` outside every hit region record
`screenX/screenY`, on `mousemove` call `moveBy(dx, dy)` with the delta since the
last move, end on `mouseup`. A pointer that moved 3px or more is a drag, never
a click.

## 4. Animation `[both]`

The state machine below (timing table, shake, ring-inversion, the Zzz
cycle) is shared `WidgetAnimationController`/`WidgetLayout` code, ticked
identically by both platforms' own ~60fps render loops. The "Chime"
subsection below is `[both]` too as of the 2026-09-21 session: real chime
playback exists on both platforms now (`ChimePlayer.swift`, one per
platform — `AVAudioPlayer(data:)` on macOS, direct `waveOut` on Windows),
not just the `soundEnabled`/`ringSeconds` settings.

Single `requestAnimationFrame` loop. Redraw only when something changed
(dirty flag) or an animation is active; when idle and paused, stop the loop.

| State | Frame | Pace |
|---|---|---|
| idle (never started) | cycling | 700ms — breathing |
| focus running | cycling | 450ms — working beat |
| focus paused | frame 0 | still |
| break running | cycling | **1400ms — drowsy** |
| break paused | frame 0 | still |
| ringing | cycling | 150ms — fluttering, plus shake |

**No blinking, and no synthesised frames of any kind** — see section 1. The
animation is the author's imported frames and nothing else.

**The z.** During a break, cycle `SPRITES.ZZZ_FRAMES` — `{ grid, dx, dy }` — at
about 500ms, anchored near (79, `FRIEND_Y + 7`), so it rises and drifts off.
A static z reads as a bug.

Motion comes from the frames themselves; there is no separate bob, which would
only add jitter on top of a sprite that is already moving.

- **shake**: sprite x offset cycles `-1,0,1,0` every 80ms.
- **ringing** also inverts the whole canvas (ink background, paper foreground)
  every 300ms, and plays the chime. Ringing lasts `settings.ringSeconds`
  (default 5) or until any button is pressed.

**Ringing holds the phase, not just the animation.** The state machine's own
`phase` stays on whichever phase just finished for the whole time it's
ringing — the switch to the next phase (and any `autoStartBreaks`/
`autoStartFocus`) is deferred until the ring is actually silenced, whether
that's the `ringSeconds` timeout or the user interacting early. Flipping
`phase` the instant the phase completes (which is what the ring's timing
alone would suggest) would start the next phase's break/Zzz animation
directly on top of the still-playing shake+ring — the two are never meant to
overlap; the ring finishes, then the break (and its Zzz) begins.

### Chime `[both]`
Plays **once**, at the moment a phase completes and the ring starts (the
`!ringing -> ringing` transition, `PomodoroTimer.completePhase()`) — the
focus-end sound when a focus phase just ended, the break-end sound when a
break just ended — only if `settings.soundEnabled`. This is exactly what
the retired Electron app did (`playChime(descending)` on that same
transition); a skip/reset that cuts a phase short never rings and never
chimes, since `PhaseCompleteEvent.completed` is only `true` on the natural
completion path. `ringSeconds` governs the visual ring only, never audio.

Four packs, selected by `settings.chime` (`PomoppiSettings.chimeIDs`:
`"classic"`/`"chord"`/`"jingle"`/`"soft"`) — synthesized, not recorded:
`Sounds/tools/synthesize-chimes.js` writes each pack's
`focus-end.wav`/`break-end.wav` under `Sounds/import/chimes/<id>/`
(16-bit mono 44100Hz), and `node refresh-sounds` re-imports them into
`Sources/PomoppiSprites/Sounds.generated.swift` (raw PCM bytes,
`GeneratedSounds.chimes[id].focusEnd`/`.breakEnd`) and syncs `chimeIDs` in
`Sources/PomoppiCore/Settings.swift` (`classic` first, the rest
alphabetical). `classic` is three square-wave blips (~90ms each,
880/1174/1568 Hz ascending, gain 0.06, break-end descending) — the
original Electron-era design, kept byte-for-byte. `chord` is two stacked
major-triad square-wave chords (~170ms each, C6 then G6 major, break-end
reversed) — polyphonic in the chiptune sense, several square-wave voices
summed and clamped rather than one voice at a time. `jingle` is a fast
square-wave arpeggio (C5 through G6) over a sustained bass note, ending on
a held chord, break-end the arpeggio descending with the held chord an
octave lower. `soft` is `classic`'s same three notes as gentler sine
tones — the one non-beeping pack, for anyone who wants something softer
than the three chiptune packs above.

On macOS, `GeneratedSounds`' raw PCM is wrapped into a WAV image at
playback time via `WAVFile.data(pcm:sampleRate:bitsPerSample:channels:)`
(`PomoppiCore/WAVFile.swift`, a 44-byte RIFF/WAVE header prepended to the
raw PCM) and played with a persistent, cached `AVAudioPlayer(data:)` per
pack+sound (`stop()`/`currentTime = 0`/`play()` on replay; the player last
started is tracked and stopped before a new one plays, so switching packs
quickly can't layer two chimes on top of each other). On Windows, the same
raw PCM is played directly with `waveOut` against a single `WAVEFORMATEX`
opened once for the process's life — no WAV header involved, since
`waveOut` already knows the format out of band, and only one `WAVEHDR` is
ever outstanding so a new play always cuts the previous one off. See
`ChimePlayer.swift`, one per platform. The Sound tab's Chime picker
(Rhythm-style segmented control on macOS, individually-clickable
segmented buttons on Windows, both built from `chimeIDs`) plays the
selected pack's focus-end sound immediately on selection — "tap it, hear
it" — regardless of `soundEnabled`, since this is a preview, not the real
end-of-phase chime. No separate Play/replay button on either platform:
Windows' picker is individual buttons that fire on every click, including
a reselect of the already-selected option, so it always replays; macOS's
segmented `Picker` doesn't fire its selection binding on a reselect, so
re-hearing the current chime there means picking another option and back.

## 5. Timer model `[both]`

Phase transitions, `skip()`'s bidirectional semantics, wall-clock timing
(`endsAt`/`remainingMs`), and the task-name prompt are all shared across
both platforms — same `PomodoroTimer` (`PomoppiCore`), driven identically.
Both macOS and Windows implement the task-name prompt:
`StartCoordinator.swift` on macOS (via `NSAlert`), `TaskPromptDialog.swift`
on Windows (via a hand-rolled Win32 modal), each prompting when
`askForTaskName` is on, or unconditionally when `loggingEnabled` (§8), exactly
as described below (see `SETTINGS_PLAN.md` Part B, phases T1–T3).

Phases: `focus` → `shortBreak` → `focus` → … and every `longBreakEvery`
completed focus sessions the break is a `longBreak` instead. `cycleIndex`
counts completed focus sessions in the current set (0-based).

`skip()` ends the current phase early and moves straight to the next one, in
**either direction**: a break jumps into the focus session, a focus session is
cut short and hands over to a `shortBreak`. Idle is the only phase with nothing
to skip. Either direction bypasses `autoStartFocus`/`autoStartBreaks` — the user
explicitly asked to move on now.

The abandoned phase is reported through `phaseComplete` with `completed: false`
and the time **actually** spent, which is what makes §8 log it as a partial.
A cut-short focus claims neither `cycleIndex` nor `completedToday`: a long break
is earned by finishing sessions, not by skipping through them, so the slot stays
open for the next one.

`requestStart()` opens the task prompt only when `askForTaskName` is on **and
no task is set yet**. Prompting unconditionally meant naming a session ahead of
time (tray > Set task…) and then pressing play re-opened the same dialog on top
of the name just typed, which made setting a task in advance pointless.
**Native additionally makes the prompt mandatory** — regardless of
`askForTaskName`'s stored value — whenever `loggingEnabled` is true: a
logged session with no task name isn't a useful line to have recorded, so
that alone forces the ask rather than silently skipping it (before the
2026-09-19 session-log redesign, this also required a configured Obsidian
vault; there's no vault concept left to check). Cancelling that forced
prompt leaves the timer idle instead of starting; cancelling the ordinary,
optional prompt still starts the timer.

Timing is **wall-clock based**, not tick-accumulated: store `endsAt`
(epoch ms) and derive `remainingMs = endsAt - Date.now()`. On pause store
`remainingMs` and clear `endsAt`. This must stay correct across sleep/wake.

## 6. IPC contract `[legacy]`

Neither native app has any IPC layer, `preload` script, or renderer
process — this section describes Electron main/renderer process
mechanics that have no equivalent in a single-process Swift app on either
platform. Kept for historical intent (what state/settings shape flows
where) — `TimerState`/`PomoppiSettings` (`PomoppiCore`) are the actual
current shape both native apps use directly, in-process, with no channel
names or `invoke` boundary at all.

`preload.js` exposes `window.pomoppi` to the widget:

```js
window.pomoppi = {
  onState(cb),          // cb(state) — see below; returns an unsubscribe fn
  onSettings(cb),       // cb(settings) — fired on change; returns unsubscribe
  getState(): Promise<State>,
  getSettings(): Promise<Settings>,
  start(), pause(), reset(), skip(), dismissRing(),
  openSettings(), openTask(),
  hideWidget(),                    // the only way a renderer puts itself away
  toggleAlwaysOnTop(): Promise<boolean>,   // flips the setting, returns the new value
  onSnapshotRequest(cb),           // cb() — main asking for an SVG; returns unsubscribe
  saveSnapshot(svg): Promise<{ ok, path?, error? }>,
}
```

`toggleAlwaysOnTop` goes through the settings patch rather than the window, so
the tray checkbox, the settings form and the shortcut all move the same value
and the level is still set in exactly one place (§9b). `onSnapshotRequest` /
`saveSnapshot` are the two halves of §14.

State object, pushed every 250ms while running and on every transition:

```js
{
  phase: 'idle' | 'focus' | 'shortBreak' | 'longBreak',
  running: boolean,
  ringing: boolean,
  remainingMs: number,   // clamped >= 0
  totalMs: number,       // duration of the current phase
  cycleIndex: number,    // 0 .. longBreakEvery-1, completed focus sessions
  completedToday: number,
  task: string,          // '' when unset
}
```

While `phase` is `'idle'` there is no phase to count down, so both `remainingMs`
and `totalMs` report the **focus length that pressing start would use** — a
widget that has never run shows `25:00`, not `00:00`, and the preview follows
`focusMinutes` as it is edited. It is derived on read, so nothing has to push it.

`preload-settings.js` exposes `window.pomoppiSettings` to **both** the settings and
task windows:

```js
window.pomoppiSettings = {
  get(): Promise<Settings>,
  set(patch): Promise<Settings>,   // shallow merge, persists, broadcasts
  reset(): Promise<Settings>,
  pickVault(): Promise<string|null>,   // native directory dialog
  testLog(): Promise<{ok: boolean, path?: string, error?: string}>,
  close(),
  // task window only:
  getTask(): Promise<string>,
  setTask(text): Promise<void>,
}
```

Channel names: `habitsuu:state`, `habitsuu:settings`, and `habitsuu:<method>` for invokes.

## 7. Settings schema + defaults `[divergent]`

The schema itself, defaults, and validation/clamping rules are `[both]` —
one `PomoppiSettings` struct (`PomoppiCore/Settings.swift`), one
`settings.json` file shape read/written identically by both platforms
(just at different paths — see §0b's parity ledger). The two subsections
below each carry their own, more specific tag.

Persisted as JSON at `app.getPath('userData')/settings.json`. Unknown keys are
dropped on load; missing keys fall back to defaults; a corrupt file is replaced
with defaults (and the bad file renamed `settings.json.bak`).

```js
{
  focusMinutes: 25,
  shortBreakMinutes: 5,
  longBreakMinutes: 15,
  longBreakEvery: 4,
  autoStartBreaks: true,
  autoStartFocus: false,

  loggingEnabled: true,              // on by default since the 2026-09-19 redesign -- no vault/folder
                                     // to misconfigure first anymore, see §8

  friend: <first of SPRITES.FRIEND_IDS>,
  frameStyle: 'scallopy',            // one of SPRITES.FRAME_STYLES
  background: <first of BACKGROUND_IDS>, // one of renderer/background.js's BACKGROUND_IDS
  inkColor: '#000000',              // the theme pair -- see section 1
  paperColor: '#FFFFFF',
  colorScheme: 'auto',              // 'auto' | 'light' | 'dark' -- governs the settings window's own
                                     // chrome only (Appearance tab, top section); 'auto' follows the OS
                                     // light/dark setting, today's behavior. Doesn't touch the widget's
                                     // own ink/paper theme above, or the tray icon tint.
  alwaysOnTop: true,
  raiseOnEnd: true,
  scale: 2,                         // 1, 2, 3 or 4
  opacity: 1.0,                     // 0.3 .. 1.0
  launchAtLogin: false,
  startHidden: false,               // startup only: skip auto-showing the widget

  soundEnabled: true,
  chime: 'classic',                 // one of PomoppiSettings.chimeIDs -- see §4
  ringSeconds: 5,
  askForTaskName: true,             // prompt for a task when starting focus; native additionally
                                     // forces this on (regardless of the stored value) whenever
                                     // loggingEnabled is true -- see §5

  shortcuts: { ... },               // the schema's one nested object -- see §13
}
```

Validation on `set`: minutes 1..180, `longBreakEvery` 2..10, `scale` in {1,2,3,4} (1x is 118x138 physical pixels —
deliberately tiny, and offered),
`friend` must be one of `SPRITES.FRIEND_IDS` (fall back to the first; the key
was called `mascot` before the rename and `validate` still reads that name off
an old file, writing it back as `friend`),
`frameStyle` one of `SPRITES.FRAME_STYLES` (fall back to `'scallopy'`),
`background` one of `renderer/background.js`'s `BACKGROUND_IDS` (fall back to
the first),
`colorScheme` one of `'auto'`/`'light'`/`'dark'` (fall back to `'auto'`),
`chime` one of `PomoppiSettings.chimeIDs` (fall back to `'classic'`),
`opacity` 0.3..1.0, `ringSeconds` 0..60. Clamp rather than reject.

`inkColor` / `paperColor` accept `#rgb` or `#rrggbb`, with or without the `#`,
in either case, and are **normalised to upper-case `#RRGGBB`** so every
consumer can compare and blend without re-parsing. Anything else falls back to
that key's default. If the two come out equal the **pair** is reset to
black-on-white — see section 1.

### Launch at login `[divergent]`

The mechanism differs completely per platform (see §0b's parity ledger for
the one-line version): macOS uses `SMAppService.mainApp`, real only from an
installed `.app` bundle, with the two-tier Login-Items-then-LaunchAgent
fallback described below. Windows uses a single
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` registry value
(`LoginItem.swift`, Phase W5) — no bundle identifier check, no fallback
tier, no Automation-permission concern (registry writes need none). Read
everything below for macOS's own intent only; none of it describes
Windows.

`launchAtLogin` is **not** `app.setLoginItemSettings`. On macOS 13+ that call
registers, through `SMAppService.mainApp`, whatever bundle the process is
running from — for an unpackaged app that is always the shared Electron binary
in `node_modules`, and Electron's `path`/`args` override for it is Windows-only
(`electron.d.ts`: "@platform win32"). macOS accepts the registration and then
opens a bare Electron at every login. It reads back as enabled; it never opened
Pomoppi. `init` clears any such registration left by an older version — only
Electron can unregister it, so `main.js` does that, not `lib/login-item.js`,
which never imports `electron`.

What gets registered is the **Pomoppi.app bundle** `npm run launcher` builds
(§10), looked for in `/Applications`, `~/Applications`, then `~/Desktop`, and
accepted only if its `Info.plist` carries `it.lucabessiaristei.pomoppi`. With
no such bundle nothing is registered and the setting says why
(`loginItemError`, §6) — the checkbox never silently lies about having worked.
`init` re-applies the preference on every launch, which also re-points a stale
registration at a bundle that has since moved.

`lib/login-item.js` has two ways to register it, and installs exactly one:

1. A **Login Items entry**, made through System Events — the visible one,
   listed as Pomoppi under System Settings ▸ General ▸ Login Items ▸ "Open at
   Login". This is what the setting means to a user, so it is always tried
   first.
2. A per-user **LaunchAgent** at
   `~/Library/LaunchAgents/it.lucabessiaristei.pomoppi.plist`, running
   `/usr/bin/open -a <Pomoppi.app>` with `RunAtLoad` — used **only** when (1)
   is refused. Editing the Login Items list is an Apple Event, so it needs
   Automation permission for System Events, which an unpackaged Electron app
   does not reliably get; the agent needs no permission at all. It works, but
   it only surfaces under "Allow in the Background", which is what made the
   first version of this look like it had done nothing. When it is what got
   installed, `loginItemError` carries a notice saying so and how to get the
   visible entry instead.

Whichever is installed, the other is removed: two registrations would be two
launches. Both go through LaunchServices — the same shape as a double-click
(§10), never the Electron binary directly — and Pomoppi's single-instance lock
means even a duplicate could only raise the widget, never start a second copy.

Enabling **never loads** a LaunchAgent it writes: `RunAtLoad` would start a
second Pomoppi on the spot. launchd picks the plist up at the next login, which
is the point of the setting. Removing one boots the job out first, best effort
— `open` exits as soon as LaunchServices has the app, so a running widget is
never a child of the job and booting out cannot kill it.

### Settings window layout `[both]`

The form is **tabbed**, one panel per group, and every setting has one flat,
visible home inside its tab — true on both platforms, same
`SettingsStore`, same validation, not reimplemented per platform. Six
tabs, left to right: **General, Rhythm, Appearance, Keys, Sound, Diary**.
`General` is `Window` renamed and moved first — `Window` was a grab-bag
naming only its first section (widget layering + tray clicks + startup +
updates + reset), and once it also holds Color scheme, "General" is what
it is; it leads because it is the app-level tab, and because both
platforms remember the last tab, so "which tab is first" only decides
what a brand-new install opens on. See `SETTINGS_PLAN.md` for the phase
that carries this shape into code.

| Tab | Section | Controls | Hint footer |
|---|---|---|---|
| **General** | Widget | Keep the widget on top of other windows; Pop to the front when a session ends | — |
| | Menu bar icon *(Windows: Tray icon)* | Swap the menu bar icon's left and right clicks | live: "Left-click raises the widget, right-click opens the menu." / swapped |
| | Startup | Open Pomoppi when I log in; Start without showing the widget | "“Start hidden” applies from the next launch." |
| | Color scheme | Auto / Light / Dark (segmented) | "Pomoppi's own windows only. Widget colors are in Appearance." |
| | *(Language — added by `LOCALIZATION_PLAN.md` L3/L4, not by this section)* | | |
| | Updates | Automatically check for updates; "Pomoppi <version>" with a Check for updates action | — |
| | Reset | **Reset Pomoppi…** | "Also erases your session history." |
| **Rhythm** | Focus | Default focus length | "Or click the clock on the widget." |
| | Breaks | Short break; Long break; Long break every N sessions | "Or click the dots on the widget." |
| | Automation | Start breaks automatically; Start the next focus automatically; Ask what I'm working on before each focus | live, on `askForTaskName`: logging on → "Always asks while session logging is on (Diary tab)."; logging off → "Leave the name blank to skip." |
| **Appearance** | Roommate / Window edge / Background / Theme | card pickers; theme presets + Ink / Paper | — |
| | Size & transparency | Size (segmented); Opacity | — |
| **Keys** | Global shortcuts | one recorder row per action | "Work from any app. Click one, then press a new combo that includes a modifier." |
| | | **Restore Default Shortcuts** | — |
| | While the widget is focused | static key list | — |
| **Sound** | Chime | Play a chime when a session ends; Chime picker (disabled while the chime is off) | "Click a chime to hear it." |
| | Ring | ring length (always enabled: the ring is visual) | "Visual only, so it rings even with the chime off." |
| **Diary** | Session history | Record every session; History size; **Erase History…** | "Stored only on this computer." |
| | Export | Sessions recorded; Export Diary… | — |
| | Sync to folder | Diary folder; Choose…; Sync Now | — |

Windows' chrome is `SysTabControl32` with hand-laid-out raw controls, not
a pixel match for SwiftUI's `Form`/`Section` — see
`WINDOWS_PORT_PLAN.md`'s locked decisions for why that's accepted (identical
information architecture, not identical pixels). Everything below this
point in the subsection (disclosure/ARIA/CSP-era rules) is `[legacy]` —
written for the Electron HTML settings page, which no longer exists on
either platform.

Rules that outlive the exact list:

- **Nothing is behind a disclosure.** There are no `<details>` elements. An
  earlier version put "set once and forget" settings inside
  `<details class="advanced">` and left the rest visible; the split was the
  comsplotchyt — some groups collapsed and some not, with no rule a user could
  predict. If a tab grows unwieldy, split the tab; do not start re-hiding
  things inside it.
- **Every hint is a footer under its control, never a disclosure, never a
  tooltip.** The table above's "Hint footer" column is the whole of it —
  static copy explaining what a control does, and occasionally (marked
  "live") copy that changes with another control's value. macOS has
  `Form`'s `footer:` for free; Windows gets its own `addHint` mechanism and
  uses it the same way.
- **Window edge lives under Appearance**, next to the pet and the theme — it is
  what the widget *looks* like, not what it *does*. It is not a pet setting.
- A real tab widget: `role="tablist"`/`role="tab"`/`role="tabpanel"`,
  `aria-selected`, `aria-controls`/`aria-labelledby`, roving `tabindex`, and
  arrow/Home/End navigation. Panels toggle with the `hidden` property — never
  an inline `style`, which the CSP blocks silently.
- Hidden panels stay part of `form.elements`, so `collectFormData` still sees
  every field whichever tab is open. Switching tabs must never drop a value.
- Each panel keeps a `<legend>` for semantics but it is **visually hidden** —
  the tab already carries the name, so showing both printed the label twice.
- The selected tab is remembered in `localStorage` (wrapped in try/catch,
  falling back to the first tab). It is a per-viewer convenience, **not** a
  setting — it never goes in the schema.
- Every control keeps its `id` and its `name` across any reshuffle — the
  load/save path is driven by `name`, so renaming one silently stops persisting
  that setting.
- The window is resizable with a min size (main.js); the page reflows and the
  **tab bar** scrolls horizontally when it no longer fits. The page body itself
  never scrolls sideways.

## 8. Session log `[both]`

**Redesigned 2026-09-19, replacing Obsidian-markdown logging entirely** —
everything below this point in the section describes the current design;
see the note at the very end for what it replaced. `SessionLogger.swift`
(`PomoppiCore`) is real and wired on **both** platforms now — the Windows
gap the previous version of this section described (no UI, no call site)
no longer exists; `main.swift` logs every phase completion the same way
`AppDelegate.swift` does.

No vault, no folder, no filename format, no heading string — those
settings are gone. The only remaining setting is `loggingEnabled` (default
`true` now — there's nothing left to misconfigure before turning it on).

Target file: `<storageDir>/sessions.json` — the same directory
`settings.json` already lives in (`AppDelegate.storageDir()` / Windows'
`storageDir()`), not a user-chosen vault. One continuous file, not one per
day: `{"sessions": [ {…}, {…}, … ]}`, newest appended last. Rewriting the
whole array on every append is a deliberate, accepted simplification —
not solved for the case where session history grows large enough for that
to matter.

Every completed **or aborted** phase (focus, short break, and long break
alike) is logged unconditionally when `loggingEnabled` is on — no
`logBreaks`/`logAborted`-style filtering anymore. This is meant to be a
complete internal record; deciding what to show or export is a job for
whatever reads the file later (see the note below), not for the logger.

Each entry:

```json
{
  "phase": "focus",
  "task": "writing spec",
  "day": 19, "month": 9, "year": 2026,
  "startTime": "2026-09-19T09:15:00Z",
  "endTime": "2026-09-19T09:40:00Z",
  "durationMinutes": 25,
  "completed": true
}
```

`day`/`month`/`year` sit alongside the full ISO8601 `startTime`/`endTime`
(not derived from them by whatever reads the file) so trivial date
filtering doesn't require every consumer to parse a timestamp first.
`durationMinutes` is the *planned* length for a completed phase, the
*actual* elapsed time for an aborted one — same distinction the old
Obsidian format made between a session's target and its real length.

Writes are atomic (write to `<file>.tmp`, then rename over the real file)
and go through an actor on both platforms, so two phases completing close
together can never interleave a read-modify-write of the same file — see
`SessionLogger`'s own comments for the one deliberate exception (a
synchronous, non-actor-isolated `eraseAllSync()`, used only by the
Diary tab's "Erase History…" button after its own confirmation
dialog, an accepted simplification for a rare, user-initiated action, not
a hot path).

The Diary tab's Session history section (§7's settings-window-layout
subsection; this used to be its own "Log" tab — renamed from "Obsidian,"
then folded into Diary entirely in the 2026-09-20 redesign, §8b) holds:
the `loggingEnabled` toggle, a live history-size readout, and that Erase
button.

**Reinstall/upgrade semantics.** `sessions.json` and `settings.json` both
live in the per-user storage dir (`AppDelegate.storageDir()` /
Windows' `storageDir()`), not inside the app bundle — an upgrade that just
replaces the app leaves both untouched. A reinstall that wipes that
directory, or the Diary tab's own "Erase History…," starts the log
empty; the diary folder (§8b) keeps whatever `.md` files it already has,
and the next sync simply continues from there — there's nothing to
double-append (sync diffs each day's file by content, not a cursor) and
nothing to skip (there's no cursor left to point at the wrong place).
Restoring `sessions.json` from an older backup, or moving to a new
machine and pointing at the same diary folder, works the same way: the
next sync fills in whatever that folder is missing and leaves everything
it already has alone. See §8b for why this is safe.

**What this replaced**: Electron/the original Swift rewrite wrote directly
to an Obsidian daily note (`<vaultPath>/<dailyNoteFolder>/<date>.md`,
inserting `- ` lines under a configurable heading and recomputing a
running `**Total focus:** ` line on every write) — Obsidian-markdown-
specific, and only ever wired up on macOS. §8b describes what replaced
it: a Diary tab that reads *this* JSON file and either syncs it to a
user-chosen folder or exports it, built on top of the internal record
rather than writing a specific editor's format directly the way the old
design did.

## 8b. Diary `[both]`

**Added 2026-09-19**, on top of §8's JSON session log — the "read *this*
JSON file and either sync it to a folder or export it" intent §8's
closing note described. **Redesigned 2026-09-20**: one diary shape
instead of two, and sync is now idempotent (no cursor) — both changes
described below. Reads `SessionLogger.allSessionsSync()`; never writes to
`sessions.json` itself.

**One shape.** Every focus session (breaks are never part of a diary)
becomes a `- HH:MM–HH:MM (Nm) — task` line — `stopped early` instead of
just the duration for an aborted session — grouped into one
`<dateKey>.md` file per day, each holding a `## Pomodoros` section.
Export and Sync are just two different destinations for that same
per-day content, both built from the same `DiaryExporter` code path so
the two shapes can't drift apart: Export bundles every day's file into a
single `.zip` (root of the archive, no wrapper folder); Sync writes those
files straight into a user-chosen folder.

Three sections in the merged Diary settings tab, top to bottom: Session
history (moved from the old Log tab, §8), Export, Sync to folder.

**Export** — "Sessions recorded: N" plus an "Export Diary…" button (save
dialog filtered to `.zip`: `NSSavePanel` on macOS, `GetSaveFileNameW` on
Windows; default name `Pomoppi Diary.zip`). `DiaryExporter.exportZip(sessions:)`
(`PomoppiCore`) builds the zip via `ZipWriter` (stored/uncompressed
entries — see below). Stateless: safe to run repeatedly, always produces
a fresh archive, no cursor to track.

**Sync** — incremental, idempotent merge into a user-chosen folder (a
plain folder; Pomoppi never assumes it's specifically an Obsidian vault,
an `SHBrowseForFolderW`/`NSOpenPanel` directory picker either way).
`DiaryExporter.syncToFolder(_:sessions:)` takes the **whole** session log
on every call — there's no cursor — and, per day, diffs the log against
whatever `<dateKey>.md` already has: each existing `- ` line is
identified by its own `HH:MM–HH:MM` clock-range key (not its full text),
so a task renamed by hand afterward is recognized as the same session
rather than duplicated. A missing session is inserted at its
chronological position among the existing lines (by start clock — not
just appended), and a day's file is only rewritten if that actually
changed something. Everything else in the file — hand-written notes
before/after the section, a later unrelated `## ` heading, any line this
pass doesn't touch — survives byte-for-byte. Returns the number of lines
actually added; throws on write failure (folder unmounted, permission
lost, etc.) rather than swallowing it, so the tab can show "Sync failed."
This is what makes the reinstall/upgrade paragraph in §8 safe: run sync
against any session log, at any time, against any state the target
folder happens to be in, and it converges rather than duplicating or
skipping.

**`ZipWriter`** (`PomoppiCore/ZipWriter.swift`) is a minimal, from-scratch
ZIP writer — neither platform's Foundation exposes a zip API, and
shelling out to `zip`/`Compress-Archive` isn't acceptable here. Stored
(uncompressed) entries only, deterministic order (sorted by name); no
directories, no general-purpose zip features beyond what one flat folder
of tiny `.md` files needs.

One settings field backs this (`Settings.swift`, `SettingsStore.swift` on
Windows): `diaryFolderPath: String` (empty = not set yet, disables the
Sync button). No cursor field — the old `diaryLastSyncedCount` (an index
into the session log) is gone along with the design it supported; an old
`settings.json` still carrying that key decodes fine, `JSONDecoder`
ignoring unknown keys for free.

## 9. Tray `[divergent]`

Menu-bar icon from `assets/trayTemplate-N.png` (generated, see §10). Tooltip
shows the current phase and remaining time.

The menu is **grouped**: what the timer is doing, then how it is configured,
then the window, then the app.

**This diagram is stale on both platforms, not just Windows.** Neither
native app has a task-naming feature or the SVG-snapshot feature (§14) at
all — both were dropped in the rewrite, not merely deferred on one side —
so neither's real tray menu has a `Set task…`/`Rename task…` row or a
`Save snapshot to Desktop` row. What both platforms actually build
(`TrayController.swift`, either one): `Start`/`Pause`, `Skip`, `Reset`,
`Sessions per long break ▸`, `Show`/`Hide Pomoppi`, `Keep on top`,
`Settings…`, `Quit` — the diagram below minus those two rows.

```
Start / Pause
Skip                        disabled while idle
Reset                       disabled while idle
Set task… / Rename task…    disabled during a break
────────
Sessions per long break ▸   radio, 2..10
────────
Show / Hide Pomoppi
Keep on top                 checkbox
Save snapshot to Desktop    accelerator shown, not registered -- see §14
────────
Settings…
Quit
```

- `Keep on top` re-reads `alwaysOnTop` in its handler rather than capturing it,
  so a rebuild mid-click can't invert the wrong value.
- `Skip` and `Reset` are **no-ops from idle** (§5), so they are disabled rather
  than looking live and doing nothing.
- The task item's label follows the phase, and it is disabled during a break —
  a task belongs to a focus session and is cleared when the phase ends, so there
  is nothing to rename. See §5 for why `requestStart` no longer re-prompts.
- `Sessions per long break` enumerates `Settings.LONG_BREAK_EVERY_MIN..MAX`, the
  same range the widget's dots and the settings form clamp to. Never hardcode
  the bounds here; three UIs offering different ranges is how they drift.
- `Save snapshot to Desktop` carries `accelerator: <the snapshot binding>` with
  `registerAccelerator: false`. The accelerator is there to *teach* the key,
  not to own it — `globalShortcut` already holds it (§13), and letting the menu
  register it too would mean two owners for one combo. Because the item now
  reads a setting, the binding joins `trayMenuSig` below; otherwise rebinding
  the key would leave the menu showing the old hint until something unrelated
  changed.
- **Friend and Window edge do not belong here.** They were tray submenus and are
  now only pickers in the settings window: two homes meant two places to keep in
  sync, for a choice nobody changes mid-session.

### The icon animates and carries a clock

`updateTray` runs on every 250ms tick — `timer.tick()` emits whether or not a
phase is running — so it is the animation clock, and **everything in it must be
guarded against re-pushing a value the OS already has**. Hold the last pushed
menu signature, title, tooltip and frame index; a tick that changes nothing must
make no OS call. The menu in particular used to be rebuilt four times a second
forever; it is now rebuilt only when its signature changes. That signature must
cover everything the template reads, `state.running` included — the Start/Pause
item's handler closes over it.

- **Frames** come from `SPRITES.TRAY_FRAMES`, one 16x16 grid each, **generated
  from `Tasukippi.aseprite`** by `npm run tray` (see §10) — the menu bar plays
  the animation the artist drew, so it is not something to author in code or by
  hand. The count lives in the art: draw another frame in Aseprite, re-import,
  re-run `npm run icons`, and it animates with no code change. `loadTrayImages`
  stops at the first missing file and falls back to the pre-animation
  `assets/trayTemplate.png` so an un-regenerated checkout still gets a tray.
- **Cadence:** an even cycle, `TRAY_FRAME_MS` per frame. The source is a loop,
  not a rest pose plus an accent, so nothing privileges frame 0. Keep
  `TRAY_FRAME_MS` at two ticks or more or a frame can be skipped entirely. The
  index is derived from the wall clock, never a tick counter — same reasoning as
  the timer's `endsAt`: a late tick must not shift the animation's phase.
- **The clock** is `tray.setTitle(formatClock(state.remainingMs))`, macOS-only,
  with `fontType: 'monospacedDigit'` so the title does not reflow every second
  as digit widths change. It reads the same `remainingMs` off the same broadcast
  the widget draws from, so the two cannot disagree — do not give it its own
  timer.

**Left-click raises the widget, right-click opens the menu** — the standard
menu-bar-app split, and the default since the Windows port (Phase W2b), which
also introduced `reverseTrayClick`: a settings toggle that swaps the two back
to the original left=menu/right=raise mapping for anyone who prefers it. Do
not use `tray.setContextMenu` either — on macOS it binds *both* buttons to the
menu, which is why both are bound by hand. Register the listeners once at
tray creation: `updateTray` runs on every 250ms tick, so registering there
stacks a listener per tick.

**Dismissing the menu must not send our windows backwards.** macOS gives event
focus to the status bar while a tray menu is up, and hands activation back to
whichever *application* was frontmost when it closes. Pomoppi is an accessory
app, so it is never that application: any window of ours that was in front
before the click ends up behind whatever is — which is why opening the menu
used to push the settings window and the widget back.

So `popTrayMenu` notes which of our windows was focused, and restores it on the
menu's `menu-will-close`, one turn of the event loop later (macOS has to finish
handing activation back first). Two rules keep this from fighting anything else:

- It **only touches activation**, never the window level. `setAlwaysOnTop` is
  not called here — see §9b.
- It **bails if any window of ours already has focus** by the time it runs. A
  menu item may have deliberately moved focus (`Settings…`, `Set task…`) or
  taken the window away (`Hide Pomoppi`, `Quit`); this only undoes the
  *incidental* deactivation of dismissing the menu.

Hold the popped `Menu` instance in a local, not the `trayMenu` variable —
`updateTray` may replace that while the menu is open, so by the time it closes
the variable may point at a newer one.

*(The whole "Dismissing the menu must not send our windows backwards"
problem above is macOS-specific — it exists because macOS hands
activation to the status bar while a tray menu is open, then back to
whichever app was frontmost, which for an accessory app is never Pomoppi.
Win32's tray context menu (`TrackPopupMenu`) doesn't have this failure
mode: the owning window keeps its own activation state through a menu
popup, so `TrayController.swift` on Windows needed no equivalent
workaround.)*

## 9b. Window layering `[divergent]`

R1 (level) and R3 (raise) are `[both]` in intent — Windows achieves the
same idempotent floating-level behavior via `SetWindowPos(HWND_TOPMOST/
HWND_NOTOPMOST)` (`WidgetWindow.swift`) rather than
`NSFloatingWindowLevel`, and the tray/global-shortcut/`raiseOnEnd` callers
all funnel through it the same way `raiseWidget()` does here. R0 and R2
below are real divergences:

- **R0** (accessory app, no Dock icon, never owns the menu bar) is a
  macOS-specific policy with no literal Windows equivalent — Windows
  achieves the closest analogous outcome (no taskbar button) via
  `WS_EX_TOOLWINDOW` on the widget window, a style flag, not an
  app-wide activation policy; there is no "owns the menu bar" concept on
  Windows at all.
- **R2** (`setVisibleOnAllWorkspaces` — the widget follows across every
  macOS Space) **has no Windows implementation.** Windows 10/11 has an
  equivalent concept (virtual desktops, via `IVirtualDesktopManager`), but
  no phase of the port has implemented it — the widget is only visible on
  whichever virtual desktop it was created on. A real gap, not a
  by-design omission; see the parity ledger above.

Three rules govern where the widget sits. They are deliberately the whole
model — this area was once a pile of special cases (a temporary level bump
with a revert timer, a position-restore listener fighting macOS, a
full-screen visibility flag) where each fix caused the next bug. Keep it this
small.

**R1 — Level.** Two states, driven only by the `alwaysOnTop` setting: on →
`'floating'` (`NSFloatingWindowLevel`, 3); off → normal. Nothing else ever
changes the level. `'floating'` stays below `NSMainMenuWindowLevel` (24), and
that is not optional: **the widget must never be able to hide the macOS menu
bar.** A window that becomes key at or above the menu bar's level makes macOS
withdraw the menu bar entirely, which reads as the app having gone
full-screen. `raiseOnEnd` once used `'screen-saver'` (1000) and did exactly
that.

Window state is applied **idempotently**, via `setWidgetAlwaysOnTop` /
`setWidgetOpacity`, which track what was last pushed and skip no-ops.
**Nothing may call `setAlwaysOnTop` directly.** It re-levels *and re-orders*
the window on macOS even when handed the value it already holds, so
re-applying it on an unrelated settings change — picking a friend from the
tray — sank the widget behind every other window.

**R0 — Activation policy.** `app.dock.hide()` makes this an accessory app:
no Dock icon, and — the part that surprises people — it **never owns the menu
bar**, so the menus at the top always belong to the last regular app even when
the widget is focused. That is macOS policy, not an Electron quirk, and the
only way to change it is `regular` policy, which forces a permanent Dock icon.
The user was offered that trade and chose to keep the Dock clear. So the
widget's window focuses but the menu bar stays foreign, deliberately.
`LSUIElement` in the launcher bundle matches this and must stay.

**R2 — Spaces.** `setVisibleOnAllWorkspaces(true, { skipTransformProcessType: true })`
so the widget is reachable on every desktop rather than stranded on the one it
was created in; a widget you have to hunt for is a widget you stop using.
`skipTransformProcessType` avoids a dock/window flash and is safe because
`app.dock.hide()` already made this an accessory app.

**Never add `visibleOnFullScreen`.** Electron documents it as making the
window "visible above fullscreen windows" — that *is* the bug where the widget
covers a full-screen film. It was added once to stop the widget sinking behind
things on a Space switch; that was a misdiagnosis (the real cause was the
non-idempotent `setAlwaysOnTop` above), and it also brought back the menu-bar
symptom and a position jump that needed its own listener to undo.

The accepted consequence: the widget does not appear over full-screen apps at
all, so `raiseOnEnd` during a full-screen film is silent. That is the correct
trade — the alternative is ripping the user out of their film.

**R3 — Bringing it forward.** One function, `raiseWidget()`, serving every
caller — the tray right-click, the tray's Show item, `raiseOnEnd`, and
`second-instance`: show if hidden → `moveTop()` → `app.focus({ steal: true })`
→ focus the window. Unconditional, no flags, no per-caller variants, **no
temporary level change and no timer**.

`app.focus({ steal: true })` is app-level activation; a window-level `focus()`
alone does not activate an accessory app while another app is frontmost.
Activating **does** pull the user out of a full-screen Space and **can** take
the keyboard mid-sentence. Both are intended: this is an alarm. The comsplotchyt
that led here was the widget *constantly overlapping* full-screen apps, which
R2 fixes — not the interruption itself, which is the point of a timer going
off.

With `alwaysOnTop` off the widget will sit behind the frontmost window — on a
Space switch and at every other time, because that is what the setting means.

A raise is therefore **not sticky**, and this is not a bug: `moveTop()` orders
a window within its own level, but *across* apps at the same level macOS
orders by activation, so the widget stays forward only while Pomoppi is the
active app. Opening the tray menu hands activation back, and the widget drops
— the same way it drops when any other window is clicked. Making a raise stick
requires raising the window's *level*, which is exactly what `alwaysOnTop`
does. The `Keep on top` menu item is the one-click answer; do not add code to
defeat this.

## 10. Generated assets `[legacy]`

Entirely the old Electron art pipeline (`tools/import-friends.js` →
`renderer/friends.js`, `tools/make-icons.js`, `tools/make-launcher.js`) —
none of these files exist in the current tree. The real, current pipeline
is documented in `CLAUDE.md`, not here: `refresh-art.js` + `Art/tools/
import-*.js` write `Sources/PomoppiSprites/Sprites.generated.swift`;
`Scripts/make-app.js` / `Scripts/make-windows-app.js` assemble the
double-clickable app per platform. Read this section only for *why* each
step exists (Aseprite as the source of truth, generated-file-never-hand-
edited, tray frames driven by the art rather than by code), not for any
literal path or command.

`tools/import-friends.js` (`npm run friends`) re-imports the pet sprites from their
`.aseprite` sources; re-run it after editing a pet in Aseprite. It requires
Aseprite installed, and writes `renderer/friends.js`, which is generated — never
edit it by hand.

`tools/import-bgs.js` (`npm run bgs`) imports every `import/bgs/*.aseprite`
file into `renderer/background.js`, keyed by id (`bg-scacchi.aseprite` ->
`scacchi`) with display order in `BACKGROUND_IDS` — the settings window's
Background picker (§7) enumerates it the same way the friend and window-edge
pickers enumerate `FRIEND_IDS`/`FRAME_STYLES`. `bg-template.aseprite` is
always skipped: it's a starting point for drawing a new pattern, not a
pattern itself. Each source must be exactly `CANVAS_W` (118) px wide; height
is whatever the artist drew.

`tools/make-icons.js` (run via `npm run icons`) writes PNGs from the grids in
`renderer/sprites.js` using **only `zlib` and `fs`** — hand-rolled PNG encoder,
no image libraries:
- `assets/trayTemplate-N.png` (16x16) and `assets/trayTemplate-N@2x.png`
  (32x32), one pair per `TRAY_FRAMES` entry, ink + alpha only.

`tools/import-tray.js` (`npm run tray`) fills `TRAY_FRAMES` itself, from
`sprites01/Tasukippi.aseprite` — sibling of `import-friends.js`, sharing its PNG
reader in `tools/read-png.js`, and like it requires Aseprite installed to decode
its own format. The drawing is 1px line work sitting small inside a 32x32
canvas, so there is **no downscaling**: the frames are cropped to one window
that holds all of them — the shared window is the point, per-frame bounds would
make the drawing jitter — and centred in the 16x16 tray box. It is
**outline-only by necessity**: macOS draws a tray image as a template, keeping
only its alpha channel, so a filled silhouette would render as a solid lozenge
with no face.
- `assets/icon.png` (512x512) from the `idle` frame, nearest-neighbour scaled,
  on a white background.

`tools/make-launcher.js` (`npm run launcher`) writes a double-clickable
`Pomoppi.app` to the Desktop — or to a path given as its one argument — so the
widget can be started without a terminal. Hand-rolled bundle, **no packager and
no new dependency**: an `Info.plist`, a `/bin/sh` stub in `Contents/MacOS` that
runs Electron with this repo as its argument, and an `icon.icns` converted
from `assets/icon.png` with the system's own `sips` and `iconutil` (best effort
— a missing icon never fails the build).

The stub **must not `exec`**. `exec` replaces the shell process, so the process
LaunchServices launched for the bundle *becomes* Electron mid-flight, and under
that path the tray's `NSStatusItem` never appears — the app runs, the menu-bar
icon silently does not, while the icon file, the `Tray` object, `LSUIElement`
and the LaunchServices record all remain identical to a `npm start` launch.
Background Electron and `wait` instead: the stub stays alive as the app's
process while Electron registers as an ordinary child, the same shape
`npm start` produces, and the icon appears. `LSUIElement` is true, matching the
`app.dock.hide()` in `main.js`: Pomoppi is a menu-bar widget and claims no Dock
tile.

This bundle is also what "launch at login" registers (§7) — the login item
points at it, so that setting only works once the bundle exists.

It is a **launcher for the working copy, not a distributable**. Absolute paths
to this repo and its `node_modules` are baked in at generation time, so moving
or deleting either breaks the bundle; re-run the script after moving the repo.
Regenerating replaces an existing bundle only when its `Info.plist` carries our
bundle identifier — anything else at that path is left alone and the script
fails instead.

## 11. File ownership `[legacy]`

Describes a two-agent split over Electron-era file paths (`main.js`,
`lib/*.js`, `renderer/*.js`) that don't exist in the current Swift tree at
all. `CLAUDE.md`'s file map (Shared/macOS/Windows tables) is the current
equivalent, and this port has generally been worked by one agent across
the whole tree rather than a fixed two-way split.

When the work is split across two agents, one owns, and only touches:
```
main.js  preload.js  preload-settings.js
lib/timer.js  lib/settings.js  lib/obsidian.js  lib/paths.js  lib/login-item.js
tools/make-icons.js
test/timer.test.js  test/obsidian.test.js  test/settings.test.js
test/login-item.test.js  test/shortcuts.test.js
```

the other owns, and only touches:
```
renderer/widget.html   renderer/widget.css   renderer/widget.js   renderer/draw.js
renderer/settings.html renderer/settings.css renderer/settings.js
renderer/task.html     renderer/task.js
```

`renderer/shortcuts.js` is shared: it is art-free data plus pure functions, read
by `lib/settings.js` on one side and by two renderer pages on the other, the
same dual-mode arrangement `renderer/sprites.js` already has (§11b). Treat it
like `sprites.js` — either agent may read it, neither changes it casually.

Neither edits `package.json`, `SPEC.md`, or `renderer/sprites.js`.
Neither runs `npm install` or adds a dependency.

## 11b. Script loading (no bundler) `[legacy]`

Entirely about `<script>` tag load order for the old renderer HTML pages —
there is no HTML, no browser, no module system in a compiled Swift binary
on either platform. The *intent* (one shared source of truth for
friend/background/shortcut data, read by both settings validation and the
UI) is `[both]` and still true — it's just `PomoppiCore`/`PomoppiSprites`
Swift types now, imported normally, not dual-mode `window.*`/
`module.exports` globals.

There is no build step and no module system. `renderer/sprites.js`,
`renderer/friends.js`, `renderer/background.js` and `renderer/shortcuts.js` are
all dual-mode: each sets `module.exports` under Node and a `window.*` global in
a renderer. That is what lets `lib/settings.js` `require` them for validation
while the pages load the very same files as plain scripts — one definition of
the friend list, the background list and the shortcut table, not two that drift.
All renderer scripts are therefore **splotchy `<script>` tags** — no
`type="module"`, no `import`/`export`. Load order in `widget.html`:

```html
<script src="friends.js"></script>
<script src="background.js"></script>
<script src="sprites.js"></script>
<script src="draw.js"></script>
<script src="widget.js"></script>
```

`settings.html` loads the same four (it draws a friend in its header and the
pickers' swatches) plus `shortcuts.js`, before `settings.js`. `task.html` needs
none of them.

## 12. Security posture `[legacy]`

CSP, `contextIsolation`, `sandbox`, and the IPC-boundary framing are all
Electron/browser security concepts. Neither native app has any untrusted
web content, renderer process, or IPC boundary to isolate — a compiled
Swift binary reads its own settings file and draws its own pixels
in-process, on both platforms. Nothing here has a native equivalent to
port.

Every page carries a CSP `<meta>`: `default-src 'none'; script-src 'self';
style-src 'self'; img-src 'self' data:`. **`style-src 'self'` blocks inline
`<style>` blocks**, silently — a page that keeps its CSS inline renders in
system serif with native controls and logs nothing. All CSS therefore lives in
a `.css` file beside its HTML: `widget.css`, `settings.css`, `task.css`.

`contextIsolation: true`, `nodeIntegration: false`, `sandbox: true` on every
window. Renderers touch the filesystem only through IPC. `preload` scripts
expose the named methods above and nothing more — no generic `invoke` passthrough.

## 13. Keyboard `[both]`

Two separate mechanisms, deliberately not one. **Global shortcuts** are
registered with the OS and fire wherever you are; **in-app keys** work only
while a Pomoppi window has focus. A menu-bar timer is mostly used from inside
some other app, so the global set is the one that matters — but a global
binding is a scarce, machine-wide resource, so it stays small, is fully
rebindable, and every one of them can be switched off.

**Two things below don't actually exist on either platform, not just
Windows**: the `snapshot` action (id + default accelerator only —
`Shortcuts.swift` defines it, but neither `AppDelegate.swift` nor
`main.swift` registers a handler for it, since the SVG-snapshot feature
itself was dropped, §14) and the in-app `T`/`P` rows (task-rename-while-
running and SVG-snapshot) — neither key does anything on macOS either;
Windows' own Keys-tab documentation explicitly lists this as why they're
left out there too. Everything else in this section is real and shared.

### Global shortcuts `[both]`

The table lives in shared `PomoppiCore/Shortcuts.swift` — one canonical
source both platforms validate against and both settings UIs render from
(the Keys tab, Phase W7, replaces this description's settings-window
rendering with a real click-to-record UI on both platforms — see §7).

| id | does | default |
|---|---|---|
| `toggleWidget` | show / hide the widget | `⌥⇧P` |
| `startPause` | start, or pause | `⌥⇧Space` |
| `skip` | skip the phase | `⌥⇧K` |
| `reset` | reset the phase | `⌥⇧R` |
| `toggleOnTop` | flip `alwaysOnTop` | `⌥⇧T` |
| `snapshot` | write an SVG to the Desktop (§14) | `⌥⇧S` |
| `openSettings` | open the settings window | `⌥⇧,` |

Defaults are all `Alt+Shift+…`: `⌥⇧` is close to unused by macOS itself and by
most apps, and keeping one prefix for the whole set makes them learnable as a
group rather than seven unrelated facts.

`shortcuts` is persisted as `{ [id]: accelerator }` — the settings schema's only
nested object, which is why `validate()` runs `SHORTCUTS.validate` over it and
why a caller changing one binding sends **the whole object**: `Settings.set`
merges shallowly, so a partial patch would drop the other six.

Normalisation, in `shortcuts.normalize`:

- Modifier aliases fold together (`cmd`/`super`/`meta` → `Command`, `ctrl` →
  `Control`, `option`/`opt` → `Alt`), and output is always ordered `Command`,
  `CommandOrControl`, `Control`, `Alt`, `Shift`, key. Canonical form is what
  makes conflict detection a string comparison instead of a parser.
- **At least one modifier is required.** A bare global key is swallowed for
  every application on the machine — you would lose `S` in your editor.
- `''` is a valid, meaningful value: *deliberately unbound*. It is not the same
  as a missing key, which falls back to the default.
- Two actions cannot hold the same combo. Walking the table in order, the first
  claimant keeps it and the later one is cleared to `''` — clamp rather than
  reject, the same rule the rest of §7 follows.

Registration is in `main.js`: `unregisterAll` then re-register the whole set,
run at startup and again only when the `shortcuts` object actually changed —
re-registering on every unrelated settings write churns a system-wide
resource for nothing. `globalShortcut.register` returns `false` (and can throw
on a malformed accelerator) when another app already owns a combo; those land
in `shortcutErrors`, which `pomoppiSettings:get` merges into its reply exactly
as it already does for `loginItemError`, so the settings window can mark the
row instead of failing silently. `unregisterAll` again on `will-quit`.

The handlers do not second-guess the timer: `skip` and `reset` are no-ops from
idle inside `lib/timer.js` (§5) and are simply forwarded, rather than gated
here into a third place that has to know the rule.

### In-app keys `[both]`

Fixed, not rebindable — they cost nothing globally, and a second binding UI for
them would be more surface than they are worth. Active while the widget window
has focus:

| key | does |
|---|---|
| `Space` / `Enter` | start / pause |
| `S` | skip |
| `R` | reset |
| `T` | set or rename the task |
| `O` | keep on top |
| `P` | save an SVG snapshot |
| `,` (or `⌘,`) | settings |
| `Esc` | dismiss the ring if it is ringing, otherwise hide the widget |
| `↑` / `↓` | focus length ±1 min, only while the clock steppers are visible |

Each routes through the same helper the corresponding button already calls —
`Space` does whatever the play button does, `↑`/`↓` go through
`stepFocusMinutes` and honour `clockSteppersVisible()`. A key that duplicates a
button's logic instead of calling it is how the two come to disagree.

The settings window closes on `Esc`, except while a shortcut row is recording,
where `Esc` cancels the recording — the nearer meaning wins, and a capture you
cannot back out of without also losing the window is a trap.

## 14. Snapshots (SVG) `[legacy]`

**Not implemented on either platform.** The `snapshot` global-shortcut id
and its default `Alt+Shift+S` accelerator still exist in
`PomoppiCore/Shortcuts.swift` (so validation/normalization has a slot for
it), but no handler is ever registered for it in `AppDelegate.swift` or
`main.swift`, and `renderer/draw.js`'s recorder-pattern design described
below has no Swift equivalent — there is no SVG export code anywhere in
this codebase. Kept for intent only, in case this is revisited; nothing
below is currently true of either native app.

`Save snapshot to Desktop` — tray item (§9), global shortcut, or `P` on the
focused widget — writes the widget **exactly as drawn** to
`~/Desktop/Pomoppi-YYYY-MM-DD-HHMMSS.svg`.

It is vector, not a screenshot, and it is not a second renderer. Every drawing
primitive in `renderer/draw.js` bottoms out in `ctx.fillStyle = c;
ctx.fillRect(x, y, w, h)` — so a snapshot is `drawCanvas()` run once against a
**recorder** that answers to exactly those two members and collects the rects in
logical pixels. The module-level `ctx` is swapped for it and restored in a
`finally`; nothing else in the drawing path is aware SVG exists. That is the
whole design, and it is the reason the snapshot cannot drift from the widget:
there is no second implementation to keep in sync.

- `viewBox="0 0 118 132"`, `width`/`height` at the current `scale`,
  `shape-rendering="crispEdges"` so the pixels stay pixels at any zoom.
- **Rects are coalesced before serialising.** The frame and the pet are drawn a
  pixel at a time; emitted raw that is tens of thousands of elements. Runs of
  the same colour sharing `y` and `h` whose x-spans touch merge into one, and
  consecutive same-colour runs sit under a single `<g fill="…">`.
- No background rect. The canvas is transparent wherever nothing is drawn and
  the SVG says the same thing.

The renderer builds the string; **main writes the file**. The renderer never
supplies a path — main generates the name, resolves collisions with `-2`, `-3`,
and refuses a payload that is not a string, does not begin with `<svg`, or runs
past 4 MB. This is the only path in the app where bytes from a renderer reach
the user's disk, and §12's posture is why it is the narrow one.

## 15. Versioning and updates `[both]`

Added by the cross-platform release/update plan (**R0-R6**; see
`RELEASE_PLAN.md` for the full phase history and `RELEASING.md` for the
checklist that actually cuts one) — the first time either platform's app
has shipped a version number that means anything beyond a source comment,
or made an outbound network call at all.

**Version source.** `Sources/PomoppiCore/Version.swift`'s `pomoppiVersion`
is the single source of truth; nothing else in the tree hardcodes its own
copy. `Scripts/version.js`'s `readVersion()` regex-reads it out for
`Scripts/make-app.js`, `Scripts/make-windows-app.js`, `Scripts/make-pkg.js`
and `Scripts/check-tag-version.js`, so all four always agree with whatever
the file says. `Scripts/set-version.js` is the one supported way to change
it (`node Scripts/set-version.js 0.3.0`) — never hand-edit the string in
place.

**Distribution.** GitHub Releases
(`github.com/lucabessiaristei/Pomoppi/releases`) is the one channel, for
both platforms: a macOS `.pkg` (`Scripts/make-pkg.js`, via `pkgbuild`) and
a Windows installer plus a plain zip (`Scripts/make-windows-app.js
--installer`, `Scripts/pomoppi.iss` via Inno Setup). Both are built and
attached to the release by `.github/workflows/macos.yml` /
`windows.yml` on `release: published`, each gated by
`Scripts/check-tag-version.js` — the release tag, minus a leading `v`,
must match `pomoppiVersion` or the build fails loudly rather than shipping
a mismatched artifact.

**Unsigned, on purpose, for now.** Both platforms ship with no code
signing at all: no Apple Developer Program enrollment (so no notarization,
and Gatekeeper treats the `.pkg`/`.app` as from an unidentified developer),
no Windows code-signing certificate (so SmartScreen flags the installer).
This is **R2, deliberately deferred** — a cost/friction tradeoff at this
small a user count, not a technical blocker: both an Apple Developer
Program membership and a Windows EV signing certificate are recurring
costs that buy nothing the unsigned, hand-rolled pipeline doesn't already
do correctly (a structurally sound, single-instance-safe install). It is
revisitable the moment the audience or the friction below justifies it.
See `README.md` for the exact Gatekeeper/SmartScreen steps this currently
costs a recipient.

**The update checker.** `Sources/PomoppiCore/UpdateChecker.swift`
(shared) holds the actual "is there something newer" logic — `SemVer`
(numeric, per-component comparison), `parseLatestRelease`,
`isUpdateAvailable`, and the `checkForUpdate` orchestration, all
Foundation-only and driven through an injected `Fetch` closure so none of
it needs a real network call to exercise. Each platform's own
`AppUpdateChecker.swift` (`Sources/PomoppiApp/` / `Sources/PomoppiWindows/`)
owns the real transport and the scheduling on top of it.

It is **passive and notify-only** — it never downloads or installs
anything on either platform, only reports that a newer tag exists and
links to its GitHub release page. It checks ~10 seconds after launch,
then every 24 hours for as long as the app keeps running; **no state is
persisted across launches** — no "last checked," no "skipped version" —
because `/releases/latest` already excludes drafts/prereleases
server-side, so there is nothing worth remembering between runs. Opt-out
is `Settings.checkForUpdates` (default `true`), a toggle in the General
tab's "Updates" section (§7) on both platforms; a separate "Reset
Pomoppi…" button lives in that tab's own "Reset" section (wipes the
storage dir after confirming — the in-app answer to "fresh install," see
§8's reinstall/upgrade semantics). A tray item ("Update available:
`<tag>`") appears only when one exists and opens the release page; the
General tab's Updates section itself shows the current version, a "Check
for Updates" button, and a status line cycling through
idle/checking/up-to-date/update-available/failed — "failed" is only
reachable through an explicit manual check; a background check's own
failure stays silent, folded into "no update" the same way a 404 ("no
releases yet") already is.

**Security posture.** This is the first outbound network call either
platform's app has ever made, which is worth being explicit about: exactly
one endpoint, `GET
https://api.github.com/repos/lucabessiaristei/Pomoppi/releases/latest`,
hit on the schedule above and nowhere else. No telemetry, no analytics, no
crash reporting. Nothing is sent but a `User-Agent: Pomoppi/<version>`
header plus the two GitHub-API-version headers `requestHeaders(appVersion:)`
sets — no request body, no user data, no machine identifier of any kind.
Nothing about the response is persisted to disk; the parsed result lives
only in memory for the running session
(`AppUpdateChecker.latestResult`) and is gone at the next launch.
