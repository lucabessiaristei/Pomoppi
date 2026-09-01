// shortcuts.js — the global-shortcut action table and Electron accelerator
// parsing shared by main.js (registers them), lib/settings.js (persists and
// validates them) and the settings window (lets someone rebind them). Dual-
// mode like renderer/sprites.js / renderer/background.js so lib/settings.js
// can require() it under Node while settings.html / widget.html load it as a
// classic <script>.

// Display order doubles as tie-break order in validate() below: whichever
// action comes first here keeps a contested accelerator.
const ACTIONS = Object.freeze([
  Object.freeze({
    id: 'toggleWidget',
    label: 'Show / hide the widget',
    hint: 'Brings Pomoppi to the front, or tucks it away.',
    default: 'Alt+Shift+P',
  }),
  Object.freeze({
    id: 'startPause',
    label: 'Start / pause',
    hint: "Same as the widget's play button.",
    default: 'Alt+Shift+Space',
  }),
  Object.freeze({
    id: 'skip',
    label: 'Skip phase',
    hint: 'Ends the current phase early. No-op while idle.',
    default: 'Alt+Shift+K',
  }),
  Object.freeze({
    id: 'reset',
    label: 'Reset phase',
    hint: 'Puts the current phase back to full. No-op while idle.',
    default: 'Alt+Shift+R',
  }),
  Object.freeze({
    id: 'toggleOnTop',
    label: 'Keep on top',
    hint: 'Toggles whether the widget floats above other windows.',
    default: 'Alt+Shift+T',
  }),
  Object.freeze({
    id: 'snapshot',
    label: 'Save SVG snapshot',
    hint: 'Writes the widget exactly as drawn to the Desktop.',
    default: 'Alt+Shift+S',
  }),
  Object.freeze({
    id: 'openSettings',
    label: 'Open settings',
    hint: '',
    default: 'Alt+Shift+,',
  }),
]);

const ACTION_IDS = Object.freeze(ACTIONS.map((a) => a.id));

// Case-insensitive aliases for the four modifiers Electron accelerators
// recognise, plus the two spellings of its cross-platform one. Everything
// maps to the canonical name normalize() below renders.
const MODIFIER_ALIASES = {
  command: 'Command', cmd: 'Command', super: 'Command', meta: 'Command',
  control: 'Control', ctrl: 'Control',
  alt: 'Alt', option: 'Alt', opt: 'Alt',
  shift: 'Shift',
  commandorcontrol: 'CommandOrControl', cmdorctrl: 'CommandOrControl',
};

// The order normalize() always emits modifiers in, so two accelerators that
// mean the same combo compare equal as strings (needed for the conflict
// check in validate()).
const MODIFIER_ORDER = ['Command', 'CommandOrControl', 'Control', 'Alt', 'Shift'];

// Punctuation Electron accepts as a key, plus each one's shifted character --
// someone binding a shortcut types whichever their keyboard actually sends.
const PUNCT_KEYS = new Set([
  '`', '-', '=', '[', ']', '\\', ';', "'", ',', '.', '/',
  '~', '_', '+', '{', '}', '|', ':', '"', '<', '>', '?',
]);

// Named keys, cased exactly as Electron's accelerator parser expects --
// TitleCase for most, but the numpad row is lower-case in Electron itself,
// so it stays lower-case here too rather than being "fixed" to match the rest.
const NAMED_KEYS = [
  'Space', 'Tab', 'Backspace', 'Delete', 'Insert', 'Return', 'Enter',
  'Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown',
  'Escape', 'Plus', 'PrintScreen',
];
for (let i = 1; i <= 24; i++) NAMED_KEYS.push('F' + i);
NAMED_KEYS.push('numdec', 'numadd', 'numsub', 'nummult', 'numdiv');
for (let i = 0; i <= 9; i++) NAMED_KEYS.push('num' + i);

const NAMED_KEY_LOOKUP = {};
for (const k of NAMED_KEYS) NAMED_KEY_LOOKUP[k.toLowerCase()] = k;

function canonicalKey(key) {
  if (/^[A-Za-z0-9]$/.test(key)) return key.toUpperCase();
  if (PUNCT_KEYS.has(key)) return key;
  return NAMED_KEY_LOOKUP[key.toLowerCase()] || '';
}

