import AppKit
import PomoppiCore
import PomoppiStrings

// The one place "start" actually happens for a fresh (idle) session, used
// by the widget's play button, the tray menu, and the startPause global
// shortcut alike, so the title prompt only has to be wired once. It appears
// only when recording sessions and askForTaskName are both on, since the
// title only ever ends up in the log (SPEC.md §5). The title is optional;
// Cancel doesn't start the timer. Under the field it offers the most recent
// titles from the log (DiaryExporter.recentTitles); clicking one fills the
// field, nothing more.
enum StartCoordinator {
    // Set once by AppDelegate: the three call sites (widget, tray, shortcut)
    // all go through requestStart, so the log is wired here rather than
    // threaded through each of them.
    static var sessionLogger: SessionLogger?

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
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true

        // Kept alive until runModal returns: NSButton's target is weak.
        let picker = TitlePicker { [weak field, weak alert] title in
            field?.stringValue = title
            alert?.window.makeFirstResponder(field)
        }
        let titles = DiaryExporter.recentTitles(sessionLogger?.allSessionsSync() ?? [])
        if titles.isEmpty {
            alert.accessoryView = field
        } else {
            let caption = NSTextField(labelWithString: L.t("prompt.task.recent"))
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [field, caption] + titles.map { picker.button(for: $0) })
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            stack.setCustomSpacing(10, after: field)
            stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
            alert.accessoryView = stack
        }
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        withExtendedLifetime(picker) {}
        guard response == .alertFirstButtonReturn else { return .cancelled }
        return .started(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// One link-style button per recent title; a click hands the title back.
private final class TitlePicker: NSObject {
    private let onPick: (String) -> Void

    init(onPick: @escaping (String) -> Void) { self.onPick = onPick }

    func button(for title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(pick(_:)))
        button.isBordered = false
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        return button
    }

    @objc private func pick(_ sender: NSButton) { onPick(sender.title) }
}
