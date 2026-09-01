// sprites.js — art data for Pomoppi.
//
// Every line is 1 pixel. The widget grid is 96x120 logical px drawn at scale 2.
//
// Grid legend: '.' transparent  '#' ink  'w' paper
//
// The pets are the author's own Aseprite drawings, imported into friends.js by
// tools/import-friends.js. Nothing here generates or retouches them.

const FRIEND_W = 32;
const FRIEND_H = 32;

const blank = (w, h) => Array.from({ length: h }, () => new Array(w).fill("."));

// Line art, not silhouettes: '#' is ink and '.' is clear, so the widget's paper
// shows through the middle and the drawing still reads when the canvas inverts
// as a timer rings.
//
// FRIEND_ART is the raw import (renderer/friends.js) -- exactly what
// tools/import-friends.js produced, nothing derived. FRIENDS below is built
// from it: same ids, plus squash frames for anyone drawn only once. Kept as
// two names on purpose, not one reused for both.
const FRIEND_ART = typeof module !== "undefined" && module.exports ? require("./friends.js") : window.FRIEND_ART;

function squash(grid, amount) {
	const h = grid.length,
		w = grid[0].length;
	let top = 0;
	while (top < h && !grid[top].includes("#")) top++;
	let bottom = h - 1;
	while (bottom > top && !grid[bottom].includes("#")) bottom--;
	const mid = Math.floor((top + bottom) / 2);

	const out = Array.from({ length: h }, () => new Array(w).fill("."));
	for (let y = 0; y < h; y++) {
		for (let x = 0; x < w; x++) {
			if (grid[y][x] !== "#") continue;
			const t = y < mid ? (mid - y) / Math.max(1, mid - top) : 0;
			const shift = Math.round(amount * t);
			const ny = Math.min(h - 1, y + shift);
			out[ny][x] = "#";
		}
	}
	return out.map((row) => row.join(""));
}

const FRIENDS = {};
for (const [id, pet] of Object.entries(FRIEND_ART)) {
	const drawn = pet.frames.length;
	FRIENDS[id] = {
		name: pet.name,
		frames: drawn > 1 ? pet.frames : [pet.frames[0], squash(pet.frames[0], 1), squash(pet.frames[0], 2), squash(pet.frames[0], 1)],
		drawn,
	};
}

const FRIEND_IDS = Object.keys(FRIENDS);

function frameCount(friendId) {
	return (FRIENDS[friendId] || FRIENDS[FRIEND_IDS[0]]).frames.length;
}

function frame(friendId, index) {
	const p = FRIENDS[friendId] || FRIENDS[FRIEND_IDS[0]];
	const n = p.frames.length;
	const i = Number.isFinite(index) ? index : 0;
	return p.frames[((i % n) + n) % n];
}

const ZZZ = ["###", "..#", ".#.", "#..", "###"];

// Two stages, smallest and biggest -- the middle step was dropped, and the
// biggest one's drift pulled in from its old (4, -8) to the middle step's
// old (2, -4), so the two remaining stages read as a tighter pair instead of
// a bigger single jump now that nothing smooths between them.
const ZZZ_FRAMES = [
	{ grid: ["##", ".#", "##"], dx: 0, dy: 0 },
	{ grid: ["####", "...#", "..#.", ".#..", "####"], dx: 2, dy: -4 },
];

// --- the window's own edge --------------------------------------------------

const FRAME_STYLES = ["ziggy", "scallopy", "splotchy", "wavey"];

const FRAME_AMP = 8;
const FRAME_RADIUS = 25;
const FRAME_PERIODS = { ziggy: 24, scallopy: 26, splotchy: 25, wavey: 10 };
const FRAME_PERIOD = 14;

