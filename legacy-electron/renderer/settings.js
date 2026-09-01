// Settings form logic
(function() {
'use strict';

const { FRIEND_IDS, FRIENDS, frame, FRIEND_W, FRIEND_H,
        FRAME_STYLES, FRAME_AMP, FRAME_PERIOD, windowFrame } = window.SPRITES;
const { BACKGROUNDS, BACKGROUND_IDS } = window;

const SCALE_OPTIONS = [1, 2, 3, 4];

// One-click theme pairs. Presets are deliberately high-contrast (>12:1, well
// past WCAG AA's 4.5:1) — this is 1px line art, and a low-contrast pair would
// make the whole widget hard to read, not just "a look".
// How much ink is mixed into paper to get the two greys (SPEC.md 1). Written
// as exact fractions of 255 rather than rounded percentages so the default
// black-on-white pair reproduces the documented palette exactly -- 0.22 lands
// on #C7C7C7, one short of the #C8C8C8 the spec names.
const BLUSH_MIX = 55 / 255;   // #FFFFFF over #000000 -> #C8C8C8
const MUTE_MIX = 145 / 255;   // #FFFFFF over #000000 -> #6E6E6E

const THEME_PRESETS = [
  { name: 'Classic',   ink: '#000000', paper: '#FFFFFF' },
  { name: 'LCD Green', ink: '#276231', paper: '#80b391' }, 
  { name: 'Pine',      ink: '#E0FFC2', paper: '#064734' }, 
  { name: 'Midnight',  ink: '#E2E8F0', paper: '#0F172A' },
  { name: 'OLED',      ink: '#FFFFFF', paper: '#000000' },
  { name: 'Amber',     ink: '#FFB000', paper: '#1A1100' },
  { name: 'Cocoa',     ink: '#2B1B12', paper: '#F4E9DC' },
  { name: 'Berry',     ink: '#FDE4ED', paper: '#3B1C2A' }, 
  { name: 'Sakura',    ink: '#5D2A42', paper: '#FFD6EC' }, 
  { name: 'Lavender',  ink: '#372856', paper: '#E8DDFF' },
  { name: 'Mint',      ink: '#1F473E', paper: '#D5F2E6' }, 
  { name: 'Peach',     ink: '#683525', paper: '#FFE1CF' },
];


let settings = null;
let saveTimeout = null;

const form = document.getElementById('settings-form');
const pickVaultBtn = document.getElementById('pick-vault-btn');
const testLogBtn = document.getElementById('test-log-btn');
const testLogResult = document.getElementById('test-log-result');
const edgePicker = document.getElementById('edge-picker');
const frameStyleValue = document.getElementById('frame-style-value');
const backgroundPicker = document.getElementById('background-picker');
const backgroundValue = document.getElementById('background-value');
const opacitySlider = document.getElementById('opacity');
const opacityValue = document.getElementById('opacity-value');
const friendPicker = document.getElementById('friend-picker');
const friendValue = document.getElementById('friend-value');
const inkColorInput = document.getElementById('ink-color');
const paperColorInput = document.getElementById('paper-color');
const themePresetPicker = document.getElementById('theme-preset-picker');
const scalePicker = document.getElementById('scale-picker');
const scaleValue = document.getElementById('scale-value');
const soundEnabledCheckbox = document.getElementById('sound-enabled');
const ringDurationRow = document.getElementById('ring-duration-row');
const resetBtn = document.getElementById('reset-btn');
const loginItemResult = document.getElementById('login-item-result');
const headerFriendCanvas = document.getElementById('header-friend');
const headerFriendCtx = headerFriendCanvas.getContext('2d');
const tablist = document.getElementById('settings-tablist');
const shortcutRowsEl = document.getElementById('shortcut-rows');

// -- tabs: one flat home per setting, replacing the old details/summary
// disclosures (SPEC.md "Settings window layout"). Panels toggle via the
// `hidden` property, never an inline style. Automatic activation: an arrow
// key both moves focus and selects, the same feel as the segmented controls
// elsewhere in this window. The selected tab is remembered per viewer via
// localStorage, wrapped in try/catch because it can throw (e.g. some
// embedding contexts disable storage) -- this is a convenience, not a
// setting, so it never goes through window.pomoppiSettings.
const TAB_IDS = ['rhythm', 'appearance', 'window', 'keys', 'sound', 'obsidian'];
const TAB_STORAGE_KEY = 'pomoppi-settings-tab';

function selectTab(id, { focus = false } = {}) {
  if (!TAB_IDS.includes(id)) id = TAB_IDS[0];
  for (const tabId of TAB_IDS) {
    const tabBtn = document.getElementById('tab-' + tabId);
    const panel = document.getElementById('panel-' + tabId);
    const active = tabId === id;
    tabBtn.setAttribute('aria-selected', String(active));
    tabBtn.tabIndex = active ? 0 : -1;
    panel.hidden = !active;
  }
  if (focus) document.getElementById('tab-' + id).focus();
  try {
    localStorage.setItem(TAB_STORAGE_KEY, id);
  } catch (e) {
    // Per-viewer convenience only -- losing it just means the next open
    // starts on the first tab again.
  }
}

function initialTab() {
  try {
    const stored = localStorage.getItem(TAB_STORAGE_KEY);
    if (stored && TAB_IDS.includes(stored)) return stored;
  } catch (e) {
    // Falls through to the first tab.
  }
  return TAB_IDS[0];
}

function setupTabs() {
  selectTab(initialTab());

  tablist.addEventListener('click', (e) => {
    const btn = e.target.closest('.tab');
    if (btn) selectTab(btn.dataset.tab);
  });

  // Roving tabindex, arrow keys move focus and activate the newly focused
  // tab (the ARIA tabs pattern's "automatic activation"); Home/End jump to
  // the ends.
  tablist.addEventListener('keydown', (e) => {
    const current = e.target.closest('.tab');
    if (!current) return;
    const idx = TAB_IDS.indexOf(current.dataset.tab);
    if (idx === -1) return;
    let nextId = null;
    if (e.key === 'ArrowRight') nextId = TAB_IDS[(idx + 1) % TAB_IDS.length];
    else if (e.key === 'ArrowLeft') nextId = TAB_IDS[(idx - 1 + TAB_IDS.length) % TAB_IDS.length];
    else if (e.key === 'Home') nextId = TAB_IDS[0];
    else if (e.key === 'End') nextId = TAB_IDS[TAB_IDS.length - 1];
    if (nextId) {
      e.preventDefault();
      selectTab(nextId, { focus: true });
    }
  });
}

// -- theme: hex <-> rgb, mixing, and applying to the page -------------------

function hexToRgb(hex) {
  const h = hex.replace('#', '');
  const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
  const n = parseInt(full, 16) || 0;
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

function rgbToHex({ r, g, b }) {
  const toHex = (c) => Math.round(Math.min(255, Math.max(0, c))).toString(16).padStart(2, '0');
  return '#' + (toHex(r) + toHex(g) + toHex(b)).toUpperCase();
}

// Mixes `amount` (0..1) of `tint` over `base` — e.g. mixHex(paper, ink, 0.22)
// is 22% ink painted over paper. This is the same relationship as the
// original hardcoded --blush (~22% ink over white -> #C8C8C8) and --mute
// (~57% -> #6E6E6E) in SPEC.md §1, so any ink/paper pair a user picks keeps
// proportionate, legible greys instead of a fixed grey that could vanish
// against a dark paper or barely register against a light one.
function mixHex(base, tint, amount) {
  const a = hexToRgb(base);
  const b = hexToRgb(tint);
  return rgbToHex({
    r: a.r + (b.r - a.r) * amount,
    g: a.g + (b.g - a.g) * amount,
    b: a.b + (b.b - a.b) * amount,
  });
}

function currentInk() { return inkColorInput.value || '#000000'; }
function currentPaper() { return paperColorInput.value || '#FFFFFF'; }

// Sets --ink/--paper/--blush/--mute on <html>, exactly the way widget.js sets
// --scale (an inline custom property, not a blocked inline `style="..."`
// attribute), then redraws everything in this window that bakes those colours
// into canvas pixels rather than reading the CSS variables: the picker
// swatches, the header friend, and the edge previews all hardcode colours in
// JS because a <canvas> can't itself be styled with CSS custom properties.
function applyTheme() {
  const ink = currentInk();
  const paper = currentPaper();
  const root = document.documentElement.style;
  root.setProperty('--ink', ink);
  root.setProperty('--paper', paper);
  root.setProperty('--blush', mixHex(paper, ink, BLUSH_MIX));
  root.setProperty('--mute', mixHex(paper, ink, MUTE_MIX));

  renderThemePresets();
  renderFriendPicker();
  renderEdgePicker();
  renderBackgroundPicker();
  drawHeaderFriend();
}

// Presets just set both inputs to a known pair, so the currently-active pair
// (whether reached by a preset or by hand) is whichever preset's colours
// happen to match — no separate "which preset is active" state to fall out
// of sync.
function renderThemePresets() {
  themePresetPicker.innerHTML = '';
  const ink = currentInk().toUpperCase();
  const paper = currentPaper().toUpperCase();

  for (const preset of THEME_PRESETS) {
    const item = document.createElement('div');
    item.className = 'picker-item';
    if (preset.ink === ink && preset.paper === paper) {
      item.classList.add('selected');
    }

    const swatch = document.createElement('div');
    swatch.className = 'theme-swatch';
    swatch.style.setProperty('--swatch-ink', preset.ink);
    swatch.style.setProperty('--swatch-paper', preset.paper);
    // Two flat halves, not one box with a gradient -- see .theme-swatch.
    for (const half of ['swatch-ink', 'swatch-paper']) {
      const el = document.createElement('span');
      el.className = half;
      swatch.appendChild(el);
    }

    const label = document.createElement('div');
    label.className = 'picker-label';
    label.textContent = preset.name;

    item.append(swatch, label);
    item.addEventListener('click', () => {
      inkColorInput.value = preset.ink;
      paperColorInput.value = preset.paper;
      applyTheme();
      saveNow();
    });
    themePresetPicker.appendChild(item);
  }
}

function debounce(fn, delay) {
  return function(...args) {
    clearTimeout(saveTimeout);
    saveTimeout = setTimeout(() => fn(...args), delay);
  };
}

function loadSettings(data) {
  settings = data;

  document.getElementById('focus-minutes').value = settings.focusMinutes || 25;
  document.getElementById('short-break-minutes').value = settings.shortBreakMinutes || 5;
  document.getElementById('long-break-minutes').value = settings.longBreakMinutes || 15;
  document.getElementById('long-break-every').value = settings.longBreakEvery || 4;
  document.getElementById('auto-start-breaks').checked = settings.autoStartBreaks ?? true;
  document.getElementById('auto-start-focus').checked = settings.autoStartFocus ?? false;
  document.getElementById('ask-for-task').checked = settings.askForTaskName ?? true;

  document.getElementById('logging-enabled').checked = settings.loggingEnabled ?? true;
  document.getElementById('vault-path').value = settings.vaultPath || '';
  document.getElementById('daily-note-folder').value = settings.dailyNoteFolder || '';
  document.getElementById('daily-note-format').value = settings.dailyNoteFormat || 'YYYY-MM-DD';
  document.getElementById('log-heading').value = settings.logHeading || '## Pomodoros';
  document.getElementById('log-breaks').checked = settings.logBreaks ?? false;
  document.getElementById('log-aborted').checked = settings.logAborted ?? false;

  friendValue.value = settings.friend || FRIEND_IDS[0];
  document.getElementById('pet-movement').checked = settings.petMovement ?? false;
  inkColorInput.value = settings.inkColor || '#000000';
  paperColorInput.value = settings.paperColor || '#FFFFFF';
  frameStyleValue.value = settings.frameStyle || FRAME_STYLES[0];
  backgroundValue.value = settings.background || BACKGROUND_IDS[0];
  scaleValue.value = settings.scale || 2;
  opacitySlider.value = settings.opacity ?? 1.0;
  updateOpacityDisplay();
  document.getElementById('always-on-top').checked = settings.alwaysOnTop ?? true;
  document.getElementById('raise-on-end').checked = settings.raiseOnEnd ?? true;
  document.getElementById('launch-at-login').checked = settings.launchAtLogin ?? false;
  document.getElementById('start-hidden').checked = settings.startHidden ?? false;
  updateLoginItemStatus(settings.loginItemError);

  soundEnabledCheckbox.checked = settings.soundEnabled ?? true;
  document.getElementById('ring-seconds').value = settings.ringSeconds ?? 10;
  syncSoundEnabledState();

  renderShortcutRows();

  // applyTheme() also renders the friend picker, edge picker and header
  // friend — they all bake ink/paper into canvas pixels, so they have to be
  // redrawn together whenever the theme is (re)applied, including on load.
  applyTheme();
  renderScalePicker();
}

function updateOpacityDisplay() {
  opacityValue.textContent = (Math.round(opacitySlider.value * 100)) + '%';
}

// main.js can't always honour launchAtLogin the way it means to: the login
// item points at Pomoppi.app, so there is nothing to register until that
// bundle has been built (`npm run launcher`), and macOS can refuse the
// Automation permission that editing the Login Items list needs, leaving a
// background item instead. Either way it reports it on every pomoppiSettings
// get/set/reset as a non-persisted loginItemError field, so the checkbox never
// gets to silently lie about what actually happened.
function updateLoginItemStatus(message) {
  loginItemResult.textContent = message || '';
}

// Ring duration only means anything when a chime is going to play at all.
function syncSoundEnabledState() {
  const on = soundEnabledCheckbox.checked;
  ringDurationRow.classList.toggle('disabled', !on);
  ringDurationRow.querySelectorAll('input, button').forEach((el) => { el.disabled = !on; });
}

// Draws the current friend's idle frame beside the window title, so the
// settings window reads as part of Pomoppi rather than a bare macOS form.
function drawHeaderFriend() {
  const id = friendValue.value || FRIEND_IDS[0];
  headerFriendCtx.setTransform(1, 0, 0, 1, 0, 0);
  headerFriendCtx.imageSmoothingEnabled = false;
  headerFriendCtx.clearRect(0, 0, headerFriendCanvas.width, headerFriendCanvas.height);
  const s = headerFriendCanvas.width / FRIEND_W;
  headerFriendCtx.scale(s, s);
  Draw.drawGrid(headerFriendCtx, frame(id, 0), 0, 0, { '#': currentInk(), 'w': currentPaper() });
}

// Shows a strip cropped from partway along the top edge -- not the corner,
// where the left/right edge's own wave would mix in and muddy the shape --
// wide enough to catch several repeats, so scallopy's rounded bumps, zigzag's
// points and tatter's irregular tears all read as a pattern rather than one
// ambiguous wiggle. Sized off SPRITES' own FRAME_AMP/FRAME_PERIOD rather than
// hardcoded pixels, so if that wave ever gets rescaled this crop rescales
// with it instead of clipping the pattern or drowning it in blank paper.
//
// The canvas is drawn at that native crop resolution and stretched to fill
// its box in CSS (see .edge-preview) -- it can never spill past its picker
// item the way a canvas sized in fixed on-screen pixels could, and it holds
// up at any number of FRAME_STYLES since every item gets the same box.
function renderEdgePicker() {
  const FRAME_W = 96, FRAME_H = 120; // the widget frame's own logical size (SPEC.md §3)
  // Show the top-left corner, not a strip of the top edge. A thin horizontal
  // slice makes every style look like the same squiggly line; the corner shows
  // the rounding and two edges meeting, which is what actually differs.
  const cropW = 46, cropH = 34, offsetX = 0, offsetY = 0;
  const ink = currentInk();
  const paper = currentPaper();
  edgePicker.innerHTML = '';

  for (const style of FRAME_STYLES) {
    const item = document.createElement('div');
    item.className = 'picker-item';
    if (style === frameStyleValue.value) item.classList.add('selected');

    const canvas = document.createElement('canvas');
    canvas.className = 'edge-preview';
    canvas.width = cropW;
    canvas.height = cropH;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;

    const grid = windowFrame(style, FRAME_W, FRAME_H);
    ctx.clearRect(0, 0, cropW, cropH);
    for (let y = 0; y < cropH; y++) {
      for (let x = 0; x < cropW; x++) {
        const ch = grid[offsetY + y] && grid[offsetY + y][offsetX + x];
        if (!ch || ch === '.') continue;
        ctx.fillStyle = ch === '#' ? ink : paper;
        ctx.fillRect(x, y, 1, 1);
      }
    }

    const label = document.createElement('div');
    label.className = 'picker-label';
    label.textContent = style;

    item.append(canvas, label);
    item.addEventListener('click', () => {
      frameStyleValue.value = style;
      renderEdgePicker();
      // The background preview is masked against this frame style (see
      // renderBackgroundPicker below), so it goes stale unless refreshed too.
      renderBackgroundPicker();
      saveNow();
    });
    edgePicker.appendChild(item);
  }
}

// Loops over BACKGROUND_IDS, so however many patterns exist in
// renderer/background.js (generated by tools/import-bgs.js) they all show up
// here. Rather than a raw crop of the pattern, this renders the same
// masked-behind-the-frame look drawCanvas() uses in the widget (see
// renderer/widget.js) at the currently selected window edge, so the preview
// matches what picking it will actually look like -- an unmasked pattern is
// much denser than what ever reaches the screen, most of it hidden under the
// frame's own opaque interior.
function renderBackgroundPicker() {
  // renderer/widget.js's own layout constants (FRAME_W/H, FRAME_X/Y) --
  // kept in sync by hand, same reasoning as renderEdgePicker's FRAME_W/H above.
  const FRAME_W = 110, FRAME_H = 124, FRAME_X = 4, FRAME_Y = 4;
  const cropW = 70, cropH = 46;
  const ink = currentInk();
  const paper = currentPaper();
  const bgColor = mixHex(paper, ink, 0.3); // same mix drawCanvas() uses for the pattern
  const style = frameStyleValue.value || FRAME_STYLES[0];
  const frameGrid = windowFrame(style, FRAME_W, FRAME_H);
  backgroundPicker.innerHTML = '';

  for (const id of BACKGROUND_IDS) {
    const bg = BACKGROUNDS[id];
    const item = document.createElement('div');
    item.className = 'picker-item';
    if (id === backgroundValue.value) item.classList.add('selected');

    const canvas = document.createElement('canvas');
    canvas.className = 'bg-preview';
    canvas.width = cropW;
    canvas.height = cropH;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;
    ctx.fillStyle = paper;
    ctx.fillRect(0, 0, cropW, cropH);

    for (let y = 0; y < cropH; y++) {
      const frameRow = frameGrid[y - FRAME_Y];
      if (!frameRow) continue;
      const patRow = bg.pattern[y];
      for (let x = 0; x < cropW; x++) {
        const fch = frameRow[x - FRAME_X];
        if (fch === '#') {
          ctx.fillStyle = ink;
          ctx.fillRect(x, y, 1, 1);
        } else if (fch === 'w' && patRow && patRow[x] === '#') {
          ctx.fillStyle = bgColor;
          ctx.fillRect(x, y, 1, 1);
        }
      }
    }

    const label = document.createElement('div');
    label.className = 'picker-label';
    label.textContent = bg.name;

    item.append(canvas, label);
    item.addEventListener('click', () => {
      backgroundValue.value = id;
      renderBackgroundPicker();
      saveNow();
    });
    backgroundPicker.appendChild(item);
  }
}

// Loops over SPRITES.FRIEND_IDS, so however many pets exist, they all show up
// here. Pets carry animation frames, not expressions, so this always draws
// frame 0 regardless of how many frames a given pet actually has.
function renderFriendPicker() {
  friendPicker.innerHTML = '';
  const ink = currentInk();
  const paper = currentPaper();
  const blush = mixHex(paper, ink, 0.22);

  for (const friendId of FRIEND_IDS) {
    const friend = FRIENDS[friendId];
    const container = document.createElement('div');
    container.className = 'picker-item';
    if (friendId === friendValue.value) {
      container.classList.add('selected');
    }

    const canvas = document.createElement('canvas');
    canvas.className = 'friend-preview';
    canvas.width = FRIEND_W * 2;
    canvas.height = FRIEND_H * 2;

    const ctx = canvas.getContext('2d');
    ctx.scale(2, 2);
    ctx.imageSmoothingEnabled = false;
    ctx.fillStyle = paper;
    ctx.fillRect(0, 0, FRIEND_W, FRIEND_H);

    Draw.drawGrid(ctx, frame(friendId, 0), 0, 0, { '#': ink, 'w': paper, 'g': blush });

    const label = document.createElement('div');
    label.className = 'picker-label';
    label.textContent = friend.name;

    container.appendChild(canvas);
    container.appendChild(label);

    container.addEventListener('click', () => {
      friendValue.value = friendId;
      renderFriendPicker();
      drawHeaderFriend();
      saveNow();
    });

    friendPicker.appendChild(container);
  }
}

// A splotchy button row rather than a native <select> — scale is one of exactly
// three sizes, and a segmented control makes that visible at a glance.
function renderScalePicker() {
  scalePicker.innerHTML = '';
  for (const n of SCALE_OPTIONS) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = n + 'x';
    if (String(n) === String(scaleValue.value)) btn.classList.add('selected');
    btn.addEventListener('click', () => {
      scaleValue.value = n;
      renderScalePicker();
      saveNow();
    });
    scalePicker.appendChild(btn);
  }
}

// -- global shortcuts (Keys tab) ---------------------------------------------
//
// One row per window.SHORTCUTS.ACTIONS entry. Each row is two *buttons*, not
// a form field: capture (shows the current binding, arms on click) and clear.
// Because they're buttons they sit outside form.elements' change/input
// auto-save path (see collectFormData/saveFromEvent above), so every save
// here is driven explicitly through pomoppiSettings.set(), always with the
// *whole* shortcuts object -- lib/settings.js's shallow merge means a patch
// carrying only one binding would silently drop every other one.
//
// Physical keys, not typed characters: capture reads e.code and the raw
// modifier flags (metaKey/ctrlKey/altKey/shiftKey) rather than e.key, because
// e.key already has the OS's character composition applied -- and on macOS,
// Option remaps the character entirely (Option+P types 'π', not 'p'). Every
// default binding in shortcuts.js holds Alt, so building off e.key would
// make it impossible to ever capture the app's own defaults back.

// e.code (physical, layout-independent) -> the token shortcuts.js's
// normalize() accepts. Escape/Backspace/Delete are handled before this table
// is consulted at all (see handleCaptureKeydown) because this UI gives them
// fixed jobs -- cancel and clear -- so they can never be captured as the
// bound key itself.
const CAPTURE_CODE_TO_KEY = {
  Space: 'Space', Tab: 'Tab', Enter: 'Return', NumpadEnter: 'Return',
  ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
  Home: 'Home', End: 'End', PageUp: 'PageUp', PageDown: 'PageDown',
  Insert: 'Insert', PrintScreen: 'PrintScreen',
  Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']',
  Backslash: '\\', Semicolon: ';', Quote: '\'', Comma: ',', Period: '.',
  Slash: '/', Backquote: '`',
  NumpadDecimal: 'numdec', NumpadAdd: 'numadd', NumpadSubtract: 'numsub',
  NumpadMultiply: 'nummult', NumpadDivide: 'numdiv',
};
for (let i = 0; i <= 9; i++) CAPTURE_CODE_TO_KEY['Digit' + i] = String(i);
for (let i = 0; i <= 9; i++) CAPTURE_CODE_TO_KEY['Numpad' + i] = 'num' + i;
for (let i = 0; i < 26; i++) {
  const letter = String.fromCharCode(65 + i);
  CAPTURE_CODE_TO_KEY['Key' + letter] = letter;
}
for (let i = 1; i <= 24; i++) CAPTURE_CODE_TO_KEY['F' + i] = 'F' + i;

// Pressing a modifier on its own (reaching for Alt before Shift before the
// letter) is a normal part of pressing a combo, not a rejected attempt --
// so these keydowns are ignored outright rather than treated as "no key yet".
const CAPTURE_MODIFIER_CODES = new Set([
  'ShiftLeft', 'ShiftRight', 'ControlLeft', 'ControlRight',
  'AltLeft', 'AltRight', 'MetaLeft', 'MetaRight', 'CapsLock',
]);

const NEEDS_MODIFIER_MESSAGE = 'Needs ⌘, ⌃, ⌥ or ⇧ held down — a bare key would be caught in every app.';
const UNSUPPORTED_KEY_MESSAGE = 'That key can’t be used in a shortcut — try a letter, number, or punctuation key.';

// Which row is currently recording, if any -- id plus the exact button/status
// nodes it's touching, so ending a capture never has to look them back up.
// Set the moment a capture button is clicked, cleared the moment it stops
// (committed, cleared, or cancelled) -- never left pointing at a row that's
// no longer actually recording.
let armedShortcut = null;

function shortcutAction(id) {
  return window.SHORTCUTS.ACTIONS.find((a) => a.id === id);
}

// The conflict this UI refuses *before* ever calling set(): another action's
// own *currently saved* binding. (lib/settings.js's validate() also clamps
// conflicts, but by ACTION_IDS order -- if this row lost that race the new
// binding would just silently come back empty instead of explaining why.)
function findShortcutConflict(normalized, excludeId) {
  const current = (settings && settings.shortcuts) || {};
  for (const action of window.SHORTCUTS.ACTIONS) {
    if (action.id === excludeId) continue;
    if (current[action.id] && current[action.id] === normalized) return action.id;
  }
  return null;
}

function showShortcutStatus(el, message) {
  el.textContent = message;
  el.hidden = false;
}

function clearShortcutStatus(el) {
  el.textContent = '';
  el.hidden = true;
}

// Resting: shows the binding via SHORTCUTS.display() (which already renders
// '' as "Not set"), italicised through .shortcut-capture--unbound so an
// intentionally-cleared row reads as a choice rather than an empty hole.
// Armed: the label says so in plain words ("Press keys…") -- copy alone
// already makes the state unambiguous without leaning on colour -- reinforced
// by the same hard-edged focus-ring idiom .tab/.pixel-check already use.
function setCaptureButtonState(btn, accel, armed) {
  btn.classList.toggle('shortcut-capture--armed', armed);
  if (armed) {
    btn.textContent = 'Press keys…';
    btn.setAttribute('aria-label', 'Recording a new shortcut. Press a key combination, or Escape to cancel.');
  } else {
    const display = window.SHORTCUTS.display(accel);
    btn.textContent = display;
    btn.classList.toggle('shortcut-capture--unbound', !accel);
    btn.setAttribute('aria-label', accel
      ? 'Shortcut ' + display + '. Click to change it.'
      : 'No shortcut set. Click to set one.');
  }
}

// Ends whatever row is recording and puts its button back to a plain resting
// state reflecting the still-current (unsaved-over) binding -- used when
// arming a different row, and by Escape. Never touches `settings`, so it
// never needs a re-render: the row's own DOM node is still live, just reset.
function cancelShortcutCapture() {
  if (!armedShortcut) return;
  const { id, btn, status } = armedShortcut;
  const current = (settings.shortcuts && settings.shortcuts[id]) || '';
  setCaptureButtonState(btn, current, false);
  clearShortcutStatus(status);
  if (settings.shortcutErrors && settings.shortcutErrors[id]) {
    showShortcutStatus(status, 'Another app on your Mac already uses this shortcut.');
  }
  document.removeEventListener('keydown', handleShortcutCaptureKeydown, true);
  armedShortcut = null;
}

function armShortcutCapture(action, btn, status) {
  if (armedShortcut && armedShortcut.id === action.id) return;
  if (armedShortcut) cancelShortcutCapture();
  armedShortcut = { id: action.id, btn, status };
  clearShortcutStatus(status);
  setCaptureButtonState(btn, null, true);
  // Capture phase, not bubble: this has to see (and be able to swallow) the
  // keydown before the window-level "Escape closes settings" listener does,
  // so an Escape that's cancelling a capture never also closes the window.
  document.addEventListener('keydown', handleShortcutCaptureKeydown, true);
}

// Saves the whole shortcuts object and re-renders every row from whatever
// lib/settings.js's validate() actually persisted -- picking a combination
// this UI already refused can't reach here, but validate() is still the
// authority on what got saved (SPEC §7's clamp-rather-than-reject rule).
// Re-focuses the same row's (rebuilt) capture button afterwards: renderShortcutRows()
// replaces every row's DOM node, and without this a keyboard user's focus
// would otherwise vanish into the page after every single capture.
async function commitShortcut(id, accel) {
  if (armedShortcut) cancelShortcutCapture();
  const current = settings.shortcuts || {};
  try {
    const result = await window.pomoppiSettings.set({ shortcuts: { ...current, [id]: accel } });
    settings = result;
  } catch (e) {
    console.error('Failed to save shortcut:', e);
  }
  renderShortcutRows(id);
}

function handleShortcutCaptureKeydown(e) {
  if (!armedShortcut) return;
  if (e.repeat) return;
  if (CAPTURE_MODIFIER_CODES.has(e.code)) return; // still waiting for the real key

  e.preventDefault();
  e.stopPropagation();

  const { id, status } = armedShortcut;

  if (e.code === 'Escape') {
    cancelShortcutCapture();
    return;
  }
  if (e.code === 'Backspace' || e.code === 'Delete') {
    commitShortcut(id, '');
    return;
  }

  const modifiers = [];
  if (e.metaKey) modifiers.push('Command');
  if (e.ctrlKey) modifiers.push('Control');
  if (e.altKey) modifiers.push('Alt');
  if (e.shiftKey) modifiers.push('Shift');

  if (modifiers.length === 0) {
    showShortcutStatus(status, NEEDS_MODIFIER_MESSAGE);
    return; // stays armed -- the next keydown gets another try
  }

  const keyToken = CAPTURE_CODE_TO_KEY[e.code];
  const normalized = keyToken && window.SHORTCUTS.normalize(modifiers.join('+') + '+' + keyToken);
  if (!normalized) {
    showShortcutStatus(status, UNSUPPORTED_KEY_MESSAGE);
    return;
  }

  const conflictId = findShortcutConflict(normalized, id);
  if (conflictId) {
    const other = shortcutAction(conflictId);
    showShortcutStatus(status, (other ? other.label : 'Another shortcut') + ' already uses this combination. Pick another, or clear that one first.');
    return;
  }

  commitShortcut(id, normalized);
}

function buildShortcutRow(action) {
  const accel = (settings.shortcuts && settings.shortcuts[action.id]) || '';
  const osError = settings.shortcutErrors && settings.shortcutErrors[action.id];

  const row = document.createElement('div');
  row.className = 'shortcut-row';

  const text = document.createElement('div');
  text.className = 'shortcut-text';

  const labelId = 'shortcut-label-' + action.id;
  const hintId = 'shortcut-hint-' + action.id;

  const label = document.createElement('div');
  label.className = 'shortcut-label';
  label.id = labelId;
  label.textContent = action.label;
  text.appendChild(label);

  const describedBy = [labelId];
  if (action.hint) {
    const hint = document.createElement('div');
    hint.className = 'field-hint';
    hint.id = hintId;
    hint.textContent = action.hint;
    text.appendChild(hint);
    describedBy.push(hintId);
  }

  const status = document.createElement('p');
  status.className = 'field-hint shortcut-status';
  status.setAttribute('role', 'status');
  status.hidden = true;
  if (osError) showShortcutStatus(status, 'Another app on your Mac already uses this shortcut.');
  text.appendChild(status);

  const controls = document.createElement('div');
  controls.className = 'shortcut-controls';

  const captureBtn = document.createElement('button');
  captureBtn.type = 'button';
  captureBtn.className = 'pixel-btn shortcut-capture';
  captureBtn.setAttribute('aria-describedby', describedBy.join(' '));
  setCaptureButtonState(captureBtn, accel, false);
  captureBtn.addEventListener('click', () => armShortcutCapture(action, captureBtn, status));

  const clearBtn = document.createElement('button');
  clearBtn.type = 'button';
  clearBtn.className = 'pixel-btn pixel-btn--quiet';
  clearBtn.textContent = 'Clear';
  clearBtn.disabled = !accel;
  clearBtn.setAttribute('aria-label', 'Clear the ' + action.label + ' shortcut');
  clearBtn.addEventListener('click', () => commitShortcut(action.id, ''));

  controls.append(captureBtn, clearBtn);
  row.append(text, controls);
  return row;
}

// Rebuilds every row from `settings` -- the only source of truth for what's
// actually saved. `focusId`, when given, re-focuses that row's capture
// button afterwards (see commitShortcut above); page load and Reset have no
// single row to return focus to, so they omit it.
function renderShortcutRows(focusId) {
  shortcutRowsEl.innerHTML = '';
  for (const action of window.SHORTCUTS.ACTIONS) {
    const row = buildShortcutRow(action);
    shortcutRowsEl.appendChild(row);
    if (action.id === focusId) {
      row.querySelector('.shortcut-capture').focus();
    }
  }
}

// Wires the +/- buttons beside every number input. Each button's data-dir is
// the exact delta to apply (most are -1/+1; ring duration steps by 5), and the
// clamp range comes from the input's own min/max rather than being duplicated
// in JS.
function wireSteppers() {
  document.querySelectorAll('.stepper').forEach((stepper) => {
    const input = stepper.querySelector('input[type="number"]');
    stepper.querySelectorAll('.stepper-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        const delta = Number(btn.dataset.dir) || 0;
        const min = input.min !== '' ? Number(input.min) : -Infinity;
        const max = input.max !== '' ? Number(input.max) : Infinity;
        const current = parseFloat(input.value) || 0;
        input.value = Math.min(max, Math.max(min, current + delta));
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        // A stepper click is discrete even though its target is a number input,
        // so it jumps the debounce the synthetic events above just queued.
        saveNow();
      });
    });
  });
}

