'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const loginItem = require('../lib/login-item');

function tmpHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'pomoppi-login-'));
}

// A stand-in for a bundle written by tools/make-launcher.js.
function makeBundle(dir, bundleId = loginItem.BUNDLE_ID) {
  const bundle = path.join(dir, loginItem.BUNDLE_NAME);
  fs.mkdirSync(path.join(bundle, 'Contents'), { recursive: true });
  fs.writeFileSync(path.join(bundle, 'Contents', 'Info.plist'),
    `<plist><dict><key>CFBundleIdentifier</key><string>${bundleId}</string></dict></plist>`);
  return bundle;
}

// Stands in for System Events' login-item list and for launchctl. Every
// apply() below is handed one of these, so no test can reach the real ones.
function fakeSystemEvents(initial = []) {
  const store = { items: [...initial], calls: [] };
  store.runner = (file, args) => {
    store.calls.push([file, ...args]);
    if (!file.endsWith('osascript')) return '';
    const script = args[1];
    // AppleScript string literals arrive escaped; System Events unescapes
    // them before it ever sees a path, so this stand-in has to as well.
    const unescape = (s) => s.replace(/\\(.)/g, '$1');
    if (script.includes('path of every login item')) return store.items.join('\n') + '\n';
    const added = script.match(/make login item at end with properties \{path:"(.*)", hidden:false\}/);
    if (added) { store.items.push(unescape(added[1])); return 'login item UNKNOWN\n'; }
    const deleted = script.match(/delete \(every login item whose path is "(.*)"\)/);
    if (deleted) {
      const gone = unescape(deleted[1]);
      store.items = store.items.filter((p) => p !== gone);
      return '';
    }
    throw new Error(`unexpected script: ${script}`);
  };
  return store;
}

// macOS refusing the Apple Event — no Automation permission for System Events.
function blockedSystemEvents() {
  const store = { calls: [] };
  store.runner = (file, args) => {
    store.calls.push([file, ...args]);
    if (file.endsWith('osascript')) {
      throw new Error('Not authorized to send Apple events to System Events. (-1743)');
    }
    return '';
  };
  return store;
}

const OTHER_APP = '/Applications/SomeoneElse.app';

test('enabling adds Pomoppi.app to the visible Login Items list', () => {
  const home = tmpHome();
  const bundle = makeBundle(path.join(home, 'Desktop'));
  const se = fakeSystemEvents([OTHER_APP]);

  const result = loginItem.apply(true, { home, uid: 501, runner: se.runner });
  assert.deepEqual(result, { ok: true, via: 'login-item', error: null });
  assert.deepEqual(se.items, [OTHER_APP, bundle]);
  // The visible entry is the only mechanism installed.
  assert.equal(loginItem.hasLaunchAgent(home), false);
});

test('enabling twice does not list Pomoppi twice', () => {
  const home = tmpHome();
  const bundle = makeBundle(path.join(home, 'Desktop'));
  const se = fakeSystemEvents();

  loginItem.apply(true, { home, uid: 501, runner: se.runner });
  loginItem.apply(true, { home, uid: 501, runner: se.runner });
  assert.deepEqual(se.items, [bundle]);
});

test('a bundle that moved replaces its stale entry', () => {
  const home = tmpHome();
  const desktop = makeBundle(path.join(home, 'Desktop'));
  const se = fakeSystemEvents([OTHER_APP, desktop]);

  fs.rmSync(desktop, { recursive: true });
  const installed = makeBundle(path.join(home, 'Applications'));
  const result = loginItem.apply(true, { home, uid: 501, runner: se.runner });

  assert.equal(result.via, 'login-item');
  assert.deepEqual(se.items, [OTHER_APP, installed]);
});

test('disabling removes our entry and touches nobody else', () => {
  const home = tmpHome();
  const bundle = makeBundle(path.join(home, 'Desktop'));
  const se = fakeSystemEvents([OTHER_APP, bundle]);

  const result = loginItem.apply(false, { home, uid: 501, runner: se.runner });
  assert.deepEqual(result, { ok: true, via: null, error: null });
  assert.deepEqual(se.items, [OTHER_APP]);
});

test('with Automation blocked, enabling falls back to a LaunchAgent and says so', () => {
  const home = tmpHome();
  const bundle = makeBundle(path.join(home, 'Desktop'));
  const se = blockedSystemEvents();

  const result = loginItem.apply(true, { home, uid: 501, runner: se.runner });
  assert.equal(result.ok, true);
  assert.equal(result.via, 'launch-agent');
  assert.equal(result.error, loginItem.BLOCKED_ENABLE);
  assert.equal(fs.readFileSync(loginItem.plistPath(home), 'utf8'), loginItem.buildPlist(bundle));
  // RunAtLoad would start a second Pomoppi the moment the job was loaded.
  assert.equal(se.calls.some(([file]) => file.endsWith('launchctl')), false);
});

test('a granted Login Items entry retires the fallback LaunchAgent', () => {
  const home = tmpHome();
  const bundle = makeBundle(path.join(home, 'Desktop'));
  loginItem.apply(true, { home, uid: 501, runner: blockedSystemEvents().runner });
  assert.equal(loginItem.hasLaunchAgent(home), true);

  const se = fakeSystemEvents();
  const result = loginItem.apply(true, { home, uid: 501, runner: se.runner });

  assert.equal(result.via, 'login-item');
  assert.deepEqual(se.items, [bundle]);
  // Never both: two registrations would be two launches at login.
  assert.equal(loginItem.hasLaunchAgent(home), false);
  assert.deepEqual(se.calls.filter(([file]) => file.endsWith('launchctl')),
    [['/bin/launchctl', 'bootout', 'gui/501/it.lucabessiaristei.pomoppi']]);
});

