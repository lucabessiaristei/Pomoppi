// tools/make-icons.js — generates assets/*.png from renderer/sprites.js
// grids, using only 'zlib' and 'fs' (SPEC.md §10). Hand-rolled PNG encoder:
// no image libraries, including no reliance on Node's zlib.crc32 (added only
// in newer Node releases) — CRC32 is computed with a splotchy JS table here.
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const SPRITES = require('../renderer/sprites');
const { TRAY_FRAMES, FRIEND_IDS } = SPRITES;
const DEFAULT_FRIEND = FRIEND_IDS[0];

const INK = [0, 0, 0];
const PAPER = [255, 255, 255];
const BLUSH = [200, 200, 200];

const ASSETS_DIR = path.join(__dirname, '..', 'assets');
const SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBuf = Buffer.from(type, 'ascii');
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(data.length, 0);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([lenBuf, typeBuf, data, crcBuf]);
}

// getPixel(x, y) -> [r, g, b, a]. Always encodes 8-bit RGBA (color type 6).
function encodePNG(width, height, getPixel) {
  const stride = 1 + width * 4;
  const raw = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const rowStart = y * stride;
    raw[rowStart] = 0; // filter: None
    for (let x = 0; x < width; x++) {
      const [r, g, b, a] = getPixel(x, y);
      const offset = rowStart + 1 + x * 4;
      raw[offset] = r;
      raw[offset + 1] = g;
      raw[offset + 2] = b;
      raw[offset + 3] = a;
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // color type: RGBA
  ihdr[10] = 0; // compression method
  ihdr[11] = 0; // filter method
  ihdr[12] = 0; // interlace method

  const idat = zlib.deflateSync(raw);

  return Buffer.concat([
    SIGNATURE,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

function trayPixel(grid, x, y) {
  return grid[y][x] === '1' ? [...INK, 255] : [0, 0, 0, 0];
}

function charPixel(grid, x, y) {
  const ch = grid[y][x];
  if (ch === '#') return [...INK, 255];
  if (ch === 'g') return [...BLUSH, 255];
  return [...PAPER, 255]; // 'w' and transparent '.' both flatten to white background
}

// One PNG pair per tray animation frame. Add a frame to SPRITES.TRAY_FRAMES and
// it lands here on the next run; main.js loads whatever it finds, so the frame
// count lives in the art and nowhere else.
function writeTrayIcons() {
  const scale = 2;
  const written = [];
  TRAY_FRAMES.forEach((grid, i) => {
    const size = grid.length;
    const base = `trayTemplate-${i}`;
    fs.writeFileSync(
      path.join(ASSETS_DIR, `${base}.png`),
      encodePNG(size, size, (x, y) => trayPixel(grid, x, y))
    );
    fs.writeFileSync(
      path.join(ASSETS_DIR, `${base}@2x.png`),
      encodePNG(size * scale, size * scale, (x, y) =>
        trayPixel(grid, Math.floor(x / scale), Math.floor(y / scale)))
    );
    written.push(`${base}.png`, `${base}@2x.png`);
  });
  return written;
}

function writeAppIcon() {
  const grid = SPRITES.frame(DEFAULT_FRIEND, 0);
  const srcHeight = grid.length;
  const srcWidth = grid[0].length;
  const destSize = 512;
  const png = encodePNG(destSize, destSize, (x, y) => {
    const sx = Math.min(srcWidth - 1, Math.floor((x * srcWidth) / destSize));
    const sy = Math.min(srcHeight - 1, Math.floor((y * srcHeight) / destSize));
    return charPixel(grid, sx, sy);
  });
  fs.writeFileSync(path.join(ASSETS_DIR, 'icon.png'), png);
}

fs.mkdirSync(ASSETS_DIR, { recursive: true });
const trayFiles = writeTrayIcons();
writeAppIcon();
console.log('Wrote ' + [...trayFiles, 'icon.png'].map((f) => 'assets/' + f).join(', '));
