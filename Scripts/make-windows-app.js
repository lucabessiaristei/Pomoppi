#!/usr/bin/env node
// Scripts/make-windows-app.js — builds the SPM package in release mode and
// assembles a distributable Windows app folder + zip. Hand-rolled: no
// packager, no MSI installer.
//
// **This script must run ON a Windows machine** — Swift does not cross-compile
// from macOS to Windows. It requires the Swift toolchain + MSVC (Build Tools
// or Visual Studio) installed, and will be invoked by GitHub Actions
// windows-latest runners or the project's Windows dev VM.
//
// Destination defaults to dist/Pomoppi-win/ (relative to repo root), and
// the script also produces dist/Pomoppi-win.zip.
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync, execSync } = require('child_process');

const REPO_ROOT = path.join(__dirname, '..');
const APP_NAME = 'Pomoppi';
const VERSION = '0.1.0';

const destFolder = path.resolve(process.argv[2] || path.join(REPO_ROOT, 'dist', 'Pomoppi-win'));
const destZip = path.join(path.dirname(destFolder), `${path.basename(destFolder)}.zip`);

function logSection(msg) {
  console.log(`\n${msg}`);
}

// Before touching anything at destFolder, make sure it's actually an app
// this script generated previously — never delete a stranger's folder.
function removeExistingFolderIfOurs(folder) {
  if (!fs.existsSync(folder)) return;

  const manifest = path.join(folder, 'Pomoppi.exe.manifest');
  let isOurs = false;
  if (fs.statSync(folder).isDirectory() && fs.existsSync(manifest)) {
    isOurs = true;
  }

  if (!isOurs) {
    console.error(
      `Refusing to overwrite ${folder}: it exists but doesn't look like a ${APP_NAME} app ` +
        `this script built (no Pomoppi.exe.manifest). ` +
        'Remove it manually or choose a different destination.'
    );
    process.exit(1);
  }

  fs.rmSync(folder, { recursive: true, force: true });
}

// Find vswhere.exe (present on any machine with VS/Build-Tools installed),
// then query it for the latest VS install root, then join VC\Auxiliary\Build\vcvarsall.bat
function findVcvarsallBat() {
  const programFilesX86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const vswhere = path.join(programFilesX86, 'Microsoft Visual Studio', 'Installer', 'vswhere.exe');

  if (!fs.existsSync(vswhere)) {
    console.error(
      `Cannot find vswhere.exe at ${vswhere}. ` +
        'Is Visual Studio or Build Tools installed?'
    );
    process.exit(1);
  }

  let vsPath;
  try {
    // -products * is required: vswhere's default query only looks at the
    // "workstation" product IDs (Community/Professional/Enterprise) and
    // silently excludes a Build-Tools-only install (confirmed live on
    // this project's own dev VM, which has Build Tools, not full VS) even
    // though -latest with no -products filter finds a full install fine —
    // needed on both this VM and CI's GitHub-hosted runner regardless,
    // since either kind of install should resolve the same way here.
    vsPath = execFileSync(vswhere, ['-products', '*', '-latest', '-property', 'installationPath'], {
      encoding: 'utf8',
    }).trim();
  } catch (err) {
    console.error(`vswhere.exe failed: ${err.message}`);
    process.exit(1);
  }

  if (!vsPath) {
    console.error('vswhere.exe returned no installationPath. Is Visual Studio/Build Tools installed?');
    process.exit(1);
  }

  const vcvarsall = path.join(vsPath, 'VC', 'Auxiliary', 'Build', 'vcvarsall.bat');
  if (!fs.existsSync(vcvarsall)) {
    console.error(`Cannot find vcvarsall.bat at ${vcvarsall}.`);
    process.exit(1);
  }

  return vcvarsall;
}

// Determine the target architecture for vcvarsall.bat based on Node's own arch
function getVcvarsArch() {
  if (process.arch === 'arm64') return 'arm64';
  return 'amd64';
}

// Build the release binary with MSVC environment loaded via vcvarsall.bat.
// Pass -Xlinker flags to produce a GUI app (no console window).
function buildReleaseBinary(vcvarsallBat, arch) {
  logSection('Building release binary (swift build -c release with MSVC environment)...');

  const buildCmd = `call "${vcvarsallBat}" ${arch} && swift build -c release --package-path "${REPO_ROOT}" -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup`;

  try {
    // windowsVerbatimArguments is required here: buildCmd already contains
    // its own embedded double-quotes (around vcvarsallBat's path), and
    // without this flag Node re-escapes the whole string as a single
    // argument before handing it to CreateProcess — confirmed live, it
    // turns every `"` into a literal `\"` that cmd.exe then fails to
    // parse as a real quote at all. This flag passes the line through to
    // cmd.exe exactly as built above.
    execFileSync('cmd.exe', ['/c', buildCmd], {
      stdio: 'inherit',
      cwd: REPO_ROOT,
      windowsVerbatimArguments: true,
    });
  } catch (err) {
    console.error(`swift build failed: ${err.message}`);
    process.exit(1);
  }

  const binary = path.join(REPO_ROOT, '.build', 'release', 'PomoppiWindows.exe');
  if (!fs.existsSync(binary)) {
    console.error(`Expected release binary at ${binary} but it doesn't exist.`);
    process.exit(1);
  }

  return binary;
}