function collectFormData() {
  const data = {};
  for (const el of form.elements) {
    if (!el.name) continue;
    if (el.type === 'checkbox') {
      data[el.name] = el.checked;
    } else if (el.type === 'number' || el.type === 'range') {
      const n = parseFloat(el.value);
      if (!Number.isNaN(n)) data[el.name] = n;
    } else {
      data[el.name] = el.value;
    }
  }
  return data;
}

async function saveSettings() {
  const data = collectFormData();
  try {
    const result = await window.pomoppiSettings.set(data);
    updateLoginItemStatus(result.loginItemError);

    // Most fields can't disagree with what main persisted, but ink/paper can:
    // picking a colour that exactly matches the other one is a state the form
    // itself can't prevent (nothing stops two colour wells from landing on
    // the same value), so main resets that pair to the default instead of
    // saving an invisible widget. Re-sync from the authoritative result so
    // the pickers never keep showing a pair that didn't actually get saved.
    if (result.inkColor.toUpperCase() !== inkColorInput.value.toUpperCase() ||
        result.paperColor.toUpperCase() !== paperColorInput.value.toUpperCase()) {
      inkColorInput.value = result.inkColor;
      paperColorInput.value = result.paperColor;
      applyTheme();
    }
  } catch (e) {
    console.error('Failed to save settings:', e);
  }
}

