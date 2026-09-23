#!/usr/bin/env node
// Scripts/check-tag-version.js — release-workflow guard: fails loudly if
// the git tag that triggered a `release: published` event doesn't match
// pomoppiVersion in Sources/PomoppiCore/Version.swift. Shared by
// macos.yml and windows.yml (via RELEASE_TAG env var) so the check can't
// drift between the two workflows or their different default shells.
'use strict';

const path = require('path');
const { readVersion } = require('./version');

const REPO_ROOT = path.join(__dirname, '..');
const tag = process.env.RELEASE_TAG || '';
const tagVersion = tag.replace(/^v/, '');
const fileVersion = readVersion(REPO_ROOT);

if (tagVersion !== fileVersion) {
  console.error(
    `Release tag "${tag}" (version ${tagVersion}) does not match pomoppiVersion "${fileVersion}" in Sources/PomoppiCore/Version.swift`
  );
  process.exit(1);
}

console.log(`Tag ${tag} matches pomoppiVersion ${fileVersion}`);
