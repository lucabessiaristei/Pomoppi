// main.swift — Phase W3 part 2: real wiring, replacing the Phase W1
// skeleton. Mirrors AppDelegate.applicationDidFinishLaunching's construction
// order for exactly what exists on this platform so far: SettingsStore ->
// PomodoroTimer -> WidgetWindow -> settingsStore.onChange -> show/hide based
// on startHidden -> the message loop. No tray, no global hotkeys, no
// settings window, no Obsidian logger, no login item yet — those are later
// phases (see WINDOWS_PORT_PLAN.md).
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

// Only the window-level properties WidgetWindow applies once rather than
// re-reading every frame (always-on-top, size-on-scale-change) need this —
// everything else it draws already re-reads settings on every tick.
settingsStore.onChange = { settings in
    widgetWindow.applyExternalSettingsChange(settings)
}

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
