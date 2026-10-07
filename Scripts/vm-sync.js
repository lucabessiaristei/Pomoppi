#!/usr/bin/env node
// Sends the Mac's working tree (uncommitted and untracked files included,
// .gitignore respected) into the Windows VM clone and builds it there, in
// one command. Never touches the Mac's index, working tree or HEAD: the
// snapshot is a throwaway commit made through a temporary index, bundled
// under refs/tmp/vm-sync and deleted afterwards. See WINDOWS_VM.md.
//
//   node Scripts/vm-sync.js            sync + debug `swift build`
//   node Scripts/vm-sync.js --test     sync + `swift test`
//   node Scripts/vm-sync.js --release  sync + `node Scripts\make-windows-app.js`
//   node Scripts/vm-sync.js --installer  same, plus the Setup .exe (`--installer`)
//   node Scripts/vm-sync.js --no-build sync only
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const host = 'pomoppi-win';
const vmRepo = 'C:\\Users\\bubvm\\pomoppi';
const vmBundle = 'C:/Users/bubvm/vm-sync.bundle';
const vcvars = '"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvarsall.bat" arm64';
const ref = 'refs/tmp/vm-sync';

const args = new Set(process.argv.slice(2));
const repo = path.resolve(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-vm-sync-'));
const index = path.join(tmp, 'index');
const bundle = path.join(tmp, 'pomoppi.bundle');

const git = (gitArgs, env = {}) =>
  execFileSync('git', gitArgs, { cwd: repo, env: { ...process.env, ...env }, encoding: 'utf8' }).trim();
const ssh = (command) => spawnSync('ssh', [host, command], { stdio: 'inherit' }).status;

let status = 0;
try {
  const env = { GIT_INDEX_FILE: index };
  git(['read-tree', 'HEAD'], env);
  git(['add', '-A'], env);
  const tree = git(['write-tree'], env);
  const commit = git(['commit-tree', tree, '-p', 'HEAD', '-m', 'vm-sync snapshot']);
  git(['update-ref', ref, commit]);
  git(['bundle', 'create', bundle, ref]);
  execFileSync('scp', ['-q', bundle, `${host}:${vmBundle}`], { stdio: 'inherit' });

  const steps = [
    `cd /d ${vmRepo}`,
    `git fetch -q ${vmBundle} ${ref}`,
    'git reset -q --hard FETCH_HEAD',
    `del ${vmBundle.replace(/\//g, '\\')}`,
  ];
  if (args.has('--installer')) steps.push('node Scripts\\make-windows-app.js --installer');
  else if (args.has('--release')) steps.push('node Scripts\\make-windows-app.js');
  else if (args.has('--test')) steps.push(`call ${vcvars} >nul`, 'swift test');
  // The debug exe needs the side-by-side manifest next to it too: without
  // it Windows loads comctl32 v5, which has no SetWindowSubclass and friends,
  // and the exe dies at load with "entry point not found". Windows caches
  // "no manifest" per exe, so the exe is touched afterwards to drop that.
  else if (!args.has('--no-build')) steps.push(`call ${vcvars} >nul`, 'swift build',
    'copy /y Sources\\PomoppiWindows\\Pomoppi.exe.manifest .build\\debug\\PomoppiWindows.exe.manifest >nul',
    'copy /b .build\\debug\\PomoppiWindows.exe +,, .build\\debug\\PomoppiWindows.exe >nul');
  const started = Date.now();
  status = ssh(steps.join(' && '));
  console.log(`vm-sync: ${commit.slice(0, 7)} ${status === 0 ? 'ok' : `failed (${status})`} in ${((Date.now() - started) / 1000).toFixed(1)}s`);
} finally {
  try { git(['update-ref', '-d', ref]); } catch {}
  fs.rmSync(tmp, { recursive: true, force: true });
}
process.exit(status);
