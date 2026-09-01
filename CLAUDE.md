# Pomoppi

Kawaii pixel pomodoro widget for macOS. Electron, **zero runtime dependencies**,
no bundler, no git repo (so: back up before destructive edits).

`SPEC.md` is the authoritative contract — if code and spec disagree, the spec
wins. Read the section you're touching, not the whole file.

## Commands

```sh
npm start          # run
npm test           # node --test, 76 tests
npm run launcher   # write /Applications/Pomoppi.app (double-clickable)
npm run icons      # regenerate assets/*.png from renderer/sprites.js grids
npm run friends    # re-import pet sprites from import/friends/*.aseprite (rewrites renderer/friends.js)
npm run bgs        # re-import background patterns from import/bgs/*.aseprite, skipping bg-template.aseprite (rewrites renderer/background.js)
```

Settings live at `~/Library/Application Support/Pomoppi/settings.json`.

## File map

| File | What |
|---|---|
| `main.js` | Electron main: windows, tray, IPC, window layering |
| `lib/timer.js` | Wall-clock pomodoro state machine (`endsAt`, never tick-accumulated) |
| `lib/settings.js` | Load/validate/persist settings; clamp helpers (no `electron` import) |
| `lib/obsidian.js` | Writes sessions into the Obsidian daily note |
| `lib/login-item.js` | Launch at login: registers `Pomoppi.app` in the Login Items list, LaunchAgent fallback (never `setLoginItemSettings`) |
| `preload.js` / `preload-settings.js` | contextBridge, named methods only |
| `renderer/widget.js` | The pixel canvas: layout, animation, hit-testing, drag |
| `renderer/draw.js` | 1px drawing kit (`fillRect` only — never a font or stroke) |
| `renderer/settings.*` | Settings window |
| `renderer/task.*` | Task-name prompt window |
| `renderer/sprites.js` | **Art data, read-only.** Mascot frames, glyphs, icons, `TRAY` |
| `renderer/shortcuts.js` | Shortcut table + accelerator normalising. Dual-mode like `sprites.js`, so `lib/settings.js` and two pages share one copy |
| `renderer/friends.js` | **Generated** by `npm run friends` — never hand-edit |
| `renderer/background.js` | **Generated** by `npm run bgs` — never hand-edit |
| `import/friends/`, `import/bgs/` | Source `.aseprite` files the importers above read. `import/bgs/bg-template.aseprite` is a starting point for a new pattern, not a background — `npm run bgs` always skips it |
| `tools/make-icons.js` | Hand-rolled PNG encoder (zlib+fs only) |
| `tools/make-launcher.js` | Builds the `/Applications/Pomoppi.app` bundle |
| `assets/pomoppi-clear.icon` | Icon Composer source for the Liquid Glass app icon (`pomoppi-simple.icon` is the same drawing with `"glass": false`) |
| `assets/AppIcon.car`, `assets/AppIcon.icns` | **Generated** from that `.icon` by `actool`, and committed — so `npm run launcher` ships the layered icon on a Mac with no Xcode. A build that *does* find `actool` rewrites both; the `.icon` stays the source of truth |

## Invariants that keep getting broken

- **Window layering** (SPEC §9b) — the area with the worst history. Level is
  `'floating'` and driven *only* by `alwaysOnTop`; nothing calls
  `setAlwaysOnTop` directly (it re-orders the window even when passed the value
  it already has); never add `visibleOnFullScreen`; no timers. One
  `raiseWidget()` serves every caller.
- **Launcher stub must not `exec`** — `exec` replaces the LaunchServices
  process and the tray icon silently never appears.
- **CSS in a `.css` file, never inline `<style>`** — every page sets
  `style-src 'self'`, which blocks inline styles with no error.
- **`renderer/widget.js` keeps its IIFE** — `sprites.js`/`friends.js`/`background.js`
  are classic scripts whose top-level `const`s share the global scope.
- Tray: left-click opens the menu, right-click raises (user's explicit choice,
  reverse of the usual). Listeners registered once, never in `updateTray`.
- App is **accessory** (`app.dock.hide()`): no Dock icon, and it never owns the
  menu bar. User chose this knowing the trade.
- **The SVG snapshot is not a second renderer** (SPEC §14) — it is `drawCanvas()`
  run against a recorder standing in for `ctx`. If you find yourself writing
  drawing code in the snapshot path, you've taken the wrong turn.
- **A global shortcut needs a modifier** and no two actions may share a combo
  (SPEC §13); `renderer/shortcuts.js` enforces both. `shortcuts` is the settings
  schema's only nested object, so a patch carries the *whole* object — `set`
  merges shallowly and a partial one silently drops the rest.

## ⚠ In flight — remove when done

A **temporary passive diagnostic** is wired into `main.js` (`diag`,
`diagState`, `wireDiagnostics`, and logging inside the two `tray.on` handlers).
It logs activation/tray events to `~/.pomoppi-diag.log`, only while the
sentinel `~/.pomoppi-diag` exists. It never steals focus.

**The open question is answered.** With `alwaysOnTop` off, a raise wasn't
durable — the widget dropped back behind other windows. The captured log plus
the user's own report identify the trigger: **opening the tray menu**. macOS
gives event focus to the status bar while the menu is up and hands activation
back to whichever *application* was frontmost when it closes; as an accessory
app Pomoppi is never that application, so whatever window of ours was in front
goes behind. (The earlier "tray menu was not observed to deactivate the app"
note was wrong — the diagnostic only tracked `widgetWindow`, and the user was
hitting this with the *settings* window focused.)

Fixed in `popTrayMenu` (main.js) — restores the previously-focused window on
`menu-will-close`, touching activation only, never the level. See SPEC.md §9.

The diagnostic is **left in place so the fix can be confirmed against the same
log**. Once confirmed: delete that code, `~/.pomoppi-diag`, and
`~/.pomoppi-diag.log`.
