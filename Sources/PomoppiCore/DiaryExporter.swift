// DiaryExporter.swift — the Diary tab's two outputs (SPEC.md §8b), shared
// by both platforms. Both read SessionLogger's sessions.json and group it
// into pomodoros; they then write different things:
//
// - Export: the complete log as one file (.md / .txt / .odt / .json), every
//   focus and break listed under its pomodoro and day.
// - Sync: one summarized Markdown file per day under <folder>/YYYY/MM/,
//   one short block per pomodoro. Pomoppi owns these files: each day the
//   log covers is regenerated and written only if it changed. Nothing is
//   ever deleted, so the old flat <folder>/YYYY-MM-DD.md files survive.
//
// Text is localized, but PomoppiCore can't import PomoppiStrings, so the
// shell hands in a DiaryText (lookup + locale).
import Foundation

public struct DiaryText {
    public let locale: Locale
    let lookup: (_ key: String, _ args: [String]) -> String

    public init(locale: Locale, lookup: @escaping (_ key: String, _ args: [String]) -> String) {
        self.locale = locale
        self.lookup = lookup
    }

    func t(_ key: String, _ args: CustomStringConvertible...) -> String {
        lookup(key, args.map(\.description))
    }
}

public enum DiaryFormat: String, CaseIterable {
    case markdown = "md"
    case text = "txt"
    case odt
    case json

    public var fileExtension: String { rawValue }
}

public enum DiaryExporter {

    public struct Pomodoro: Equatable {
        public let start: Date
        public let title: String
        public let entries: [SessionLogEntry]

        var focus: [SessionLogEntry] { entries.filter { $0.phase == "focus" } }
        public var sessions: Int { focus.count }
        public var stoppedEarly: Int { focus.filter { !$0.completed }.count }
        public var focusSeconds: Int { focus.reduce(0) { $0 + $1.seconds } }
        public var breakSeconds: Int { entries.filter { $0.phase != "focus" }.reduce(0) { $0 + $1.seconds } }
    }

    // -- grouping -----------------------------------------------------------

    static func isShown(_ entry: SessionLogEntry) -> Bool {
        entry.phase != "focus" || entry.isRealFocus
    }

