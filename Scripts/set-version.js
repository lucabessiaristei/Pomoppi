#!/usr/bin/env node
// Scripts/set-version.js — the one supported way to bump Pomoppi's version
// number: rewrites pomoppiVersion in Sources/PomoppiCore/Version.swift in
// place, rather than hand-editing that Swift file. See RELEASING.md for the
// release checklist this is the first step of.
//
//   node Scripts/set-version.js 0.3.0
'use strict';

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.join(__dirname, '..');
const VERSION_SWIFT = path.join(REPO_ROOT, 'Sources/PomoppiCore/Version.swift');

const newVersion = process.argv[2];
if (!newVersion || !/^\d+\.\d+\.\d+$/.test(newVersion)) {
  console.error('Usage: node Scripts/set-version.js <X.Y.Z>');
  process.exit(1);
}

const contents = fs.readFileSync(VERSION_SWIFT, 'utf8');
const pattern = /public let pomoppiVersion = "[^"]+"/;
if (!pattern.test(contents)) {
  console.error(`could not find "public let pomoppiVersion = ..." in ${VERSION_SWIFT}`);
  process.exit(1);
}

fs.writeFileSync(VERSION_SWIFT, contents.replace(pattern, `public let pomoppiVersion = "${newVersion}"`));
console.log(`Set pomoppiVersion to ${newVersion} in ${path.relative(REPO_ROOT, VERSION_SWIFT)}`);
