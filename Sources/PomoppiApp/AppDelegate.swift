import AppKit
import Combine
import Foundation
import PomoppiCore
import PomoppiRender
import PomoppiStrings
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var settingsStore: SettingsStore!
    private var timer: PomodoroTimer!
    private var sessionLogger: SessionLogger!
    private var chimePlayer: ChimePlayer!
    private var widgetWindow: WidgetWindow!
    private var trayController: TrayController!
    private var updateChecker: AppUpdateChecker!

    // Owned here so the SwiftUI Settings scene can reuse one view model
    // instead of constructing a new one every time the scene body runs.
    @Published private(set) var settingsViewModel: SettingsViewModel?

    // Never shown — exists only so `SettingsOpenerView` has a live place in
    // the scene graph to read `\.openSettings` from (see SettingsOpener.swift).
    private var settingsOpenerWindow: NSWindow!
    private let settingsOpenerModel = SettingsOpenerModel()

    private var appliedShortcutsKey: String?
    private var appliedLaunchAtLogin: Bool?
    private var appliedCheckForUpdates: Bool?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Accessory, before any window exists: no Dock icon, and the app
        // never owns the system menu bar even when focused — an accepted
        // trade for a menu-bar-style widget (SPEC.md §9b). WillFinish so
        // SwiftUI's App lifecycle doesn't flash a Dock icon first.
        NSApp.setActivationPolicy(.accessory)
        useRepoIconWhenUnbundled()
    }

    // A `swift run` build is a loose binary with no bundle icon, so alerts
    // (the title prompt, confirmations) would show a generic one. Use the
    // repo's own icon then; a real Pomoppi.app already has it.
    private func useRepoIconWhenUnbundled() {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PomoppiApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent()
        if let icon = NSImage(contentsOf: repoRoot.appendingPathComponent("assets/AppIcon.icns")) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        settingsStore = SettingsStore(storageDir: Self.storageDir())
        L.configure(systemLanguages: Locale.preferredLanguages)
        L.apply(setting: settingsStore.get().language)
        timer = PomodoroTimer(settingsGetter: { [unowned self] in self.timerSettingsSnapshot() })
        sessionLogger = SessionLogger(getSettings: { [unowned self] in self.settingsStore.get() }, storageDir: Self.storageDir())
        Task { [sessionLogger] in
            await sessionLogger?.migrateLegacyLog()
            await sessionLogger?.pruneEmptyPomodoros()
        }
        chimePlayer = ChimePlayer()
        DispatchQueue.main.async { [chimePlayer] in chimePlayer?.prewarm() }
        updateChecker = AppUpdateChecker()
        updateChecker.isSessionActive = { [unowned self] in self.timer.getState().phase != .idle }
        settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore, sessionLogger: sessionLogger, chimePlayer: chimePlayer,
            updateChecker: updateChecker)
        timer.onPhaseComplete = { [unowned self] event in
            Task { await self.sessionLogger.logSession(event) }
            // SPEC.md §4: the chime plays once, at the moment a phase
            // completes and the ring starts — `completed` is only true on
            // that path (completePhase()), never on a skip/reset that cuts
            // a phase short, so this alone is the right gate; no separate
            // ringing check needed.
            let settings = self.settingsStore.get()
            if event.completed, settings.soundEnabled {
                self.chimePlayer.play(chime: settings.chime, focusEnd: event.phase == .focus)
            }
        }
        timer.onPomodoroDiscarded = { [unowned self] start in
            Task { await self.sessionLogger.discardPomodoro(startedAt: start) }
        }

        widgetWindow = WidgetWindow(
            timer: timer, settingsStore: settingsStore,
            onOpenSettingsRequested: { [unowned self] in self.showSettingsWindow() })
        updateChecker.onInstallerRunningChange = { [unowned self] in self.widgetWindow.yieldLevel($0) }

        settingsOpenerWindow = Self.makeSettingsOpenerWindow(model: settingsOpenerModel)

        trayController = TrayController(
            timer: timer, settingsStore: settingsStore, widgetWindow: widgetWindow, updateChecker: updateChecker,
            focusedOwnWindow: { [unowned self] in self.focusedOwnWindow() },
            onOpenSettingsRequested: { [unowned self] in self.showSettingsWindow() },
            onQuitRequested: { NSApp.terminate(nil) })

        // Everything a settings change might need to propagate to, in one
        // place: the widget window's own re-read of settings every frame
        // covers everything it draws, but window-level properties, the OS
        // hotkey table, and the login-item registration are each owned by
        // exactly one thing that applies them once rather than continuously.
        settingsStore.onChange = { [unowned self] settings in
            L.apply(setting: settings.language)
            self.widgetWindow.applyExternalSettingsChange(settings)
            self.registerGlobalShortcuts()
            self.applyLoginItemIfNeeded(settings)
            self.applyUpdateCheckingIfNeeded(settings)
        }

        registerGlobalShortcuts()
        applyLoginItemIfNeeded(settingsStore.get())
        applyUpdateCheckingIfNeeded(settingsStore.get())

        if !settingsStore.get().startHidden {
            widgetWindow.raise()
        }
    }

    // Quit fades the widget out first, then lets termination go on.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let widgetWindow, widgetWindow.isShown else { return .terminateNow }
        widgetWindow.hide { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // globalShortcut is process-wide, not window-scoped — it outlives
        // every window, so it needs its own explicit teardown on quit.
        GlobalShortcutManager.shared.unregisterAll()
    }

    // macOS 14+ dropped support for opening a SwiftUI `Settings` scene via
    // `sendAction(showSettingsWindow:)` from AppKit (it finds a responder
    // and returns true, but no window appears) — routing through
    // `settingsOpenerModel` reaches the scene via the `openSettings`
    // environment action instead (see SettingsOpener.swift).
    func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        settingsOpenerModel.requestOpen()
    }

    // A window that's never ordered onto screen, whose sole purpose is
    // giving `SettingsOpenerView` a spot in the scene graph so its
    // `\.openSettings` environment action is populated.
    private static func makeSettingsOpenerWindow(model: SettingsOpenerModel) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsOpenerView(model: model))
        return window
    }

    private func focusedOwnWindow() -> NSWindow? {
        if widgetWindow.isKeyWindow { return widgetWindow }
        if let settings = NSApp.windows.first(where: { $0 !== widgetWindow && $0.isKeyWindow }) {
            return settings
        }
        return nil
    }

    // -- global shortcuts -----------------------------------------------------

    // One handler per Shortcuts action id, mirroring the tray item or
    // in-app key each shortcut stands in for. "snapshot" has no handler —
    // there's no snapshot feature yet (later phase) — so a binding for it
    // is simply never registered with the OS rather than registered as a
    // no-op, leaving that combo free until the feature exists.
    private lazy var shortcutHandlers: [String: () -> Void] = [
        "toggleWidget": { [unowned self] in
            self.widgetWindow.isShown ? self.widgetWindow.hide() : self.widgetWindow.raise()
        },
        "startPause": { [unowned self] in
            if self.timer.getState().running {
                self.timer.pause()
            } else {
                StartCoordinator.requestStart(timer: self.timer, settingsStore: self.settingsStore)
            }
        },
        "skip": { [unowned self] in self.timer.skip() },
        "reset": { [unowned self] in self.timer.reset() },
        "toggleOnTop": { [unowned self] in self.settingsStore.update { $0.alwaysOnTop.toggle() } },
        "openSettings": { [unowned self] in self.showSettingsWindow() },
    ]

    // Unregisters and rebinds every non-empty shortcut only when the table
    // actually changed — globalShortcut is a system-wide resource, and
    // re-registering seven hotkeys on every settings write that has nothing
    // to do with shortcuts would needlessly churn it (same reasoning as
    // WidgetWindow's idempotent always-on-top setter).
    private func registerGlobalShortcuts() {
        let bindings = settingsStore.get().shortcuts
        let key = Shortcuts.actionIDs.map { "\($0)=\(bindings[$0] ?? "")" }.joined(separator: "|")
        guard key != appliedShortcutsKey else { return }
        appliedShortcutsKey = key

        let manager = GlobalShortcutManager.shared
        manager.unregisterAll()
        for id in Shortcuts.actionIDs {
            guard let accel = bindings[id], !accel.isEmpty, let handler = shortcutHandlers[id] else { continue }
            manager.register(id: id, accelerator: accel, handler: handler)
        }
    }

    // -- login item -------------------------------------------------------

    private func applyLoginItemIfNeeded(_ settings: PomoppiSettings) {
        guard appliedLaunchAtLogin != settings.launchAtLogin else { return }
        appliedLaunchAtLogin = settings.launchAtLogin
        _ = LoginItem.apply(enabled: settings.launchAtLogin)
    }

    // -- update checking --------------------------------------------------

    private func applyUpdateCheckingIfNeeded(_ settings: PomoppiSettings) {
        guard appliedCheckForUpdates != settings.checkForUpdates else { return }
        appliedCheckForUpdates = settings.checkForUpdates
        if settings.checkForUpdates {
            updateChecker.start()
        } else {
            updateChecker.stop()
        }
    }

    // -- settings storage location -------------------------------------------

    // Running from a real, installed .app bundle (has a real bundle
    // identifier): use the shared production path, the same file the
    // Electron app reads and writes, so this build can actually take over
    // day-to-day use with continuity. Running as a loose dev binary
    // (`swift run`/`.build/debug/PomoppiApp`, no bundle identifier): keep
    // settings local to the package instead, so iterating on this doesn't
    // reformat/rewrite a file you rely on day to day, or touch your real
    // Obsidian vault. #filePath is stable at compile time on this machine,
    // so the dev path doesn't depend on the process's working directory.
    private static func storageDir() -> URL {
        if Bundle.main.bundleIdentifier != nil {
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pomoppi")
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PomoppiApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // native
            .appendingPathComponent(".dev-app-support")
    }

    private func timerSettingsSnapshot() -> TimerSettingsSnapshot {
        let s = settingsStore.get()
        return TimerSettingsSnapshot(
            focusMinutes: s.focusMinutes, shortBreakMinutes: s.shortBreakMinutes,
            longBreakMinutes: s.longBreakMinutes, longBreakEvery: s.longBreakEvery,
            autoStartBreaks: s.autoStartBreaks, autoStartFocus: s.autoStartFocus,
            ringSeconds: s.ringSeconds)
    }
}
