'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const Settings = require('../lib/settings');
const { FRIEND_IDS } = require('../renderer/sprites');
const { BACKGROUND_IDS } = require('../renderer/background');
const SHORTCUTS = require('../renderer/shortcuts');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-settings-'));
}

test('fresh directory loads defaults and writes settings.json', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const s = settings.get();
  assert.equal(s.focusMinutes, 25);
  assert.equal(s.scale, 2);
  assert.equal(s.friend, FRIEND_IDS[0]);
  assert.equal(s.vaultPath, '/Users/lucabessiaristei/Documents/Opal');

  const filePath = path.join(dir, 'settings.json');
  assert.equal(fs.existsSync(filePath), true);
  const onDisk = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  assert.equal(onDisk.focusMinutes, 25);
});

test('missing keys fall back to defaults, unknown keys are dropped', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({
    focusMinutes: 50,
    somethingMadeUp: 'nope',
  }));
  const settings = new Settings(dir);
  const s = settings.get();
  assert.equal(s.focusMinutes, 50);
  assert.equal(s.shortBreakMinutes, 5); // default, key was missing
  assert.equal('somethingMadeUp' in s, false);

  const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.equal('somethingMadeUp' in onDisk, false);
});

test('corrupt file is replaced with defaults and backed up to .bak', () => {
  const dir = tmpDir();
  const filePath = path.join(dir, 'settings.json');
  fs.writeFileSync(filePath, '{ this is not json');
  const settings = new Settings(dir);
  const s = settings.get();
  assert.equal(s.focusMinutes, 25); // defaults

  assert.equal(fs.existsSync(filePath + '.bak'), true);
  assert.equal(fs.readFileSync(filePath + '.bak', 'utf8'), '{ this is not json');
  const onDisk = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  assert.equal(onDisk.focusMinutes, 25);
});

test('set() clamps out-of-range numeric values', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const s = settings.set({
    focusMinutes: 999,
    shortBreakMinutes: 0,
    longBreakEvery: 100,
    opacity: 5,
    ringSeconds: -10,
  });
  assert.equal(s.focusMinutes, 180);
  assert.equal(s.shortBreakMinutes, 1);
  assert.equal(s.longBreakEvery, 10);
  assert.equal(s.opacity, 1.0);
  assert.equal(s.ringSeconds, 0);
});

test('a settings.json written before the rename keeps its friend', () => {
  const dir = tmpDir();
  // The pre-rename key, as it sits in an existing settings.json.
  const legacy = Settings.DEFAULTS.friend === 'utsupon' ? 'namidappi' : 'utsupon';
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ mascot: legacy }));
  const settings = new Settings(dir);
  assert.equal(settings.get().friend, legacy);

  // Written back under the new name, and the old key does not linger.
  settings.set({});
  const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.equal(onDisk.friend, legacy);
  assert.equal('mascot' in onDisk, false);
});

test('set() snaps an invalid scale back to the default rather than rejecting', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const s = settings.set({ scale: 7 });
  assert.equal(s.scale, 2);
  const ok = settings.set({ scale: 4 });
  assert.equal(ok.scale, 4);
});

test('every offered scale is accepted, 1x included', () => {
  const settings = new Settings(tmpDir());
  // 1x is 104x128 physical pixels -- tiny, but a real option (SPEC.md 7).
  for (const n of [1, 2, 3, 4]) assert.equal(settings.set({ scale: n }).scale, n);
  // and nothing outside that set survives
  for (const n of [0, 5, 1.5, '3', null]) assert.equal([1, 2, 3, 4].includes(settings.set({ scale: n }).scale), true);
});

test('set() performs a shallow merge, leaving other keys untouched', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  settings.set({ focusMinutes: 40 });
  const s = settings.set({ shortBreakMinutes: 10 });
  assert.equal(s.focusMinutes, 40);
  assert.equal(s.shortBreakMinutes, 10);
});

