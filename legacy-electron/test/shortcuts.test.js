'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const SHORTCUTS = require('../renderer/shortcuts');
const { ACTION_IDS, DEFAULTS, normalize, validate, display } = SHORTCUTS;

// -- normalize(): modifier aliasing and canonical ordering -------------------

test('normalize maps every modifier alias to its canonical name', () => {
  assert.equal(normalize('cmd+P'), 'Command+P');
  assert.equal(normalize('super+P'), 'Command+P');
  assert.equal(normalize('meta+P'), 'Command+P');
  assert.equal(normalize('ctrl+P'), 'Control+P');
  assert.equal(normalize('option+P'), 'Alt+P');
  assert.equal(normalize('opt+P'), 'Alt+P');
  assert.equal(normalize('cmdorctrl+P'), 'CommandOrControl+P');
  assert.equal(normalize('CommandOrControl+P'), 'CommandOrControl+P');
});

test('normalize reorders modifiers to Command, CommandOrControl, Control, Alt, Shift', () => {
  assert.equal(normalize('Shift+Alt+P'), 'Alt+Shift+P');
  assert.equal(normalize('shift+control+P'), 'Control+Shift+P');
  assert.equal(normalize('Shift+Command+Control+Alt+P'), 'Command+Control+Alt+Shift+P');
});

test('normalize collapses a modifier repeated in the input', () => {
  assert.equal(normalize('Alt+alt+P'), 'Alt+P');
  assert.equal(normalize('Shift+Shift+Alt+P'), 'Alt+Shift+P');
});

// -- normalize(): bare-key rejection ------------------------------------------

test('normalize rejects a key with no modifier at all', () => {
  // A bare global key would swallow that key for every app on the machine.
  assert.equal(normalize('P'), '');
  assert.equal(normalize('Space'), '');
  assert.equal(normalize('F5'), '');
  assert.equal(normalize(','), '');
});

test('normalize rejects modifiers with no key', () => {
  assert.equal(normalize('Alt+Shift'), '');
  assert.equal(normalize('Command'), '');
});

test('normalize rejects more than one non-modifier part', () => {
  assert.equal(normalize('Alt+P+K'), '');
});

// -- normalize(): named-key casing --------------------------------------------

test('normalize matches named keys case-insensitively and emits the listed casing', () => {
  assert.equal(normalize('alt+space'), 'Alt+Space');
  assert.equal(normalize('alt+SPACE'), 'Alt+Space');
  assert.equal(normalize('alt+PageUp'), 'Alt+PageUp');
  assert.equal(normalize('alt+pageup'), 'Alt+PageUp');
  assert.equal(normalize('alt+PAGEDOWN'), 'Alt+PageDown');
  assert.equal(normalize('alt+return'), 'Alt+Return');
  assert.equal(normalize('alt+ENTER'), 'Alt+Enter');
  assert.equal(normalize('alt+f5'), 'Alt+F5');
  assert.equal(normalize('alt+F24'), 'Alt+F24');
  assert.equal(normalize('alt+printscreen'), 'Alt+PrintScreen');
});

test('normalize keeps the numpad row lower-case, matching Electron itself', () => {
  assert.equal(normalize('alt+NUM5'), 'Alt+num5');
  assert.equal(normalize('alt+numadd'), 'Alt+numadd');
  assert.equal(normalize('alt+NUMDEC'), 'Alt+numdec');
});

test('normalize upper-cases a single letter or digit key', () => {
  assert.equal(normalize('alt+p'), 'Alt+P');
  assert.equal(normalize('alt+9'), 'Alt+9');
});

// -- normalize(): punctuation keys --------------------------------------------

test('normalize accepts the base punctuation row as-is', () => {
  assert.equal(normalize('Alt+,'), 'Alt+,');
  assert.equal(normalize('Alt+.'), 'Alt+.');
  assert.equal(normalize("Alt+'"), "Alt+'");
  assert.equal(normalize('Alt+;'), 'Alt+;');
  assert.equal(normalize('Alt+/'), 'Alt+/');
  assert.equal(normalize('Alt+`'), 'Alt+`');
});

test('normalize accepts the shifted punctuation row as-is', () => {
  assert.equal(normalize('Alt+<'), 'Alt+<');
  assert.equal(normalize('Alt+>'), 'Alt+>');
  assert.equal(normalize('Alt+?'), 'Alt+?');
  assert.equal(normalize('Alt+"'), 'Alt+"');
  assert.equal(normalize('Alt+:'), 'Alt+:');
  assert.equal(normalize('Alt+~'), 'Alt+~');
});