function wave(style, t, period) {
	const p = ((t % period) + period) % period;
	if (style === "ziggy") {
		const half = period / 2;
		return FRAME_AMP * (p < half ? p / half : (period - p) / half);
	}
	if (style === "scallopy") {
		const r = period / 2;
		const dx = (p - r) / r;
		return 10 * Math.sqrt(Math.max(0, 1 - dx * dx));
	}
	if (style === "splotchy") {
		return 5 * (0.5 - 0.5 * Math.cos((p / period) * Math.PI * 2));
	}
	if (style === "wavey") {
		const half = period / 2;
		return FRAME_AMP * (p < half ? p / half : (period - p) / half);
	}
	return 0;
}

function rrProbe(px, py, w, h, r) {
	const ix = Math.min(Math.max(px, r), w - r);
	const iy = Math.min(Math.max(py, r), h - r);
	const vx = px - ix,
		vy = py - iy;
	const dist = Math.hypot(vx, vy);

	const sw = w - 2 * r,
		sh = h - 2 * r,
		arc = (Math.PI / 2) * r;
	const cxOut = px < r ? -1 : px > w - r ? 1 : 0;
	const cyOut = py < r ? -1 : py > h - r ? 1 : 0;

	let seg, t, s;
	if (cxOut !== 0 && cyOut !== 0) {
		const a = Math.atan2(vy, vx);
		const q = (a + 2 * Math.PI) % (2 * Math.PI);
		if (cxOut > 0 && cyOut < 0) {
			seg = 1;
			t = ((q - 1.5 * Math.PI) / (Math.PI / 2)) * arc;
			s = sw + t;
		} else if (cxOut > 0) {
			seg = 3;
			t = (q / (Math.PI / 2)) * arc;
			s = sw + arc + sh + t;
		} else if (cyOut > 0) {
			seg = 5;
			t = ((q - Math.PI / 2) / (Math.PI / 2)) * arc;
			s = 2 * sw + 2 * arc + sh + t;
		} else {
			seg = 7;
			t = ((q - Math.PI) / (Math.PI / 2)) * arc;
			s = 2 * sw + 3 * arc + 2 * sh + t;
		}
	} else if (cyOut < 0) {
		seg = 0;
		t = px - r;
		s = t;
	} else if (cxOut > 0) {
		seg = 2;
		t = py - r;
		s = sw + arc + t;
	} else if (cyOut > 0) {
		seg = 4;
		t = w - r - px;
		s = 2 * sw + 2 * arc + sh + t;
	} else if (cxOut < 0) {
		seg = 6;
		t = h - r - py;
		s = 2 * sw + 3 * arc + 2 * sh + t;
	} else {
		seg = 0;
		t = px - r;
		s = t;
	}

	return { d: dist - r, s, seg, t };
}

const frameCache = new Map();

function windowFrame(style, w, h) {
	const key = style + ":" + w + "x" + h;
	if (frameCache.has(key)) return frameCache.get(key);

	const amp = style === "scallopy" ? 10 : FRAME_AMP;

	const r = style === "scallopy" ? 32
        : style === "splotchy"   ? 25 
        : style === "wavey"      ? 25 
        : FRAME_RADIUS;
        
	const bw = w - 1 - 2 * amp,
		bh = h - 1 - 2 * amp;

	const wanted = FRAME_PERIODS[style] || FRAME_PERIOD;

	// Adatta i periodi segmento per segmento
	const segLen = (function () {
		const sw = bw - 2 * r,
			sh = bh - 2 * r,
			arc = (Math.PI / 2) * r;
		return [sw, arc, sh, arc, sw, arc, sh, arc];
	})();
	
	const segPeriod = segLen.map(function (len) {
		return len / Math.max(1, Math.round(len / wanted));
	});

	const inside = [];
	for (let y = 0; y < h; y++) {
		const row = new Array(w);
		for (let x = 0; x < w; x++) {
			const probe = rrProbe(x - amp, y - amp, bw, bh, r);
			// Calcola l'onda relazionandola rigorosamente al segmento corrente
			const out = wave(style, probe.t, segPeriod[probe.seg]);
			row[x] = probe.d <= out;
		}
		inside.push(row);
	}

	const g = blank(w, h);
	for (let y = 0; y < h; y++) {
		for (let x = 0; x < w; x++) {
			if (!inside[y][x]) continue;
			const edge = x === 0 || y === 0 || x === w - 1 || y === h - 1 || !inside[y][x - 1] || !inside[y][x + 1] || !inside[y - 1][x] || !inside[y + 1][x];
			g[y][x] = edge ? "#" : "w";
		}
	}

	const out = g.map((row) => row.join(""));
	frameCache.set(key, out);
	return out;
}

