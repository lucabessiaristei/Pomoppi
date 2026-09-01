#!/usr/bin/env node
// native/Scripts/make-app.js — builds the SPM package in release mode and
// assembles a real, double-clickable Pomoppi.app bundle. Hand-rolled, same
// spirit as legacy-electron/tools/make-launcher.js (the Electron app's
// launcher, now retired): no packager, no Xcode project.
//
// Destination defaults to /Applications/Pomoppi.app — the Electron app has
// been fully retired (no longer installed), so this is now simply where
// Pomoppi lives. Bundle identifier is the original shared one
// (it.lucabessiaristei.pomoppi): there's only one Pomoppi identity now,
// which is also what SMAppService's "launch at login" (LoginItem.swift)
// needs to register correctly.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const REPO_ROOT = path.join(__dirname, '..', '..');
const NATIVE_ROOT = path.join(__dirname, '..');
const BUNDLE_ID = 'it.lucabessiaristei.pomoppi';
const APP_NAME = 'Pomoppi';
const VERSION = '0.1.0';

const GLASS_ICON_SOURCE = 'pomoppi-clear.icon';
const GLASS_ICON_NAME = 'AppIcon';
const ACTOOL_FALLBACK = '/Applications/Xcode.app/Contents/Developer/usr/bin/actool';
const GLASS_CACHE_CAR = 'AppIcon.car';
const GLASS_CACHE_ICNS = 'AppIcon.icns';

const dest = path.resolve(process.argv[2] || path.join('/Applications', `${APP_NAME}.app`));

