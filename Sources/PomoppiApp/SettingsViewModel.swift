import Combine
import Foundation
import PomoppiCore

// Thin ObservableObject bridge between SettingsStore (framework-light, no
// SwiftUI/Combine dependency by design) and the settings window's SwiftUI
// views. Only this view model talks to SettingsStore directly on the
// settings-window side; the widget window has its own separate reaction
// path (SettingsStore.onChange), so there's no risk of the two stepping on
// each other's single onChange subscription.
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings: PomoppiSettings
    private let settingsStore: SettingsStore
    let sessionLogger: SessionLogger
    let chimePlayer: ChimePlayer
    let updateChecker: AppUpdateChecker
    // The folder holding settings.json and sessions.json, for the Pomoppi tab's Data folder button.
    let storageDir: URL
    // Bumped when the log changes behind the Diary tab's back (a phase logged,
    // a delete in the history viewer), so its count and size refresh.
    @Published var historyRevision = 0
    // Wired by AppDelegate: opens the Diary's history viewer window.
    var openDiary: () -> Void = {}
    // Wired by AppDelegate: refreshes everything that shows the log after a Transfer import.
    var onLogImported: () -> Void = {}

    init(
        settingsStore: SettingsStore, sessionLogger: SessionLogger, chimePlayer: ChimePlayer,
        updateChecker: AppUpdateChecker, storageDir: URL
    ) {
        self.settingsStore = settingsStore
        self.sessionLogger = sessionLogger
        self.chimePlayer = chimePlayer
        self.updateChecker = updateChecker
        self.storageDir = storageDir
        self.settings = settingsStore.get()
    }

    func update(_ mutate: (inout PomoppiSettings) -> Void) {
        settings = settingsStore.update(mutate)
    }

    // The Pomoppi tab's "Reset Pomoppi…": erases session history, then
    // resets the settings store to defaults. reset() persists and fires
    // onChange, which AppDelegate already wires to re-apply the widget,
    // shortcuts, login item and update checking live — so this resets the
    // running app, not just what's on disk, with no restart needed.
    func resetToDefaults() {
        sessionLogger.eraseAllSync()
        settings = settingsStore.reset()
    }
}
