// StartCoordinator.swift — the one place "start" actually happens for a
// fresh (idle) session on Windows, a deliberate duplicate of macOS's
// Sources/PomoppiApp/StartCoordinator.swift (Sources/PomoppiApp/ is
// off-limits for this port, CLAUDE.md's invariant, and this port has
// consistently duplicated small amounts of logic rather than sharing it —
// tray clicks, picker previews, the login item, now this). Same gate, same
// two-strictness-levels logic, TaskPromptDialog's Win32 modal standing in
// for NSAlert. The "must ask" gate is stricter than askForTaskName alone:
// once session logging is on, asking becomes mandatory regardless of that
// toggle, because without a task name there's no good line to log
// (SPEC.md §5).
import PomoppiCore
import WinSDK

enum StartCoordinator {
    // owner is the widget's hwnd — TaskPromptDialog is created owned by it
    // (see that file) and is also who gets disabled for the prompt's
    // duration. Returns the resulting TimerState so WidgetInput's "play"
    // case can assign it the same way a plain timer.start() call already
    // did.
    static func requestStart(timer: PomodoroTimer, settingsStore: SettingsStore, owner: HWND) -> TimerState {
        let state = timer.getState()
        guard state.phase == .idle, timer.getTask().isEmpty else {
            return timer.start()
        }

        let settings = settingsStore.get()
        let loggingMandatory = settings.loggingEnabled
        guard settings.askForTaskName || loggingMandatory else {
            return timer.start()
        }

        switch TaskPromptDialog.run(owner: owner, mandatory: loggingMandatory) {
        case .started(let task):
            if !task.isEmpty { timer.setTask(task) }
            return timer.start()
        case .cancelled:
            // A purely optional prompt still starts on cancel — only the
            // logging-mandated ask actually blocks starting the timer.
            return loggingMandatory ? state : timer.start()
        }
    }
}