    // The log in pomodoros, oldest first, grouped by each entry's
    // pomodoroStart. Entries written before that field existed have none and
    // are left out (no guessing which pomodoro they belonged to); they stay
    // in the raw JSON export. Pomodoros with no focus left to show are
    // dropped.
    public static func pomodoros(_ sessions: [SessionLogEntry], calendar: Calendar = .current) -> [Pomodoro] {
        var groups: [[SessionLogEntry]] = []
        var index: [Int64: Int] = [:]
        for entry in sessions {
            guard let start = entry.pomodoroStart else { continue }
            let key = pomodoroKey(start)
            if let i = index[key] {
                groups[i].append(entry)
            } else {
                index[key] = groups.count
                groups.append([entry])
            }
        }

        return groups.compactMap { group -> Pomodoro? in
            let shown = group.filter(isShown)
            guard shown.contains(where: { $0.phase == "focus" }), let start = group.first?.pomodoroStart else { return nil }
            let title = group.last(where: { !$0.task.isEmpty })?.task ?? ""
            return Pomodoro(start: start, title: title, entries: shown)
        }
        .sorted { $0.start < $1.start }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> (year: Int, month: Int, day: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func byDay(_ pomodoros: [Pomodoro], calendar: Calendar) -> [(date: Date, pomodoros: [Pomodoro])] {
        var order: [String] = []
        var groups: [String: [Pomodoro]] = [:]
        for pomodoro in pomodoros {
            let d = dayKey(pomodoro.start, calendar: calendar)
            let key = "\(d.year)-\(d.month)-\(d.day)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(pomodoro)
        }
        return order.compactMap { key in
            guard let list = groups[key], let first = list.first else { return nil }
            return (date: first.start, pomodoros: list)
        }
    }

    // -- formatting -----------------------------------------------------------

    static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
    }

    // "1h 32m", "25m", "<1m": never "0m".
    static func duration(_ seconds: Int, _ text: DiaryText) -> String {
        let minutes = seconds / 60
        if minutes < 1 { return text.t("diary.duration.lessThanMinute") }
        if minutes < 60 { return text.t("diary.duration.minutes", minutes) }
        return text.t("diary.duration.hoursMinutes", minutes / 60, minutes % 60)
    }

    static func heading(_ pomodoro: Pomodoro, calendar: Calendar) -> String {
        let time = clock(pomodoro.start, calendar: calendar)
        return pomodoro.title.isEmpty ? time : "\(time) · \(pomodoro.title)"
    }

    static func sessionsLine(_ pomodoro: Pomodoro, _ text: DiaryText) -> String {
        let count = pomodoro.sessions
        var line = count == 1 ? text.t("diary.sessions.one") : text.t("diary.sessions.other", count)
        if pomodoro.stoppedEarly > 0 {
            line += " · " + text.t("diary.stoppedEarlyCount", pomodoro.stoppedEarly)
        }
        return line
    }

    static func totalsLine(_ pomodoro: Pomodoro, _ text: DiaryText) -> String {
        text.t("diary.focusTotal", duration(pomodoro.focusSeconds, text))
            + " · " + text.t("diary.breaksTotal", duration(pomodoro.breakSeconds, text))
    }

    static func phaseName(_ phase: String, _ text: DiaryText) -> String {
        switch phase {
        case "focus": return text.t("tray.phase.focus")
        case "shortBreak": return text.t("tray.phase.shortBreak")
        case "longBreak": return text.t("tray.phase.longBreak")
        default: return phase
        }
    }

    static func entryLine(_ entry: SessionLogEntry, _ text: DiaryText, calendar: Calendar) -> String {
        var line = "\(clock(entry.startTime, calendar: calendar))–\(clock(entry.endTime, calendar: calendar))"
            + " · \(phaseName(entry.phase, text)) · \(duration(entry.seconds, text))"
        if !entry.completed { line += " · " + text.t("diary.stoppedEarly") }
        return line
    }

    static func dayTitle(_ date: Date, _ text: DiaryText, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = text.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // -- Sync -------------------------------------------------------------------

    // One day's file: a block per pomodoro. The two summary lines are
    // separate paragraphs so a renderer that ignores single line breaks
    // doesn't run them together.
    public static func dayFile(_ pomodoros: [Pomodoro], text: DiaryText, calendar: Calendar = .current) -> String {
        pomodoros.map { pomodoro in
            "## \(heading(pomodoro, calendar: calendar))\n\n\(sessionsLine(pomodoro, text))\n\n\(totalsLine(pomodoro, text))\n"
        }.joined(separator: "\n")
    }

    // Every day the log covers, as the relative path Sync writes it to
    // ("YYYY/MM/YYYY-MM-DD.md") and its content. Shared by Sync and the
    // archive export, so the two can't drift apart.
    static func dayFiles(_ sessions: [SessionLogEntry], text: DiaryText, calendar: Calendar) -> [(path: String, content: String)] {
        byDay(pomodoros(sessions, calendar: calendar), calendar: calendar).map { day in
            let d = dayKey(day.date, calendar: calendar)
            let path = "\(d.year)/\(pad2(d.month))/\(d.year)-\(pad2(d.month))-\(pad2(d.day)).md"
            return (path: path, content: dayFile(day.pomodoros, text: text, calendar: calendar))
        }
    }

    // Regenerates every day the log covers into <folder>/YYYY/MM/YYYY-MM-DD.md,
    // writing only files whose content changed. Returns how many were
    // written; throws the first write failure.
    @discardableResult
    public static func syncToFolder(_ folderURL: URL, sessions: [SessionLogEntry], text: DiaryText, calendar: Calendar = .current) throws -> Int {
        var written = 0
        for file in dayFiles(sessions, text: text, calendar: calendar) {
            let fileURL = file.path.split(separator: "/").reduce(folderURL) { $0.appendingPathComponent(String($1)) }
            if (try? String(contentsOf: fileURL, encoding: .utf8)) == file.content { continue }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
            written += 1
        }
        return written
    }

    // The Diary Archive: the same YYYY/MM/ day files Sync writes, as one
    // .zip (SPEC.md §8b).
    public static func exportArchive(sessions: [SessionLogEntry], text: DiaryText, now: Date = Date(), calendar: Calendar = .current) -> Data {
        ZipWriter.zip(dayFiles(sessions, text: text, calendar: calendar).map {
            ZipWriter.Entry(name: $0.path, data: Data($0.content.utf8))
        }, date: now)
    }

    // -- Export -----------------------------------------------------------------

    public static func export(
        sessions: [SessionLogEntry], format: DiaryFormat, text: DiaryText,
        now: Date = Date(), calendar: Calendar = .current
    ) -> Data {
        switch format {
        case .json: return exportJSON(sessions)
        case .odt: return ODTWriter.document(documentBlocks(sessions, text: text, now: now, calendar: calendar), date: now)
        case .markdown: return Data(markdown(documentBlocks(sessions, text: text, now: now, calendar: calendar)).utf8)
        case .text: return Data(plainText(documentBlocks(sessions, text: text, now: now, calendar: calendar)).utf8)
        }
    }

    static func documentBlocks(_ sessions: [SessionLogEntry], text: DiaryText, now: Date, calendar: Calendar) -> [DocumentBlock] {
        let all = pomodoros(sessions, calendar: calendar)
        let d = dayKey(now, calendar: calendar)
        let stamp = "\(d.year)-\(pad2(d.month))-\(pad2(d.day)) \(clock(now, calendar: calendar))"
        let count = all.count == 1 ? text.t("diary.pomodoros.one") : text.t("diary.pomodoros.other", all.count)

        var blocks: [DocumentBlock] = [
            .title(text.t("diary.export.documentTitle")),
            .paragraph(text.t("diary.export.documentSubtitle", stamp, count)),
        ]
        for (date, dayPomodoros) in byDay(all, calendar: calendar) {
            blocks.append(.heading(dayTitle(date, text, calendar: calendar), level: 1))
            for pomodoro in dayPomodoros {
                blocks.append(.heading(heading(pomodoro, calendar: calendar), level: 2))
                blocks.append(.paragraph(sessionsLine(pomodoro, text) + " · " + totalsLine(pomodoro, text)))
                for entry in pomodoro.entries {
                    blocks.append(.item(entryLine(entry, text, calendar: calendar)))
                }
            }
        }
        return blocks
    }

    // Items are grouped into one list; any other block gets a blank line
    // around it.
    static func markdown(_ blocks: [DocumentBlock]) -> String {
        var out = ""
        var previousWasItem = false
        for block in blocks {
            let isItem: Bool
            let line: String
            switch block {
            case .title(let s): line = "# \(s)"; isItem = false
            case .heading(let s, let level): line = String(repeating: "#", count: level + 1) + " \(s)"; isItem = false
            case .paragraph(let s): line = s; isItem = false
            case .item(let s): line = "- \(s)"; isItem = true
            }
            if !out.isEmpty { out += (isItem && previousWasItem) ? "\n" : "\n\n" }
            out += line
            previousWasItem = isItem
        }
        return out + "\n"
    }

    static func plainText(_ blocks: [DocumentBlock]) -> String {
        var out = ""
        var previousWasItem = false
        for block in blocks {
            let isItem: Bool
            let text: String
            switch block {
            case .title(let s): text = s + "\n" + String(repeating: "=", count: s.count); isItem = false
            case .heading(let s, let level):
                text = level == 1 ? s + "\n" + String(repeating: "-", count: s.count) : s
                isItem = false
            case .paragraph(let s): text = s; isItem = false
            case .item(let s): text = "  " + s; isItem = true
            }
            if !out.isEmpty { out += (isItem && previousWasItem) ? "\n" : "\n\n" }
            out += text
            previousWasItem = isItem
        }
        return out + "\n"
    }

    private struct LogFile: Encodable {
        let sessions: [SessionLogEntry]
    }

    static func exportJSON(_ sessions: [SessionLogEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(LogFile(sessions: sessions))) ?? Data("{\"sessions\":[]}".utf8)
    }
}
