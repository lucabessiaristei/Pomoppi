// main.swift — Phase W3 part 2: real wiring, replacing the Phase W1
// skeleton. Mirrors AppDelegate.applicationDidFinishLaunching's construction
// order for exactly what exists on this platform so far: SettingsStore ->
// PomodoroTimer -> WidgetWindow -> settingsStore.onChange -> show/hide based
// on startHidden -> the message loop. No settings window, no Obsidian
// logger yet — those are later phases (see WINDOWS_PORT_PLAN.md).
import PomoppiCore
import WinSDK

let settingsStore = SettingsStore(storageDir: storageDir())

let timer = PomodoroTimer(settingsGetter: {
    let s = settingsStore.get()
    return TimerSettingsSnapshot(
        focusMinutes: s.focusMinutes, shortBreakMinutes: s.shortBreakMinutes,
        longBreakMinutes: s.longBreakMinutes, longBreakEvery: s.longBreakEvery,
        autoStartBreaks: s.autoStartBreaks, autoStartFocus: s.autoStartFocus,
        ringSeconds: s.ringSeconds)
})

let widgetWindow = WidgetWindow(timer: timer, settingsStore: settingsStore)
let trayController = TrayController(window: widgetWindow)
widgetWindow.trayController = trayController

let globalShortcutManager = GlobalShortcutManager(hwnd: widgetWindow.hwnd)
widgetWindow.globalShortcutManager = globalShortcutManager

// -- global shortcuts -------------------------------------------------------

// One handler per Shortcuts action id, mirroring the tray item or in-app key
// each shortcut stands in for — same 6 ids as AppDelegate.shortcutHandlers
// (macOS), "snapshot" excluded (no snapshot feature yet, so its binding is
// simply never registered with the OS). startPause starts directly with no
// task-name prompt, same as the existing play button/tray menu item on
// Windows (StartCoordinator's NSAlert-based prompt is AppKit-only, out of
// scope for this phase).
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
    SettingsWindow.show(settingsStore: settingsStore, globalShortcutManager: globalShortcutManager, reregisterShortcuts: reapplyGlobalShortcuts)
}

// -- login item ---------------------------------------------------------

var appliedLaunchAtLogin: Bool?
func applyLoginItemIfNeeded(_ settings: PomoppiSettings) {
    guard appliedLaunchAtLogin != settings.launchAtLogin else { return }
    appliedLaunchAtLogin = settings.launchAtLogin
    _ = LoginItem.apply(enabled: settings.launchAtLogin)
}

// Only the window-level properties WidgetWindow applies once rather than
// re-reading every frame (always-on-top, size-on-scale-change) need this —
// everything else it draws already re-reads settings on every tick.
settingsStore.onChange = { settings in
    widgetWindow.applyExternalSettingsChange(settings)
    registerGlobalShortcuts()
    applyLoginItemIfNeeded(settings)
}

registerGlobalShortcuts()
applyLoginItemIfNeeded(settingsStore.get())

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
