# Pomoppi

ポモっぴ — *pomodoro* + *-ppi*, the Habitsuu creature suffix.

A spin-off. **Habitsuu** is the habit-and-task tracker these creatures belong to;
this is the pomodoro that borrows them. Different app, same cast.

A pomodoro widget with a virtual pet that **deteriorates because you are
productive**. It does your tasks in your place and suffers for it: Namidappi
cries from the workload, Jankuppin eats its feelings. Inverse care. You get the
finished pomodoros; it gets the consequences.

Black on white, every pixel drawn on a canvas, and it logs each session into
your Obsidian daily note.

Black on white, predominantly white, every pixel drawn on a canvas. Floats
above your other windows, gets out of the way, and jumps to the front with a
little animation when a timer ends.

Swift/AppKit + SwiftUI, no Electron, no npm runtime dependency. See
`CLAUDE.md` for the full developer contract (commands, file map,
invariants) and `SPEC.md` for the behavior spec.

```
     ┌────────────────┐     Pomoppi draws its own chamfered pixel
     │                │     frame — no macOS rounded rectangle,
     │     ( ᴗ )      │     no drop shadow, transparent corners.
     │                │
     │     24:59      │     Seven-segment clock, 1px strokes.
     │   ▓▓▓▓▓░░░░    │
     │   ■ ■ · ·      │     Cycle dots: done / pending.
     │   ▶   ⏮   ⚙    │
     └────────────────┘
```

## Installing

Pomoppi ships as an unsigned app on both macOS and Windows via
[GitHub Releases](https://github.com/lucabessiaristei/Pomoppi/releases) —
see `SPEC.md` §15 for why it's unsigned (a deliberate, revisitable
cost/friction tradeoff, not an oversight) and `RELEASING.md`/
`RELEASE_PLAN.md` for how a release actually gets cut.

**As of this writing there is no release yet** — this hasn't shipped its
first one. Once it has, grab the right file from the latest release page
and follow the steps below; being unsigned means both platforms throw up
a warning the first time you run it.

### macOS

Download `Pomoppi-<version>.pkg` and run it.

1. Double-click the `.pkg`. macOS refuses it: "*Pomoppi.pkg* can't be
   opened because it is from an unidentified developer," with no way to
   proceed from that dialog alone.
2. Open **System Settings → Privacy & Security**, scroll down to the
   security section, and click **Open Anyway** next to the mention of
   the blocked file.
3. Confirm **Open** in the dialog that follows. The installer runs
   normally from here.

(Faster alternative: right-click the `.pkg` in Finder → **Open** →
**Open** in the confirmation dialog. This works on the very first try,
no trip through System Settings needed.)

The installer places `Pomoppi.app` in `/Applications`. Launch it from
there or Spotlight.

### Windows

Download `Pomoppi-Setup-<version>.exe` and run it.

1. Run the `.exe`. Windows shows a blue **"Windows protected your PC"**
   screen with only a **Don't run** button visible.
2. Click **More info** — this reveals a **Run anyway** button.
3. Click **Run anyway**. The installer runs normally from here (a
   per-user install under your user profile, no admin prompt needed).

Alternatively, download `Pomoppi-win.zip` from the same release and run
`Pomoppi.exe` directly with no install step — SmartScreen shows the same
warning either way, since it's the executable itself that's unsigned,
not the installer.

## The pets

Four virtual pets, drawn in Aseprite by hand. Pick one in **Settings →
Appearance**, or from the **Friend** submenu in the menu bar.

| | |
|---|---|
| **Namidappi** | ナミダっぴ — tears; cries at every inconvenience |
| **Onanippi** | オナニっぴ — the late-night browsing one |
| **Gemuppin** | ゲームっぴ — lost to another six-hour session |
| **Jankuppin** | ジャンクっぴん — eats its feelings |

The sprites are imported verbatim — nothing here generates or retouches them:

```sh
node refresh-art --friends  # re-import from Aseprite, then rewrite Sources/PomoppiSprites/Sprites.generated.swift
```

That reads the `.aseprite` files, splits each sheet into 32×32 frames and
writes `Art/renderer/friends.js`. **Every pet needs exactly 2 frames** — an
idle/step pair, alternated to animate; a sheet with 1 or 3+ is skipped on
import rather than padded or trimmed to fit. Pace is what tells you the
phase — a working beat while focusing, drowsy on a break with a `z` beside
it, a fast flutter when time is up, and completely still when you pause.

