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

This README describes the app conceptually and, in a couple of places below,
the **legacy Electron implementation's** specific commands/files. The
actively developed build is the Swift/AppKit rewrite under `native/` (see
`native/CLAUDE.md`) — the Electron app now lives archived under
`legacy-electron/` (see `legacy-electron/CLAUDE.md`); every bare command below
(`npm run …`) must be run from inside that directory.

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
npm run friends  # re-import after editing a sprite in Aseprite
```

That reads the `.aseprite` files, splits each sheet into 32×32 frames and
writes `renderer/friends.js`. **Draw more frames and they animate**: a pet with
several frames plays them in order, and one drawn only once gets a derived
squash frame so it still breathes. Pace is what tells you the phase — a
working beat while focusing, drowsy on a break with a `z` beside it, a fast
flutter when time is up, and completely still when you pause.

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
npm start
```

Or put a launcher on the Desktop once and double-click it from then on:

```sh
npm run launcher
```

That writes `/Applications/Pomoppi.app`, a small bundle that just starts this
working copy — it is not a distributable app, so re-run the command if you move
the repo.

**Launch at login** rides on that bundle: switching it on in Settings adds
`Pomoppi.app` to System Settings ▸ General ▸ Login Items, so it opens at the
next login and you can see and remove it like any other login item. Build the
launcher first — the settings window says so if it can't find the bundle. If
macOS refuses the Automation permission that editing that list needs, Pomoppi
falls back to a background item that opens the same bundle, and says so under
the checkbox.

First run only, if `node_modules` is missing:

```sh
npm install
# npm 11 blocks Electron's postinstall by default; if `npm start` comsplotchys
# that Electron failed to install, fetch the binary explicitly:
node node_modules/electron/install.js
```

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
legacy-electron/main.js              Electron main: windows, tray, IPC, always-on-top
legacy-electron/preload*.js          contextBridge surfaces (no generic passthrough)
legacy-electron/lib/timer.js         wall-clock timer state machine (no Electron, unit-tested)
legacy-electron/lib/settings.js      load / validate / clamp / persist
legacy-electron/lib/obsidian.js      atomic daily-note appender
legacy-electron/renderer/friends.js  GENERATED pet sprites — npm run friends
legacy-electron/renderer/task.css    CSS lives in files: the CSP blocks inline <style>
legacy-electron/renderer/sprites.js  digits, icons, window edge; wraps the pets
legacy-electron/renderer/draw.js     pixel drawing kit (fillRect only, no fonts, no images)
legacy-electron/renderer/shortcuts.js the shortcut table + accelerator parsing, shared main/renderer
legacy-electron/renderer/widget.js   the widget: layout, animation, hit-testing, chime, SVG snapshot
legacy-electron/tools/make-icons.js  hand-rolled PNG encoder for the tray & app icons
legacy-electron/test/                node --test
```

No runtime dependencies — Electron and nothing else.

This layout, and the rest of this README, describe the legacy Electron app,
archived under `legacy-electron/` above. The actively developed, primary
implementation is the Swift/AppKit rewrite under `native/` — see
`native/CLAUDE.md`.

## Editing the art

The pets live in `renderer/friends.js`, which is **generated** — edit the
`.aseprite` files and run `npm run friends` instead. `tools/import-friends.js`
shells out to Aseprite for the decoding, so Aseprite must be installed.

Everything else is in `renderer/sprites.js` and has no image files at all:
the clock digits are generated from a seven-segment table so every stroke is
exactly 1px, the 16×16 control icons are `0`/`1` grids, and the window edge is
computed by `windowFrame(style, w, h)`.

```sh
npm run friends  # re-import pet sprites from Aseprite
npm run icons    # regenerate assets/ PNGs (tray + app icon)
npm run launcher # write /Applications/Pomoppi.app
npm test
```
# Pomoppi
