// Scripts/version.js — reads Pomoppi's version number out of
// Sources/PomoppiCore/Version.swift, the single source of truth. Shared by
// make-app.js, make-windows-app.js, and make-pkg.js so none of them carries
// its own copy of this regex that could drift from the others.
'use strict';

const fs = require('fs');
const path = require('path');

function readVersion(repoRoot) {
  const versionSwift = path.join(repoRoot, 'Sources/PomoppiCore/Version.swift');
  const contents = fs.readFileSync(versionSwift, 'utf8');
  const match = contents.match(/public let pomoppiVersion = "([^"]+)"/);
  if (!match) {
    console.error(`could not find "public let pomoppiVersion = ..." in ${versionSwift}`);
    process.exit(1);
  }
  return match[1];
}

module.exports = { readVersion };