// Copy the built exe to the destination folder, renaming it to Pomoppi.exe
function copyExe(source, destFolder) {
  logSection('Copying executable...');
  fs.mkdirSync(destFolder, { recursive: true });
  const dest = path.join(destFolder, `${APP_NAME}.exe`);
  fs.copyFileSync(source, dest);
  console.log(`  → ${dest}`);
}

// Copy the manifest from the source tree to the destination folder, alongside the exe
function copyManifest(destFolder) {
  logSection('Copying manifest...');
  const source = path.join(REPO_ROOT, 'Sources', 'PomoppiWindows', 'Pomoppi.exe.manifest');
  if (!fs.existsSync(source)) {
    console.error(`Cannot find manifest at ${source}.`);
    process.exit(1);
  }
  const dest = path.join(destFolder, `${APP_NAME}.exe.manifest`);
  fs.copyFileSync(source, dest);
  console.log(`  → ${dest}`);
}

// Check for assets/pomoppi.ico and copy if present; log a note if absent
function copyIconIfPresent(destFolder) {
  logSection('Checking for icon...');
  const iconSource = path.join(REPO_ROOT, 'assets', 'pomoppi.ico');
  if (fs.existsSync(iconSource)) {
    const iconDest = path.join(destFolder, 'pomoppi.ico');
    fs.copyFileSync(iconSource, iconDest);
    console.log(`  → ${iconDest}`);
    return true;
  }
  console.log('  no assets/pomoppi.ico found yet — shipping without an icon');
  return false;
}

// Find the Swift runtime DLLs and copy them all to the destination folder.
// Globs %LOCALAPPDATA%\Programs\Swift\Runtimes\*\usr\bin\*.dll, picking
// the highest version if multiple exist, and copies every DLL found.
function copySwiftRuntimeDlls(destFolder) {
  logSection('Copying Swift runtime DLLs...');

  const localAppData = process.env.LOCALAPPDATA;
  if (!localAppData) {
    console.error('LOCALAPPDATA environment variable not set.');
    process.exit(1);
  }

  const runtimesBase = path.join(localAppData, 'Programs', 'Swift', 'Runtimes');
  if (!fs.existsSync(runtimesBase)) {
    console.error(
      `Cannot find Swift runtime directory at ${runtimesBase}. ` +
        'Is the Swift toolchain installed?'
    );
    process.exit(1);
  }

  // Find all version directories (e.g., "6.4", "6.5", etc.), sorted lexically descending
  const versions = fs
    .readdirSync(runtimesBase)
    .filter((f) => fs.statSync(path.join(runtimesBase, f)).isDirectory())
    .sort()
    .reverse();

  if (versions.length === 0) {
    console.error(`No Swift version directories found under ${runtimesBase}.`);
    process.exit(1);
  }

  const selectedVersion = versions[0];
  const dllDir = path.join(runtimesBase, selectedVersion, 'usr', 'bin');
  if (!fs.existsSync(dllDir)) {
    console.error(`Cannot find DLL directory at ${dllDir}.`);
    process.exit(1);
  }

  // Find all .dll files
  const dlls = fs
    .readdirSync(dllDir)
    .filter((f) => f.endsWith('.dll'))
    .sort();

  if (dlls.length === 0) {
    console.error(`No DLL files found in ${dllDir}.`);
    process.exit(1);
  }

  dlls.forEach((dll) => {
    const src = path.join(dllDir, dll);
    const dst = path.join(destFolder, dll);
    fs.copyFileSync(src, dst);
  });

  console.log(`  copied ${dlls.length} DLLs from Swift ${selectedVersion}`);
  dlls.slice(0, 5).forEach((dll) => console.log(`    - ${dll}`));
  if (dlls.length > 5) console.log(`    ... and ${dlls.length - 5} more`);
}

// Create a zip file of the destFolder's *contents* (not a wrapper folder).
// Use PowerShell Compress-Archive.
function createZip(sourceFolder, zipPath) {
  logSection('Creating zip archive...');

  // Use PowerShell to create a zip of the folder's contents
  const psCommand = `Compress-Archive -Path '${sourceFolder}\\*' -DestinationPath '${zipPath}' -Force`;

  try {
    execSync(`powershell -Command "${psCommand}"`, {
      stdio: 'inherit',
    });
  } catch (err) {
    console.error(`Failed to create zip: ${err.message}`);
    process.exit(1);
  }

  console.log(`  → ${zipPath}`);
}

function main() {
  const vcvarsallBat = findVcvarsallBat();
  const arch = getVcvarsArch();

  const binary = buildReleaseBinary(vcvarsallBat, arch);

  removeExistingFolderIfOurs(destFolder);

  copyExe(binary, destFolder);
  copyManifest(destFolder);
  const hasIcon = copyIconIfPresent(destFolder);
  copySwiftRuntimeDlls(destFolder);

  createZip(destFolder, destZip);

  console.log('\n' + '='.repeat(70));
  console.log('Success! Windows app assembled.');
  console.log('='.repeat(70));
  console.log(`\nFolder: ${destFolder}`);
  console.log(`Zip:    ${destZip}`);
  console.log(`Icon:   ${hasIcon ? 'included' : 'not included (add assets/pomoppi.ico to include it)'}`);
  console.log(`\nTo distribute: send ${destZip} or unzip it and send the folder contents.`);
}

main();