## Poking at it

The widget is operated, not just watched:

| Do this | Get this |
|---|---|
| click the pet | swap to the next one |
| click the clock's left or right half | focus length −5 / +5 minutes (when idle) |
| click a cycle dot | that many sessions before a long break |
| click − / + beside the dots | shorten or lengthen the cycle |
| click the clock, then type | set the focus length; Enter commits, Esc cancels |
| hover the dots | ghost slots appear, so you can make the cycle *longer* |
| drag anywhere else | move the widget |

## The window

No macOS rounded rectangle. Pomoppi cuts its own edge, and you can choose it in
**Settings → Appearance** or the **Window edge** menu-bar submenu:

| | |
|---|---|
| **scallopy** | rounded bumps, the default |
| **zigzag** | sharp triangular teeth |
| **tatter** | irregular and non-repeating, like torn paper |
| **splotchy** | a straight rectangle |

The notches are genuinely transparent, so the desktop shows through them.

## Running it

```sh
swift run PomoppiApp
```

Or build a real, double-clickable app once and launch it from Spotlight/Finder
from then on:

```sh
node Scripts/make-app.js
```

That writes `/Applications/Pomoppi.app` (release build, ad-hoc signed) — not a
distributable app, so re-run the command after pulling changes.

**Launch at login** rides on that bundle: switching it on in Settings adds
`Pomoppi.app` to System Settings ▸ General ▸ Login Items, so it opens at the
next login and you can see and remove it like any other login item. Build the
app first — the settings window says so if it can't find the bundle. If
macOS refuses the Automation permission that editing that list needs, Pomoppi
falls back to a background item that opens the same bundle, and says so under
the checkbox.

## Using it

- **Drag** anywhere on the widget except the button row to move it.
- Four controls: **↺** resets the current phase, **▶ / ⏸** start and pause,
  **⏭** skips ahead, **♥** opens settings.
- **⏭ works in both directions.** During a break it jumps straight back to
  work; during a session it cuts the pomodoro short and sends you to the break.
  A session ended that way is logged as a partial (see below), and it does not
  count toward the long break — you earn that by finishing sessions.
- The **menu-bar ghost** animates, shows the countdown beside itself, and its
  menu gives you start/pause, skip, reset, the task name, sessions per long
  break, show/hide, keep-on-top, settings and quit. Pomoppi has no Dock icon —
  it lives in the menu bar.
- When a timer ends, Pomoppi raises above whatever you're doing, flashes, shakes
  and chimes for a few seconds. Click any button to dismiss.
- **Save snapshot to Desktop** (tray menu, or <kbd>⌥⇧S</kbd>) drops the widget
  onto your Desktop as an SVG, drawn exactly as it looks right now — vector, so
  it scales to any size without going soft. It's the same drawing code the
  widget renders with, pointed at a recorder instead of the canvas, so the file
  can't disagree with what's on screen.

## Keyboard

**From anywhere**, whatever app you're in. All seven are rebindable in
**Settings → Keys**, and any of them can be cleared if you'd rather have the
combo back.

| | |
|---|---|
| <kbd>⌥⇧P</kbd> | show / hide the widget |
| <kbd>⌥⇧Space</kbd> | start / pause |
| <kbd>⌥⇧K</kbd> | skip the phase |
| <kbd>⌥⇧R</kbd> | reset the phase |
| <kbd>⌥⇧T</kbd> | keep on top |
| <kbd>⌥⇧S</kbd> | save an SVG snapshot |
| <kbd>⌥⇧,</kbd> | settings |

They're all on <kbd>⌥⇧</kbd> on purpose: macOS barely uses that prefix, so the
set is learnable as one thing. If another app already owns a combo, the Keys tab
says so on that row rather than failing quietly.

**With the widget focused**, no modifier needed:

| | |
|---|---|
| <kbd>Space</kbd> / <kbd>↩</kbd> | start / pause |
| <kbd>S</kbd> · <kbd>R</kbd> · <kbd>T</kbd> | skip · reset · set task |
| <kbd>O</kbd> · <kbd>P</kbd> · <kbd>,</kbd> | keep on top · snapshot · settings |
| <kbd>Esc</kbd> | dismiss the chime, or tuck the widget away |
| <kbd>↑</kbd> / <kbd>↓</kbd> | focus length ±1 min, while it's idle |

