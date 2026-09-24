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
// the script also produces dist/Pomoppi-win.zip. Pass --installer to also
// build a setup .exe via Inno Setup (Scripts/pomoppi.iss) — the zip stays
// the default/no-flag output either way (some chat apps block .exe
// attachments outright, so it's kept as the fallback distribution path).
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync, execSync } = require('child_process');

const { readVersion } = require('./version');

const REPO_ROOT = path.join(__dirname, '..');
const APP_NAME = 'Pomoppi';

// The version, read straight out of Sources/PomoppiCore/Version.swift — the
// single source of truth — rather than hardcoding a copy here that can
// drift from the real one.
const VERSION = readVersion(REPO_ROOT);

// --installer is a flag, not positional — filter it out before reading
// argv[2] as an optional custom destFolder, same as before its addition.
const rawArgs = process.argv.slice(2);
const installerRequested = rawArgs.includes('--installer');
const positionalArgs = rawArgs.filter((a) => a !== '--installer');

const destFolder = path.resolve(positionalArgs[0] || path.join(REPO_ROOT, 'dist', 'Pomoppi-win'));
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
// then query it for the latest VS install root — shared by findVcvarsallBat
// and findDumpbin below, both of which just join a fixed relative path onto
// this same installationPath.
function findVsInstallPath() {
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

  return vsPath;
}

function findVcvarsallBat(vsPath) {
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

// The MSVC Tools folder uses "arm64"/"x64" for its Host<X>\<X> naming,
// unlike vcvarsall.bat's own "arm64"/"amd64" argument convention above —
// two different naming schemes for the same two architectures.
function getMsvcToolsArch() {
  if (process.arch === 'arm64') return 'arm64';
  return 'x64';
}

// dumpbin.exe lives under VC\Tools\MSVC\<version>\bin\Host<arch>\<arch>\ —
// confirmed by listing it directly on this project's dev VM. Picks the
// highest MSVC tools version if more than one is installed, same
// highest-version-wins convention as copySwiftRuntimeDlls uses for the
// Swift toolchain below.
function findDumpbin(vsPath, msvcArch) {
  const msvcToolsBase = path.join(vsPath, 'VC', 'Tools', 'MSVC');
  if (!fs.existsSync(msvcToolsBase)) {
    console.error(`Cannot find MSVC tools directory at ${msvcToolsBase}.`);
    process.exit(1);
  }
  const versions = fs
    .readdirSync(msvcToolsBase)
    .filter((f) => fs.statSync(path.join(msvcToolsBase, f)).isDirectory())
    .sort()
    .reverse();
  if (versions.length === 0) {
    console.error(`No MSVC tool versions found under ${msvcToolsBase}.`);
    process.exit(1);
  }
  const dumpbin = path.join(msvcToolsBase, versions[0], 'bin', `Host${msvcArch}`, msvcArch, 'dumpbin.exe');
  if (!fs.existsSync(dumpbin)) {
    console.error(`Cannot find dumpbin.exe at ${dumpbin}.`);
    process.exit(1);
  }
  return dumpbin;
}

// Builds the `rc.exe ...` command that compiles Sources/PomoppiWindows/
// Pomoppi.rc (icon + VERSIONINFO) into a .res, and the matching -Xlinker
// arg to feed that .res straight to link.exe — link.exe accepts a compiled
// resource file as an ordinary extra input, same as an .obj. rc.exe is
// already on PATH once vcvarsall.bat has run (it ships with the Windows
// SDK, which every VS/Build Tools install pulls in). Always compiles (the
// VERSIONINFO block has no dependency on the icon existing) — the /D
// POMOPPI_HAS_ICON define is only added, and /I only points at assets/,
// when assets/pomoppi.ico is actually there, same "ship without it, don't
// fail the build" stance copyIconIfPresent below already takes for the
// loose-file copy. The version (read out of Sources/PomoppiCore/Version.swift
// above) is threaded through as three plain numeric /D defines — Pomoppi.rc
// builds the dotted "x.y.z" string itself via the preprocessor's
// stringizing operator, so no quoted value ever has to survive Node's
// cmd.exe/rc.exe argv-escaping.
function compileResourceCmd() {
  const [major, minor, patch] = VERSION.split('.').map((n) => parseInt(n, 10) || 0);
  const versionDefines =
    `/D POMOPPI_VERSION_MAJOR=${major} /D POMOPPI_VERSION_MINOR=${minor} /D POMOPPI_VERSION_PATCH=${patch}`;

  const iconIco = path.join(REPO_ROOT, 'assets', 'pomoppi.ico');
  const hasIcon = fs.existsSync(iconIco);
  const iconDefine = hasIcon ? ' /D POMOPPI_HAS_ICON=1' : '';
  const iconIncludePath = hasIcon ? ` /I "${path.join(REPO_ROOT, 'assets')}"` : '';

  const rcSource = path.join(REPO_ROOT, 'Sources', 'PomoppiWindows', 'Pomoppi.rc');
  const resOutput = path.join(REPO_ROOT, '.build', 'Pomoppi.res');
  fs.mkdirSync(path.dirname(resOutput), { recursive: true });
  const rcCmd = `rc.exe${iconIncludePath} ${versionDefines}${iconDefine} /fo "${resOutput}" "${rcSource}"`;
  return { rcCmd, linkerArg: ` -Xlinker "${resOutput}"` };
}

// The real release output folder (.build\<triple>\release), straight from
// SwiftPM. .build\release is only a convenience symlink SwiftPM tries to
// create after each build, and on Windows that can fail (confirmed live: "unable
// to create symbolic link ... code: 512") while the build itself succeeds.
function releaseBinPath(vcvarsallBat, arch) {
  const cmd =
    `call "${vcvarsallBat}" ${arch} >nul` +
    ` && swift build -c release --package-path "${REPO_ROOT}" --show-bin-path`;
  const output = execFileSync('cmd.exe', ['/c', cmd], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    windowsVerbatimArguments: true,
  });
  const lines = output.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines[lines.length - 1];
}

