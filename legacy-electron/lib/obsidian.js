// lib/obsidian.js — daily-note appender (SPEC.md §8). Pure fs/path, no
// Electron. Writes are atomic (.tmp + rename) and serialised through a
// promise chain so two sessions can never interleave. Never throws outward —
// every public method resolves, worst case with {ok:false, error}.
'use strict';

const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const paths = require('./paths');

const HEADING_RE = /^##(?!#)\s/; // a level-2 heading, but not ###+

function pad2(n) {
  return String(n).padStart(2, '0');
}

function formatClock(epochMs) {
  const d = new Date(epochMs);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function minutesFrom(ms) {
  return Math.max(0, Math.round(ms / 60000));
}

// Builds the "- ..." line for one session entry.
function buildEntryLine(entry) {
  const isFocus = entry.phase === 'focus';
  const minutes = minutesFrom(entry.completed ? entry.plannedMs : entry.actualMs);
  const start = formatClock(entry.startedAt);
  const end = formatClock(entry.endedAt);
  const durationLabel = isFocus ? `${minutes}m` : `${minutes}m break`;
  const taskPart = isFocus && entry.task ? ` — ${entry.task}` : '';
  // Completed breaks carry no mark (per the SPEC.md §8 example); aborted
  // sessions of any phase are marked ❌; completed focus sessions are ✅.
  const mark = !entry.completed ? '❌' : (isFocus ? '✅' : '');
  const markPart = mark ? ` ${mark}` : '';
  return `- ${start}–${end} (${durationLabel})${taskPart}${markPart}`;
}

function findSection(lines, heading) {
  const headingIndex = lines.findIndex((l) => l === heading);
  if (headingIndex === -1) return null;
  let endIndex = lines.length;
  for (let i = headingIndex + 1; i < lines.length; i++) {
    if (HEADING_RE.test(lines[i])) {
      endIndex = i;
      break;
    }
  }
  return { headingIndex, endIndex };
}

function buildTotalLine(lines, start, end) {
  let totalMinutes = 0;
  let count = 0;
  for (let i = start; i < end; i++) {
    const line = lines[i];
    if (line.startsWith('- ') && line.trimEnd().endsWith('✅')) {
      const m = line.match(/\((\d+)m\)/);
      if (m) totalMinutes += Number(m[1]);
      count += 1;
    }
  }
  return `**Total focus: ${totalMinutes}m across ${count} pomodoros**`;
}

class ObsidianLogger {
  constructor(getSettings) {
    this.getSettings = getSettings;
    this._chain = Promise.resolve();
  }

  // Decides whether this phaseComplete event should be logged, then appends
  // it. Always resolves — never rejects.
  logSession(entry) {
    const settings = this.getSettings();
    if (!settings.loggingEnabled) return Promise.resolve({ ok: true, skipped: true });

    const isFocus = entry.phase === 'focus';
    const shouldLog = entry.completed
      ? (isFocus || settings.logBreaks)
      : settings.logAborted;
    if (!shouldLog) return Promise.resolve({ ok: true, skipped: true });

    const run = () => this._appendEntry(entry, settings);
    this._chain = this._chain.then(run, run);
    return this._chain;
  }

  // A dry check used by pomoppiSettings.testLog(): confirms the vault/folder is
  // reachable and writable without adding a log entry.
  async test() {
    try {
      const settings = this.getSettings();
      const filePath = paths.dailyNotePath(
        settings.vaultPath, settings.dailyNoteFolder, settings.dailyNoteFormat, new Date()
      );
      const dir = path.dirname(filePath);
      await fsp.mkdir(dir, { recursive: true });
      await fsp.access(dir, fs.constants.W_OK);
      return { ok: true, path: filePath };
    } catch (err) {
      return { ok: false, error: String((err && err.message) || err) };
    }
  }

  async _appendEntry(entry, settings) {
    try {
      const date = new Date(entry.endedAt || entry.startedAt || Date.now());
      const filePath = paths.dailyNotePath(
        settings.vaultPath, settings.dailyNoteFolder, settings.dailyNoteFormat, date
      );
      await fsp.mkdir(path.dirname(filePath), { recursive: true });

      let content = '';
      try {
        content = await fsp.readFile(filePath, 'utf8');
      } catch (err) {
        if (err.code !== 'ENOENT') throw err;
        content = '';
      }

      const nextContent = this._insertEntry(content, entry, settings.logHeading);

      const tmpPath = filePath + '.tmp';
      await fsp.writeFile(tmpPath, nextContent, 'utf8');
      await fsp.rename(tmpPath, filePath);

      return { ok: true, path: filePath };
    } catch (err) {
      return { ok: false, error: String((err && err.message) || err) };
    }
  }

  // Pure string transform — split out so it's trivial to unit test.
  _insertEntry(content, entry, heading) {
    const hadTrailingNewline = content.length === 0 || content.endsWith('\n');
    let lines = content.length ? content.replace(/\r\n/g, '\n').split('\n') : [];
    if (hadTrailingNewline && lines.length && lines[lines.length - 1] === '') lines.pop();

    let section = findSection(lines, heading);
    if (!section) {
      // Heading absent: append it, preceded by a blank line, at end of file.
      if (lines.length > 0) lines.push('');
      lines.push(heading);
      section = { headingIndex: lines.length - 1, endIndex: lines.length };
    }

    const { headingIndex, endIndex } = section;

    // Find the last "- " line and the "**Total focus:" line within the section.
    let lastDashIndex = -1;
    let totalLineIndex = -1;
    for (let i = headingIndex + 1; i < endIndex; i++) {
      if (lines[i].startsWith('- ')) lastDashIndex = i;
      else if (lines[i].startsWith('**Total focus:')) totalLineIndex = i;
    }

    const newLine = buildEntryLine(entry);
    const insertAt = lastDashIndex !== -1
      ? lastDashIndex + 1
      : (totalLineIndex !== -1 ? totalLineIndex : endIndex);
    lines.splice(insertAt, 0, newLine);

    // Recompute the section bounds after the insertion.
    const newEndIndex = endIndex + 1;
    const newLastDashIndex = insertAt;

    // Recompute where the total line now lives (shifted by one if it was
    // after the insertion point).
    let newTotalLineIndex = -1;
    for (let i = headingIndex + 1; i < newEndIndex; i++) {
      if (lines[i].startsWith('**Total focus:')) {
        newTotalLineIndex = i;
        break;
      }
    }

    const totalLine = buildTotalLine(lines, headingIndex + 1, newEndIndex);
    if (newTotalLineIndex !== -1) {
      lines[newTotalLineIndex] = totalLine;
    } else {
      lines.splice(newLastDashIndex + 1, 0, '', totalLine);
    }

    return lines.join('\n') + '\n';
  }
}

module.exports = ObsidianLogger;
