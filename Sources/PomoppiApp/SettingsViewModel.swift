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
    private let storageDir: URL

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

    // The Window tab's "Reset to Defaults…": wipes settings.json/
    // sessions.json/everything else under storageDir so the app comes back
    // up at defaults next launch — this session keeps running on whatever's
    // already in memory rather than resetting live, same "no state to
    // reconcile mid-run" approach as everything else here. Replaces the
    // installer-side fresh/update toggle by design.
    func resetToDefaults() {
        try? FileManager.default.removeItem(at: storageDir)
    }
}
