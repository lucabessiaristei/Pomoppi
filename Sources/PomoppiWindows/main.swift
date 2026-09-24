// main.swift — real wiring, replacing the Phase W1 skeleton. Mirrors
// AppDelegate.applicationDidFinishLaunching's construction order: SettingsStore
// -> PomodoroTimer -> SessionLogger -> WidgetWindow -> settingsStore.onChange
// -> show/hide based on startHidden -> the message loop.
import PomoppiCore
import WinSDK

// -- single-instance guard ---------------------------------------------
// A named mutex is the standard Win32 way to detect "am I already
// running" across processes: CreateMutexW either creates a brand-new
// mutex object or, if one by this name already exists (owned by another
// process), opens a handle to that existing one instead — only in the
// latter case does GetLastError() report ERROR_ALREADY_EXISTS right
// after the call returns. Checked first, before anything else here is
// constructed, so a second launch never gets as far as creating a
// second widget window or a second tray icon — a real pre-existing bug
// (launching Pomoppi twice used to give two of each). Deliberately not
// also wired up as Scripts/pomoppi.iss's AppMutex: verified live in the
// VM that Inno's AppMutex check has no silent auto-close path of its own
// (it only ever shows a blocking, manually-answered "please close it"
// message box) — installing over a running instance is handled
// separately, by CloseApplications' own file-lock-based detection
// (RestartManager), which needs no cooperation from this mutex at all.
let singleInstanceMutexName = "PomoppiSingleInstanceMutex"
let singleInstanceMutex = singleInstanceMutexName.withCString(encodedAs: UTF16.self) { namePtr in
    CreateMutexW(nil, false, namePtr)
}
if GetLastError() == ERROR_ALREADY_EXISTS {
    print("Pomoppi (Windows) already running, exiting")
    ExitProcess(0)
}

let settingsStore = SettingsStore(storageDir: storageDir())
let sessionLogger = SessionLogger(getSettings: { settingsStore.get() }, storageDir: storageDir())
let chimePlayer = ChimePlayer()

let timer = PomodoroTimer(settingsGetter: {
    let s = settingsStore.get()
    return TimerSettingsSnapshot(
        focusMinutes: s.focusMinutes, shortBreakMinutes: s.shortBreakMinutes,
        longBreakMinutes: s.longBreakMinutes, longBreakEvery: s.longBreakEvery,
        autoStartBreaks: s.autoStartBreaks, autoStartFocus: s.autoStartFocus,
        ringSeconds: s.ringSeconds)
})
// This is the first phase-completion consumer on Windows at all — macOS's
// equivalent (AppDelegate.swift) has always logged to Obsidian; Windows
// never had any logging wired in until this session log replaced it.
timer.onPhaseComplete = { event in
    Task { await sessionLogger.logSession(event) }
    // SPEC.md §4: the chime plays once, at the moment a phase completes and
    // the ring starts — `completed` is only true on that path
    // (PomodoroTimer.completePhase()), never on a skip/reset that cuts a
    // phase short, so this alone is the right gate; no separate ringing
    // check needed.
    let settings = settingsStore.get()
    if event.completed, settings.soundEnabled {
        chimePlayer.play(chime: settings.chime, focusEnd: event.phase == .focus)
    }
}

let widgetWindow = WidgetWindow(timer: timer, settingsStore: settingsStore)
let trayController = TrayController(window: widgetWindow)
widgetWindow.trayController = trayController

let globalShortcutManager = GlobalShortcutManager(hwnd: widgetWindow.hwnd)
widgetWindow.globalShortcutManager = globalShortcutManager

let updateChecker = AppUpdateChecker(hwnd: widgetWindow.hwnd)
widgetWindow.updateChecker = updateChecker

// -- global shortcuts -------------------------------------------------------

