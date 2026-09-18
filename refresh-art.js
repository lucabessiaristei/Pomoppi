#!/usr/bin/env node
// refresh-art.js — the one command that keeps the app's art in sync with its
// sources: re-imports .aseprite files (friends / backgrounds / tray icon)
// into Art/renderer/*.js, then regenerates
// Sources/PomoppiSprites/Sprites.generated.swift from them.
//
//   node refresh-art                     # everything (default)
//   node refresh-art --all                # same, explicit
//   node refresh-art --friends             # just Art/import/friends/
//   node refresh-art --bgs                 # just Art/import/bgs/
//   node refresh-art --icon                # just Art/import/icon/
//   node refresh-art --friends --icon       # any combination
//   node refresh-art --rebuild              # also rebuild + reinstall /Applications/Pomoppi.app
//
// Sprites.generated.swift is always rewritten last, regardless of which
// import(s) ran, so it's never left stale relative to Art/renderer/*.js. Art
// changes are compiled into the binary (there's no runtime asset loading), so
// without --rebuild the installed app keeps showing the old art — --rebuild
// runs Scripts/make-app.js, the actual release build + reinstall, not just
// `swift build` (which only touches the debug binary under .build/, not
// /Applications/Pomoppi.app).
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const { importFriends } = require('./Art/tools/import-friends');
const { importBgs } = require('./Art/tools/import-bgs');
const { importTray } = require('./Art/tools/import-tray');

const CATEGORIES = ['friends', 'bgs', 'icon'];
const KNOWN_FLAGS = ['all', 'rebuild', ...CATEGORIES];

const requested = process.argv.slice(2).map((a) => {
  if (!a.startsWith('--')) {
    console.error(`unrecognized argument "${a}" (expected one of ${KNOWN_FLAGS.map((f) => '--' + f).join(', ')})`);
    process.exit(1);
  }
  return a.slice(2);
});
for (const flag of requested) {
  if (!KNOWN_FLAGS.includes(flag)) {
    console.error(`unknown flag --${flag} (expected one of ${KNOWN_FLAGS.map((f) => '--' + f).join(', ')})`);
    process.exit(1);
  }
}
const rebuild = requested.includes('rebuild');
const categoryFlags = requested.filter((f) => f !== 'rebuild');
const targets = categoryFlags.length === 0 || categoryFlags.includes('all') ? CATEGORIES : categoryFlags;

const DEFAULT_FRIEND_ID = 'namidappi';
const DEFAULT_BACKGROUND_ID = 'scacchi';

if (targets.includes('friends')) syncIDs('friendIDs', importFriends(), DEFAULT_FRIEND_ID);
if (targets.includes('bgs')) syncIDs('backgroundIDs', importBgs(), DEFAULT_BACKGROUND_ID);
if (targets.includes('icon')) importTray();

