#!/usr/bin/env node
// Scripts/make-pkg.js — wraps a release Pomoppi.app (built via
// Scripts/make-app.js's existing logic, into a scratch staging directory
// rather than straight to /Applications) into an installable
// dist/Pomoppi-<version>_macOS.pkg via pkgbuild.
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
const pkgPath = path.join(distDir, `${APP_NAME}-${VERSION}_macOS.pkg`);

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

// `--component` mode leaves pkgbuild's defaults in place, and two of them
// break updates: BundleIsRelocatable makes Installer.app install over any
// other copy with the same bundle ID it finds on disk (a dist/ or .build
// copy) instead of /Applications, and BundleIsVersionChecked refuses to
// replace a newer version. `--root` + an explicit component plist turns
// both off, so every install lands in /Applications/Pomoppi.app.
function writeComponentPlist(plistPath) {
  fs.writeFileSync(plistPath, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>RootRelativeBundlePath</key><string>${APP_NAME}.app</string>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><false/>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
  </dict>
</array>
</plist>
`);
}

function buildPkg(stagingDir, bundleId) {
  fs.mkdirSync(distDir, { recursive: true });
  const scriptsDir = path.join(REPO_ROOT, 'Scripts', 'pkg-scripts');
  const plistPath = path.join(os.tmpdir(), `pomoppi-component-${process.pid}.plist`);
  writeComponentPlist(plistPath);
  console.log(`Building ${pkgPath} (identifier ${bundleId}, version ${VERSION})...`);
  try {
    execFileSync(
      'pkgbuild',
      [
        // stagingDir holds only Pomoppi.app, so the payload is exactly that.
        '--root', stagingDir,
        '--component-plist', plistPath,
        '--install-location', '/Applications',
        '--identifier', bundleId,
        '--version', VERSION,
        '--scripts', scriptsDir,
        pkgPath,
      ],
      { stdio: 'inherit' }
    );
  } finally {
    fs.rmSync(plistPath, { force: true });
  }
}

function main() {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-pkg-'));
  try {
    const appPath = buildStagedApp(stagingDir);
    const bundleId = readBundleIdentifier(appPath);
    buildPkg(stagingDir, bundleId);
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }

  console.log(`\nWrote ${pkgPath}`);
}

main();
