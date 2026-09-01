// tools/read-png.js — minimal PNG reader shared by the two Aseprite importers.
// Aseprite writes 32-bit RGBA sheets; all either importer needs is the alpha,
// since the art is one colour on nothing.
'use strict';

const fs = require('fs');
const zlib = require('zlib');

function readPng(file) {
  const d = fs.readFileSync(file);
  if (d.readUInt32BE(0) !== 0x89504e47) throw new Error('not a png: ' + file);
  let pos = 8, idat = [], w = 0, h = 0, depth = 0, ctype = 0, plte = null, trns = null;
  while (pos < d.length) {
    const len = d.readUInt32BE(pos);
    const type = d.toString('ascii', pos + 4, pos + 8);
    const body = d.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      w = body.readUInt32BE(0); h = body.readUInt32BE(4);
      depth = body[8]; ctype = body[9];
    } else if (type === 'IDAT') idat.push(body);
    else if (type === 'PLTE') plte = body;
    else if (type === 'tRNS') trns = body;
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  if (depth !== 8) throw new Error('unsupported bit depth ' + depth);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ctype];
  const bpp = channels;
  const stride = w * channels;
  const rows = [];
  let prev = Buffer.alloc(stride), p = 0;

  for (let y = 0; y < h; y++) {
    const filter = raw[p++];
    const line = Buffer.from(raw.subarray(p, p + stride));
    p += stride;
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? line[i - bpp] : 0;
      const b = prev[i];
      const c = i >= bpp ? prev[i - bpp] : 0;
      if (filter === 1) line[i] = (line[i] + a) & 255;
      else if (filter === 2) line[i] = (line[i] + b) & 255;
      else if (filter === 3) line[i] = (line[i] + ((a + b) >> 1)) & 255;
      else if (filter === 4) {
        const pp = a + b - c;
        const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
        line[i] = (line[i] + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 255;
      }
    }
    rows.push(line);
    prev = line;
  }

  // alpha per pixel: everything we need, since the art is one colour on nothing
  const alpha = (x, y) => {
    const r = rows[y];
    if (ctype === 6) return r[x * 4 + 3];
    if (ctype === 4) return r[x * 2 + 1];
    if (ctype === 3) { const i = r[x]; return trns && i < trns.length ? trns[i] : 255; }
    return 255;
  };
  return { w, h, alpha };
}

module.exports = { readPng };
