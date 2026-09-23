#!/usr/bin/env node
// Scripts/make-pkg.js — wraps a release Pomoppi.app (built via
// Scripts/make-app.js's existing logic, into a scratch staging directory
// rather than straight to /Applications) into an installable
// dist/Pomoppi-<version>.pkg via pkgbuild.
//
// Unsigned on purpose: no `productsign`, no notarization. That's a later
// phase — this one only proves the payload is structurally sound (installs
// only under /Applications/Pomoppi.app, never touches user data) and that
// an install-over doesn't fight a running instance.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { readVersion } = require('./version');

const REPO_ROOT = path.join(__dirname, '..');
const APP_NAME = 'Pomoppi';
const VERSION = readVersion(REPO_ROOT);

const distDir = path.join(REPO_ROOT, 'dist');
const pkgPath = path.join(distDir, `${APP_NAME}-${VERSION}.pkg`);

// Runs make-app.js's own build/assemble pipeline (release binary, Info.plist,
// icon, ad-hoc codesign) unchanged, just pointed at a scratch staging
// directory instead of /Applications — make-app.js already supports a
// custom target path as argv[2].
function buildStagedApp(stagingDir) {
  const appPath = path.join(stagingDir, `${APP_NAME}.app`);
  console.log(`Building ${APP_NAME}.app into ${appPath}...`);
  execFileSync('node', [path.join(REPO_ROOT, 'Scripts', 'make-app.js'), appPath], { stdio: 'inherit' });
  return appPath;
}

// Read the bundle identifier straight out of the built Info.plist rather
// than hardcoding a copy — keeps the pkg's --identifier matching whatever
// make-app.js actually shipped, so upgrades/login-item registration stay
// consistent even if that identifier ever changes there.
function readBundleIdentifier(appPath) {
  const infoPlist = path.join(appPath, 'Contents', 'Info.plist');
  const contents = fs.readFileSync(infoPlist, 'utf8');
  const match = contents.match(/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/);
  if (!match) {
    console.error(`could not find CFBundleIdentifier in ${infoPlist}`);
    process.exit(1);
  }
  return match[1];
}

function buildPkg(appPath, bundleId) {
  fs.mkdirSync(distDir, { recursive: true });
  const scriptsDir = path.join(REPO_ROOT, 'Scripts', 'pkg-scripts');
  console.log(`Building ${pkgPath} (identifier ${bundleId}, version ${VERSION})...`);
  execFileSync(
    'pkgbuild',
    [
      '--component', appPath,
      '--install-location', '/Applications',
      '--identifier', bundleId,
      '--version', VERSION,
      '--scripts', scriptsDir,
      pkgPath,
    ],
    { stdio: 'inherit' }
  );
}

function main() {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-pkg-'));
  try {
    const appPath = buildStagedApp(stagingDir);
    const bundleId = readBundleIdentifier(appPath);
    buildPkg(appPath, bundleId);
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }

  console.log(`\nWrote ${pkgPath}`);
}

main();
