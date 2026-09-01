'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ObsidianLogger = require('../lib/obsidian');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-obsidian-'));
}

function ts(h, m) {
  return new Date(2024, 0, 15, h, m, 0, 0).getTime();
}

function noteFile(dir) {
  return path.join(dir, '2024-01-15.md');
}

function makeLogger(dir, overrides) {
  const settings = Object.assign({
    vaultPath: dir,
    dailyNoteFolder: '',
    dailyNoteFormat: 'YYYY-MM-DD',
    logHeading: '## Pomodoros',
    logBreaks: false,
    logAborted: false,
    loggingEnabled: true,
  }, overrides);
  return new ObsidianLogger(() => settings);
}

function focusEntry(overrides) {
  return Object.assign({
    phase: 'focus',
    startedAt: ts(9, 15),
    endedAt: ts(9, 40),
    plannedMs: 25 * 60000,
    actualMs: 25 * 60000,
    task: 'writing spec',
    completed: true,
  }, overrides);
}

function breakEntry(overrides) {
  return Object.assign({
    phase: 'shortBreak',
    startedAt: ts(9, 45),
    endedAt: ts(9, 50),
    plannedMs: 5 * 60000,
    actualMs: 5 * 60000,
    task: '',
    completed: true,
  }, overrides);
}

test('file missing: creates the file, heading, entry and total', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir);
  const result = await logger.logSession(focusEntry());
  assert.equal(result.ok, true);

  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:15–09:40 (25m) — writing spec ✅',
    '',
    '**Total focus: 25m across 1 pomodoros**',
    '',
  ].join('\n'));
});

test('heading missing from an existing file: appended at end, preceded by a blank line', async () => {
  const dir = tmpDir();
  fs.writeFileSync(noteFile(dir), '# Daily Notes\n\nSome unrelated text\n');
  const logger = makeLogger(dir);
  await logger.logSession(focusEntry());

  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '# Daily Notes',
    '',
    'Some unrelated text',
    '',
    '## Pomodoros',
    '- 09:15–09:40 (25m) — writing spec ✅',
    '',
    '**Total focus: 25m across 1 pomodoros**',
    '',
  ].join('\n'));
});

test('heading present with no entries yet', async () => {
  const dir = tmpDir();
  fs.writeFileSync(noteFile(dir), '## Pomodoros\n');
  const logger = makeLogger(dir);
  await logger.logSession(focusEntry());

  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:15–09:40 (25m) — writing spec ✅',
    '',
    '**Total focus: 25m across 1 pomodoros**',
    '',
  ].join('\n'));
});

test('heading present, immediately followed by another ## heading', async () => {
  const dir = tmpDir();
  fs.writeFileSync(noteFile(dir), '## Pomodoros\n## Other Section\n- unrelated bullet\n');
  const logger = makeLogger(dir);
  await logger.logSession(focusEntry());

  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:15–09:40 (25m) — writing spec ✅',
    '',
    '**Total focus: 25m across 1 pomodoros**',
    '## Other Section',
    '- unrelated bullet',
    '',
  ].join('\n'));
});

test('existing **Total focus: line is recomputed in place, matching the SPEC.md §8 example', async () => {
  const dir = tmpDir();
  fs.writeFileSync(noteFile(dir), [
    '## Pomodoros',
    '- 09:15–09:40 (25m) — writing spec ✅',
    '- 09:45–09:50 (5m break)',
    '',
    '**Total focus: 25m across 1 pomodoros**',
    '',
  ].join('\n'));

  const logger = makeLogger(dir);
  await logger.logSession(focusEntry({
    startedAt: ts(10, 0),
    endedAt: ts(10, 25),
    task: 'refactor auth',
  }));

  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:15–09:40 (25m) — writing spec ✅',
    '- 09:45–09:50 (5m break)',
    '- 10:00–10:25 (25m) — refactor auth ✅',
    '',
    '**Total focus: 50m across 2 pomodoros**',
    '',
  ].join('\n'));
});

test('completed break entries have no checkmark and are only logged when logBreaks is on', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir, { logBreaks: false });
  const skipped = await logger.logSession(breakEntry());
  assert.equal(skipped.ok, true);
  assert.equal(skipped.skipped, true);
  assert.equal(fs.existsSync(noteFile(dir)), false);

  const logger2 = makeLogger(dir, { logBreaks: true });
  await logger2.logSession(breakEntry());
  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:45–09:50 (5m break)',
    '',
    '**Total focus: 0m across 0 pomodoros**',
    '',
  ].join('\n'));
});

