#!/usr/bin/env node
// refresh-strings.js — the one command that keeps the app's UI strings in
// sync with Localization/*.json (LOCALIZATION_PLAN.md, L0):
//
//   node refresh-strings
//
// - Localization/en.json is the source of truth. Every other <id>.json must
//   carry every English key (a missing key fails the run, an extra key only
//   warns), and may only use {n} placeholders its English source has.
// - Each file's "language.name" is the language's own name ("Italiano"),
//   shown in the Language picker.
// - PomoppiSettings.languageIDs in Settings.swift is regex-synced, the same
//   way refresh-sounds.js syncs chimeIDs.
// - Sources/PomoppiStrings/Strings.generated.swift is always rewritten last.
'use strict';

const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, 'Localization');
const read = (id) => JSON.parse(fs.readFileSync(path.join(dir, `${id}.json`), 'utf8'));

const english = read('en');
const englishKeys = Object.keys(english);
const others = fs.readdirSync(dir)
  .filter((f) => /^[a-z]{2,3}\.json$/.test(f) && f !== 'en.json')
  .map((f) => f.slice(0, -5))
  .sort();
const languageIDs = ['en', ...others];

const placeholders = (s) => new Set([...s.matchAll(/\{(\d+)\}/g)].map((m) => m[1]));

let failed = false;
const tables = { en: english };
for (const id of others) {
  const table = read(id);
  const missing = englishKeys.filter((k) => !(k in table));
  const extra = Object.keys(table).filter((k) => !(k in english));
  if (missing.length) {
    failed = true;
    console.error(`${id}.json: missing ${missing.length} key(s):\n  ${missing.join('\n  ')}`);
  }
  if (extra.length) console.warn(`${id}.json: ignoring ${extra.length} key(s) not in en.json:\n  ${extra.join('\n  ')}`);
  for (const key of englishKeys) {
    if (!(key in table)) continue;
    const allowed = placeholders(english[key]);
    const unknown = [...placeholders(table[key])].filter((n) => !allowed.has(n));
    if (unknown.length) {
      failed = true;
      console.error(`${id}.json: "${key}" uses {${unknown.join('}, {')}}, which en.json's source doesn't have`);
    }
  }
  // Only English keys, in English order.
  tables[id] = Object.fromEntries(englishKeys.filter((k) => k in table).map((k) => [k, table[k]]));
}
for (const id of languageIDs) {
  if (typeof tables[id]['language.name'] !== 'string') {
    failed = true;
    console.error(`${id}.json: needs a "language.name" (the language's own name for itself)`);
  }
}
for (const [key, value] of Object.entries(english)) {
  if (typeof value !== 'string') {
    failed = true;
    console.error(`en.json: "${key}" must be a string`);
  }
}
if (failed) process.exit(1);

// --- keep Sources/PomoppiCore/Settings.swift's languageIDs in sync ---------
// Same trick as refresh-sounds.js: PomoppiCore has no dependency on the
// generated module, so the roster is copied into one array literal. Inserted
// after chimeIDs the first time.
function syncIDs(fieldName, ids) {
  const line = (indent) => `${indent}public static let ${fieldName} = [${ids.map((id) => JSON.stringify(id)).join(', ')}]`;
  const dest = path.join(__dirname, 'Sources/PomoppiCore/Settings.swift');
  const before = fs.readFileSync(dest, 'utf8');
  const re = new RegExp(`^(\\s*)public static let ${fieldName} = \\[[^\\]]*\\]`, 'm');
  const match = before.match(re);
  if (match) {
    const next = line(match[1]);
    if (next !== match[0]) {
      fs.writeFileSync(dest, before.replace(re, next));
      console.log(`Settings.swift ${fieldName}: [${ids.join(', ')}]`);
    }
    return;
  }
  const anchor = /^(\s*)public static let chimeIDs = \[[^\]]*\]\n/m;
  const anchorMatch = before.match(anchor);
  if (!anchorMatch) {
    console.error(`could not find "public static let chimeIDs = [...]" in Settings.swift to insert ${fieldName} after`);
    process.exit(1);
  }
  fs.writeFileSync(dest, before.replace(anchor, anchorMatch[0] + line(anchorMatch[1]) + '\n'));
  console.log(`Settings.swift: inserted ${fieldName} = [${ids.join(', ')}]`);
}

syncIDs('languageIDs', languageIDs);

// --- regenerate Sources/PomoppiStrings/Strings.generated.swift -------------

// A Swift string literal. JSON.stringify's \uXXXX isn't Swift syntax, so
// escape by hand; everything else (accents, the ellipsis, emoji) stays as is.
function swiftString(s) {
  let out = '"';
  for (const ch of s) {
    const code = ch.codePointAt(0);
    if (ch === '\\') out += '\\\\';
    else if (ch === '"') out += '\\"';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\t') out += '\\t';
    else if (code < 0x20) out += `\\u{${code.toString(16)}}`;
    else out += ch;
  }
  return out + '"';
}

// One explicitly typed constant per language keeps the type checker fast on
// a few hundred entries.
const swiftName = (id) => `table_${id}`;
const tableDecls = languageIDs.map((id) => {
  const entries = Object.entries(tables[id]).map(([k, v]) => `        ${swiftString(k)}: ${swiftString(v)},`).join('\n');
  return `    static let ${swiftName(id)}: [String: String] = [\n${entries}\n    ]`;
}).join('\n\n');

const output = `// Strings.generated.swift — GENERATED by refresh-strings.js.
// Do not hand-edit. Source: Localization/*.json. Re-run
// \`node refresh-strings\` after those change.
enum GeneratedStrings {
    static let languageIDs: [String] = [${languageIDs.map(swiftString).join(', ')}]

    static let tables: [String: [String: String]] = [
${languageIDs.map((id) => `        ${swiftString(id)}: ${swiftName(id)},`).join('\n')}
    ]

${tableDecls}
}
`;

const outPath = path.join(__dirname, 'Sources/PomoppiStrings/Strings.generated.swift');
fs.writeFileSync(outPath, output);
console.log(`wrote ${path.relative(__dirname, outPath)} (${languageIDs.length} language(s), ${englishKeys.length} keys)`);