## Obsidian logging

Completed pomodoros are appended to that day's daily note in your vault,
under a `## Pomodoros` heading:

```markdown
## Pomodoros
- 09:15–09:40 (25m) — writing spec ✅
- 10:00–10:25 (25m) — refactor auth ✅

**Total focus: 50m across 2 pomodoros**
```

The note is created if it doesn't exist, the heading is added if missing, and
the total line is recomputed on every write. Writes are atomic and serialised,
so nothing is ever half-written. If logging fails, the timer carries on
regardless — it never takes the app down.

Point it at your vault under **Settings → Obsidian**, where you can also change
the folder, the date format, the heading, and whether breaks get logged. The
**Test log** button writes a sample entry so you can check the path is right.

Default vault: `~/Documents/Opal`, and sessions land in its **`Pomodoro/`** folder rather than cluttering the root.

## Settings

Everything is editable in the settings window and saved as you type, to
`~/Library/Application Support/Pomoppi/settings.json`.

| Group | What's in it |
|---|---|
| Timer | focus / short break / long break lengths, long-break cadence, auto-start |
| Obsidian | vault path, daily-note folder & format, heading, log breaks, log aborted |
| Appearance | friend, always on top, raise on end, pixel scale (2/3/4), opacity, launch at login |
| Keys | the seven global shortcuts, plus a reference card for the in-widget keys |
| Sound | chime on/off, how long the ring lasts |

## Layout

```
Sources/PomoppiApp/       app lifecycle, window/tray wiring, global shortcuts, settings UI
Sources/PomoppiCore/      wall-clock timer state machine, settings load/validate/persist, Obsidian logger
Sources/PomoppiRender/    the 1px drawing kit and widget layout/animation
Sources/PomoppiSprites/   digits, icons, window edge, and the generated pet/background art
Art/                      the Aseprite pixel-art pipeline (sources + importers), independent of the app itself
Scripts/                  make-app.js
refresh-art.js            re-import Aseprite art + rewrite Sources/PomoppiSprites/Sprites.generated.swift
Tests/                    swift-testing/XCTest suites mirroring Sources/
```

No runtime dependencies — this is a plain SPM package, nothing else. Full
file map and invariants: `CLAUDE.md`.

## Editing the art

The pets live in `Art/renderer/friends.js`, backgrounds in
`Art/renderer/background.js`, and the menu-bar animation in the `TRAY_FRAMES`
block of `Art/renderer/sprites.js` — all three are **generated**. Edit the
`.aseprite` source instead and re-import with `node refresh-art`. It shells
out to Aseprite for the decoding, so Aseprite must be installed.

- **Friends**: drop `Name_ok.aseprite` into `Art/import/friends/`. The `_ok`
  suffix means "done, ship it" — draft art can sit in the same folder as
  `Name.aseprite` (no suffix) and stays invisible to the app until renamed.
  `refresh-art` adds/removes friends from Settings' picker automatically to
  match whichever `_ok` files exist — nothing to register by hand, in either
  direction.
- **Backgrounds**: same as friends — drop `bg-name_ok.aseprite` into
  `Art/import/bgs/`. `bg-template.aseprite` (a starting point, not a
  background) is excluded for free: it has no `_ok`, so it never matches.
- **Tray icon**: `Art/import/icon/` holds the single menu-bar animation
  source.

Art changes are compiled into the binary, so `node refresh-art` alone won't
show up in the app you actually run — pass `--rebuild` to also rebuild and
reinstall `/Applications/Pomoppi.app`.

Everything else in `Art/renderer/sprites.js` has no image files at all: the
clock digits are generated from a seven-segment table so every stroke is
exactly 1px, the 16×16 control icons are `0`/`1` grids, and the window edge is
computed by `windowFrame(style, w, h)`.

```sh
node refresh-art             # re-import everything, then rewrite Sources/PomoppiSprites/Sprites.generated.swift
node refresh-art --bgs       # or --friends / --icon, alone or combined, for just one category
node refresh-art --rebuild   # also rebuilds + reinstalls /Applications/Pomoppi.app when done
swift test
```
