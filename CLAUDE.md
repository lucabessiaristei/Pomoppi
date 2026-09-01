# Pomoppi

Kawaii pixel pomodoro widget for macOS, with two implementations living side
by side at the top level of this repo:

| Directory | What | Status |
|---|---|---|
| `native/` | Swift/AppKit + SwiftUI rewrite | **Primary** — build and ship this one |
| `legacy-electron/` | The original Electron app (includes its `import/` Aseprite sources, `renderer/`, `lib/`, etc.) | Archived for reference/continuity |
| `assets/` | App icon sources (Icon Composer `.icon`, generated `.car`/`.icns`) | Shared by both — read but not owned by either |

`SPEC.md` is the authoritative **behavior** contract for both implementations
— if code and spec disagree, the spec wins. Read the section you're touching,
not the whole file. Where it describes Electron-specific mechanics (IPC,
`contextBridge`, npm packaging), read that for intent, not literal API, when
working in `native/`.

Each implementation has its own contract file with its own commands, file
map, and invariants:

- **`native/CLAUDE.md`** — the Swift app (primary)
- **`legacy-electron/CLAUDE.md`** — the Electron app (archived)

Don't mix the two: a rule in one file doesn't apply to the other's tree.
