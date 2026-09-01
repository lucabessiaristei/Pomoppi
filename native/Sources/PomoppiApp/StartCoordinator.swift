import AppKit
import PomoppiCore

// The one place "start" actually happens for a fresh (idle) session, used
// by the widget's play button, the tray menu, and the startPause global
// shortcut alike, so the task-name prompt only has to be wired once —
// mirrors requestStart() in main.js. The "must ask" gate is stricter here
// than askForTaskName alone: once Obsidian logging is turned on and pointed
// at a vault, asking becomes mandatory regardless of that toggle, because
// without a task name there's no good line to write to the daily note.
enum StartCoordinator {
    static func requestStart(timer: PomodoroTimer, settingsStore: SettingsStore) {
        let state = timer.getState()
        guard state.phase == .idle, timer.getTask().isEmpty else {
            timer.start()
            return
        }

        let settings = settingsStore.get()
        let vaultConfigured = !settings.vaultPath.trimmingCharacters(in: .whitespaces).isEmpty
        let obsidianMandatory = settings.loggingEnabled && vaultConfigured
        guard settings.askForTaskName || obsidianMandatory else {
            timer.start()
            return
        }

        switch promptForTaskName(mandatory: obsidianMandatory) {
        case .started(let task):
            if !task.isEmpty { timer.setTask(task) }
            timer.start()
        case .cancelled:
            // A purely optional prompt still starts on cancel — only the
            // Obsidian-mandated ask actually blocks starting the timer.
            if !obsidianMandatory { timer.start() }
        }
    }

    private enum PromptResult {
        case started(String)
        case cancelled
    }

    private static func promptForTaskName(mandatory: Bool) -> PromptResult {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "What are you working on?"
        alert.informativeText = mandatory
            ? "Obsidian logging is on, so this session needs a task name to log a useful line."
            : "Optional — leave blank to skip."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Task or project name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
        return .started(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
