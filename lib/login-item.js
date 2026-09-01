// lib/login-item.js — "Open Pomoppi when I log in" (SPEC.md §7 "Launch at
// login"). Two mechanisms, in preference order, both pointing at the
// Pomoppi.app bundle tools/make-launcher.js builds (§10):
//
//   1. A **Login Items entry**, via System Events. This is the one users can
//      see and manage: System Settings ▸ General ▸ Login Items ▸ "Open at
//      Login", named Pomoppi, with our icon.
//   2. A per-user **LaunchAgent**, if and only if macOS blocks (1). Editing
//      the Login Items list is an Apple Event, so it needs Automation
//      permission for System Events, which an unpackaged Electron app does
//      not reliably get. The agent needs no permission at all, but only
//      surfaces under "Allow in the Background" — which is exactly what made
//      the first version of this look like it had done nothing.
//
// What it is NOT is app.setLoginItemSettings: on macOS 13+ that registers,
// through SMAppService.mainApp, *the bundle the process is running from*. For
// an unpackaged app that is always the shared Electron binary in
// node_modules, and Electron's `path`/`args` override is Windows-only
// (electron.d.ts: "@platform win32"). macOS accepts the registration and then
// opens a bare Electron at every login.
//
// Only ever one mechanism is installed at a time. Both launch through
// LaunchServices — the same shape as a double-click, the one the tray icon is
// known to survive (§10) — and Pomoppi's single-instance lock means even a
// duplicate registration would only raise the widget, never start a second
// copy.
//
// Takes the home directory as an argument rather than calling Electron's
// app.getPath, and shells out through an injectable `runner`, so this file
// never imports 'electron' and tests never touch the real login items.
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// Must match tools/make-launcher.js — a bundle is only ours if it says so.
const BUNDLE_ID = 'it.lucabessiaristei.pomoppi';
const LABEL = BUNDLE_ID;
const PLIST_NAME = `${LABEL}.plist`;
const BUNDLE_NAME = 'Pomoppi.app';

const OSASCRIPT = '/usr/bin/osascript';
const LAUNCHCTL = '/bin/launchctl';

const BLOCKED_ENABLE =
  'macOS blocked Pomoppi from editing the Login Items list, so it opens at login as a background item instead. ' +
  'To get the visible entry, allow System Events under Privacy & Security ▸ Automation, then switch this off and on again.';
const BLOCKED_DISABLE =
  "macOS blocked Pomoppi from editing the Login Items list. If Pomoppi is still listed under System Settings ▸ General ▸ Login Items, remove it there.";
const NO_BUNDLE =
  'Couldn’t find Pomoppi.app, so there’s nothing to open at login — run "npm run launcher" to build it in Applications, then switch this back on.';

// ---------------------------------------------------------------------------
// The bundle to open
// ---------------------------------------------------------------------------

// Where a bundle built by `npm run launcher` plausibly lives: its default
// destination, plus the two places a user would drag it to. Order is
// preference — an installed copy wins over the one left on the Desktop.
function bundleCandidates(home) {
  return [
    path.join('/Applications', BUNDLE_NAME),
    path.join(home, 'Applications', BUNDLE_NAME),
    path.join(home, 'Desktop', BUNDLE_NAME),
  ];
}

// The same identity check tools/make-launcher.js makes before overwriting: a
// directory called Pomoppi.app is not enough, its Info.plist has to carry our
// bundle identifier.
function isPomoppiBundle(bundlePath) {
  try {
    if (!fs.statSync(bundlePath).isDirectory()) return false;
    const info = fs.readFileSync(path.join(bundlePath, 'Contents', 'Info.plist'), 'utf8');
    return info.includes('<key>CFBundleIdentifier</key>') && info.includes(BUNDLE_ID);
  } catch (_) {
    return false;
  }
}

function findAppBundle(home) {
  return bundleCandidates(home).find(isPomoppiBundle) || null;
}

// A login item we own, judged by name alone: a stale entry points at a bundle
// that has since moved or been deleted, so there is nothing left to read a
// bundle identifier out of.
function isOurLoginItemPath(itemPath) {
  return path.basename(itemPath.replace(/\/+$/, '')) === BUNDLE_NAME;
}

// ---------------------------------------------------------------------------
// 1. The Login Items list (System Events)
// ---------------------------------------------------------------------------

