import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import PomoppiCore
import PomoppiStrings

// The Diary's history viewer (SPEC.md §8b): its own resizable window, one
// instance, reopened to the front rather than duplicated. Not part of the
// SwiftUI `Settings` scene, so it's a plain NSWindow hosting SwiftUI; the app
// is accessory, so showing it has to activate the app too.
final class DiaryWindowController {
    private let viewModel: DiaryViewModel
    private var window: NSWindow?

    init(viewModel: DiaryViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        viewModel.reload()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L.t("diary.viewer.windowTitle")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 620, height: 460)
            // By default an NSHostingView resizes its window to the SwiftUI
            // content's ideal size, so the window jumped with every search
            // keystroke; only the minimum comes from SwiftUI, the user owns the rest.
            let hostingView = NSHostingView(rootView: DiaryView(viewModel: viewModel))
            hostingView.sizingOptions = [.minSize]
            window.contentView = hostingView
            window.setFrameAutosaveName("pomoppi.diaryWindow")
            if !window.setFrameUsingName("pomoppi.diaryWindow") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// The rows come from the log through DiaryHistory; sort, search and the two
// delete kinds all go back through it / SessionLogger, so the window holds no
// copy of that logic.
final class DiaryViewModel: ObservableObject {
    enum PendingDelete {
        case pomodoro(DiaryHistory.Row)
        case entry(DiaryHistory.Item)
    }

    @Published private(set) var rows: [DiaryHistory.Row] = []
    @Published var query = ""
    @Published var sortOrder = [KeyPathComparator(\DiaryHistory.Row.start, order: .reverse)]
    @Published var selection: Date?
    @Published var pendingDelete: PendingDelete?
    @Published var exportStatus: String?

    private let sessionLogger: SessionLogger
    private let currentPomodoroStart: () -> Date?
    private let getSettings: () -> PomoppiSettings
    // Set by AppDelegate: refreshes every other view of the log (the Settings
    // Diary tab's count) after a delete.
    var onHistoryChanged: (() -> Void)?

    init(sessionLogger: SessionLogger, currentPomodoroStart: @escaping () -> Date?,
         getSettings: @escaping () -> PomoppiSettings) {
        self.sessionLogger = sessionLogger
        self.currentPomodoroStart = currentPomodoroStart
        self.getSettings = getSettings
    }

    // The friend's resting pose in the current theme colours, the same icon the
    // Appearance picker shows; nil when the id wasn't recorded or is unknown.
    func friendImage(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        let settings = getSettings()
        return PixelPreviews.friendIcon(friendID: id, inkColor: settings.inkColor, paperColor: settings.paperColor)
    }

    var text: DiaryText {
        DiaryText(locale: Locale(identifier: L.current), lookup: { key, args in L.t(key, args: args) })
    }

    func reload() {
        rows = DiaryHistory.rows(sessionLogger.allSessionsSync())
    }

    // Filtered, then ordered by the Table's first sort comparator. Date and
    // Start are two columns over the same instant (Start sorts on `id`).
    var displayed: [DiaryHistory.Row] {
        var column = DiaryHistory.SortColumn.start
        var ascending = false
        if let comparator = sortOrder.first {
            ascending = comparator.order == .forward
            switch comparator.keyPath {
            case \DiaryHistory.Row.title: column = .title
            case \DiaryHistory.Row.focusCount: column = .focusCount
            case \DiaryHistory.Row.focusSeconds: column = .focusSeconds
            case \DiaryHistory.Row.breakSeconds: column = .breakSeconds
            default: column = .start
            }
        }
        return DiaryHistory.sorted(
            DiaryHistory.filtered(rows, query: query), by: column, ascending: ascending,
            locale: Locale(identifier: L.current))
    }

    func isInProgress(_ row: DiaryHistory.Row) -> Bool {
        row.isInProgress(current: currentPomodoroStart())
    }

    func confirmDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        Task {
            switch pending {
            case .pomodoro(let row): await sessionLogger.deletePomodoro(startedAt: row.id)
            case .entry(let item): await sessionLogger.deleteEntry(startTime: item.entry.startTime, phase: item.entry.phase)
            }
            await MainActor.run {
                reload()
                onHistoryChanged?()
            }
        }
    }

    // The complete log, as Settings' Export does, always as .xlsx.
    func exportExcel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pomoppi Diary.\(DiaryFormat.xlsx.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: DiaryFormat.xlsx.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = DiaryExporter.export(sessions: sessionLogger.allSessionsSync(), format: .xlsx, text: text)
        do {
            try data.write(to: url, options: .atomic)
            exportStatus = L.t("diary.export.success", url.lastPathComponent)
        } catch {
            exportStatus = L.t("diary.export.failed")
        }
    }
}

extension DiaryHistory.Row: Identifiable {}

struct DiaryView: View {
    @ObservedObject var viewModel: DiaryViewModel