// Build the release binary with MSVC environment loaded via vcvarsall.bat.
// Pass -Xlinker flags to produce a GUI app (no console window), plus the
// compiled icon+version resource (see compileResourceCmd below) —
// embedded straight into the exe's PE resources at link time, not just a
// loose file dropped alongside it.
function buildReleaseBinary(vcvarsallBat, arch) {
  logSection('Building release binary (swift build -c release with MSVC environment)...');
  const binDir = releaseBinPath(vcvarsallBat, arch);

  // SwiftPM's incremental build only hashes the -Xlinker flag *string*, not
  // the .res file's contents it points at — a re-run with an unchanged
  // command line (same path, different bytes, e.g. after re-editing
  // pomoppi.ico) silently reuses the stale linked exe instead of relinking.
  // Deleting the previous output first forces llbuild's own
  // output-must-exist check to redo the link step for real, every time.
  const previousBinary = path.join(binDir, 'PomoppiWindows.exe');
  if (fs.existsSync(previousBinary)) fs.rmSync(previousBinary);

  const { rcCmd, linkerArg } = compileResourceCmd();
  const buildCmd =
    `call "${vcvarsallBat}" ${arch}` +
    ` && ${rcCmd}` +
    ` && swift build -c release --package-path "${REPO_ROOT}" -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup${linkerArg}`;

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

  const binary = path.join(binDir, 'PomoppiWindows.exe');
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

// Parses `dumpbin /dependents <binary>`'s "Image has the following
// dependencies:" block into a plain list of imported DLL filenames — the
// only section we care about. dumpbin's own format has a blank line
// *right after* that header line before the indented list starts, then
// another blank line once the list ends (before the "Summary" section,
// or a delay-load-dependencies block this app's own binaries don't have)
// — so the first blank line doesn't end the list, only one seen *after*
// at least one real entry does.
function directDependencies(dumpbinPath, binaryPath) {
  const output = execFileSync(dumpbinPath, ['/dependents', binaryPath], { encoding: 'utf8' });
  const lines = output.split(/\r?\n/);
  const deps = [];
  let inDeps = false;
  for (const line of lines) {
    if (line.includes('Image has the following dependencies:')) {
      inDeps = true;
      continue;
    }
    if (!inDeps) continue;
    const trimmed = line.trim();
    if (trimmed === '') {
      if (deps.length > 0) break;
      continue;
    }
    deps.push(trimmed);
  }
  return deps;
}

// Computes exactly the set of Swift-toolchain DLLs Pomoppi.exe needs, by
// walking its real import table rather than hand-maintaining a list —
// so a Swift toolchain upgrade that changes which runtime pieces a given
// feature pulls in can't silently go stale here the way a hardcoded list
// would. Starts from the exe's own direct dependencies (dumpbin only ever
// shows one binary's first-level imports, never the full transitive
// closure), and for every one that's actually a file in dllDir (as
// opposed to a Windows system DLL like KERNEL32.dll or an
// api-ms-win-crt-*.dll, always present on Windows and never ours to
// ship), recurses into *that* DLL's own dependencies too — e.g.
// Foundation.dll pulling in FoundationInternationalization.dll and
// _FoundationICU.dll, neither of which shows up in Pomoppi.exe's own
// direct import list. A DLL not found in dllDir simply has nothing to
// recurse into and terminates that branch, exactly the system-DLL case.
function resolveSwiftRuntimeDlls(dumpbinPath, dllDir, entryBinaryPath) {
  const resolved = new Set();
  const queue = [entryBinaryPath];
  const visited = new Set([path.basename(entryBinaryPath).toLowerCase()]);

  while (queue.length > 0) {
    const current = queue.shift();
    for (const dep of directDependencies(dumpbinPath, current)) {
      const key = dep.toLowerCase();
      if (visited.has(key)) continue;
      visited.add(key);
      const candidatePath = path.join(dllDir, dep);
      if (fs.existsSync(candidatePath)) {
        resolved.add(dep);
        queue.push(candidatePath);
      }
    }
  }
  return Array.from(resolved).sort();
}

// Finds the Swift runtime DLLs and copies only the ones
// resolveSwiftRuntimeDlls actually found Pomoppi.exe (transitively)
// depending on — not "every .dll in the folder" (Swift's Windows runtime
// distribution bundles support for every language feature any Swift
// program might use — Differentiation, Distributed actors, regex
// literals, @Observable, RemoteMirror's debugger-only reflection,
// XML/HTTP support in swift-corelibs-foundation — none of which this app
// touches, confirmed by this exact resolution never finding them
// reachable from the exe). Globs
// %LOCALAPPDATA%\Programs\Swift\Runtimes\*\usr\bin, picking the highest
// version if multiple exist.
function copySwiftRuntimeDlls(destFolder, dumpbinPath, exePath) {
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

  const requiredDlls = resolveSwiftRuntimeDlls(dumpbinPath, dllDir, exePath);
  if (requiredDlls.length === 0) {
    console.error(`dumpbin found no Swift-toolchain dependencies for ${exePath} — that's almost certainly wrong.`);
    process.exit(1);
  }

  requiredDlls.forEach((dll) => {
    const src = path.join(dllDir, dll);
    const dst = path.join(destFolder, dll);
    fs.copyFileSync(src, dst);
  });

  console.log(`  copied ${requiredDlls.length} DLLs from Swift ${selectedVersion} (resolved via dumpbin, not the whole folder)`);
  requiredDlls.forEach((dll) => console.log(`    - ${dll}`));
}

// Find ISCC.exe (Inno Setup's command-line compiler). GitHub's
// windows-latest runner image ships Inno Setup preinstalled machine-wide
// (confirmed against actions/runner-images' own software manifest for
// windows-2025, the same way findVsInstallPath's -products * gap was
// confirmed rather than assumed) — that lands under Program Files (x86).
// This project's own dev VM has no such preinstall and needs it added by
// hand (`winget install --id JRSoftware.InnoSetup`), which — being a
// non-elevated install, matching every other low-privilege tool this repo
// already favors — lands under %LOCALAPPDATA%\Programs instead, confirmed
// live in the VM. Try both real locations before falling back to a bare
// "ISCC.exe" for a PATH-based install (e.g. one that added its own shim).
function findIsccPath() {
  const programFilesX86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';
  const localAppData = process.env.LOCALAPPDATA || '';
  const candidates = [
    path.join(programFilesX86, 'Inno Setup 6', 'ISCC.exe'),
    path.join(localAppData, 'Programs', 'Inno Setup 6', 'ISCC.exe'),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return 'ISCC.exe';
}

// Compiles Scripts/pomoppi.iss via ISCC.exe into a setup .exe next to the
// zip (dist/), reusing the exact contents already assembled at destFolder
// rather than having the .iss script rebuild or re-locate anything itself.
function buildInstaller(destFolder) {
  logSection('Building installer (ISCC.exe)...');

  const isccPath = findIsccPath();
  const issScript = path.join(REPO_ROOT, 'Scripts', 'pomoppi.iss');
  const outputDir = path.dirname(destFolder);

  try {
    execFileSync(
      isccPath,
      [
        `/DMyAppVersion=${VERSION}`,
        `/DMySourceDir=${destFolder}`,
        `/DMyOutputDir=${outputDir}`,
        issScript,
      ],
      { stdio: 'inherit' }
    );
  } catch (err) {
    console.error(`ISCC.exe failed: ${err.message}`);
    process.exit(1);
  }

  const setupExe = path.join(outputDir, `Pomoppi-Setup-${VERSION}.exe`);
  if (!fs.existsSync(setupExe)) {
    console.error(`Expected installer at ${setupExe} but it doesn't exist.`);
    process.exit(1);
  }
  return setupExe;
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
  const vsPath = findVsInstallPath();
  const vcvarsallBat = findVcvarsallBat(vsPath);
  const arch = getVcvarsArch();
  const dumpbinPath = findDumpbin(vsPath, getMsvcToolsArch());

  const binary = buildReleaseBinary(vcvarsallBat, arch);

  removeExistingFolderIfOurs(destFolder);

  copyExe(binary, destFolder);
  copyManifest(destFolder);
  const hasIcon = copyIconIfPresent(destFolder);
  copySwiftRuntimeDlls(destFolder, dumpbinPath, path.join(destFolder, `${APP_NAME}.exe`));

  createZip(destFolder, destZip);

  const setupExe = installerRequested ? buildInstaller(destFolder) : null;

  console.log('\n' + '='.repeat(70));
  console.log('Success! Windows app assembled.');
  console.log('='.repeat(70));
  console.log(`\nFolder: ${destFolder}`);
  console.log(`Zip:    ${destZip}`);
  if (setupExe) console.log(`Setup:  ${setupExe}`);
  console.log(`Icon:   ${hasIcon ? 'embedded in Pomoppi.exe, and copied loose alongside it' : 'not included (add assets/pomoppi.ico to include it)'}`);
  console.log(`\nTo distribute: send ${destZip} or unzip it and send the folder contents.`);
}

main();