test('reset() restores every default and persists it', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  settings.set({ focusMinutes: 5, vaultPath: '/tmp/somewhere' });
  const s = settings.reset();
  assert.equal(s.focusMinutes, 25);
  assert.equal(s.vaultPath, '/Users/lucabessiaristei/Documents/Opal');

  const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.equal(onDisk.focusMinutes, 25);
});

test('non-boolean values for boolean keys are coerced', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const s = settings.set({ autoStartBreaks: 0, soundEnabled: 'yes' });
  assert.equal(s.autoStartBreaks, false);
  assert.equal(s.soundEnabled, true);
});

// -- startHidden -------------------------------------------------------------
// Startup-only preference (main.js createWidgetWindow); never acted on by
// applySettingsSideEffects at runtime.

test('startHidden defaults to false', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  assert.equal(settings.get().startHidden, false);
});

test('startHidden is coerced to a boolean like the other flags', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const s = settings.set({ startHidden: 1 });
  assert.equal(s.startHidden, true);
});

test('startHidden survives a save/reload round trip', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  settings.set({ startHidden: true });

  const reloaded = new Settings(dir);
  assert.equal(reloaded.get().startHidden, true);

  const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.equal(onDisk.startHidden, true);
});

test('set() accepts any known friend id from renderer/sprites.js', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  assert.equal(FRIEND_IDS.length > 1, true); // sanity: more than just the default exists
  for (const id of FRIEND_IDS) {
    const s = settings.set({ friend: id });
    assert.equal(s.friend, id);
  }
});

test('set() falls back to tama for an unknown friend id', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const otherId = FRIEND_IDS.find((id) => id !== FRIEND_IDS[0]);
  settings.set({ friend: otherId });
  const s = settings.set({ friend: 'definitely-not-a-real-pet' });
  assert.equal(s.friend, FRIEND_IDS[0]);
});

test('a corrupt-friend value on disk is corrected on load, not just on set()', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ friend: 'nope' }));
  const settings = new Settings(dir);
  assert.equal(settings.get().friend, FRIEND_IDS[0]);
});

test('set() accepts any known background id from renderer/background.js', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  assert.equal(BACKGROUND_IDS.length > 1, true); // sanity: more than just the default exists
  for (const id of BACKGROUND_IDS) {
    const s = settings.set({ background: id });
    assert.equal(s.background, id);
  }
});

test('set() falls back to the default background for an unknown id', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const otherId = BACKGROUND_IDS.find((id) => id !== BACKGROUND_IDS[0]);
  settings.set({ background: otherId });
  const s = settings.set({ background: 'definitely-not-a-real-background' });
  assert.equal(s.background, BACKGROUND_IDS[0]);
});

test('a corrupt-background value on disk is corrected on load, not just on set()', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ background: 'nope' }));
  const settings = new Settings(dir);
  assert.equal(settings.get().background, BACKGROUND_IDS[0]);
});

// -- petMovement -------------------------------------------------------------
// Off by default (see lib/settings.js DEFAULTS.petMovement): a wandering pet
// changes the widget's resting look, so it's opt-in, not switched on under
// an existing install.

test('petMovement defaults to false', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  assert.equal(settings.get().petMovement, false);
});

test('petMovement is coerced to a boolean like the other flags', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const s = settings.set({ petMovement: 1 });
  assert.equal(s.petMovement, true);
});

test('petMovement survives a save/reload round trip', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  settings.set({ petMovement: true });

  const reloaded = new Settings(dir);
  assert.equal(reloaded.get().petMovement, true);

  const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.equal(onDisk.petMovement, true);
});

// -- Settings.clampFocusAdjust / Settings.clampLongBreakEvery --------------
// Back the widget's click-to-adjust controls (main.js habitsuu:adjustFocusMinutes
// / habitsuu:setLongBreakEvery). Their range is deliberately narrower than the
// settings-form range, so these get their own tests rather than reusing the
// set()-clamping ones above.