    var body: some View {
        let displayed = viewModel.displayed
        let totals = DiaryHistory.totals(displayed)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(totalsLine(totals))
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = viewModel.exportStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField(L.t("diary.viewer.search"), text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button(L.t("diary.viewer.exportExcel")) { viewModel.exportExcel() }
                    .disabled(viewModel.rows.isEmpty)
            }
            .padding(12)
            Divider()
            if displayed.isEmpty {
                ContentUnavailableView(
                    viewModel.rows.isEmpty ? L.t("diary.viewer.empty") : L.t("diary.viewer.noMatch"),
                    systemImage: viewModel.rows.isEmpty ? "book.closed" : "magnifyingglass")
            } else {
                VSplitView {
                    // VSplitView doesn't stretch its panes across on first
                    // layout; without maxWidth the table sat at its ideal width.
                    table(displayed)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                    detail(displayed.first { $0.id == viewModel.selection })
                        .frame(maxWidth: .infinity, minHeight: 200, idealHeight: 260, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            confirmTitle, isPresented: Binding(
                get: { viewModel.pendingDelete != nil },
                set: { if !$0 { viewModel.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirmButton, role: .destructive) { viewModel.confirmDelete() }
        } message: {
            Text(L.t("diary.history.eraseConfirm.message"))
        }
    }

    private func totalsLine(_ totals: DiaryHistory.Totals) -> String {
        let count = totals.pomodoroCount
        return (count == 1 ? L.t("diary.pomodoros.one") : L.t("diary.pomodoros.other", count))
            + " · " + L.t("diary.focusTotal", DiaryExporter.duration(totals.focusSeconds, viewModel.text))
    }

    private var confirmTitle: String {
        if case .entry = viewModel.pendingDelete { return L.t("diary.viewer.deleteEntryConfirm.title") }
        return L.t("diary.viewer.deletePomodoroConfirm.title")
    }

    private var confirmButton: String {
        if case .entry = viewModel.pendingDelete { return L.t("diary.viewer.deleteEntry") }
        return L.t("diary.viewer.deletePomodoro")
    }

    private func table(_ rows: [DiaryHistory.Row]) -> some View {
        let locale = Locale(identifier: L.current)
        return Table(rows, selection: $viewModel.selection, sortOrder: $viewModel.sortOrder) {
            TableColumn(L.t("diary.viewer.column.date"), value: \.start) { row in
                Text(row.start.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
            }
            // Same instant as Date; its own key path only so each column
            // shows its own sort indicator.
            TableColumn(L.t("diary.viewer.column.start"), value: \.id) { row in
                Text(row.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
            }
            .width(min: 60, ideal: 70)
            TableColumn(L.t("diary.viewer.column.title"), value: \.title) { row in
                if row.title.isEmpty {
                    Text(L.t("diary.viewer.untitled")).foregroundStyle(.tertiary)
                } else {
                    Text(row.title)
                }
            }
            TableColumn(L.t("diary.viewer.column.sessions"), value: \.focusCount) { row in
                Text("\(row.focusCount)")
            }
            .width(min: 70, ideal: 90)
            TableColumn(L.t("diary.viewer.column.focus"), value: \.focusSeconds) { row in
                Text(DiaryExporter.duration(row.focusSeconds, viewModel.text))
            }
            .width(min: 70, ideal: 90)
            TableColumn(L.t("diary.viewer.column.breaks"), value: \.breakSeconds) { row in
                Text(DiaryExporter.duration(row.breakSeconds, viewModel.text))
            }
            .width(min: 70, ideal: 90)
        }
    }

    @ViewBuilder
    private func detail(_ row: DiaryHistory.Row?) -> some View {
        if let row {
            let inProgress = viewModel.isInProgress(row)
            // The friend stands to the left of the whole detail (header and
            // entries), not squeezed into the header line.
            HStack(alignment: .top, spacing: 12) {
                friendBadge(row.friend)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(row.title.isEmpty ? L.t("diary.viewer.untitled") : row.title)
                            .font(.headline)
                            .foregroundStyle(row.title.isEmpty ? .tertiary : .primary)
                        if inProgress {
                            Text(L.t("diary.viewer.inProgress"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L.t("diary.viewer.deletePomodoro"), role: .destructive) {
                            viewModel.pendingDelete = .pomodoro(row)
                        }
                        .disabled(inProgress)
                    }
                    List(row.entries, id: \.entry.startTime) { item in
                        entryRow(item, inProgress: inProgress)
                    }
                }
            }
            .padding(12)
        } else {
            ContentUnavailableView(L.t("diary.viewer.selectPrompt"), systemImage: "list.bullet.rectangle")
        }
    }

    // Nearest-neighbor so the pixel art stays crisp; a dimmed "?" tile stands
    // in when the friend wasn't recorded (older entries) or no longer exists.
    @ViewBuilder
    private func friendBadge(_ id: String?) -> some View {
        if let image = viewModel.friendImage(id) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help((id ?? "").capitalized)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 72, height: 72)
                .overlay(Text("?").font(.title).foregroundStyle(.tertiary))
                .help(L.t("diary.viewer.friendUnknown"))
        }
    }

    private func entryRow(_ item: DiaryHistory.Item, inProgress: Bool) -> some View {
        let entry = item.entry
        let locale = Locale(identifier: L.current)
        let clock = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        return HStack(spacing: 10) {
            Text(DiaryExporter.phaseName(entry.phase, viewModel.text))
                .frame(width: 90, alignment: .leading)
            Text(entry.focusNumber.map { "#\($0)" } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text("\(entry.startTime.formatted(clock))–\(entry.endTime.formatted(clock))")
            Text(DiaryExporter.duration(entry.seconds, viewModel.text))
                .foregroundStyle(.secondary)
            if !entry.completed {
                Text(L.t("diary.stoppedEarly"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                viewModel.pendingDelete = .entry(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L.t("diary.viewer.deleteEntry"))
            .disabled(inProgress)
        }
        // A focus the diary leaves out (stopped early under a minute).
        .opacity(item.isHiddenFromDiary ? 0.5 : 1)
        .help(item.isHiddenFromDiary ? L.t("diary.viewer.hiddenEntry") : "")
    }
}
