import Combine
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
    let obsidianLogger: ObsidianLogger

    init(settingsStore: SettingsStore, obsidianLogger: ObsidianLogger) {
        self.settingsStore = settingsStore
        self.obsidianLogger = obsidianLogger
        self.settings = settingsStore.get()
    }

    func update(_ mutate: (inout PomoppiSettings) -> Void) {
        settings = settingsStore.update(mutate)
    }
}
