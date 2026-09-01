// lib/paths.js — pure filesystem path helpers. No Electron dependency, so
// both lib/settings.js and lib/obsidian.js can share them and stay testable.
'use strict';

const path = require('path');

const SETTINGS_FILENAME = 'settings.json';

function settingsFilePath(storageDir) {
  return path.join(storageDir, SETTINGS_FILENAME);
}

// Formats a Date against a template that supports only YYYY, MM, DD tokens
// (per SPEC.md §8 — "and nothing else").
function formatDate(date, format) {
  const yyyy = String(date.getFullYear());
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return format.replace(/YYYY/g, yyyy).replace(/MM/g, mm).replace(/DD/g, dd);
}

function dailyNotePath(vaultPath, dailyNoteFolder, dailyNoteFormat, date) {
  const fileName = formatDate(date, dailyNoteFormat) + '.md';
  return dailyNoteFolder
    ? path.join(vaultPath, dailyNoteFolder, fileName)
    : path.join(vaultPath, fileName);
}

module.exports = { SETTINGS_FILENAME, settingsFilePath, formatDate, dailyNotePath };
