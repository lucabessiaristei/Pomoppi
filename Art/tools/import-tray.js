#!/usr/bin/env node
// Imports the menu-bar animation from an .aseprite file into the
// TRAY_FRAMES block of renderer/sprites.js.
//
//   node Art/tools/import-tray.js              # the one *.aseprite in import/icon/
//   node Art/tools/import-tray.js <dir> [name]
//
// Re-run after editing the sprite in Aseprite. Sibling of
// tools/import-friends.js; same requirement, Aseprite installed to decode
// its own format.
//
// The art is 1px line work drawn small inside a 32x32 canvas, so there is no
// downscaling to do — the frames are cropped to a single window that holds all
// of them and centred in the 16x16 tray box. One shared window, not per-frame
// bounds, or the drawing would jitter between frames.
//
// Alpha is the whole story: macOS renders a tray image as a template, keeping
// only the alpha channel. Line art with a hollow interior is what makes the
// face survive that; a filled silhouette would come out a solid lozenge.

'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { readPng } = require('./read-png');

const ASEPRITE = '/Applications/Aseprite.app/Contents/MacOS/aseprite';
const DEFAULT_DIR = path.join(__dirname, '..', 'import', 'icon');
const CELL = 32;  // the source canvas
const BOX = 16;   // the macOS tray cell

function resolveName(dir, name) {
  if (name) return name;
  const found = fs.readdirSync(dir).filter((f) => f.endsWith('.aseprite'));
  if (found.length === 1) return found[0].slice(0, -'.aseprite'.length);
  if (found.length === 0) {
    console.error(`no .aseprite file in ${dir}`);
  } else {
    console.error(`multiple .aseprite files in ${dir} — pass a name: node Art/tools/import-tray.js ${dir} <name>\n` + found.join('\n'));
  }
  process.exit(1);
}

function importTray({ dir = DEFAULT_DIR, name } = {}) {
  if (!fs.existsSync(ASEPRITE)) {
    console.error('Aseprite not found at ' + ASEPRITE + '\nInstall it, or edit TRAY_FRAMES by hand.');
    process.exit(1);
  }
  const resolvedName = resolveName(dir, name);
  const src = path.join(dir, resolvedName + '.aseprite');
  if (!fs.existsSync(src)) {
    console.error('missing: ' + src);
    process.exit(1);
  }

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-tray-'));
  const sheet = path.join(tmp, resolvedName + '.png');
  execFileSync(ASEPRITE, ['-b', src, '--sheet', sheet], { stdio: 'pipe' });

  const { w, h, alpha } = readPng(sheet);
  if (h !== CELL || w % CELL !== 0) {
    console.error(`${resolvedName}: expected a ${CELL}px-tall sheet in ${CELL}px frames, got ${w}x${h}`);
    process.exit(1);
  }
  const count = w / CELL;
  const on = (f, x, y) => alpha(f * CELL + x, y) > 127;

  // One bounding box over every frame, so the frames stay registered with each other.
  let x0 = CELL, x1 = -1, y0 = CELL, y1 = -1;
  for (let f = 0; f < count; f++) {
    for (let y = 0; y < CELL; y++) {
      for (let x = 0; x < CELL; x++) {
        if (!on(f, x, y)) continue;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) { console.error(resolvedName + ': no ink in any frame'); process.exit(1); }

  const inkW = x1 - x0 + 1, inkH = y1 - y0 + 1;
  if (inkW > BOX || inkH > BOX) {
    console.error(`${resolvedName}: drawing is ${inkW}x${inkH}, too big for the ${BOX}x${BOX} tray box.`);
    process.exit(1);
  }
  const originX = x0 - Math.floor((BOX - inkW) / 2);
  const originY = y0 - Math.floor((BOX - inkH) / 2);

  const frames = [];
  for (let f = 0; f < count; f++) {
    const grid = [];
    for (let y = 0; y < BOX; y++) {
      let row = '';
      for (let x = 0; x < BOX; x++) row += on(f, originX + x, originY + y) ? '1' : '0';
      grid.push(row);
    }
    frames.push(grid);
  }
  fs.rmSync(tmp, { recursive: true, force: true });

  const block = 'const TRAY_FRAMES = [\n' + frames.map(
    (g) => '  [\n' + g.map((r) => `  "${r}",`).join('\n') + '\n],'
  ).join('\n') + '\n];';

  const dest = path.join(__dirname, '..', 'renderer', 'sprites.js');
  const before = fs.readFileSync(dest, 'utf8');
  const re = /const TRAY_FRAMES = \[[\s\S]*?\n\];/;
  if (!re.test(before)) {
    console.error('could not find the TRAY_FRAMES block in renderer/sprites.js');
    process.exit(1);
  }
  fs.writeFileSync(dest, before.replace(re, block));

  frames.forEach((g, i) => {
    const ink = g.join('').split('').filter((c) => c === '1').length;
    console.log(`  frame ${i}: ${ink} ink px`);
  });
  console.log(`\n${resolvedName}: ${count} frame(s), ${inkW}x${inkH} drawing centred in ${BOX}x${BOX}`);
  console.log('wrote renderer/sprites.js');
}

module.exports = { importTray, DEFAULT_DIR };

if (require.main === module) {
  const args = process.argv.slice(2);
  importTray({ dir: args[0] || DEFAULT_DIR, name: args[1] });
}