// --- keep Sources/PomoppiCore/Settings.swift's roster arrays in sync -------
//
// friendIDs/backgroundIDs are hand-written Swift (PomoppiCore intentionally
// has no dependency on PomoppiSprites — see the comment above them), but
// their membership shouldn't require a manual edit every time a friend or
// background is added or removed under Art/import/. So the roster itself
// stays text-derived from the _ok filenames (import-friends.js's /
// import-bgs.js's job), and this step regex-rewrites just the one array
// literal to match — same trick import-tray.js already uses on TRAY_FRAMES
// in sprites.js.
function syncIDs(fieldName, ids, defaultID) {
  const ordered = ids.includes(defaultID)
    ? [defaultID, ...ids.filter((id) => id !== defaultID).sort()]
    : [...ids].sort();

  const dest = path.join(__dirname, 'Sources/PomoppiCore/Settings.swift');
  const before = fs.readFileSync(dest, 'utf8');
  const re = new RegExp(`^(\\s*)public static let ${fieldName} = \\[[^\\]]*\\]`, 'm');
  const match = before.match(re);
  if (!match) {
    console.error(`could not find "public static let ${fieldName} = [...]" in Settings.swift`);
    process.exit(1);
  }

  const previous = [...match[0].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  const added = ordered.filter((id) => !previous.includes(id));
  const removed = previous.filter((id) => !ordered.includes(id));

  const line = `${match[1]}public static let ${fieldName} = [${ordered.map((id) => JSON.stringify(id)).join(', ')}]`;
  if (line !== match[0]) {
    fs.writeFileSync(dest, before.replace(re, line));
    console.log(`\nSettings.swift ${fieldName}: ${added.length ? '+' + added.join(', +') + ' ' : ''}${removed.length ? '-' + removed.join(', -') : ''}`.trim());
  }
}

// --- regenerate Sources/PomoppiSprites/Sprites.generated.swift -------------
//
// Always reads the live Art/renderer/*.js files, never hand-transcribed
// data, so this step runs the same whether or not an import ran above.
//
// Only what Phase 1 renders ships here: the 5 button icons, the ZZZ
// break-sleep frames, one default friend's frames, and one default
// background's pattern. To widen the roster later, add ids to
// FRIEND_IDS_TO_EXPORT / BACKGROUND_IDS_TO_EXPORT below.

const SPRITES = require(path.join(__dirname, 'Art/renderer/sprites.js'));
const { BACKGROUNDS, BACKGROUND_IDS } = require(path.join(__dirname, 'Art/renderer/background.js'));

const FRIEND_IDS_TO_EXPORT = SPRITES.FRIEND_IDS;
const BACKGROUND_IDS_TO_EXPORT = BACKGROUND_IDS;

for (const id of FRIEND_IDS_TO_EXPORT) {
  if (!SPRITES.FRIENDS[id]) throw new Error(`Unknown friend id: ${id}`);
}
for (const id of BACKGROUND_IDS_TO_EXPORT) {
  if (!BACKGROUNDS[id]) throw new Error(`Unknown background id: ${id}`);
}

function swiftStringLiteral(str) {
  return JSON.stringify(str);
}

function swiftStringArray(rows, indent) {
  const pad = '    '.repeat(indent);
  const items = rows.map((r) => pad + '    ' + swiftStringLiteral(r)).join(',\n');
  return `[\n${items}\n${pad}]`;
}

function swiftStringArrayOfArrays(arrays, indent) {
  const pad = '    '.repeat(indent);
  const items = arrays.map((rows) => pad + '    ' + swiftStringArray(rows, indent + 1)).join(',\n');
  return `[\n${items}\n${pad}]`;
}

const iconEntries = Object.entries(SPRITES.ICONS)
  .map(([name, rows]) => `        ${swiftStringLiteral(name)}: ${swiftStringArray(rows, 2)},`)
  .join('\n');

const zzzFrameEntries = SPRITES.ZZZ_FRAMES
  .map((f) => `        ZzzFrame(grid: ${swiftStringArray(f.grid, 2)}, dx: ${f.dx}, dy: ${f.dy}),`)
  .join('\n');

const friendEntries = FRIEND_IDS_TO_EXPORT
  .map((id) => `        ${swiftStringLiteral(id)}: ${swiftStringArrayOfArrays(SPRITES.FRIENDS[id].frames, 2)},`)
  .join('\n');

const backgroundEntries = BACKGROUND_IDS_TO_EXPORT
  .map((id) => `        ${swiftStringLiteral(id)}: ${swiftStringArray(BACKGROUNDS[id].pattern, 2)},`)
  .join('\n');

const trayFrameEntries = SPRITES.TRAY_FRAMES
  .map((frame) => `        ${swiftStringArray(frame, 2)},`)
  .join('\n');

const output = `// Sprites.generated.swift — GENERATED by refresh-art.js.
// Do not hand-edit. Source: Art/renderer/sprites.js,
// Art/renderer/friends.js, Art/renderer/background.js.
// Re-run \`node refresh-art\` after those change.
public enum GeneratedSprites {
    public static let iconSize = ${SPRITES.ICON_SIZE}
    public static let icons: [String: [String]] = [
${iconEntries}
    ]

    public struct ZzzFrame {
        public let grid: [String]
        public let dx: Int
        public let dy: Int
    }
    public static let zzz: [String] = ${swiftStringArray(SPRITES.ZZZ, 1)}
    public static let zzzFrames: [ZzzFrame] = [
${zzzFrameEntries}
    ]

    public static let friendWidth = ${SPRITES.FRIEND_W}
    public static let friendHeight = ${SPRITES.FRIEND_H}
    public static let defaultFriendID = ${swiftStringLiteral(DEFAULT_FRIEND_ID)}
    // [friend id: frames], each frame ${SPRITES.FRIEND_H} rows of ${SPRITES.FRIEND_W} characters.
    public static let friendFrames: [String: [[String]]] = [
${friendEntries}
    ]

    public static let defaultBackgroundID = ${swiftStringLiteral(DEFAULT_BACKGROUND_ID)}
    public static let backgroundPatterns: [String: [String]] = [
${backgroundEntries}
    ]

    // Menu-bar art, 16x16, '1'/'0' grids like icons above. One entry per
    // renderer/sprites.js TRAY_FRAMES element; the tray animates by cycling
    // through them (see TrayController).
    public static let trayFrames: [[String]] = [
${trayFrameEntries}
    ]
}
`;

const outPath = path.join(__dirname, 'Sources/PomoppiSprites/Sprites.generated.swift');
fs.writeFileSync(outPath, output);
console.log(`wrote ${outPath}`);

if (rebuild) {
  console.log('\n$ node Scripts/make-app.js');
  try {
    execFileSync('node', ['Scripts/make-app.js'], { cwd: __dirname, stdio: 'inherit' });
  } catch (err) {
    process.exit(err.status || 1);
  }
}