// One handler per Shortcuts action id, mirroring the tray item or in-app key
// each shortcut stands in for — same 6 ids as AppDelegate.shortcutHandlers
// (macOS), "snapshot" excluded (no snapshot feature yet, so its binding is
// simply never registered with the OS). startPause goes through the same
// task-name prompt as the widget's own play button and the tray menu's
// Start item — all three funnel through activateButton("play"), which now
// calls StartCoordinator.requestStart.
let shortcutHandlers: [String: () -> Void] = [
    "toggleWidget": {
        let visible: Bool = IsWindowVisible(widgetWindow.hwnd)
        widgetWindow.setVisible(!visible)
    },
    // activateButton("play") already does exactly this toggle (plus
    // dismissing a ringing alarm first) — reused rather than duplicated.
    "startPause": { widgetWindow.activateButton("play") },
    "skip": { widgetWindow.activateButton("skip") },
    "reset": { widgetWindow.activateButton("reset") },
    "toggleOnTop": { widgetWindow.toggleAlwaysOnTop() },
    "openSettings": { widgetWindow.activateButton("settings") },
]

// Unregisters and rebinds every non-empty shortcut only when the table
// actually changed — same "don't needlessly churn a system-wide resource"
// discipline as AppDelegate.registerGlobalShortcuts on macOS.
var appliedShortcutsKey: String?
func registerGlobalShortcuts() {
    let bindings = settingsStore.get().shortcuts
    let key = Shortcuts.actionIDs.map { "\($0)=\(bindings[$0] ?? "")" }.joined(separator: "|")
    guard key != appliedShortcutsKey else { return }
    appliedShortcutsKey = key

    globalShortcutManager.unregisterAll()
    for id in Shortcuts.actionIDs {
        guard let accel = bindings[id], !accel.isEmpty, let handler = shortcutHandlers[id] else { continue }
        globalShortcutManager.register(id: id, accelerator: accel, handler: handler)
    }
}

// Forces a full re-apply regardless of whether the bindings table actually
// changed — used after the Keys tab's shortcut recorder (SettingsWindow)
// temporarily unregisters every global hotkey mid-capture: without
// invalidating the memoized key first, registerGlobalShortcuts' own
// change-detection would skip re-registering whenever a recording is
// cancelled or ends in no net change, leaving every hotkey unregistered.
func reapplyGlobalShortcuts() {
    appliedShortcutsKey = nil
    registerGlobalShortcuts()
}

widgetWindow.onOpenSettingsRequested = {
    SettingsWindow.show(settingsStore: settingsStore, sessionLogger: sessionLogger, chimePlayer: chimePlayer, globalShortcutManager: globalShortcutManager, updateChecker: updateChecker, reregisterShortcuts: reapplyGlobalShortcuts)
}

// -- login item ---------------------------------------------------------

var appliedLaunchAtLogin: Bool?
func applyLoginItemIfNeeded(_ settings: PomoppiSettings) {
    guard appliedLaunchAtLogin != settings.launchAtLogin else { return }
    appliedLaunchAtLogin = settings.launchAtLogin
    _ = LoginItem.apply(enabled: settings.launchAtLogin)
}

// -- update checking ------------------------------------------------------

var appliedCheckForUpdates: Bool?
func applyUpdateCheckingIfNeeded(_ settings: PomoppiSettings) {
    guard appliedCheckForUpdates != settings.checkForUpdates else { return }
    appliedCheckForUpdates = settings.checkForUpdates
    if settings.checkForUpdates {
        updateChecker.start()
    } else {
        updateChecker.stop()
    }
}

// Only the window-level properties WidgetWindow applies once rather than
// re-reading every frame (always-on-top, size-on-scale-change) need this —
// everything else it draws already re-reads settings on every tick.
settingsStore.onChange = { settings in
    widgetWindow.applyExternalSettingsChange(settings)
    registerGlobalShortcuts()
    applyLoginItemIfNeeded(settings)
    applyUpdateCheckingIfNeeded(settings)
}

registerGlobalShortcuts()
applyLoginItemIfNeeded(settingsStore.get())
applyUpdateCheckingIfNeeded(settingsStore.get())

widgetWindow.setVisible(!settingsStore.get().startHidden)

print("Pomoppi (Windows) widget window created, entering message loop")

// GetMessageW's BOOL return imports as Swift Bool here (audited Windows
// headers), not Int32/WindowsBool — so no "> 0" needed, just `while`.
var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}
print("Pomoppi (Windows) message loop exited")
