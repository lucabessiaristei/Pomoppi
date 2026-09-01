// main.js — Electron main process for Pomoppi (SPEC.md §2, §6, §9, §12).
'use strict';

const path = require('path');
const fs = require('fs');
const { app, BrowserWindow, Tray, Menu, ipcMain, dialog, nativeImage, globalShortcut } = require('electron');

const Settings = require('./lib/settings');
const Timer = require('./lib/timer');
const ObsidianLogger = require('./lib/obsidian');
const loginItem = require('./lib/login-item');
// Read-only art data (SPEC.md §1) — used here only for the tray's Friend and
// submenu labels/ids. Never edited.
const SPRITES = require('./renderer/sprites');
// Dual-mode like sprites.js (module.exports under Node, window.SHORTCUTS in a
// renderer) — see renderer/shortcuts.js. Read here for ACTION_IDS (registration
// order) and the id -> accelerator map's shape; the bindings themselves live in
// settings, not here.
const SHORTCUTS = require('./renderer/shortcuts');

// 104x128, not the 96x120 the widget canvas actually draws on: macOS clips a
// frameless window's corners with its own rounded-rect mask, which was eating
// the corners of the drawn pixel frame. The frame is now drawn inset 4px so
// its corners fall inside that rounded region instead of on the clip edge.
const LOGICAL_WIDTH = 118;
const LOGICAL_HEIGHT = 132;
const TICK_MS = 250;
// INVARIANT: the widget must never be able to cover or hide the macOS menu
// bar. NSFloatingWindowLevel (3) is above ordinary windows and below
// NSMainMenuWindowLevel (24), so it cannot. Never raise this level:
// 'screen-saver' (1000) was used here once and macOS withdrew the menu bar
// entirely for as long as the widget held it.
const ALWAYS_ON_TOP_LEVEL = 'floating';

let settings = null;
let timer = null;
let obsidian = null;

let widgetWindow = null;
let settingsWindow = null;
let taskWindow = null;
let tray = null;

let lastLogError = null;
let lastLoginItemError = null; // human-readable, or null — see applyLoginItemSetting
let shortcutErrors = {}; // { [actionId]: accelerator } — every binding globalShortcut.register refused, see registerGlobalShortcuts
let pendingTaskIntent = null; // 'start' | 'rename' | null — what submitting the task window should do

function sizeForScale(scale) {
  return { width: LOGICAL_WIDTH * scale, height: LOGICAL_HEIGHT * scale };
}

function formatClock(ms) {
  const totalSeconds = Math.max(0, Math.ceil(ms / 1000));
  const m = Math.floor(totalSeconds / 60);
  const s = totalSeconds % 60;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}