function defaultRunner(file, args) {
  return execFileSync(file, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function osa(runner, script) {
  return runner(OSASCRIPT, ['-e', script]);
}

function appleScriptString(str) {
  return `"${String(str).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

// One path per line rather than osascript's default ", " join — a path is
// allowed to contain a comma, a line feed is not.
function listLoginItemPaths(runner) {
  const script = [
    'tell application "System Events" to set thePaths to path of every login item',
    "set AppleScript's text item delimiters to linefeed",
    'return thePaths as text',
  ].join('\n');
  return osa(runner, script)
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

function addLoginItem(runner, bundlePath) {
  osa(runner,
    'tell application "System Events" to make login item at end with properties ' +
    `{path:${appleScriptString(bundlePath)}, hidden:false}`);
}

function deleteLoginItemsAt(runner, itemPaths) {
  for (const itemPath of itemPaths) {
    osa(runner,
      'tell application "System Events" to delete (every login item whose path is ' +
      `${appleScriptString(itemPath)})`);
  }
}

// ---------------------------------------------------------------------------
// 2. The LaunchAgent fallback
// ---------------------------------------------------------------------------

function launchAgentsDir(home) {
  return path.join(home, 'Library', 'LaunchAgents');
}

function plistPath(home) {
  return path.join(launchAgentsDir(home), PLIST_NAME);
}

// One-shot job: `open` returns as soon as LaunchServices has the app, so the
// running Pomoppi is never a child of this agent — which is what makes
// removing it safe (booting the job out can't kill a running widget).
function buildPlist(bundlePath) {
  const xml = (str) => String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${xml(LABEL)}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>${xml(bundlePath)}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
`;
}

function hasLaunchAgent(home) {
  return fs.existsSync(plistPath(home));
}

// Never loads the job it writes: RunAtLoad would start a second Pomoppi on
// the spot. launchd picks the plist up at the next login, which is the point.
// Writing is skipped when the file already says exactly this, so re-applying
// the setting on every launch doesn't churn the file.
function writeLaunchAgent(home, bundlePath) {
  const file = plistPath(home);
  const wanted = buildPlist(bundlePath);
  let current = null;
  try { current = fs.readFileSync(file, 'utf8'); } catch (_) { /* not written yet */ }
  if (current !== wanted) {
    fs.mkdirSync(launchAgentsDir(home), { recursive: true });
    fs.writeFileSync(file, wanted);
  }
}

// Best effort by design, and never throws: the plist on disk is what decides
// the next login, so a failure to unload a job in *this* session must not
// turn into a failed setting.
function removeLaunchAgent(home, uid, runner) {
  try {
    if (!hasLaunchAgent(home)) return;
    try {
      runner(LAUNCHCTL, ['bootout', `gui/${uid}/${LABEL}`]);
    } catch (_) {
      // Not loaded — the usual case, nothing loads it until the next login.
    }
    fs.rmSync(plistPath(home));
  } catch (_) {
    // Leave it; the next apply() tries again.
  }
}

// ---------------------------------------------------------------------------
// apply
// ---------------------------------------------------------------------------

// Brings both mechanisms in line with `enabled`, preferring the visible one.
// Returns { ok, via, error } — `error` is the human-readable line the settings
// window shows under the checkbox (a notice, when the fallback is what got
// installed), and `via` is which mechanism ended up in place.
function apply(enabled, options = {}) {
  const home = options.home;
  const uid = options.uid != null ? options.uid : process.getuid();
  const runner = options.runner || defaultRunner;

  if (!enabled) {
    removeLaunchAgent(home, uid, runner);
    try {
      const ours = listLoginItemPaths(runner).filter(isOurLoginItemPath);
      if (ours.length) deleteLoginItemsAt(runner, ours);
    } catch (_) {
      return { ok: false, via: null, error: BLOCKED_DISABLE };
    }
    return { ok: true, via: null, error: null };
  }

  const bundlePath = options.bundlePath || findAppBundle(home);
  if (!bundlePath) return { ok: false, via: null, error: NO_BUNDLE };

  try {
    const ours = listLoginItemPaths(runner).filter(isOurLoginItemPath);
    // A stale entry is one left pointing at a copy of Pomoppi.app that has
    // since moved — delete it rather than ending up listed twice.
    const stale = ours.filter((p) => p !== bundlePath);
    if (stale.length) deleteLoginItemsAt(runner, stale);
    if (!ours.includes(bundlePath)) addLoginItem(runner, bundlePath);
    removeLaunchAgent(home, uid, runner);
    return { ok: true, via: 'login-item', error: null };
  } catch (_) {
    // Automation permission refused, or System Events unavailable. Fall back
    // rather than leave the setting on and doing nothing.
    try {
      writeLaunchAgent(home, bundlePath);
    } catch (err) {
      return { ok: false, via: null, error: `Couldn’t update the login item: ${err.message}` };
    }
    return { ok: true, via: 'launch-agent', error: BLOCKED_ENABLE };
  }
}

module.exports = {
  BUNDLE_ID,
  LABEL,
  BUNDLE_NAME,
  BLOCKED_ENABLE,
  BLOCKED_DISABLE,
  NO_BUNDLE,
  bundleCandidates,
  isPomoppiBundle,
  findAppBundle,
  isOurLoginItemPath,
  listLoginItemPaths,
  launchAgentsDir,
  plistPath,
  buildPlist,
  hasLaunchAgent,
  apply,
};