const debouncedSave = debounce(saveSettings, 300);

// Saves right now, cancelling any debounced save already queued.
//
// The debounce exists so we are not writing settings on every keystroke, and
// for typing it is right. For a *discrete* gesture — clicking a friend, a
// checkbox, a scale button — there is no stream of events to coalesce, and the
// 300ms wait was the entire delay between changing a setting and seeing the
// widget change. Persisting itself costs ~0.15ms; nothing here is slow, it was
// only ever waiting. So: discrete controls call this, continuous ones keep the
// debounce.
function saveNow() {
  clearTimeout(saveTimeout);
  saveSettings();
}

// One gesture, many events: typing in a field, dragging the opacity slider or a
// colour wheel. Everything else fires once and should act at once.
const CONTINUOUS_INPUT_TYPES = new Set(['text', 'number', 'range', 'color', 'search', 'url']);

function isContinuous(el) {
  if (!el) return false;
  if (el.tagName === 'TEXTAREA') return true;
  return el.tagName === 'INPUT' && CONTINUOUS_INPUT_TYPES.has(el.type);
}

function saveFromEvent(e) {
  if (isContinuous(e.target)) debouncedSave();
  else saveNow();
}

function setupListeners() {
  form.addEventListener('submit', (e) => e.preventDefault());
  form.addEventListener('change', saveFromEvent);
  form.addEventListener('input', saveFromEvent);

  opacitySlider.addEventListener('input', updateOpacityDisplay);
  soundEnabledCheckbox.addEventListener('change', syncSoundEnabledState);

  // The generic form-level listeners above already debounce a save whenever
  // either colour input fires 'input' or 'change' — this just repaints the
  // page immediately as the user drags inside the native colour well,
  // instead of waiting on that debounce to see the effect.
  inkColorInput.addEventListener('input', applyTheme);
  paperColorInput.addEventListener('input', applyTheme);

  pickVaultBtn.addEventListener('click', async () => {
    testLogResult.textContent = '';
    const result = await window.pomoppiSettings.pickVault();
    if (result) {
      document.getElementById('vault-path').value = result;
      saveNow();
    }
  });

  testLogBtn.addEventListener('click', async () => {
    testLogResult.textContent = 'Testing…';
    testLogResult.className = '';
    try {
      const result = await window.pomoppiSettings.testLog();
      if (result.ok) {
        testLogResult.textContent = '✓ ' + (result.path || 'looks good');
        testLogResult.className = 'success';
      } else {
        testLogResult.textContent = '! ' + (result.error || 'unknown error');
        testLogResult.className = 'error';
      }
    } catch (e) {
      testLogResult.textContent = '! ' + e.message;
      testLogResult.className = 'error';
    }
  });

  resetBtn.addEventListener('click', async () => {
    const ok = window.confirm('Reset every Pomoppi setting to its default? This cannot be undone.');
    if (!ok) return;
    try {
      const data = await window.pomoppiSettings.reset();
      loadSettings(data);
    } catch (e) {
      console.error('Failed to reset settings:', e);
    }
  });

  wireSteppers();

  // Escape closes the window -- except while a shortcut row is armed, where
  // it cancels the capture instead (handleShortcutCaptureKeydown, registered
  // only while armed, sits on the *capture* phase and stops propagation, so
  // this bubble-phase listener never even sees that Escape). The armedShortcut
  // check below is belt-and-braces, not the mechanism.
  window.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || armedShortcut) return;
    window.pomoppiSettings.close();
  });
}

async function init() {
  setupTabs();
  const data = await window.pomoppiSettings.get();
  loadSettings(data);
  setupListeners();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

})();