function phaseLabel(phase) {
  if (phase === 'focus') return 'Focus';
  if (phase === 'shortBreak') return 'Short Break';
  if (phase === 'longBreak') return 'Long Break';
  return 'Idle';
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

// What we have actually pushed to the widget window, so a settings change that
// doesn't touch a property doesn't re-push it. This is not micro-optimisation:
// on macOS setAlwaysOnTop re-levels and re-orders the window even when handed
// the value it already has, so with alwaysOnTop off, picking a friend from the
// tray menu sank the widget behind every other window.
// INVARIANT: nothing calls widgetWindow.setAlwaysOnTop directly. Every level
// change goes through setWidgetAlwaysOnTop, and the alwaysOnTop setting is the
// only value it is ever handed.
let appliedAlwaysOnTop = null;
let appliedOpacity = null;

function setWidgetAlwaysOnTop(value) {
  if (!widgetWindow || widgetWindow.isDestroyed()) return;
  if (appliedAlwaysOnTop === value) return;
  widgetWindow.setAlwaysOnTop(value, ALWAYS_ON_TOP_LEVEL);
  appliedAlwaysOnTop = value;
}

function setWidgetOpacity(value) {
  if (!widgetWindow || widgetWindow.isDestroyed()) return;
  if (appliedOpacity === value) return;
  widgetWindow.setOpacity(value);
  appliedOpacity = value;
}

function createWidgetWindow() {
  const s = settings.get();
  const size = sizeForScale(s.scale);
  widgetWindow = new BrowserWindow({
    width: size.width,
    height: size.height,
    frame: false,
    transparent: true,
    hasShadow: false,
    backgroundColor: '#00000000',
    resizable: false,
    skipTaskbar: true,
    opacity: s.opacity,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  // The window is new, so nothing has been pushed to it yet: the constructor
  // already applied opacity, the level has to be set explicitly below.
  appliedOpacity = s.opacity;
  appliedAlwaysOnTop = null;
  // Explicit level rather than the constructor's splotchy `alwaysOnTop: true`
  // boolean, so this and applySettingsSideEffects — the only two places that
  // touch the level — pin the same one. See ALWAYS_ON_TOP_LEVEL.
  setWidgetAlwaysOnTop(s.alwaysOnTop);
  // A menu-bar widget with no fixed home is easy to lose on another Space, so
  // it lives on all of them. This is a persistent NSWindow property: setting
  // it once here is enough, and it survives resize, show/hide and raise.
  // INVARIANT: no visibleOnFullScreen. Electron documents that option as
  // "visible above fullscreen windows"; it sets NSWindowCollectionBehavior
  // FullScreenAuxiliary, which is precisely what lets a window join another
  // app's full-screen Space. The widget must never appear over a full-screen
  // app — it was covering full-screen video, and an auxiliary window in a
  // Space whose menu bar is auto-hidden took the menu bar with it.
  // skipTransformProcessType avoids a brief dock/window flash; safe because
  // app.dock.hide() already made this an accessory app.
  widgetWindow.setVisibleOnAllWorkspaces(true, { skipTransformProcessType: true });
  widgetWindow.loadFile(path.join(__dirname, 'renderer', 'widget.html'));
  // startHidden is a startup-only preference (applySettingsSideEffects never
  // touches it) — the window still exists and keeps receiving state/settings
  // broadcasts, it just never auto-shows. The tray's Show Pomoppi item and
  // raiseOnEnd both go through raiseWidget(), which shows it, so either still
  // brings it up from here.
  if (!s.startHidden) {
    widgetWindow.once('ready-to-show', () => widgetWindow.show());
  }
  widgetWindow.on('closed', () => { widgetWindow = null; });
}

function openSettingsWindow() {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }
  settingsWindow = new BrowserWindow({
    width: 480,
    height: 680,
    // The settings page reflows rather than scrolling sideways; these are the
    // narrowest/shortest it was designed against, so the layout can't be
    // dragged into a size it has no answer for.
    minWidth: 380,
    minHeight: 420,
    title: 'Pomoppi Settings',
    webPreferences: {
      preload: path.join(__dirname, 'preload-settings.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  settingsWindow.setMenuBarVisibility(false);
  settingsWindow.loadFile(path.join(__dirname, 'renderer', 'settings.html'));
  settingsWindow.on('closed', () => { settingsWindow = null; });
}

function openTaskWindow(intent) {
  pendingTaskIntent = intent;
  if (taskWindow && !taskWindow.isDestroyed()) {
    taskWindow.show();
    taskWindow.focus();
    return;
  }
  taskWindow = new BrowserWindow({
    width: 320,
    height: 150,
    frame: false,
    resizable: false,
    center: true,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload-settings.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  taskWindow.loadFile(path.join(__dirname, 'renderer', 'task.html'));
  taskWindow.once('ready-to-show', () => taskWindow.show());
  taskWindow.on('closed', () => { taskWindow = null; pendingTaskIntent = null; });
}

function closeTaskWindow() {
  if (taskWindow && !taskWindow.isDestroyed()) taskWindow.close();
}

// Brings the widget to the front and makes Pomoppi the active app. One
// behaviour for every caller — the tray, a second launch, and raiseOnEnd all
// mean "put this in front of me now", so there are no flags and no variants.
//
// It activates unconditionally, on purpose: this is an alarm, and it is meant
// to interrupt. That pulls the user out of a full-screen Space (the widget
// itself never joins one — see setVisibleOnAllWorkspaces) and can take the
// keyboard mid-sentence. Both are accepted; the constant overlap of
// full-screen apps was the actual comsplotchyt, not being interrupted when a
// session ends.
//
// app.focus is what does the activating. Pomoppi is an accessory app
// (app.dock.hide below), so making one of its windows key does not make the
// application active by itself; { steal: true } is documented as making the
// receiver active even when another app currently is. moveTop() only
// re-orders the window within its own level — the level is never touched
// here, it belongs to the alwaysOnTop setting alone, and a raise that changed
// it is what put the widget over full-screen apps and the menu bar before.
function raiseWidget() {
  if (!widgetWindow || widgetWindow.isDestroyed()) return;
  if (!widgetWindow.isVisible()) widgetWindow.show();
  widgetWindow.moveTop();
  app.focus({ steal: true });
  widgetWindow.focus();
}

// Shared by the tray's Show/Hide item and the toggleWidget global shortcut,
// so the two definitions of "toggle" can't drift. Showing goes through
// raiseWidget() rather than a bare .show(), for the same reason every other
// raise does; hiding never touches the level (SPEC.md §9b).
function toggleWidgetVisibility() {
  if (!widgetWindow || widgetWindow.isDestroyed()) return;
  if (widgetWindow.isVisible()) widgetWindow.hide();
  else raiseWidget();
}

// ---------------------------------------------------------------------------
// Tray
// ---------------------------------------------------------------------------

function requestStart() {
  const state = timer.getState();
  const s = settings.get();
  // Only prompt when there is actually nothing to name. Setting a task ahead of
  // time (tray > Set task...) and then pressing play used to re-open the same
  // dialog on top of the name just typed, which made naming a session in
  // advance pointless.
  if (state.phase === 'idle' && s.askForTaskName && !timer.getTask()) {
    openTaskWindow('start');
  } else {
    timer.start();
  }
}

// Rebuilt by updateTray on every broadcast (so its radio items/labels stay
// current) and shown on demand by the right-click handler below — kept
// separate from Tray's own setContextMenu, which on macOS binds *both*
// clicks to the menu and would swallow the left-click raise.
let trayMenu = null;
// Rebuild guards. updateTray runs on every 250ms tick forever (timer.tick emits
// whether or not a phase is running), so anything unguarded here is work done
// four times a second for the life of the process. Each of these holds the
// value last pushed to the OS; a tick that changes nothing costs nothing.
let trayMenuSig = null;
let trayTitle = null;
let trayTip = null;
let trayFrameIdx = -1;
let trayImages = [];

// Menu-bar animation. Every frame gets the same time on screen: the source is a
// loop the artist drew in Aseprite, not a rest pose plus an accent, so nothing
// here should privilege frame 0. The index comes off the wall clock rather than
// a tick counter, for the same reason the timer stores endsAt — a missed or
// late tick must not shift the animation's phase.
const TRAY_FRAME_MS = 500; // >= 2 ticks, so a frame can never be skipped

// Which of our own windows currently has focus, if any.
function focusedOwnWindow() {
  for (const w of [settingsWindow, taskWindow, widgetWindow]) {
    if (w && !w.isDestroyed() && w.isFocused()) return w;
  }
  return null;
}

// macOS gives event focus to the status bar for as long as a tray menu is up,
// and when the menu closes activation returns to whichever *application* was
// frontmost. Pomoppi is an accessory app (app.dock.hide), so it is never that
// application — which means any window of ours that was in front before the
// click ends up behind whatever is. That is the whole reason opening the tray
// menu sent the settings window and the widget backwards.
//
// So note what was focused and put it back once the menu is gone. Only
// activation is touched here: the window *level* is still owned solely by the
// alwaysOnTop setting, and nothing in this path calls setAlwaysOnTop
// (SPEC.md §9b).
function popTrayMenu() {
  // updateTray rebuilds trayMenu on every broadcast, so hold the instance we
  // actually pop rather than the variable, which may point at a newer menu by
  // the time this one closes.
  const menu = trayMenu;
  if (!menu) return;
  const restore = focusedOwnWindow();
  if (restore) {
    menu.once('menu-will-close', () => {
      // menu-will-close fires while the menu is still tearing down, so the
      // restore goes on the next turn of the event loop — macOS has to finish
      // handing activation back first. This is not a layering timer; it never
      // touches the level.
      setImmediate(() => {
        // A menu item may have deliberately put focus somewhere (Settings…,
        // Set task…) or taken the window away (Hide Pomoppi, Quit). In either
        // case leave it alone — this only undoes the *incidental* deactivation
        // of dismissing the menu.
        if (focusedOwnWindow()) return;
        if (restore.isDestroyed() || !restore.isVisible()) return;
        app.focus({ steal: true });
        restore.focus();
      });
    });
  }
  tray.popUpContextMenu(menu);
}

// One image per SPRITES.TRAY_FRAMES entry, written by `npm run icons`. The
// frame count lives in the art: draw another frame, re-run icons, and it
// animates with no change here. Falls back to the single pre-animation asset so
// a checkout whose icons have not been regenerated still gets a tray.
function loadTrayImages() {
  const images = [];
  for (let i = 0; i < SPRITES.TRAY_FRAMES.length; i++) {
    const img = nativeImage.createFromPath(
      path.join(__dirname, 'assets', `trayTemplate-${i}.png`));
    if (img.isEmpty()) break;
    img.setTemplateImage(true);
    images.push(img);
  }
  if (images.length === 0) {
    const legacy = nativeImage.createFromPath(
      path.join(__dirname, 'assets', 'trayTemplate.png'));
    legacy.setTemplateImage(true);
    images.push(legacy);
  }
  return images;
}

function trayFrameFor(nowTs) {
  const n = trayImages.length;
  if (n < 2) return 0;
  return Math.floor(nowTs / TRAY_FRAME_MS) % n;
}

function createTray() {
  trayImages = loadTrayImages();
  tray = new Tray(trayImages[0]);
  // Left-click opens the menu, right-click surfaces the widget — the user's
  // choice, and the reverse of the usual menu-bar-app split. Both buttons are
  // bound explicitly rather than through tray.setContextMenu, which on macOS
  // binds the menu to *both* of them and would leave no click that finds a
  // widget hiding behind other windows. Registered once here, not in
  // updateTray (which runs on every 250ms tick) — re-registering there would
  // stack a new listener per tick and leak.
  tray.on('click', () => {
    diagState('TRAY left-click (menu) BEFORE');
    popTrayMenu();
    setTimeout(() => diagState('TRAY left-click (menu) +500ms'), 500);
    setTimeout(() => diagState('TRAY left-click (menu) +2s'), 2000);
  });
  tray.on('right-click', () => {
    diagState('TRAY right-click (raise) BEFORE');
    raiseWidget();
    setTimeout(() => diagState('TRAY right-click (raise) +500ms'), 500);
    setTimeout(() => diagState('TRAY right-click (raise) +2s'), 2000);
  });
  updateTray(timer.getState());
}

// Sessions per long break — the same clamp the widget's dots and the settings
// form use, so the three can't offer different ranges.
function buildSessionsSubmenu() {
  const current = settings.get().longBreakEvery;
  const items = [];
  for (let n = Settings.LONG_BREAK_EVERY_MIN; n <= Settings.LONG_BREAK_EVERY_MAX; n++) {
    items.push({
      label: String(n),
      type: 'radio',
      checked: n === current,
      click: () => applySettingsPatch({ longBreakEvery: n }),
    });
  }
  return items;
}

// Grouped: what the timer is doing, then how it is configured, then the window,
// then the app. Friend and Window edge used to live here and no longer do —
// they are pickers in the settings window and having two homes meant two places
// to keep in sync for a choice nobody changes mid-session.
function buildTrayTemplate(state, widgetVisible) {
  const idle = state.phase === 'idle';
  const onBreak = state.phase === 'shortBreak' || state.phase === 'longBreak';
  return [
    {
      label: state.running ? 'Pause' : 'Start',
      click: () => { if (state.running) timer.pause(); else requestStart(); },
    },
    // Both are no-ops from idle (lib/timer.js), so they say so rather than
    // looking live and doing nothing.
    { label: 'Skip', enabled: !idle, click: () => timer.skip() },
    { label: 'Reset', enabled: !idle, click: () => timer.reset() },
    {
      // A task belongs to a focus session and is cleared when the phase ends,
      // so during a break there is nothing to rename.
      label: state.phase === 'focus' ? 'Rename task…' : 'Set task…',
      enabled: !onBreak,
      click: () => openTaskWindow('rename'),
    },
    { type: 'separator' },
    { label: 'Sessions per long break', submenu: buildSessionsSubmenu() },
    { type: 'separator' },
    {
      label: widgetVisible ? 'Hide Pomoppi' : 'Show Pomoppi',
      click: toggleWidgetVisibility,
    },
    {
      label: 'Keep on top',
      type: 'checkbox',
      checked: settings.get().alwaysOnTop,
      click: () => applySettingsPatch({ alwaysOnTop: !settings.get().alwaysOnTop }),
    },
    {
      label: 'Save snapshot to Desktop',
      // The key itself is already live through globalShortcut
      // (registerGlobalShortcuts) — registerAccelerator: false paints the
      // hint without asking the menu to also own the combo.
      accelerator: settings.get().shortcuts.snapshot || undefined,
      registerAccelerator: false,
      click: () => captureSnapshot(),
    },
    { type: 'separator' },
    { label: 'Settings…', click: () => openSettingsWindow() },
    { label: 'Quit', click: () => app.quit() },
  ];
}


function updateTray(state) {
  if (!tray) return;
  const s = settings.get();
  const widgetVisible = !!(widgetWindow && !widgetWindow.isDestroyed() && widgetWindow.isVisible());

  // The menu is rebuilt only when something it actually shows has changed. It
  // used to be rebuilt on every tick, throwing away a fresh Menu four times a
  // second. Everything the template reads is in this signature — including
  // state.running, which the Start/Pause item's click handler closes over, so
  // the closure can never go stale.
  const sig = [widgetVisible, s.alwaysOnTop, state.running, state.phase,
               s.longBreakEvery, s.shortcuts.snapshot].join('|');
  if (sig !== trayMenuSig) {
    trayMenu = Menu.buildFromTemplate(buildTrayTemplate(state, widgetVisible));
    trayMenuSig = sig;
  }

  // The clock, live in the menu bar beside the icon. It is the same
  // remainingMs the widget is drawing from the same broadcast, so the two can
  // never disagree. monospacedDigit stops the title reflowing every second as
  // digit widths change. setTitle is macOS-only.
  const clock = formatClock(state.remainingMs);
  if (process.platform === 'darwin' && clock !== trayTitle) {
    tray.setTitle(clock, { fontType: 'monospacedDigit' });
    trayTitle = clock;
  }

  const frame = trayFrameFor(Date.now());
  if (frame !== trayFrameIdx && trayImages[frame]) {
    tray.setImage(trayImages[frame]);
    trayFrameIdx = frame;
  }

  const tip = `${phaseLabel(state.phase)} — ${clock}`;
  if (tip !== trayTip) {
    tray.setToolTip(tip);
    trayTip = tip;
  }
}

// ---------------------------------------------------------------------------
// SVG snapshot
// ---------------------------------------------------------------------------

// Asks the widget to draw itself out as SVG and hand the result back through
// pomoppi:saveSnapshot. The global shortcut and the tray item both land here.
// Guarded against firing before the window (or its first load) exists, since
// a global shortcut can be pressed the instant the app finishes launching.
function captureSnapshot() {
  if (!widgetWindow || widgetWindow.isDestroyed()) return;
  if (widgetWindow.webContents.isLoading()) {
    widgetWindow.webContents.once('did-finish-load', () => {
      widgetWindow.webContents.send('pomoppi:snapshot-request');
    });
    return;
  }
  widgetWindow.webContents.send('pomoppi:snapshot-request');
}

const SNAPSHOT_MAX_BYTES = 4 * 1024 * 1024;

function pad2(n) { return String(n).padStart(2, '0'); }

// Local time, not UTC — the name is meant to sit naturally among whatever else
// lands on the Desktop that day, not match a server log.
function snapshotBaseName(nowTs) {
  const d = new Date(nowTs);
  const date = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const time = `${pad2(d.getHours())}${pad2(d.getMinutes())}${pad2(d.getSeconds())}`;
  return `Pomoppi-${date}-${time}`;
}

// The renderer only ever hands over the SVG text — main generates the
// filename and picks the Desktop, the renderer never supplies a path. This is
// the one place renderer-fed bytes land on disk, so the payload is checked
// before anything is written: a string, starting with '<svg' (nothing else is
// a snapshot), under 4 MB (the widget is 118x132 logical px — a real snapshot
// is a few KB, so this is a sanity ceiling, not a working limit).
function saveSnapshot(svg) {
  if (typeof svg !== 'string' || !svg.startsWith('<svg') ||
      Buffer.byteLength(svg, 'utf8') > SNAPSHOT_MAX_BYTES) {
    return { ok: false, error: 'invalid snapshot payload' };
  }
  const dir = app.getPath('desktop');
  const base = snapshotBaseName(Date.now());
  let name = `${base}.svg`;
  for (let n = 2; fs.existsSync(path.join(dir, name)); n++) {
    name = `${base}-${n}.svg`;
  }
  const target = path.join(dir, name);
  try {
    fs.writeFileSync(target, svg, 'utf8');
    return { ok: true, path: target };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

// ---------------------------------------------------------------------------
// State broadcast
// ---------------------------------------------------------------------------

function broadcastState() {
  const state = { ...timer.getState(), logError: lastLogError };
  if (widgetWindow && !widgetWindow.isDestroyed()) {
    widgetWindow.webContents.send('pomoppi:state', state);
  }
  updateTray(state);
}

function broadcastSettings() {
  const s = settings.get();
  if (widgetWindow && !widgetWindow.isDestroyed()) {
    widgetWindow.webContents.send('pomoppi:settings', s);
  }
}

// Launch at login registers Pomoppi.app — the bundle, the one a user can see
// in System Settings ▸ Login Items — through lib/login-item.js, and NOT
// through app.setLoginItemSettings. That API registers the bundle the process
// is running from, which for an unpackaged app is always the shared Electron
// binary in node_modules: macOS accepts it and then launches a bare Electron
// at login instead of Pomoppi. See lib/login-item.js and SPEC.md §7.
function applyLoginItemSetting(openAtLogin) {
  if (process.platform !== 'darwin') return;
  const result = loginItem.apply(openAtLogin, { home: app.getPath('home') });
  lastLoginItemError = result.error;
}

// One-time repair for machines that ran the old setLoginItemSettings path:
// that registration is still live, still points at node_modules' Electron,
// and only the same API can take it back. Unregistering is keyed off the
// running bundle, so it has to happen from Electron — lib/login-item.js can't
// do it. Safe to run every launch: with nothing registered it's a no-op.
function clearStaleElectronLoginItem() {
  if (process.platform !== 'darwin') return;
  try {
    if (app.getLoginItemSettings().openAtLogin) {
      app.setLoginItemSettings({ openAtLogin: false });
    }
  } catch (_) {
    // Best effort — a leftover registration must never stop the app booting.
  }
}

// One handler per SHORTCUTS action id, mirroring the tray item or in-app key
// each shortcut stands in for — see the shortcuts contract for the mapping.
// A plain object rather than a switch: registerGlobalShortcuts below just
// looks each id up.
const SHORTCUT_HANDLERS = {
  toggleWidget: () => toggleWidgetVisibility(),
  startPause: () => { if (timer.getState().running) timer.pause(); else requestStart(); },
  // Both are no-ops from idle (lib/timer.js) — the same reasoning that leaves
  // the tray's Skip/Reset items enabled or not; there is nothing to gate here.
  skip: () => timer.skip(),
  reset: () => timer.reset(),
  toggleOnTop: () => applySettingsPatch({ alwaysOnTop: !settings.get().alwaysOnTop }),
  snapshot: () => captureSnapshot(),
  openSettings: () => openSettingsWindow(),
};

// Last shortcuts object actually registered with the OS, as JSON. Comparing
// serialised objects is only sound because SHORTCUTS.validate always emits the
// keys in ACTION_IDS order, so equal settings always serialise identically —
// every shortcuts object reaching here has been through it.
// globalShortcut is a system-wide resource: unregistering and rebinding seven
// hotkeys on every settings write that has nothing to do with shortcuts would
// needlessly churn it, so this short-circuits the same way appliedAlwaysOnTop
// and appliedOpacity already do above.
let appliedShortcutsKey = null;

// unregisterAll() then re-register every non-empty binding. globalShortcut can
// both return false and throw for a combo it can't claim — Electron's docs
// only promise the former, but a genuinely malformed accelerator string throws
// instead, so both are caught and recorded the same way: another app (or a
// typo) holds it.
function registerGlobalShortcuts() {
  const bindings = settings.get().shortcuts;
  const key = JSON.stringify(bindings);
  if (key === appliedShortcutsKey) return;
  appliedShortcutsKey = key;

  globalShortcut.unregisterAll();
  shortcutErrors = {};
  for (const id of SHORTCUTS.ACTION_IDS) {
    const accel = bindings[id];
    if (!accel) continue; // '' means deliberately unbound
    try {
      if (!globalShortcut.register(accel, SHORTCUT_HANDLERS[id])) shortcutErrors[id] = accel;
    } catch (_) {
      shortcutErrors[id] = accel;
    }
  }
}

function applySettingsSideEffects(s) {
  applyLoginItemSetting(s.launchAtLogin);
  registerGlobalShortcuts();
  if (widgetWindow && !widgetWindow.isDestroyed()) {
    // All three are no-ops when the value hasn't changed. That matters most
    // for the level: re-applying it re-orders the window, so without this a
    // friend change from the tray buried the widget.
    setWidgetOpacity(s.opacity);
    setWidgetAlwaysOnTop(s.alwaysOnTop);
    const size = sizeForScale(s.scale);
    const [w, h] = widgetWindow.getSize();
    if (w !== size.width || h !== size.height) {
      widgetWindow.setSize(size.width, size.height);
    }
  }
}

// The one path every settings mutation goes through — IPC (settings window)
// and the tray's Friend submenu both call this, so they stay in sync.
function applySettingsPatch(patch) {
  const updated = settings.set(patch);
  applySettingsSideEffects(updated);
  broadcastSettings();
  // State, not just the tray: an idle timer reports the focus length as its
  // clock (lib/timer.js getState), so editing focusMinutes moves the widget's
  // countdown too. Without this it would sit stale until the next 250ms tick.
  broadcastState();
  // loginItemError and shortcutErrors ride along on the response rather than
  // living in settings.json — both are runtime facts about the OS calls just
  // made, not persisted preferences (see applyLoginItemSetting and
  // registerGlobalShortcuts above).
  return { ...updated, loginItemError: lastLoginItemError, shortcutErrors };
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

function registerIpcHandlers() {
  // window.pomoppi (widget) — see SPEC.md §6
  ipcMain.handle('pomoppi:getState', () => timer.getState());
  ipcMain.handle('pomoppi:getSettings', () => settings.get());
  ipcMain.handle('pomoppi:start', () => { requestStart(); return timer.getState(); });
  ipcMain.handle('pomoppi:pause', () => timer.pause());
  ipcMain.handle('pomoppi:reset', () => timer.reset());
  ipcMain.handle('pomoppi:skip', () => timer.skip());
  ipcMain.handle('pomoppi:dismissRing', () => timer.dismissRing());
  ipcMain.handle('pomoppi:openSettings', () => openSettingsWindow());
  ipcMain.handle('pomoppi:openTask', () => openTaskWindow('rename'));
  // Widget-driven counterparts to the tray's Keep on top checkbox and
  // Hide/Show item — the widget's own in-app keys go through these.
  ipcMain.handle('pomoppi:toggleAlwaysOnTop', () => {
    const next = !settings.get().alwaysOnTop;
    applySettingsPatch({ alwaysOnTop: next });
    return next;
  });
  ipcMain.handle('pomoppi:hideWidget', () => {
    if (widgetWindow && !widgetWindow.isDestroyed()) widgetWindow.hide();
  });
  // The renderer answers a snapshot-request (captureSnapshot above) by handing
  // back the SVG text it built; saveSnapshot does the validation and the
  // actual write, since those bytes are the one thing on this page that lands
  // on the user's disk.
  ipcMain.handle('pomoppi:saveSnapshot', (event, svg) => saveSnapshot(svg));

  // Direct-manipulation controls on the widget itself (click-to-adjust focus
  // length and long-break cadence, cycling the friend, dragging). Clamping
  // lives in lib/settings.js so it's unit-tested without requiring 'electron'.
  ipcMain.handle('pomoppi:adjustFocusMinutes', (event, delta) => {
    const next = Settings.clampFocusAdjust(settings.get().focusMinutes, delta);
    return applySettingsPatch({ focusMinutes: next });
  });
  ipcMain.handle('pomoppi:setLongBreakEvery', (event, n) => {
    const next = Settings.clampLongBreakEvery(n);
    return applySettingsPatch({ longBreakEvery: next });
  });
  // The clock's direct-edit mode (click minutes/seconds, type, Enter). Goes
  // through the same applySettingsPatch -> broadcastSettings path as every
  // other setting, so a widget sitting idle picks up the new length right
  // away, same as adjustFocusMinutes above.
  ipcMain.handle('pomoppi:setFocusDuration', (event, totalSeconds) => {
    const seconds = Settings.clampFocusDurationSeconds(totalSeconds);
    return applySettingsPatch({ focusMinutes: seconds / 60 });
  });
  // Not a persisted setting, so it bypasses applySettingsPatch entirely: Po's
  // widget can no longer use -webkit-app-region: drag (too much of the
  // surface is now clickable), so it drags itself by replaying mouse deltas
  // through this on every move.
  ipcMain.handle('pomoppi:moveBy', (event, dx, dy) => {
    if (!widgetWindow || widgetWindow.isDestroyed()) return null;
    const [x, y] = widgetWindow.getPosition();
    const next = { x: Math.round(x + (Number(dx) || 0)), y: Math.round(y + (Number(dy) || 0)) };
    widgetWindow.setPosition(next.x, next.y);
    return next;
  });

  // window.pomoppiSettings (settings + task windows)
  // loginItemError (see applyLoginItemSetting) and shortcutErrors (see
  // registerGlobalShortcuts) ride along on every one of these so the settings
  // window can show a standing failure even when the user hasn't just touched
  // the toggle, or binding, themselves.
  ipcMain.handle('pomoppiSettings:get', () => ({ ...settings.get(), loginItemError: lastLoginItemError, shortcutErrors }));
  ipcMain.handle('pomoppiSettings:set', (event, patch) => applySettingsPatch(patch));
  ipcMain.handle('pomoppiSettings:reset', () => {
    const updated = settings.reset();
    applySettingsSideEffects(updated);
    broadcastSettings();
    broadcastState();
    return { ...updated, loginItemError: lastLoginItemError, shortcutErrors };
  });
  ipcMain.handle('pomoppiSettings:pickVault', async (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    const result = await dialog.showOpenDialog(win, { properties: ['openDirectory'] });
    if (result.canceled || !result.filePaths.length) return null;
    return result.filePaths[0];
  });
  ipcMain.handle('pomoppiSettings:testLog', () => obsidian.test());
  ipcMain.handle('pomoppiSettings:close', (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (win) win.close();
  });
  ipcMain.handle('pomoppiSettings:getTask', () => timer.getTask());
  ipcMain.handle('pomoppiSettings:setTask', (event, text) => {
    timer.setTask(text);
    if (pendingTaskIntent === 'start') timer.start();
    closeTaskWindow();
  });
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

function wireTimerEvents() {
  timer.on('change', broadcastState);
  timer.on('tick', broadcastState);
  timer.on('phaseComplete', (entry) => {
    obsidian.logSession(entry).then((result) => {
      lastLogError = result && result.ok === false ? result.error : null;
      broadcastState();
    });
    if (settings.get().raiseOnEnd) raiseWidget();
  });
}

function init() {
  if (process.platform === 'darwin' && app.dock) app.dock.hide();

  settings = new Settings(app.getPath('userData'));
  timer = new Timer({ settingsGetter: () => settings.get(), now: Date.now });
  obsidian = new ObsidianLogger(() => settings.get());
  // Re-assert the persisted login-item preference on every launch — nothing
  // else re-applies it, so without this it would only take effect the next
  // time someone happened to touch the settings form. It also re-points the
  // LaunchAgent if Pomoppi.app has since been moved or rebuilt elsewhere.
  clearStaleElectronLoginItem();
  applyLoginItemSetting(settings.get().launchAtLogin);

  wireTimerEvents();
  registerIpcHandlers();
  createWidgetWindow();
  createTray();
  registerGlobalShortcuts();

  wireDiagnostics();

  setInterval(() => timer.tick(), TICK_MS);
}

// TEMPORARY passive diagnostic. Enabled only while ~/.pomoppi-diag exists, so
// it works however the app was launched (shortcut included). Records activation
// and tray events; never calls focus itself, so it cannot perturb what it
// measures. Remove this block and the sentinel when the investigation is done.
const DIAG_ON = (() => {
  try { return require('fs').existsSync(require('os').homedir() + '/.pomoppi-diag'); }
  catch (_) { return false; }
})();
const DIAG_LOG = require('os').homedir() + '/.pomoppi-diag.log';
function diag(msg) {
  if (!DIAG_ON) return;
  const line = `${new Date().toISOString().slice(11, 23)} ${msg}\n`;
  try { require('fs').appendFileSync(DIAG_LOG, line); } catch (_) { /* best effort */ }
}
// Reports the settings window as well as the widget. Watching only the widget
// is what made an earlier pass conclude the tray menu "was not observed to
// deactivate the app": the deactivation was real, it was just the *settings*
// window that had focus and lost it.
function diagState(tag) {
  if (!DIAG_ON) return;
  const w = widgetWindow && !widgetWindow.isDestroyed() ? widgetWindow : null;
  const st = settingsWindow && !settingsWindow.isDestroyed() ? settingsWindow : null;
  diag(`${tag} | widget: focused=${w && w.isFocused()} visible=${w && w.isVisible()} onTop=${w && w.isAlwaysOnTop()}`
     + ` | settings: ${st ? `focused=${st.isFocused()} visible=${st.isVisible()}` : 'closed'}`);
}
function wireDiagnostics() {
  if (!DIAG_ON) return;
  diag('=== app start ===');
  app.on('did-become-active', () => diag('app BECAME active'));
  app.on('did-resign-active', () => diag('app RESIGNED active'));
  if (widgetWindow) {
    widgetWindow.on('focus', () => diag('  window focus'));
    widgetWindow.on('blur', () => diag('  window blur'));
    widgetWindow.on('show', () => diag('  window show'));
    widgetWindow.on('hide', () => diag('  window hide'));
  }
}

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  // Launching Pomoppi again means "put it in front of me", which is exactly
  // what every other raise means, so it shares the one implementation.
  app.on('second-instance', raiseWidget);
  // Pomoppi is a menu-bar widget, not a document app — never quit just because
  // every window closed; only the tray's Quit item should end the process.
  app.on('window-all-closed', () => {});
  // globalShortcut is process-wide, not window-scoped — it outlives every
  // BrowserWindow closing, so it has to be released explicitly or the
  // bindings would keep the keys reserved after Pomoppi itself is gone.
  app.on('will-quit', () => globalShortcut.unregisterAll());
  app.whenReady().then(init);
}