test('clampFocusAdjust adds the delta then clamps into 5..90', () => {
  assert.equal(Settings.clampFocusAdjust(25, 5), 30);
  assert.equal(Settings.clampFocusAdjust(25, -5), 20);
  assert.equal(Settings.clampFocusAdjust(88, 10), 90); // clamps at the top
  assert.equal(Settings.clampFocusAdjust(6, -10), 5);  // clamps at the bottom
  assert.equal(Settings.clampFocusAdjust(25, 0), 25);
});

test('clampFocusAdjust falls back sanely on non-numeric input', () => {
  assert.equal(Settings.clampFocusAdjust(NaN, 5), 30);   // bad base -> default (25), then + delta
  assert.equal(Settings.clampFocusAdjust(25, NaN), 25);  // bad delta -> treated as 0
  assert.equal(Settings.clampFocusAdjust(undefined, undefined), 25);
});

test('clampLongBreakEvery rounds and clamps into 2..8', () => {
  assert.equal(Settings.clampLongBreakEvery(1), 2);   // clamps at the bottom
  assert.equal(Settings.clampLongBreakEvery(4), 4);
  assert.equal(Settings.clampLongBreakEvery(10), 10); // the widget's full dot row
  assert.equal(Settings.clampLongBreakEvery(12), 10); // clamps at the top
  assert.equal(Settings.clampLongBreakEvery(5.6), 6); // rounds
});

test('clampLongBreakEvery falls back to the default on non-numeric input', () => {
  assert.equal(Settings.clampLongBreakEvery(NaN), Settings.DEFAULTS.longBreakEvery);
  assert.equal(Settings.clampLongBreakEvery(undefined), Settings.DEFAULTS.longBreakEvery);
});

// -- Settings.clampFocusDurationSeconds ------------------------------------
// Backs the widget's directly-editable clock (main.js habitsuu:setFocusDuration).

test('clampFocusDurationSeconds clamps into 60..5400 seconds (1..90 minutes)', () => {
  assert.equal(Settings.clampFocusDurationSeconds(30), 60);      // clamps at the bottom
  assert.equal(Settings.clampFocusDurationSeconds(6000), 5400);  // clamps at the top
  assert.equal(Settings.clampFocusDurationSeconds(1500), 1500);  // 25 minutes, untouched
  assert.equal(Settings.clampFocusDurationSeconds(125), 125);    // sub-minute precision preserved
});

test('clampFocusDurationSeconds falls back to the default focus length on non-numeric input', () => {
  assert.equal(Settings.clampFocusDurationSeconds(NaN), Settings.DEFAULTS.focusMinutes * 60);
  assert.equal(Settings.clampFocusDurationSeconds(undefined), Settings.DEFAULTS.focusMinutes * 60);
});

// -- dailyNoteFolder default -------------------------------------------------

test('fresh install defaults dailyNoteFolder to a Pomodoro subfolder, not the vault root', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  assert.equal(settings.get().dailyNoteFolder, 'Pomodoro');
});

test('a settings.json that already had dailyNoteFolder set keeps its own value on load', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ dailyNoteFolder: '' }));
  const settings = new Settings(dir);
  assert.equal(settings.get().dailyNoteFolder, ''); // old root-writing installs are left alone
});

// --- theme pair (SPEC.md §1, §7) --------------------------------------------

test('the theme pair defaults to black on white', () => {
  const settings = new Settings(tmpDir());
  const s = settings.get();
  assert.equal(s.inkColor, '#000000');
  assert.equal(s.paperColor, '#FFFFFF');
});

test('colours normalise to upper-case #RRGGBB, expanding the 3-digit form', () => {
  const settings = new Settings(tmpDir());
  // Consumers compare and blend these without re-parsing, so one canonical
  // shape matters more than accepting exactly what was typed.
  assert.equal(settings.set({ inkColor: '2a2' }).inkColor, '#22AA22');
  assert.equal(settings.set({ inkColor: '#1a2b3c' }).inkColor, '#1A2B3C');
  assert.equal(settings.set({ paperColor: 'FFEEDD' }).paperColor, '#FFEEDD');
  assert.equal(settings.set({ paperColor: '  #AbCdEf  ' }).paperColor, '#ABCDEF');
  assert.equal(settings.set({ paperColor: 'eee' }).paperColor, '#EEEEEE');
});