function xmlEscape(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

// Before touching anything at `dest`, make sure it's actually a bundle this
// script generated previously — never delete a stray file/folder that
// happens to sit at the destination path.
function removeExistingBundleIfOurs(bundleDir) {
  if (!fs.existsSync(bundleDir)) return;

  const infoPlist = path.join(bundleDir, 'Contents', 'Info.plist');
  let isOurs = false;
  if (fs.statSync(bundleDir).isDirectory() && fs.existsSync(infoPlist)) {
    const contents = fs.readFileSync(infoPlist, 'utf8');
    isOurs = contents.includes('<key>CFBundleIdentifier</key>') && contents.includes(BUNDLE_ID);
  }

  if (!isOurs) {
    console.error(
      `Refusing to overwrite ${bundleDir}: it exists but doesn't look like a ${APP_NAME}.app bundle ` +
        `this script built (no Contents/Info.plist with CFBundleIdentifier ${BUNDLE_ID}). ` +
        'Remove it manually or choose a different destination.'
    );
    process.exit(1);
  }

  fs.rmSync(bundleDir, { recursive: true, force: true });
}

function buildReleaseBinary() {
  console.log('Building release binary (swift build -c release)...');
  execFileSync('swift', ['build', '-c', 'release', '--package-path', NATIVE_ROOT], { stdio: 'inherit' });
  const binary = path.join(NATIVE_ROOT, '.build', 'release', 'PomoppiApp');
  if (!fs.existsSync(binary)) {
    console.error(`Expected release binary at ${binary} but it doesn't exist.`);
    process.exit(1);
  }
  return binary;
}

function writeInfoPlist(contentsDir, icon) {
  let iconXml = '';
  if (icon && icon.iconFile) {
    iconXml += `\t<key>CFBundleIconFile</key>\n\t<string>${xmlEscape(icon.iconFile)}</string>\n`;
  }
  if (icon && icon.iconName) {
    iconXml += `\t<key>CFBundleIconName</key>\n\t<string>${xmlEscape(icon.iconName)}</string>\n`;
  }

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${xmlEscape(BUNDLE_ID)}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
${iconXml}	<key>CFBundleShortVersionString</key>
	<string>${xmlEscape(VERSION)}</string>
	<key>CFBundleVersion</key>
	<string>${xmlEscape(VERSION)}</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
`;
  fs.writeFileSync(path.join(contentsDir, 'Info.plist'), plist);
}

// actool lives in Xcode.app; `xcrun -f` finds it only when xcode-select
// points at a full Xcode rather than the Command Line Tools.
function resolveActool() {
  try {
    const found = execFileSync('xcrun', ['-f', 'actool'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (found && fs.existsSync(found)) return found;
  } catch {
    // xcode-select points at the CLT, which has no actool. Not an error.
  }
  return fs.existsSync(ACTOOL_FALLBACK) ? ACTOOL_FALLBACK : null;
}

// Compiles assets/<GLASS_ICON_SOURCE> (the same Liquid Glass icon the
// Electron launcher ships) into this bundle's layered macOS icon. Returns a
// descriptor for writeInfoPlist(), or null to fall through to the cached
// catalog — no missing tool or actool failure may break the build.
function buildGlassIcon(resourcesDir) {
  const source = path.join(REPO_ROOT, 'assets', GLASS_ICON_SOURCE);
  if (!fs.existsSync(source)) {
    console.error(`Note: assets/${GLASS_ICON_SOURCE} not found; using the cached icon.`);
    return null;
  }
  const actool = resolveActool();
  if (!actool) {
    console.error('Note: actool not found (needs full Xcode, not just the Command Line Tools); using the cached icon.');
    return null;
  }

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-native-glass-'));
  try {
    const staged = path.join(tmpDir, `${GLASS_ICON_NAME}.icon`);
    fs.cpSync(source, staged, { recursive: true });
    const outDir = path.join(tmpDir, 'out');
    fs.mkdirSync(outDir);

    execFileSync(actool, [
      '--output-format', 'human-readable-text',
      '--app-icon', GLASS_ICON_NAME,
      '--output-partial-info-plist', path.join(tmpDir, 'partial.plist'),
      '--development-region', 'en',
      '--target-device', 'mac',
      '--minimum-deployment-target', '26.0',
      '--platform', 'macosx',
      '--compile', outDir,
      staged,
    ], { stdio: 'ignore' });

    const car = path.join(outDir, 'Assets.car');
    if (!fs.existsSync(car)) {
      console.error('Warning: actool emitted no Assets.car; using the cached icon.');
      return null;
    }
    fs.copyFileSync(car, path.join(resourcesDir, 'Assets.car'));

    const icns = path.join(outDir, `${GLASS_ICON_NAME}.icns`);
    const gotIcns = fs.existsSync(icns);
    if (gotIcns) fs.copyFileSync(icns, path.join(resourcesDir, `${GLASS_ICON_NAME}.icns`));

    return {
      iconFile: gotIcns ? GLASS_ICON_NAME : null,
      iconName: GLASS_ICON_NAME,
      label: `Assets.car (Liquid Glass, compiled from ${GLASS_ICON_SOURCE})`,
    };
  } catch (err) {
    console.error(`Warning: could not compile ${GLASS_ICON_SOURCE} (${err.message}); using the cached icon.`);
    return null;
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

// The Xcode-less path: ship the Electron app's already-committed catalog —
// same drawing, so the two apps look consistent on a machine with no Xcode.
function useCachedGlassIcon(resourcesDir) {
  const car = path.join(REPO_ROOT, 'assets', GLASS_CACHE_CAR);
  if (!fs.existsSync(car)) return null;
  fs.copyFileSync(car, path.join(resourcesDir, 'Assets.car'));

  const icns = path.join(REPO_ROOT, 'assets', GLASS_CACHE_ICNS);
  const gotIcns = fs.existsSync(icns);
  if (gotIcns) fs.copyFileSync(icns, path.join(resourcesDir, `${GLASS_ICON_NAME}.icns`));

  return {
    iconFile: gotIcns ? GLASS_ICON_NAME : null,
    iconName: GLASS_ICON_NAME,
    label: `Assets.car (Liquid Glass, prebuilt assets/${GLASS_CACHE_CAR})`,
  };
}

function codesign(bundleDir) {
  console.log('Ad-hoc code signing (local use only — not for distribution)...');
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', bundleDir], { stdio: 'inherit' });
}

const LSREGISTER =
  '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';

// Every rebuild replaces the bundle's file content in place, but
// LaunchServices' own database entry (icon, metadata) is keyed loosely
// enough that a previous registration under this same bundle identifier —
// a moved/deleted build, or (during the Electron-to-native transition) a
// trashed copy of the old app — can linger and get consulted instead of
// this one, most visibly as a generic placeholder icon in Finder. Forcing
// re-registration of exactly this path after every build keeps this from
// silently going stale again.
function reregisterWithLaunchServices(bundleDir) {
  if (!fs.existsSync(LSREGISTER)) return;
  try {
    execFileSync(LSREGISTER, ['-f', bundleDir], { stdio: 'ignore' });
  } catch {
    // Best effort — a failure here shouldn't fail the whole build.
  }
}

function main() {
  const binary = buildReleaseBinary();

  removeExistingBundleIfOurs(dest);

  const contentsDir = path.join(dest, 'Contents');
  const macosDir = path.join(contentsDir, 'MacOS');
  const resourcesDir = path.join(contentsDir, 'Resources');
  fs.mkdirSync(macosDir, { recursive: true });
  fs.mkdirSync(resourcesDir, { recursive: true });

  fs.copyFileSync(binary, path.join(macosDir, APP_NAME));
  fs.chmodSync(path.join(macosDir, APP_NAME), 0o755);

  const icon = buildGlassIcon(resourcesDir) || useCachedGlassIcon(resourcesDir);
  writeInfoPlist(contentsDir, icon);

  codesign(dest);
  reregisterWithLaunchServices(dest);

  console.log(`\nWrote ${dest}`);
  console.log(`  executable: ${path.join(macosDir, APP_NAME)}`);
  console.log(`  icon: ${icon ? icon.label : '(none)'}`);
  console.log(`\nRun it with: open ${JSON.stringify(dest)}`);
}

main();