// -- normalize(): invalid input -> '' -----------------------------------------

test('normalize returns "" for non-string or empty input', () => {
  assert.equal(normalize(undefined), '');
  assert.equal(normalize(null), '');
  assert.equal(normalize(42), '');
  assert.equal(normalize(''), '');
  assert.equal(normalize('   '), '');
});

test('normalize returns "" for a key that is not on the accepted list', () => {
  assert.equal(normalize('Alt+@'), '');
  assert.equal(normalize('Alt+F25'), '');
  assert.equal(normalize('Alt+Foo'), '');
});

// -- validate() ---------------------------------------------------------------

test('validate() with no input returns exactly the defaults', () => {
  assert.deepEqual(validate(undefined), DEFAULTS);
  assert.deepEqual(validate(null), DEFAULTS);
  assert.deepEqual(validate({}), DEFAULTS);
});

test('validate() fills missing ids from defaults and normalizes the ones present', () => {
  const out = validate({ toggleWidget: 'shift+alt+x' });
  assert.equal(out.toggleWidget, 'Alt+Shift+X');
  for (const id of ACTION_IDS) {
    if (id === 'toggleWidget') continue;
    assert.equal(out[id], DEFAULTS[id]);
  }
});

test('validate() honours an explicit "" as deliberately unbound', () => {
  const out = validate({ skip: '' });
  assert.equal(out.skip, '');
  // every other id still falls back to its default, unaffected
  assert.equal(out.toggleWidget, DEFAULTS.toggleWidget);
});

test('validate() honours an unbindable value as "" too, distinct from a missing id', () => {
  const out = validate({ skip: 'just-junk' });
  assert.equal(out.skip, '');
});

test('validate() drops ids that are not in ACTION_IDS', () => {
  const out = validate({ toggleWidget: DEFAULTS.toggleWidget, notARealAction: 'Alt+Shift+Z' });
  assert.equal('notARealAction' in out, false);
  assert.deepEqual(Object.keys(out).sort(), [...ACTION_IDS].sort());
});

test('validate() resolves a duplicate accelerator in favour of the earlier ACTION_IDS entry', () => {
  // toggleWidget precedes startPause in ACTION_IDS, so it keeps the combo and
  // startPause -- reaching for the same one -- loses it rather than the app
  // silently registering two global shortcuts for one key combination.
  const combo = 'Alt+Shift+Q';
  const out = validate({ toggleWidget: combo, startPause: combo });
  assert.equal(out.toggleWidget, combo);
  assert.equal(out.startPause, '');
});

test('validate() clears a later action that collides with an earlier one left at its default', () => {
  const out = validate({ startPause: DEFAULTS.toggleWidget });
  assert.equal(out.toggleWidget, DEFAULTS.toggleWidget);
  assert.equal(out.startPause, '');
});

test('validate() ignores a non-object raw value entirely, same as settings.js', () => {
  assert.deepEqual(validate('nope'), DEFAULTS);
  assert.deepEqual(validate(42), DEFAULTS);
});

// -- display() -----------------------------------------------------------------

test('display() reports "Not set" for an unbound accelerator', () => {
  assert.equal(display(''), 'Not set');
});

test('display() renders modifiers in macOS order with glyphs, then the key', () => {
  assert.equal(display('Alt+Shift+P'), '⌥⇧P');
  assert.equal(display('Control+Alt+Shift+Command+Space'), '⌃⌥⇧⌘Space');
  assert.equal(display('CommandOrControl+,'), '⌘,');
});

test('display() maps the named keys with their own glyphs', () => {
  assert.equal(display('Alt+Shift+Return'), '⌥⇧↩');
  assert.equal(display('Alt+Enter'), '⌥↩');
  assert.equal(display('Alt+Escape'), '⌥⎋');
  assert.equal(display('Alt+Up'), '⌥↑');
  assert.equal(display('Alt+Down'), '⌥↓');
  assert.equal(display('Alt+Left'), '⌥←');
  assert.equal(display('Alt+Right'), '⌥→');
});

test('display() leaves an unmapped key exactly as normalize() emitted it', () => {
  assert.equal(display('Alt+F5'), '⌥F5');
  assert.equal(display('Alt+numadd'), '⌥numadd');
  assert.equal(display('Alt+,'), '⌥,');
});