test('an unparseable colour falls back to that key default, and clamps rather than rejects', () => {
  const settings = new Settings(tmpDir());
  assert.equal(settings.set({ inkColor: 'rebeccapurple' }).inkColor, '#000000');
  assert.equal(settings.set({ paperColor: '#12345' }).paperColor, '#FFFFFF');
  assert.equal(settings.set({ inkColor: null }).inkColor, '#000000');
  assert.equal(settings.set({ paperColor: 42 }).paperColor, '#FFFFFF');
});

test('ink equal to paper resets the whole pair, never leaving a blank widget', () => {
  const settings = new Settings(tmpDir());
  // Both the same colour would draw a widget with nothing visible on it and
  // no way to click back out, so the pair goes back to the defaults together.
  const s = settings.set({ inkColor: '#123456', paperColor: '#123456' });
  assert.equal(s.inkColor, '#000000');
  assert.equal(s.paperColor, '#FFFFFF');

  // Only when they actually collide -- a legitimate pair survives untouched.
  const ok = settings.set({ inkColor: '#1A1A2E', paperColor: '#EAEAEA' });
  assert.equal(ok.inkColor, '#1A1A2E');
  assert.equal(ok.paperColor, '#EAEAEA');
});

test('a themed pair survives a reload from disk', () => {
  const dir = tmpDir();
  new Settings(dir).set({ inkColor: '#2E1A1A', paperColor: '#F5EFE6' });
  const reloaded = new Settings(dir).get();
  assert.equal(reloaded.inkColor, '#2E1A1A');
  assert.equal(reloaded.paperColor, '#F5EFE6');
});

test('reset() puts the theme back to black on white', () => {
  const settings = new Settings(tmpDir());
  settings.set({ inkColor: '#2E1A1A', paperColor: '#F5EFE6' });
  const s = settings.reset();
  assert.equal(s.inkColor, '#000000');
  assert.equal(s.paperColor, '#FFFFFF');
});

// --- shortcuts (renderer/shortcuts.js) --------------------------------------
// The schema's only nested object -- SHORTCUTS.validate() does the actual
// validation, so these just prove lib/settings.js wires it in correctly.

test('a fresh settings file gets the default shortcuts', () => {
  const settings = new Settings(tmpDir());
  assert.deepEqual(settings.get().shortcuts, SHORTCUTS.DEFAULTS);
});

test('a partial shortcuts object on disk is completed from defaults', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({
    shortcuts: { skip: 'Alt+Shift+X' },
  }));
  const settings = new Settings(dir);
  const s = settings.get();
  assert.equal(s.shortcuts.skip, 'Alt+Shift+X');
  assert.equal(s.shortcuts.toggleWidget, SHORTCUTS.DEFAULTS.toggleWidget);
});

test('a garbage shortcuts value falls back to the defaults, not just the offending id', () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'settings.json'), JSON.stringify({ shortcuts: 'nope' }));
  const settings = new Settings(dir);
  assert.deepEqual(settings.get().shortcuts, SHORTCUTS.DEFAULTS);
});

test('set({ shortcuts }) round-trips through persistence', () => {
  const dir = tmpDir();
  const settings = new Settings(dir);
  const next = { ...settings.get().shortcuts, skip: 'Alt+Shift+X' };
  const s = settings.set({ shortcuts: next });
  assert.equal(s.shortcuts.skip, 'Alt+Shift+X');

  const reloaded = new Settings(dir);
  assert.equal(reloaded.get().shortcuts.skip, 'Alt+Shift+X');

  const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json'), 'utf8'));
  assert.equal(onDisk.shortcuts.skip, 'Alt+Shift+X');
});