// --- 7x11 seven-segment digits ---------------------------------------------

const GLYPH_W = 7;
const GLYPH_H = 11;
const DIGIT_GAP = 2;

const SEGMENTS = {
	0: [1, 1, 1, 0, 1, 1, 1],
	1: [0, 0, 1, 0, 0, 1, 0],
	2: [1, 0, 1, 1, 1, 0, 1],
	3: [1, 0, 1, 1, 0, 1, 1],
	4: [0, 1, 1, 1, 0, 1, 0],
	5: [1, 1, 0, 1, 0, 1, 1],
	6: [1, 1, 0, 1, 1, 1, 1],
	7: [1, 0, 1, 0, 0, 1, 0],
	8: [1, 1, 1, 1, 1, 1, 1],
	9: [1, 1, 1, 1, 0, 1, 1],
};

function segmentGlyph(segs) {
	const g = blank(GLYPH_W, GLYPH_H).map((r) => r.fill("0"));
	const [top, tl, tr, mid, bl, br, bot] = segs;
	const H = (y) => {
		for (let x = 1; x <= GLYPH_W - 2; x++) g[y][x] = "1";
	};
	const V = (x, y0, y1) => {
		for (let y = y0; y <= y1; y++) g[y][x] = "1";
	};
	if (top) H(0);
	if (mid) H(5);
	if (bot) H(10);
	if (tl) V(0, 1, 4);
	if (tr) V(GLYPH_W - 1, 1, 4);
	if (bl) V(0, 6, 9);
	if (br) V(GLYPH_W - 1, 6, 9);
	return g.map((r) => r.join(""));
}

const GLYPHS = {};
for (const [ch, segs] of Object.entries(SEGMENTS)) GLYPHS[ch] = segmentGlyph(segs);
GLYPHS[":"] = ["00", "00", "11", "11", "00", "00", "00", "11", "11", "00", "00"];
GLYPHS[" "] = Array.from({ length: GLYPH_H }, () => "000");

// --- 16x16 controls ---------------------------------------------------------

// Icon cells are exactly the widget button box (SPEC.md §3), so an icon is
// drawn at the box origin with no inset. Ink must stay within cols/rows 1..11:
// row/col 0 and 12 are where the hover border draws and the press inversion
// ends, so ink out there reads as merged with the box.
const ICON_SIZE = 13;

const ICONS = {
	play: [
		"0000000000000",
		"0000000000000",
		"0000000000000",
		"0001100000000",
		"0001111000000",
		"0001111110000",
		"0001111111100",
		"0001111110000",
		"0001111000000",
		"0001100000000",
		"0000000000000",
		"0000000000000",
		"0000000000000",
	],
	pause: [
		"0000000000000",
		"0000000000000",
		"0000000000000",
		"0001100011000",
		"0001100011000",
		"0001100011000",
		"0001100011000",
		"0001100011000",
		"0001100011000",
		"0001100011000",
		"0000000000000",
		"0000000000000",
		"0000000000000",
	],
	reset: [
		"0000000000000",
		"0000000000000",
		"0000000000000",
		"0001100001000",
		"0001100011000",
		"0001100111000",
		"0001101111000",
		"0001100111000",
		"0001100011000",
		"0001100001000",
		"0000000000000",
		"0000000000000",
		"0000000000000",
	],
	skip: [
		"0000000000000",
		"0000000000000",
		"0000000000000",
		"0001000011000",
		"0001100011000",
		"0001110011000",
		"0001111011000",
		"0001110011000",
		"0001100011000",
		"0001000011000",
		"0000000000000",
		"0000000000000",
		"0000000000000",
	],
	heart: [
		"0000000000000",
		"0000000000000",
		"0000000000000",
		"0000100010000",
		"0001110111000",
		"0001111111000",
		"0001111111000",
		"0000111110000",
		"0000011100000",
		"0000001000000",
		"0000000000000",
		"0000000000000",
		"0000000000000",
	],
};

