// StartCoordinator.swift — the one place "start" actually happens for a
// fresh (idle) session on Windows, a deliberate duplicate of macOS's
// Sources/PomoppiApp/StartCoordinator.swift (Sources/PomoppiApp/ is
// off-limits for this port, CLAUDE.md's invariant). Same gate as macOS
// (SPEC.md §5): the title prompt appears only when recording sessions and
// askForTaskName are both on, since the title only ever ends up in the
// log. The title is optional; Cancel doesn't start the timer.
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
        guard settings.loggingEnabled, settings.askForTaskName else {
            return timer.start()
        }

        // WM_HOTKEY is still dispatched by TaskPromptDialog's own nested
        // message loop even while the widget (this function's owner) is
        // disabled for the prompt's duration, so the startPause hotkey
        // pressed twice fast re-enters this function while the first
        // prompt is still up. Re-focus it instead of stacking a second one
        // — no timer/task state changes on this call, since nothing about
        // the still-open first prompt has resolved yet.
        guard !TaskPromptDialog.isShowing else {
            TaskPromptDialog.refocus()
            return state
        }

        let darkMode = WindowsTheme.resolveDarkMode(colorScheme: settings.colorScheme)
        switch TaskPromptDialog.run(owner: owner, darkMode: darkMode) {
        case .started(let task):
            if !task.isEmpty { timer.setTask(task) }
            return timer.start()
        case .cancelled:
            return state
        }
    }
}
