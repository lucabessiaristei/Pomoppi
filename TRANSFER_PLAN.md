# Transfer plan — moving settings and the log between computers, offline

Agreed 2026-10-07. Built in chunks, each stopped for a go-ahead.

## Status

| Chunk | State |
|---|---|
| 0. "Pomoppi" settings tab | done |
| 1. Core codec | done |
| 2. Core QR encoder + render | done |
| 3. Core QR decoder (images) | done |
| 4. macOS UI | done (real phone photo: user check pending) |
| 5. Windows UI | done (Open image with a real photo unchecked) |

Update this table (and the chunk's commit hash) when a chunk lands.

## How to run this plan (read first in a fresh session)

- **One chunk per turn**, then report and stop for the user's go-ahead.
- **Delegate execution** to the `dipsy` agent (edits, builds, tests, VM
  runs) with a dense brief; the main thread reviews the diff and commits.
  Tell it not to commit.
- **No mouse, keyboard, System Events or screenshot automation on the Mac**
  without asking the user first. Anything visual on macOS is checked by
  the user by hand (`swift run PomoppiApp`). Inside the Windows VM,
  screenshots via the `schtasks /it` scripts in `C:\Users\bubvm\` are fine
  (see `WINDOWS_VM.md`); back up and restore the VM's `sessions.json` /
  `settings.json` around any test, never overwrite them otherwise.
- **Verify lightly:** `swift build` + `swift test` once per chunk.
- **Commits:** one short plain subject line, no body, no co-author
  trailers; user is sole author.
- **Docs per chunk:** the `SPEC.md` section for what landed (new §
  "Transfer"; the byte format must be complete enough for a phone app to
  implement), a `NEXT_RELEASE.md` bullet, and `CLAUDE.md`'s file map for
  new files.
- **Strings:** add keys to all 5 `Localization/*.json`, then
  `node refresh-strings` (never hand-edit `Strings.generated.swift`).
- **Windows:** `Sources/PomoppiApp/` is off-limits for Windows work and
  vice versa; Windows code only compiles in the VM.

## Facts the codec builds on

- `PomoppiSettings` (`Sources/PomoppiCore/Settings.swift`): focus/short/
  long minutes (Double), longBreakEvery, autoStartBreaks/Focus,
  loggingEnabled, diaryFolderPath, friend, frameStyle, background,
  inkColor/paperColor (`#RRGGBB`), colorScheme, alwaysOnTop, raiseOnEnd,
  reverseTrayClick, scale (Int), opacity (Double), launchAtLogin,
  startHidden, checkForUpdates, language (`system` or an id), soundEnabled,
  chime, ringSeconds, askForTaskName, shortcuts `[actionID: accelerator]`.
  ID lists: `friendIDs`, `frameStyles`, `backgroundIDs`, `chimeIDs`,
  `languageIDs`, `colorSchemeIDs`; `defaults`. Read the file for the
  current set; new settings may have landed since.
- Shortcuts (`Shortcuts.swift`): accelerators like `Alt+Shift+Space`,
  canonical modifier order `Command, CommandOrControl, Control, Alt,
  Shift`; already platform-neutral.
- `SessionLogEntry` (`SessionLogger.swift`): phase (`focus`/`shortBreak`/
  `longBreak`), task, day/month/year, startTime/endTime (ISO8601, whole
  seconds), durationMinutes, completed, and optional durationSeconds,
  plannedSeconds, pausedSeconds, pomodoroStart, focusNumber, focusCount,
  timeZone, appVersion, friend. The schema only grows; the codec must
  round-trip every field, including absent optionals. Verify each
  derivation rule against `logSession` before relying on it.
- From-scratch precedent: `ZipWriter.swift`, `ODTWriter.swift`,
  `XLSXWriter.swift`, `SHA256.swift` (use it for the checksum),
  `PixelCanvas.swift` (QR rendering, platform-neutral).
- Dev data: `.dev-app-support/sessions.json` holds 88 seeded sample
  pomodoros (some with `friend`), good for size reports.

## Goal

Move Pomoppi's settings and pomodoro log from one computer to another
(macOS ↔ Windows, either direction) with no account and no network. The
QR is the main carrier long term, but **no webcam scanning for now**
(decided 2026-10-07: no phone app yet). Receiving reads a **QR image**
(e.g. a phone photo of the screen, AirDropped/sent over), a pasted **text
code**, or a **`.pomoppi` file**, all the same bytes. The format is
documented in `SPEC.md` so a future phone app can read and write it too.

## Payload (`PomoppiCore`, `TransferCodec`)

All numbers are LEB128 varints unless noted. One binary payload:

- **Header:** format version (`1`), flags for which blocks are present and
  which compact options were used.
- **Settings block:** only what differs from `PomoppiSettings.defaults`.
  - Every setting has a permanent field number in an add-only table.
  - Booleans: one bitmask of the ones that differ from the defaults (0 bytes
    when none do).
  - Enums (friend, frame, background, chime, language, colorScheme): one
    index into a **frozen, add-only registry inside the codec** — never the
    live `friendIDs`/etc. lists, which `refresh-art` can reorder. An id the
    registry doesn't know falls back to its string.
  - Colors: 3 bytes RGB. Minutes: seconds. Opacity: 0–100 in one byte.
    Scale and ringSeconds: small ints.
  - Shortcuts: only non-default ones, about 3 bytes each (action index,
    modifier bitmask, key code; named-key table, string fallback). The
    stored accelerator form is already cross-platform.
  - **Never transferred** (machine-local): `diaryFolderPath`,
    `launchAtLogin`, `startHidden`, `alwaysOnTop`.
- **Log block:** grouped by pomodoro.
  - Tables up front: titles (deduped, most used first, so common titles
    get 1-byte references), time zones, app versions.
  - Per pomodoro (~4–6 bytes): start as a delta from the previous
    pomodoro, title ref, friend (registry index or "same as previous"),
    planned focus count / time zone / app version, each with a "same as
    previous" flag.
  - Per entry: **one flag byte** (phase 2 bits, completed, contiguous with
    the previous entry, planned length same as the last of this phase, no
    pause, all derived values match). Extra varints only for what isn't
    implied (gap, actual duration, pause, corrections).
  - Derived, not stored: day/month/year (start + time zone),
    durationMinutes, focusNumber, endTime (start + duration + paused),
    durationSeconds of a completed entry (= planned), pomodoroStart (= first
    entry's start, unless flagged).
  - Lossless: when an entry breaks any derivation rule, the "all match"
    flag is off and the explicit values are stored.
- **Checksum:** first 4 bytes of SHA-256 (`SHA256.swift`) over everything
  before it.
- **Encode-time safety net:** the encoder decodes its own output and
  compares it with the input; on any mismatch it refuses to produce a code.

Expected sizes: a normal 4-focus pomodoro ≈ 13 bytes; the 88-pomodoro dev
sample ≈ 1.3 KB; a heavy year (~1,500 pomodoros, ~200 titles) ≈ 23 KB.
Settings alone ≈ 10–20 bytes.

**Compact options** (the popup's toggles): settings on/off, log on/off,
titles on/off, sub-minute skipped focuses on/off, extra details (paused
time, app version, time zone) on/off. Turning details or titles off is
lossy by design and says so.

**Carriers of the same payload:**
- **Text code:** `pomoppi1-<base64url>`, one unbroken token (no spaces,
  so a double-click selects it all and chat apps don't wrap it).
- **File:** `Pomoppi Transfer.pomoppi`, the raw payload bytes.
- **QR:** below.

## QR (`PomoppiCore`)

- **Encoder** (hand-rolled, same precedent as `ZipWriter`/`SHA256`): byte
  mode, versions 1–40, Reed–Solomon, masking with penalty scoring, error
  correction M (survives a skewed or slightly blurry phone photo). Renders to `PixelCanvas`,
  so both platforms draw it identically, always plain black on white (never the theme colors: a light-on-dark or low-contrast theme can make it unscannable).
- **Size:** the encoder picks the smallest version that fits (21×21 up
  to 177×177), error correction M: one code holds up to ~2.3 KB. A payload
  bigger than that shows no QR; the popup says so and offers the code and
  the file (or turning off titles/details to make it fit).
- **Later, with the phone app (not in this plan):** webcam scanning,
  multi-part animated codes for big logs, a "Smaller codes" cap for
  cameras. Keep the payload format ready for a part header, but don't
  build it.
- **Decoder** (hand-rolled, shared, used by Windows for images and by
  both platforms' tests): binarize, find the finder patterns, perspective
  transform (phone photos are skewed), sample the grid, read format/version
  info, RS error correction, unmask, parse byte mode. macOS reads images
  with Apple's Vision instead (more robust), but the shared decoder stays
  the reference both are tested against.

## Import

- **Preview before applying:** "62 pomodoros (40 new), settings: 5
  differ", with a choice to apply the settings or only merge the log.
- **Log merge by `pomodoroStart`:** idempotent (importing twice changes
  nothing); pomodoros only on the receiving machine are kept. New
  `SessionLogger` call, written atomically; it isn't automatic removal, so
  the `pruneEmptyPomodoros()` rule stands.
- **Errors:** bad checksum, unknown format version, missing parts: one
  clear message, nothing written.

## UI: the Transfer popup

Opened from a Transfer section in Settings → General.
- **Send:** the toggles above, a live weight line ("≈ 1.3 KB · QR 137×137 ·
  ~1,800 characters", or "too big for a QR"), the QR, Copy code, Save
  QR image…, Save file….
- **Receive:** Open image… (also drag and drop), Paste code, Open file…;
  then the preview and confirm.
- All 5 languages.

## Chunks

0. **New "Pomoppi" settings tab (pre-step, both platforms).** Last tab,
   after Diary. Holds, top to bottom: version line ("Pomoppi 0.5.0" + a
   link to the release notes), the **Updates** row (moved from General as
   is: toggle, Check now, install progress), a **Transfer** section
   placeholder that chunks 4/5 fill (no section at all until then, don't
   ship an empty one), **Data folder** ("Show in Finder" / "Show in
   Explorer" for the storage dir: `AppDelegate.storageDir()` /
   `AppStorage.swift`), and **Reset all settings** (moved from General
   with its confirmation). General keeps widget, tray, startup, color
   scheme, language.
   - **macOS icon:** the menu-bar Pomoppi, from `trayFrames[0]`
     (`Sprites.generated.swift`, the same pixel data `TrayController`
     renders as a template `NSImage`), rendered as a template image with
     its strokes **thickened** (dilate the pixel shape by one pixel, or
     render each pixel as a slightly larger square) so its weight matches
     the SF Symbols of the other tabs at toolbar size. Use
     `Tab(value:) { … } label: { Label { Text(…) } icon: { Image(nsImage:) } }`
     since `systemImage:` only takes SF Symbols. The user checks the look by
     hand.
   - **Windows:** tabs are text only; add the 7th tab to the
     `SysTabControl32` and check the strip's width in light and dark in the
     VM.
   - **Everything that opens Settings on General to show the Updates row**
     must open the new tab instead: `AppDelegate.offerLaunchUpdate` and
     `TrayController` (macOS, `"pomoppi.settingsTab"` = `"general"` today)
     and the Windows equivalents (`SettingsTab` registry value,
     `SettingsWindow.swift` tab memory).
   - Strings: tab name and the new rows in all 5 languages; SPEC's
     settings-tab section updated.

1. **Core codec:** `TransferCodec` (varints, settings diff + frozen
   registry, log packing, compact options, base64url, checksum,
   self-check, size estimate), `SessionLogger` merge import. Tests: round
   trips (normal and odd entries, each derivation rule broken once),
   options, corrupted input, size report on the dev sample. `SPEC.md`
   section for the format.
2. **Core QR encoder + `PixelCanvas` render.** Tests check output against
   a known-good reference (Vision decode in a macOS-only test).
3. **Core QR decoder** for images. Tests: encode → render → scale/rotate/
   perspective/blur/noise → decode.
4. **macOS UI:** the popup (send + receive), image import via Vision,
   paste, file.
5. **Windows UI:** same popup over Win32, image import via the shared
   decoder (WIC to load PNG/JPEG), paste, file; VM build and verify.

Later, not in this plan: partial codes (log since a date), a phone app,
webcam scanning, multi-part QR.