// Parses whatever a capture UI or an old settings.json hands in and returns
// Electron's own accelerator syntax, or '' if the input can't be one. '' is
// a valid result, not an error state -- it means "deliberately unbound".
function normalize(accel) {
  if (typeof accel !== 'string') return '';
  const trimmed = accel.trim();
  if (!trimmed) return '';

  // '+' is both the separator and a bindable key, so a combo ending in it
  // ('Alt+Shift++', which is what capturing ⌥⇧= sends on a US layout) would
  // otherwise split into an empty key and be refused. Lift it out to its
  // Electron name before splitting; nothing after this point sees a bare '+'.
  const body = trimmed.length > 1 && trimmed.endsWith('+')
    ? trimmed.slice(0, -1) + 'Plus'
    : trimmed;

  const mods = new Set();
  let key = '';
  let extraKey = false;
  for (const part of body.split('+').map((p) => p.trim())) {
    if (!part) continue; // a stray '+' next to itself, not a Plus key
    const alias = MODIFIER_ALIASES[part.toLowerCase()];
    if (alias) mods.add(alias);
    else if (!key) key = part;
    else extraKey = true; // more than one non-modifier part -- not one key
  }
  if (extraKey || !key) return '';

  // A bare global key with no modifier would swallow that key for every app
  // on the machine, not just Pomoppi -- refuse it rather than register it.
  if (mods.size === 0) return '';

  const resolvedKey = canonicalKey(key);
  if (!resolvedKey) return '';

  const out = MODIFIER_ORDER.filter((m) => mods.has(m));
  out.push(resolvedKey);
  return out.join('+');
}

const DEFAULTS = Object.freeze(
  ACTIONS.reduce((acc, a) => {
    acc[a.id] = normalize(a.default);
    return acc;
  }, {}),
);

// Fills in every id, clamping rather than rejecting (SPEC.md §7): an id
// missing from raw falls back to its default, one present but unbindable
// stays unbound ('' -- the raw value was a deliberate choice, not an
// omission), and unknown ids are dropped.
function validate(raw) {
  const out = { ...DEFAULTS };
  if (raw && typeof raw === 'object') {
    for (const id of ACTION_IDS) {
      if (Object.prototype.hasOwnProperty.call(raw, id)) out[id] = normalize(raw[id]);
    }
  }

  // Two actions can't share one global accelerator -- macOS would only ever
  // fire one of them. Walk ACTION_IDS in table order so the earlier action
  // keeps a contested combo and the later one loses it, rather than the
  // outcome depending on object key order.
  const claimed = new Set();
  for (const id of ACTION_IDS) {
    if (!out[id]) continue;
    if (claimed.has(out[id])) out[id] = '';
    else claimed.add(out[id]);
  }

  return out;
}

const MODIFIER_GLYPHS = { Control: '⌃', Alt: '⌥', Shift: '⇧', Command: '⌘', CommandOrControl: '⌘' };
const KEY_GLYPHS = { Space: 'Space', Return: '↩', Enter: '↩', Escape: '⎋', Up: '↑', Down: '↓', Left: '←', Right: '→' };

// Human string for macOS, e.g. 'Alt+Shift+P' -> '⌥⇧P'. Purely cosmetic --
// the settings window's capture buttons and nowhere else reads this.
function display(accel) {
  if (!accel) return 'Not set';
  const parts = accel.split('+');
  const key = parts[parts.length - 1];
  const mods = new Set(parts.slice(0, -1));

  // macOS glyph order is fixed (⌃⌥⇧⌘) regardless of the storage order above.
  let out = '';
  for (const m of ['Control', 'Alt', 'Shift', 'Command', 'CommandOrControl']) {
    if (mods.has(m)) out += MODIFIER_GLYPHS[m];
  }
  return out + (KEY_GLYPHS[key] || key);
}

const SHORTCUTS = { ACTIONS, ACTION_IDS, DEFAULTS, normalize, validate, display };

if (typeof module !== 'undefined' && module.exports) module.exports = SHORTCUTS;
if (typeof window !== 'undefined') window.SHORTCUTS = SHORTCUTS;