test('disabling still removes the LaunchAgent when Automation is blocked', () => {
  const home = tmpHome();
  makeBundle(path.join(home, 'Desktop'));
  loginItem.apply(true, { home, uid: 501, runner: blockedSystemEvents().runner });

  const result = loginItem.apply(false, { home, uid: 501, runner: blockedSystemEvents().runner });
  assert.equal(loginItem.hasLaunchAgent(home), false);
  assert.equal(result.ok, false);
  assert.equal(result.error, loginItem.BLOCKED_DISABLE);
});

test('a launchctl failure while removing the agent is not a failed setting', () => {
  const home = tmpHome();
  makeBundle(path.join(home, 'Desktop'));
  loginItem.apply(true, { home, uid: 501, runner: blockedSystemEvents().runner });

  const se = fakeSystemEvents();
  const runner = (file, args) => {
    if (file.endsWith('launchctl')) throw new Error('Boot-out failed: 3: No such process');
    return se.runner(file, args);
  };
  const result = loginItem.apply(false, { home, uid: 501, runner });
  assert.deepEqual(result, { ok: true, via: null, error: null });
  assert.equal(loginItem.hasLaunchAgent(home), false);
});

test('disabling when nothing was ever registered is a silent no-op', () => {
  const home = tmpHome();
  const se = fakeSystemEvents([OTHER_APP]);
  const result = loginItem.apply(false, { home, uid: 501, runner: se.runner });
  assert.deepEqual(result, { ok: true, via: null, error: null });
  assert.deepEqual(se.items, [OTHER_APP]);
});

test('with no Pomoppi.app to open, enabling reports why and registers nothing', () => {
  const home = tmpHome();
  const se = fakeSystemEvents();
  const result = loginItem.apply(true, { home, uid: 501, runner: se.runner });
  assert.equal(result.ok, false);
  assert.equal(result.error, loginItem.NO_BUNDLE);
  assert.match(result.error, /npm run launcher/);
  assert.deepEqual(se.items, []);
  assert.equal(loginItem.hasLaunchAgent(home), false);
});

test('only a bundle carrying our identifier counts', () => {
  const home = tmpHome();
  const ours = makeBundle(path.join(home, 'Desktop'));
  assert.equal(loginItem.isPomoppiBundle(ours), true);

  const impostor = makeBundle(path.join(home, 'Elsewhere'), 'com.example.other');
  assert.equal(loginItem.isPomoppiBundle(impostor), false);
  assert.equal(loginItem.isPomoppiBundle(path.join(home, 'Nothing.app')), false);
});

test('findAppBundle prefers ~/Applications over the Desktop', () => {
  const home = tmpHome();
  makeBundle(path.join(home, 'Desktop'));
  assert.equal(loginItem.findAppBundle(home), path.join(home, 'Desktop', 'Pomoppi.app'));

  const installed = makeBundle(path.join(home, 'Applications'));
  assert.equal(loginItem.findAppBundle(home), installed);
});

test('a login item is ours by bundle name, wherever it points', () => {
  assert.equal(loginItem.isOurLoginItemPath('/Users/x/Desktop/Pomoppi.app'), true);
  assert.equal(loginItem.isOurLoginItemPath('/Applications/Pomoppi.app/'), true);
  assert.equal(loginItem.isOurLoginItemPath('/Applications/Pomodoro.app'), false);
});

test('the list parses one path per line, so a comma in a path survives', () => {
  const se = fakeSystemEvents(['/Applications/Thing, Inc.app', '/Users/x/Desktop/Pomoppi.app']);
  assert.deepEqual(loginItem.listLoginItemPaths(se.runner),
    ['/Applications/Thing, Inc.app', '/Users/x/Desktop/Pomoppi.app']);
});

test('the fallback plist opens the bundle through LaunchServices', () => {
  const plist = loginItem.buildPlist('/Users/someone/Desktop/Pomoppi.app');
  assert.match(plist, /<key>Label<\/key>\s*<string>it\.lucabessiaristei\.pomoppi<\/string>/);
  assert.match(plist, /<string>\/usr\/bin\/open<\/string>/);
  assert.match(plist, /<string>\/Users\/someone\/Desktop\/Pomoppi\.app<\/string>/);
  assert.match(plist, /<key>RunAtLoad<\/key>\s*<true\/>/);
  // Never the Electron binary the process happens to be running from.
  assert.equal(plist.includes('node_modules'), false);
});

test('paths with XML- and AppleScript-special characters survive', () => {
  const home = tmpHome();
  const weird = '/Users/a & b/say "hi"/Pomoppi.app';
  const se = fakeSystemEvents();
  loginItem.apply(true, { home, uid: 501, bundlePath: weird, runner: se.runner });
  assert.deepEqual(se.items, [weird]);

  assert.match(loginItem.buildPlist(weird), /<string>\/Users\/a &amp; b\/say &quot;hi&quot;\/Pomoppi\.app<\/string>/);
});