test('aborted focus session uses ❌ and elapsed time, not the target, gated by logAborted', async () => {
  const dir = tmpDir();
  const aborted = focusEntry({ completed: false, actualMs: 7 * 60000, endedAt: ts(9, 22) });

  const skippedLogger = makeLogger(dir, { logAborted: false });
  const skipped = await skippedLogger.logSession(aborted);
  assert.equal(skipped.skipped, true);
  assert.equal(fs.existsSync(noteFile(dir)), false);

  const logger = makeLogger(dir, { logAborted: true });
  await logger.logSession(aborted);
  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:15–09:22 (7m) — writing spec ❌',
    '',
    '**Total focus: 0m across 0 pomodoros**',
    '',
  ].join('\n'));
});

test('task is omitted entirely (no em dash) when empty', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir);
  await logger.logSession(focusEntry({ task: '' }));
  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content.includes('— '), false);
  assert.match(content, /^- 09:15–09:40 \(25m\) ✅$/m);
});

test('loggingEnabled: false suppresses all logging', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir, { loggingEnabled: false });
  const result = await logger.logSession(focusEntry());
  assert.equal(result.skipped, true);
  assert.equal(fs.existsSync(noteFile(dir)), false);
});

test('concurrent logSession calls are serialised without interleaving', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir);
  const first = logger.logSession(focusEntry({ startedAt: ts(9, 0), endedAt: ts(9, 25) }));
  const second = logger.logSession(focusEntry({ startedAt: ts(9, 30), endedAt: ts(9, 55), task: 'second' }));
  const [r1, r2] = await Promise.all([first, second]);
  assert.equal(r1.ok, true);
  assert.equal(r2.ok, true);

  const content = fs.readFileSync(noteFile(dir), 'utf8');
  assert.equal(content, [
    '## Pomodoros',
    '- 09:00–09:25 (25m) — writing spec ✅',
    '- 09:30–09:55 (25m) — second ✅',
    '',
    '**Total focus: 50m across 2 pomodoros**',
    '',
  ].join('\n'));
});

test('logSession never throws, even for an unwritable vault path', async () => {
  const dir = tmpDir();
  const blocker = path.join(dir, 'blocker');
  fs.writeFileSync(blocker, 'i am a file, not a directory');
  const logger = new ObsidianLogger(() => ({
    vaultPath: blocker,
    dailyNoteFolder: 'sub',
    dailyNoteFormat: 'YYYY-MM-DD',
    logHeading: '## Pomodoros',
    logBreaks: false,
    logAborted: false,
    loggingEnabled: true,
  }));
  const result = await logger.logSession(focusEntry());
  assert.equal(result.ok, false);
  assert.equal(typeof result.error, 'string');
});

test('a multi-level dailyNoteFolder is created on demand, intermediate directories included', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir, { dailyNoteFolder: 'Pomodoro/2024' });
  const result = await logger.logSession(focusEntry());
  assert.equal(result.ok, true);

  const filePath = path.join(dir, 'Pomodoro', '2024', '2024-01-15.md');
  assert.equal(fs.existsSync(filePath), true);
  const content = fs.readFileSync(filePath, 'utf8');
  assert.match(content, /^## Pomodoros$/m);
});

test('test() reports the resolved daily-note path when the vault is writable', async () => {
  const dir = tmpDir();
  const logger = makeLogger(dir, { dailyNoteFolder: 'sub' });
  const result = await logger.test();
  assert.equal(result.ok, true);
  const now = new Date();
  const expectedName = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}.md`;
  assert.equal(result.path, path.join(dir, 'sub', expectedName));
});

test('test() resolves ok:false for an unwritable vault path instead of throwing', async () => {
  const dir = tmpDir();
  const blocker = path.join(dir, 'blocker');
  fs.writeFileSync(blocker, 'i am a file, not a directory');
  const logger = new ObsidianLogger(() => ({
    vaultPath: blocker,
    dailyNoteFolder: 'sub',
    dailyNoteFormat: 'YYYY-MM-DD',
    logHeading: '## Pomodoros',
  }));
  const result = await logger.test();
  assert.equal(result.ok, false);
  assert.equal(typeof result.error, 'string');
});
