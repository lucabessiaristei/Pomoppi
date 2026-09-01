// Main widget logic: rendering, animations, interactions
// Wrapped in an IIFE: sprites.js is a classic script, so its top-level
// `const` vars live in the shared global scope and would collide.
(function () {
'use strict';

const { frame, frameCount, ZZZ, GLYPHS, ICONS, ICON_SIZE, GLYPH_W, GLYPH_H,
        DIGIT_GAP, FRIEND_W, FRIEND_H, windowFrame } = window.SPRITES;
const BACKGROUNDS = window.BACKGROUNDS;
const BACKGROUND_IDS = window.BACKGROUND_IDS;

const CANVAS_W = 118;
const CANVAS_H = 132;
const FRAME_W = 110;
const FRAME_H = 124;
const FRAME_X = 4;
const FRAME_Y = 4;
const FRIEND_SIZE = 32;
const FRIEND_X = centreX(FRIEND_SIZE);
const FRIEND_Y = 22;
const TIME_Y = 61;
const TIME_SCALE = 1;
const PROGRESS_Y = 87;
const PROGRESS_X = 25;
const PROGRESS_W = 68;
const PROGRESS_H = 7;
const CYCLE_DOTS_Y = 77;

// settings.petMovement: the pet ambles back and forth instead of sitting at
// FRIEND_X. Bounded to the progress bar's own x-span so it never wanders
// outside the card's established horizontal rhythm (see updateAnimations()
// and petPosition() below). WANDER_EDGE_INSET is the one knob for how far
// inside that span it stays: 0 walks the pet flush to the bar's own edges,
// a bigger number pulls both ends in by that many px.
const WANDER_EDGE_INSET = 5;
const WANDER_MIN_X = PROGRESS_X + WANDER_EDGE_INSET;
const WANDER_MAX_X = PROGRESS_X + PROGRESS_W - FRIEND_SIZE - WANDER_EDGE_INSET;

// The walk is mechanical, not eased: position only advances when the
// friend's own sprite frame changes (see friendFrameIndex() below), the way
// an old Tamagotchi's few-pixel walk cycle steps in lockstep with its pose
// changes instead of sliding smoothly. Two knobs to taste:
// WANDER_STEP_PX -- how far it steps sideways on each frame change.
// WANDER_STEP_HEIGHT_PX -- how far it toggles up/down each step (0 = flat).
const WANDER_STEP_PX = 1;
const WANDER_STEP_HEIGHT_PX = 1;

const DOT_MIN = 2;
const DOT_MAX = 10;
const DOT_SIZE = 5;
const DOT_GAP = 2;
const DOT_PITCH = DOT_SIZE + DOT_GAP;
const STEP_SIZE = 5;
const STEP_BOX_PAD = 1;
const STEP_BOX = STEP_SIZE + STEP_BOX_PAD * 2;
// The only steppers left are the clock's; the dot row lost its -/+ pair and is
// now sized purely by longBreakEvery. Flush with the progress bar's ends.
const CLOCK_MINUS_X = PROGRESS_X;
const CLOCK_PLUS_X = PROGRESS_X + PROGRESS_W - STEP_SIZE;
const MINUTE_STEP = 60;
const FOCUS_MIN = 60;
const FOCUS_MAX = 5400;

const BUTTONS_Y = 96;
const BUTTON_SIZE = ICON_SIZE;
const BUTTON_COUNT = 4;
const BUTTON_ROW_X = PROGRESS_X;
const BUTTON_ROW_W = PROGRESS_W;

// One centring rule for every horizontally-centred element, so they all land on
// the same axis and an odd width always leans the same way. CANVAS_W is even,
// which is what keeps the even-width pieces (frame, bar, buttons, time, pet)
// exact; an odd dot count is the only thing that can't sit dead centre.
function centreX(w) {
  return Math.floor((CANVAS_W - w) / 2);
}

// Four 13px boxes inside the bar's 68px leave 16px of gap across 3 slots, which
// does not divide evenly. Rounding the *running* offset rather than each gap
// keeps every box on a whole pixel, pins the last one to the bar's right edge
// exactly, and spreads the remainder across the row instead of piling it up at
// one end — here that gives 5, 6, 5, symmetric about the axis.
function buttonPositions() {
  const slack = BUTTON_ROW_W - BUTTON_COUNT * BUTTON_SIZE;
  const gaps = BUTTON_COUNT - 1;
  const xs = [];
  for (let i = 0; i < BUTTON_COUNT; i++) {
    xs.push(BUTTON_ROW_X + i * BUTTON_SIZE + Math.round((i * slack) / gaps));
  }
  return xs;
}

function dotCount() {
  const n = (settings && settings.longBreakEvery) || 4;
  return Math.max(DOT_MIN, Math.min(DOT_MAX, Math.round(n)));
}

function dotGeometry() {
  const cycleLen = dotCount();
  const w = cycleLen * DOT_SIZE + (cycleLen - 1) * DOT_GAP;
  return { count: cycleLen, w, x: centreX(w) };
}

function dotSlotAt(lx) {
  if (!settings) return -1;
  const { count: cycleLen, x: dotsX } = dotGeometry();
  const rel = lx - dotsX;
  if (rel < 0) return -1;
  const i = Math.floor(rel / DOT_PITCH);
  if (i < 0 || i >= cycleLen) return -1;
  return rel % DOT_PITCH < DOT_SIZE ? i : -1;
}

function stepperHit(lx, ly, x, y) {
  return lx >= x - 3 && lx < x + STEP_SIZE + 3 &&
         ly >= y - 3 && ly < y + STEP_SIZE + 3;
}

function clockSteppers() {
  const y = TIME_Y + Math.floor((GLYPH_H - STEP_SIZE) / 2);
  return { y, minusX: CLOCK_MINUS_X, plusX: CLOCK_PLUS_X };
}

function clockSteppersVisible() {
  return !!(state && state.phase === 'idle' && !state.running);
}

let canvas = document.getElementById('canvas');
let ctx = canvas.getContext('2d');

let state = null;
let settings = null;
let scale = 2;

let shakeOffset = 0;
let shakeTime = 0;
let ringTime = 0;
let animClock = 0;
let animationTime = 0;
let rafId = null;
let dirty = false;

let zFrameIndex = 0;
let zFrameTime = 0;

// settings.petMovement (see updateAnimations()/petPosition() below).
// wanderX null = not placed yet; first tick with petMovement on plants it
// at WANDER_MIN_X. wanderDir: 1 = walking right (mirrored), -1 = walking
// left (native art orientation). wanderFrameIndex is the last friend frame
// index seen, so a step fires exactly once per pose change, not per tick.
let wanderX = null;
let wanderDir = 1;
let wanderUp = true;
let wanderFrameIndex = null;

let audioContext = null;

let hoveredButton = null;
let pressedButton = null;
let hoveredRegion = null;
let pressedRegion = null;

let dragStartX = 0;
let dragStartY = 0;
let lastDragX = 0;
let lastDragY = 0;
let lastDragScreenX = 0;
let lastDragScreenY = 0;
let isDragging = false;
let pointerCaptured = false;

function isBreak() {
  return state.phase === 'shortBreak' || state.phase === 'longBreak';
}

function isAnimating() {
  if (!state) return false;
  return state.ringing || state.running || state.phase === 'idle';
}

function isInverted() {
  return !!(state && state.ringing && Math.floor(ringTime / 300) % 2 === 1);
}

function updateAnimations(dt) {
  animClock += dt;

  if (state && state.ringing) {
    shakeTime = (shakeTime + dt) % 320;
    if (shakeTime < 80) shakeOffset = -1;
    else if (shakeTime < 160) shakeOffset = 0;
    else if (shakeTime < 240) shakeOffset = 1;
    else shakeOffset = 0;
    ringTime += dt;
  } else {
    shakeOffset = 0;
    shakeTime = 0;
    ringTime = 0;
  }

  if (isBreak()) {
    zFrameTime += dt;
    if (window.SPRITES && window.SPRITES.ZZZ_FRAMES) {
      zFrameIndex = Math.floor(zFrameTime / 500) % window.SPRITES.ZZZ_FRAMES.length;
    }
  } else {
    zFrameTime = 0;
    zFrameIndex = 0;
  }

  // settings.petMovement: step once per friend pose change, not per tick --
  // see the WANDER_* consts above. wanderFrameIndex always tracks the
  // current pose (even with movement off) so turning it on mid-session
  // never fires a backlog of steps from a stale comparison. Suppressed
  // during a break: asleep, the friend just breathes on the spot like
  // before wandering existed (see petPosition()) -- it resumes walking
  // from wherever it left off once focus starts again.
  if (state) {
    const idx = friendFrameIndex();
    if (settings && settings.petMovement && !isBreak()) {
      if (wanderX === null) wanderX = WANDER_MIN_X;
      if (wanderFrameIndex !== null && idx !== wanderFrameIndex) {
        let next = wanderX + wanderDir * WANDER_STEP_PX;
        if (next >= WANDER_MAX_X) { next = WANDER_MAX_X; wanderDir = -1; }
        else if (next <= WANDER_MIN_X) { next = WANDER_MIN_X; wanderDir = 1; }
        wanderX = next;
        wanderUp = !wanderUp;
      }
    }
    wanderFrameIndex = idx;
  }
}

function friendFrameIndex() {
  if (state.ringing) return Math.floor(ringTime / 150);
  if (state.phase === 'idle') return Math.floor(animClock / 520);
  if (!state.running) return 0;
  return Math.floor(animClock / (isBreak() ? 900 : 340));
}

function getFriendFrame() {
  const id = settings && settings.friend;
  return frame(id, friendFrameIndex());
}

// Flips a sprite grid left-right by reversing each row -- plain string
// reversal, not a canvas transform, so it can never land a pixel off-grid.
function mirrorGridH(grid) {
  return grid.map((row) => row.split('').reverse().join(''));
}

// Where the pet draws this frame. Off (the default), before the first step
// has landed, or asleep on a break: always FRIEND_X/FRIEND_Y, unmirrored --
// identical to the pre-wander layout, so a break reads the same "breathing
// on the spot" way it always did. Otherwise wherever updateAnimations() last
// stepped it to. Friend art (renderer/sprites.js) is drawn facing left
// natively, so only the rightward leg (wanderDir === 1) needs flipping to
// face the way it's walking.
function petPosition() {
  if (!settings || !settings.petMovement || !state || wanderX === null || isBreak()) {
    return { x: FRIEND_X, y: FRIEND_Y, mirrored: false };
  }
  return {
    x: wanderX,
    y: FRIEND_Y - (wanderUp ? WANDER_STEP_HEIGHT_PX : 0),
    mirrored: wanderDir === 1,
  };
}

function formatTime(ms) {
  const totalSeconds = Math.max(0, Math.ceil(ms / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

// reset - play/pause - skip - heart. Reset and skip are their own buttons now
// rather than one slot that swapped icon by phase: skip ends whatever is
// running, in either direction, so it no longer needs to hide during focus.
function buttonLayout() {
  const xs = buttonPositions();
  return [
    { x: xs[0], id: 'reset', icon: ICONS.reset },
    { x: xs[1], id: 'play', icon: state.running ? ICONS.pause : ICONS.play },
    { x: xs[2], id: 'skip', icon: ICONS.skip },
    { x: xs[3], id: 'settings', icon: ICONS.heart },
  ];
}

// hex <-> rgb and mixing, for the one derived colour drawCanvas needs (the
// background pattern, at 20% ink over paper). Own copy, same as
// settings.js's — no bundler, no shared module between the two pages.
function hexToRgb(hex) {
  const h = hex.replace('#', '');
  const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
  const n = parseInt(full, 16) || 0;
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

function mixHex(base, tint, amount) {
  const a = hexToRgb(base);
  const b = hexToRgb(tint);
  const toHex = (c) => Math.round(Math.min(255, Math.max(0, c))).toString(16).padStart(2, '0');
  return '#' + [
    a.r + (b.r - a.r) * amount,
    a.g + (b.g - a.g) * amount,
    a.b + (b.b - a.b) * amount,
  ].map(toHex).join('').toUpperCase();
}

function drawCanvas() {
  if (!state || !settings) return;

  const inv = isInverted();
  const themeInk = settings.inkColor || '#000000';
  const themePaper = settings.paperColor || '#FFFFFF';
  const ink = inv ? themePaper : themeInk;
  const paper = inv ? themeInk : themePaper;

  const frameStyle = settings.frameStyle || 'scallopy';
  const frameGrid = windowFrame(frameStyle, FRAME_W, FRAME_H);
  Draw.drawGrid(ctx, frameGrid, FRAME_X, FRAME_Y, { '#': ink, 'w': paper, '.': '.' });

  // Pattern lives inside the card only, masked pixel-by-pixel against the
  // frame's own interior ('w') cells so it's cropped to the frame's shape
  // (rounded corners, scallops/zigzags and all) instead of a plain rectangle.
  const bgId = (BACKGROUND_IDS && BACKGROUND_IDS.includes(settings.background))
    ? settings.background
    : (BACKGROUND_IDS && BACKGROUND_IDS[0]);
  const background = BACKGROUNDS && bgId ? BACKGROUNDS[bgId] : null;
  if (background) {
    const pattern = background.pattern;
    const bgColor = mixHex(paper, ink, 0.3);
    for (let y = 0; y < pattern.length; y++) {
      const row = pattern[y];
      const frameRow = frameGrid[y - FRAME_Y];
      if (!frameRow) continue;
      for (let x = 0; x < row.length; x++) {
        if (row[x] !== '#') continue;
        if (frameRow[x - FRAME_X] !== 'w') continue;
        Draw.fillRect(ctx, x, y, 1, 1, bgColor);
      }
    }
  }

  const pet = petPosition();
  const petFrame = pet.mirrored ? mirrorGridH(getFriendFrame()) : getFriendFrame();
  Draw.drawGrid(ctx, petFrame, pet.x + shakeOffset, pet.y,
                { '#': ink, 'w': paper });

  if (isBreak()) {
    if (window.SPRITES && window.SPRITES.ZZZ_FRAMES && window.SPRITES.ZZZ_FRAMES[zFrameIndex]) {
      const zzzFrame = window.SPRITES.ZZZ_FRAMES[zFrameIndex];
      const zx = 79 + (zzzFrame.dx || 0);
      const zy = FRIEND_Y + 7 + (zzzFrame.dy || 0);
      Draw.drawGrid(ctx, zzzFrame.grid, zx, zy, { '#': ink });
    } else {
      Draw.drawGrid(ctx, ZZZ, 79, FRIEND_Y + 7, { '#': ink });
    }
  }

  let timeStr = formatTime(state.remainingMs);
  const timeW = Draw.measureText(timeStr, TIME_SCALE, GLYPHS, DIGIT_GAP);
  const timeX = centreX(timeW);
  Draw.drawText(ctx, timeStr, timeX, TIME_Y, TIME_SCALE, ink, GLYPHS, DIGIT_GAP);

  if (clockSteppersVisible()) {
    const st = clockSteppers();
    drawStepperControl(ctx, st.minusX, st.y, false, 'clock-minus', ink, paper);
    drawStepperControl(ctx, st.plusX, st.y, true, 'clock-plus', ink, paper);
  }

  Draw.drawRoundRect(ctx, PROGRESS_X, PROGRESS_Y, PROGRESS_W, PROGRESS_H, ink, false);
  if (state.totalMs > 0) {
    const done = 1 - Math.min(1, Math.max(0, state.remainingMs / state.totalMs));
    const fillW = Math.round((PROGRESS_W - 2) * done);
    if (fillW > 0) {
      Draw.fillRect(ctx, PROGRESS_X + 1, PROGRESS_Y + 1, fillW, PROGRESS_H - 2, ink);
    }
  }

  const { count: cycleLen, x: dotsX } = dotGeometry();
  for (let i = 0; i < cycleLen; i++) {
    const x = dotsX + i * DOT_PITCH;
    if (i < state.cycleIndex) {
      Draw.fillRect(ctx, x, CYCLE_DOTS_Y, DOT_SIZE, DOT_SIZE, ink);
    } else {
      Draw.drawBorder(ctx, x, CYCLE_DOTS_Y, DOT_SIZE, DOT_SIZE, ink);
    }
  }

  for (const btn of buttonLayout()) {
    if (pressedButton === btn.id) {
      Draw.fillRect(ctx, btn.x, BUTTONS_Y, BUTTON_SIZE, BUTTON_SIZE, ink);
      Draw.drawIcon(ctx, btn.icon, btn.x, BUTTONS_Y, paper);
    } else {
      if (hoveredButton === btn.id) Draw.drawBorder(ctx, btn.x, BUTTONS_Y, BUTTON_SIZE, BUTTON_SIZE, ink);
      Draw.drawIcon(ctx, btn.icon, btn.x, BUTTONS_Y, ink);
    }
  }
}

function drawStepper(ctx, x, y, isPlus, ink) {
  Draw.fillRect(ctx, x, y + 2, STEP_SIZE, 1, ink);
  if (isPlus) Draw.fillRect(ctx, x + 2, y, 1, STEP_SIZE, ink);
}

function drawStepperControl(ctx, x, y, isPlus, region, ink, paper) {
  const bx = x - STEP_BOX_PAD;
  const by = y - STEP_BOX_PAD;
  if (pressedRegion === region) {
    Draw.fillRect(ctx, bx, by, STEP_BOX, STEP_BOX, ink);
    drawStepper(ctx, x, y, isPlus, paper);
    return;
  }
  if (hoveredRegion === region) Draw.drawBorder(ctx, bx, by, STEP_BOX, STEP_BOX, ink);
  drawStepper(ctx, x, y, isPlus, ink);
}

// Both the button row's click handling below and the fixed key commands
// further down (§5) end up wanting exactly the same play/reset/skip/settings
// behaviour, dismiss-on-press included -- one function so Space/Enter can't
// drift from what pressing the play button actually does.
function activateButton(id) {
  window.pomoppi.dismissRing?.();
  if (id === 'play') {
    if (state.running) window.pomoppi.pause();
    else window.pomoppi.start();
  } else if (id === 'reset') {
    window.pomoppi.reset();
  } else if (id === 'skip') {
    window.pomoppi.skip();
  } else if (id === 'settings') {
    window.pomoppi.openSettings();
  }
}

function handleMouseMove(e) {
  if (!state) return;
  const rect = canvas.getBoundingClientRect();
  const lx = Math.floor((e.clientX - rect.left) / scale);
  const ly = Math.floor((e.clientY - rect.top) / scale);

  const before = hoveredRegion;
  hoveredRegion = null;
  hoveredButton = null;

  const petPos = petPosition();
  if (lx >= petPos.x && lx < petPos.x + FRIEND_SIZE &&
      ly >= petPos.y && ly < petPos.y + FRIEND_SIZE) {
    hoveredRegion = 'pet';
  } else if (clockSteppersVisible()) {
    const st = clockSteppers();
    if (stepperHit(lx, ly, st.minusX, st.y)) hoveredRegion = 'clock-minus';
    else if (stepperHit(lx, ly, st.plusX, st.y)) hoveredRegion = 'clock-plus';
  }

  const { w: groupW, x: dotsX } = dotGeometry();
  if (lx >= dotsX && lx < dotsX + groupW &&
      ly >= CYCLE_DOTS_Y - 2 && ly < CYCLE_DOTS_Y + DOT_SIZE + 2) {
    hoveredRegion = 'dots';
  }

  if (!hoveredRegion) {
    for (const btn of buttonLayout()) {
      if (lx >= btn.x - 2 && lx < btn.x + BUTTON_SIZE + 2 &&
          ly >= BUTTONS_Y - 2 && ly < BUTTONS_Y + BUTTON_SIZE + 2) {
        hoveredButton = btn.id;
        hoveredRegion = btn.id;
        break;
      }
    }
  }

  if (isDragging) {
    const dx = e.screenX - lastDragScreenX;
    const dy = e.screenY - lastDragScreenY;
    lastDragScreenX = e.screenX;
    lastDragScreenY = e.screenY;
    window.pomoppi.moveBy?.(dx, dy);
  }

  if (hoveredRegion !== before) scheduleRender();
}

function handleMouseDown(e) {
  dragStartX = e.screenX;
  dragStartY = e.screenY;
  lastDragScreenX = e.screenX;
  lastDragScreenY = e.screenY;

  const onControl = (hoveredRegion && hoveredRegion !== 'pet') || !!hoveredButton;
  if (!onControl) {
    isDragging = true;
    try {
      canvas.setPointerCapture(e.pointerId);
      pointerCaptured = true;
    } catch (err) {
      pointerCaptured = false;
    }
  }

  pressedRegion = hoveredRegion;
  pressedButton = hoveredButton;
  scheduleRender();
}

function handleMouseUp(e) {
  const dx = e.screenX - dragStartX;
  const dy = e.screenY - dragStartY;
  const moved = Math.sqrt(dx * dx + dy * dy);
  const clickedRegion = pressedRegion;
  const clickedButton = pressedButton;
  pressedRegion = null;
  pressedButton = null;
  isDragging = false;

  if (pointerCaptured && canvas.releasePointerCapture) {
    try { canvas.releasePointerCapture(e.pointerId); } catch (err) {}
    pointerCaptured = false;
  }

  if (moved >= 3) {
    scheduleRender();
    return;
  }

  if (!clickedRegion && !clickedButton) {
    scheduleRender();
    return;
  }

  if (clickedRegion === 'clock-minus') {
    stepFocusMinutes(-1);
  } else if (clickedRegion === 'clock-plus') {
    stepFocusMinutes(1);
  } else if (clickedRegion === 'dots') {
    const rect = canvas.getBoundingClientRect();
    const slot = dotSlotAt(Math.floor((e.clientX - rect.left) / scale));
    if (slot >= 0) {
      const newLen = Math.max(DOT_MIN, Math.min(DOT_MAX, slot + 1));
      window.pomoppi.setLongBreakEvery?.(newLen);
    }
  } else if (clickedButton) {
    activateButton(clickedButton);
  }

  scheduleRender();
}

function stepFocusMinutes(delta) {
  const current = focusSeconds();
  const next = Math.max(FOCUS_MIN, Math.min(FOCUS_MAX, current + delta * MINUTE_STEP));
  if (next === current) return;
  settings.focusMinutes = next / 60;
  window.pomoppi.setFocusDuration?.(next);
  scheduleRender();
}

function focusSeconds() {
  const minutes = Number(settings && settings.focusMinutes);
  if (!Number.isFinite(minutes)) return FOCUS_MIN;
  return Math.max(FOCUS_MIN, Math.min(FOCUS_MAX, Math.round(minutes * 60)));
}

// --- SVG snapshot (§4) --------------------------------------------------
// Every Draw.* call bottoms out in ctx.fillStyle = colour; ctx.fillRect(...)
// (draw.js), so a snapshot needs no drawing code of its own: point the
// module-level ctx at an object that only answers to those two members, run
// the real drawCanvas() against it, and read back exactly what it painted --
// in logical pixels, since a recorder never sees the real ctx's scale(),
// which is exactly the coordinate space the SVG wants.
function captureSnapshotRects() {
  const recorder = { fillStyle: '#000000', rects: [] };
  recorder.fillRect = function (x, y, w, h) {
    this.rects.push({ x, y, w, h, color: this.fillStyle });
  };
  const realCtx = ctx;
  ctx = recorder;
  try {
    drawCanvas();
  } finally {
    // A throw mid-draw must never leave the widget drawing into the
    // recorder for the rest of its life.
    ctx = realCtx;
  }
  return recorder.rects;
}

// The frame and the pet are drawn a pixel at a time, so uncoalesced this is
// tens of thousands of <rect>s. A single left-to-right pass is enough:
// every grid/pattern loop in drawCanvas() already emits one row's pixels in
// x order, so same colour + same row (y, h) + touching-or-overlapping
// x-spans are always adjacent in the array, never scattered.
function coalesceRects(rects) {
  const out = [];
  for (const r of rects) {
    const prev = out[out.length - 1];
    if (prev && prev.color === r.color && prev.y === r.y && prev.h === r.h &&
        r.x <= prev.x + prev.w) {
      prev.w = Math.max(prev.w, r.x + r.w - prev.x);
    } else {
      out.push({ x: r.x, y: r.y, w: r.w, h: r.h, color: r.color });
    }
  }
  return out;
}

// Runs of the same colour are otherwise scattered through the array (ink and
// paper alternate row by row in the frame), so this only groups what ended
// up consecutive after coalescing -- the runs drawCanvas happened to paint
// back to back -- under one <g fill> instead of repeating the fill per rect.
// Only the <title> carries text, and only ever a formatted date -- but it is
// the one place in the file that isn't a number or a hex colour, so it goes
// through here rather than trusting a locale to never emit an angle bracket.
function escapeXml(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function svgFromRects(rects, w, h, atScale) {
  const groups = [];
  for (const r of rects) {
    const last = groups[groups.length - 1];
    if (last && last.color === r.color) last.rects.push(r);
    else groups.push({ color: r.color, rects: [r] });
  }

  const body = groups.map((g) => {
    const inner = g.rects.map((r) =>
      `<rect x="${Math.round(r.x)}" y="${Math.round(r.y)}" width="${Math.round(r.w)}" height="${Math.round(r.h)}"/>`
    ).join('');
    return `<g fill="${g.color}">${inner}</g>`;
  }).join('');

  // No background rect: the canvas is transparent wherever nothing was
  // drawn, and an SVG with no rect there already reads the same way.
  //
  // No <?xml?> prolog either. It is optional for a standalone .svg and every
  // viewer opens the file without it, while main.js's saveSnapshot admits
  // only a payload that literally starts with '<svg' -- the one check
  // standing between a renderer and the user's disk (SPEC.md §14), and worth
  // more kept blunt than worth a declaration nothing reads.
  const stamp = escapeXml(new Date().toLocaleString());
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" ` +
    `width="${w * atScale}" height="${h * atScale}" shape-rendering="crispEdges">` +
    `<title>Pomoppi widget snapshot, ${stamp}</title>${body}</svg>`;
}

// Both entry points -- the onSnapshotRequest push from the global shortcut
// and tray item (init(), below), and the widget's own P key (§5) -- meet
// here. The main process is the one that names the file and rejects
// anything that isn't a small, well-formed SVG string; this side just
// builds one.
async function saveSnapshot() {
  const rects = coalesceRects(captureSnapshotRects());
  const svg = svgFromRects(rects, CANVAS_W, CANVAS_H, scale);
  try {
    const result = await window.pomoppi.saveSnapshot?.(svg);
    if (result && result.ok === false) console.error('Snapshot failed:', result.error);
  } catch (e) {
    console.error('Snapshot failed:', e);
  }
}

function playChime(descending) {
  if (!settings || !settings.soundEnabled) return;

  if (!audioContext) {
    audioContext = new (window.AudioContext || window.webkitAudioContext)();
  }

  const ac = audioContext;
  const now = ac.currentTime;
  const frequencies = descending ? [1568, 1174, 880] : [880, 1174, 1568];
  const duration = 0.09;
  const gap = 0.06;
  const gain = 0.06;

  for (let i = 0; i < frequencies.length; i++) {
    const startTime = now + i * (duration + gap);

    const osc = ac.createOscillator();
    osc.type = 'square';
    osc.frequency.value = frequencies[i];

    const gainNode = ac.createGain();
    gainNode.gain.setValueAtTime(gain, startTime);
    gainNode.gain.linearRampToValueAtTime(0, startTime + duration);

    osc.connect(gainNode);
    gainNode.connect(ac.destination);

    osc.start(startTime);
    osc.stop(startTime + duration);
  }
}

function animate(timestamp) {
  const dt = animationTime ? Math.min(100, timestamp - animationTime) : 16;
  animationTime = timestamp;

  updateAnimations(dt);

  if (dirty || isAnimating()) {
    drawCanvas();
    dirty = false;
  }

  if (!isAnimating()) {
    rafId = null;
    animationTime = 0;
    return;
  }
  rafId = requestAnimationFrame(animate);
}

function scheduleRender() {
  if (rafId === null) {
    rafId = requestAnimationFrame(animate);
  }
  dirty = true;
}

function onStateChange(newState) {
  const wasRinging = state && state.ringing;
  const prevPhase = state ? state.phase : null;
  state = newState;

  if (!wasRinging && newState.ringing) {
    playChime(prevPhase === 'shortBreak' || prevPhase === 'longBreak');
  }

  scheduleRender();
}

function onSettingsChange(newSettings) {
  settings = newSettings;
  scale = settings.scale || 2;

  canvas.width = CANVAS_W * scale;
  canvas.height = CANVAS_H * scale;

  ctx.scale(scale, scale);
  ctx.imageSmoothingEnabled = false;

  document.documentElement.style.setProperty('--scale', scale);

  scheduleRender();
}

// --- In-app key commands (§5) --------------------------------------------
// A fixed table, unlike the user-rebindable global shortcuts in
// renderer/shortcuts.js (main.js's territory) -- so no lookup, just one
// listener. A row's own modifier (none, except settings' extra Command) is
// the only one allowed through; anything else falls through untouched so it
// can't shadow a combo meant for elsewhere.
function plainKey(e) {
  return !e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey;
}

function handleKeyDown(e) {
  if (!state || !settings) return;
  const key = e.key.toLowerCase();

  if ((key === ' ' || key === 'enter') && plainKey(e)) {
    e.preventDefault(); // Space would otherwise scroll the page.
    if (e.repeat) return;
    activateButton('play');
  } else if (key === 's' && plainKey(e) && !e.repeat) {
    activateButton('skip');
  } else if (key === 'r' && plainKey(e) && !e.repeat) {
    activateButton('reset');
  } else if (key === 't' && plainKey(e) && !e.repeat) {
    window.pomoppi.openTask();
  } else if (key === 'o' && plainKey(e) && !e.repeat) {
    window.pomoppi.toggleAlwaysOnTop?.();
  } else if (key === 'p' && plainKey(e) && !e.repeat) {
    saveSnapshot();
  } else if (key === ',' && !e.repeat &&
             (plainKey(e) || (e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey))) {
    activateButton('settings');
  } else if (key === 'escape' && plainKey(e) && !e.repeat) {
    if (state.ringing) window.pomoppi.dismissRing?.();
    else window.pomoppi.hideWidget?.();
  } else if (key === 'arrowup' && plainKey(e) && clockSteppersVisible()) {
    e.preventDefault(); // would otherwise scroll the page.
    stepFocusMinutes(1);
  } else if (key === 'arrowdown' && plainKey(e) && clockSteppersVisible()) {
    e.preventDefault();
    stepFocusMinutes(-1);
  }
}

async function init() {
  state = await window.pomoppi.getState();
  settings = await window.pomoppi.getSettings();

  scale = settings.scale || 2;

  canvas.width = CANVAS_W * scale;
  canvas.height = CANVAS_H * scale;
  ctx.scale(scale, scale);
  ctx.imageSmoothingEnabled = false;

  document.documentElement.style.setProperty('--scale', scale);

  canvas.addEventListener('pointerdown', handleMouseDown);
  canvas.addEventListener('pointermove', handleMouseMove);
  canvas.addEventListener('pointerup', handleMouseUp);
  canvas.addEventListener('pointercancel', handleMouseUp);
  canvas.addEventListener('pointerleave', () => {
    hoveredButton = null;
    hoveredRegion = null;
    scheduleRender();
  });

  window.addEventListener('keydown', handleKeyDown);

  window.pomoppi.onState(onStateChange);
  window.pomoppi.onSettings(onSettingsChange);
  window.pomoppi.onSnapshotRequest?.(saveSnapshot);

  scheduleRender();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

})();