function soften(grid) {
	const h = grid.length,
		w = grid[0].length;
	const on = (x, y) => (x < 0 || y < 0 || x >= w || y >= h ? false : grid[y][x] === "1");
	const corners = [
		[-1, -1, 1, 1],
		[1, -1, -1, 1],
		[-1, 1, 1, -1],
		[1, 1, -1, -1],
	];
	return grid.map((row, y) =>
		row
			.split("")
			.map((ch, x) => {
				if (ch !== "1") return "0";
				for (const [ox, oy, ix, iy] of corners) {
					if (!on(x + ox, y) && !on(x, y + oy) && on(x + ix, y) && on(x, y + iy) && on(x + ix, y + iy)) return "0";
				}
				return "1";
			})
			.join(""),
	);
}

// Menu-bar art, 16x16 — the system's cell, not a widget button box, so it is
// deliberately not ICON_SIZE.
//
// GENERATED by tools/import-tray.js from Tasukippi.aseprite: `npm run tray`,
// then `npm run icons` to write the PNGs main.js loads. Every frame the artist
// drew comes through, cropped to one shared window so they stay registered with
// each other, and main.js cycles them evenly — the frame count lives in the
// art and nowhere else. Do not hand-edit; redraw in Aseprite and re-import.
//
// Line art with a hollow interior is not a style choice here: macOS renders a
// tray image as a template and keeps only its alpha, so a filled silhouette
// would come out a solid lozenge with no face.
const TRAY_FRAMES = [
  [
  "0000000000000000",
  "0000000000000000",
  "0001111111100000",
  "0010000000010000",
  "0100000000010000",
  "0100010001001000",
  "0100000110001000",
  "0100000000001000",
  "0100000000001000",
  "0100000000001000",
  "0100000000001000",
  "0010000000010000",
  "0001111111100000",
  "0000000000000000",
  "0000000000000000",
  "0000000000000000",
],
  [
  "0000000000000000",
  "0000000000000000",
  "0001111111000000",
  "0010000000110000",
  "0100000000001000",
  "0100000000001000",
  "0100001000101000",
  "0100000011001000",
  "0100000000001000",
  "0100000000001000",
  "0100000000001000",
  "0010000000010000",
  "0001111111100000",
  "0000000000000000",
  "0000000000000000",
  "0000000000000000",
],
  [
  "0000000000000000",
  "0000000000000000",
  "0000000000000000",
  "0001111110000000",
  "0010000001110000",
  "0100000000001000",
  "0100000000001000",
  "0100001000100100",
  "0100000011000100",
  "0100000000000100",
  "0100000000001000",
  "0010000000001000",
  "0001111111110000",
  "0000000000000000",
  "0000000000000000",
  "0000000000000000",
],
];

// Frame 0 under its old name, for everything that just wants "the tray icon".
const TRAY = TRAY_FRAMES[0];

const SPRITES = {
	FRIEND_W,
	FRIEND_H,
	FRIENDS,
	FRIEND_IDS,
	frame,
	frameCount,
	ZZZ,
	ZZZ_FRAMES,
	FRAME_STYLES,
	FRAME_AMP,
	FRAME_RADIUS,
	FRAME_PERIOD,
	windowFrame,
	GLYPH_W,
	GLYPH_H,
	DIGIT_GAP,
	GLYPHS,
	ICON_SIZE,
	ICONS,
	TRAY,
	TRAY_FRAMES,
};

if (typeof module !== "undefined" && module.exports) module.exports = SPRITES;
if (typeof window !== "undefined") window.SPRITES = SPRITES;