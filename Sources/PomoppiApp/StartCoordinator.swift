import AppKit
import PomoppiCore
import PomoppiStrings

// The one place "start" actually happens for a fresh (idle) session, used
// by the widget's play button, the tray menu, and the startPause global
// shortcut alike, so the title prompt only has to be wired once. It appears
// only when recording sessions and askForTaskName are both on, since the
// title only ever ends up in the log (SPEC.md §5). The title is optional;
// Cancel doesn't start the timer.
enum StartCoordinator {
    static func requestStart(timer: PomodoroTimer, settingsStore: SettingsStore) {
        let state = timer.getState()
        guard state.phase == .idle, timer.getTask().isEmpty else {
            timer.start()
            return
        }

        let settings = settingsStore.get()
        guard settings.loggingEnabled, settings.askForTaskName else {
            timer.start()
            return
        }

        if case .started(let task) = promptForTaskName() {
            if !task.isEmpty { timer.setTask(task) }
            timer.start()
        }
    }

    private enum PromptResult {
        case started(String)
        case cancelled
    }

    private static func promptForTaskName() -> PromptResult {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.t("prompt.task.title")
        alert.informativeText = L.t("prompt.task.hint.optional")
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: L.t("common.start"))
        alert.addButton(withTitle: L.t("common.cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L.t("prompt.task.placeholder")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
        return .started(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
