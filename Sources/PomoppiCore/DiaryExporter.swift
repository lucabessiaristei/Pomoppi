// DiaryExporter.swift — the Diary tab's export/sync logic (SPEC.md §8b),
// shared by both platforms. Reads from SessionLogger's sessions.json and
// writes plain Markdown — either a one-shot, complete snapshot (Export) or
// an incremental append into per-day notes in a user-chosen folder (Sync,
// e.g. an Obsidian vault, though Pomoppi doesn't need to know that's what
// it is — just a folder to drop date-named .md files into).
//
// Both directions exclude breaks entirely (a diary is "what did I work
// on", not a break-timing log) and include aborted focus sessions, marked
// distinctly rather than dropped — an honest diary includes the sessions
// given up on, not just the finished ones.
import Foundation

public enum DiaryExporter {
    // -- shared formatting ------------------------------------------------

    private static func focusEntries(_ sessions: [SessionLogEntry]) -> [SessionLogEntry] {
        sessions.filter { $0.phase == "focus" }
    }

    private static func pad2(_ n: Int) -> String { String(format: "%02d", n) }

    private static func clockString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
    }

    private static func dateKey(_ entry: SessionLogEntry) -> String {
        "\(entry.year)-\(pad2(entry.month))-\(pad2(entry.day))"
    }

    // "- 09:15–09:40 (25m) — writing spec" for a completed session,
    // "- 09:15–09:27 (12m, stopped early) — writing spec" for an aborted
    // one. Task omitted entirely (no "— ") when empty.
    private static func lineFor(_ entry: SessionLogEntry) -> String {
        let start = clockString(entry.startTime)
        let end = clockString(entry.endTime)
        let durationLabel = entry.completed ? "\(entry.durationMinutes)m" : "\(entry.durationMinutes)m, stopped early"
        let taskPart = entry.task.isEmpty ? "" : " — \(entry.task)"
        return "- \(start)–\(end) (\(durationLabel))\(taskPart)"
    }

    private static func formattedDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
    }

    // Groups by day, preserving the array's own chronological order (it's
    // append-only, never reordered) both within and across days.
    private static func groupedByDay(_ entries: [SessionLogEntry]) -> [(dateKey: String, entries: [SessionLogEntry])] {
        var order: [String] = []
        var groups: [String: [SessionLogEntry]] = [:]
        for entry in entries {
            let key = dateKey(entry)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    // -- Export: a complete, one-shot snapshot ----------------------------

    // Every focus session, oldest first, grouped by day, each day closing
    // with a "Total focus" line counting only completed sessions'
    // duration — an aborted session still gets its own line, just doesn't
    // count toward the total (matches what "how much did I actually
    // focus today" means). Safe to fully recompute every time: this
    // always writes a brand-new file, never edits an existing one.
    public static func exportMarkdown(sessions: [SessionLogEntry]) -> String {
        let focus = focusEntries(sessions)
        guard !focus.isEmpty else {
            return "# Pomoppi Diary\n\nNo focus sessions logged yet.\n"
        }

        var lines = ["# Pomoppi Diary", ""]
        for (dateKey, dayEntries) in groupedByDay(focus) {
            lines.append("## \(dateKey)")
            lines.append(contentsOf: dayEntries.map(lineFor))
            let totalMinutes = dayEntries.filter(\.completed).reduce(0) { $0 + $1.durationMinutes }
            lines.append("")
            lines.append("**Total focus: \(formattedDuration(totalMinutes))**")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // -- Sync: incremental append into per-day notes ----------------------

    private static let heading = "## Pomodoros"

    // One file per day (`<folder>/<dateKey>.md`), each holding a
    // "## Pomodoros" section — mirrors the pre-redesign Obsidian format's
    // own heading convention, since a real vault's daily note may already
    // have other content (a later `## ` section, or a heading of its own)
    // the sync must never touch. Deliberately never recomputes a running
    // total inside an existing file — that needs re-parsing a file the
    // user may have hand-edited between syncs, exactly the fragility the
    // 2026-09-19 redesign moved away from — just appends new "- " lines
    // at the end of the Pomodoros section, creating the section (and the
    // file) if this is the first sync for that day. Returns the number of
    // entries actually written; throws the first write failure hit (e.g.
    // the folder moved, was unmounted, or lost its permission) without
    // partially updating the caller's sync cursor for a day that never
    // actually landed.
    @discardableResult
    public static func syncToFolder(_ folderURL: URL, newEntries: [SessionLogEntry]) throws -> Int {
        let focus = focusEntries(newEntries)
        guard !focus.isEmpty else { return 0 }
        for (dateKey, dayEntries) in groupedByDay(focus) {
            try appendEntries(dayEntries, toFileAt: folderURL.appendingPathComponent("\(dateKey).md"))
        }
        return focus.count
    }

    private static func appendEntries(_ entries: [SessionLogEntry], toFileAt fileURL: URL) throws {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if !existing.isEmpty, let last = lines.last, last.isEmpty { lines.removeLast() }

        var headingIndex = lines.firstIndex(of: heading)
        if headingIndex == nil {
            if !lines.isEmpty { lines.append("") }
            lines.append(heading)
            headingIndex = lines.count - 1
        }
        guard let headingIndex else { return }

        // The section runs until the next top-level heading, or EOF —
        // never past a "## " that isn't ours, so other content in the
        // same note (before or after) is left exactly where it was.
        var sectionEnd = lines.count
        for i in (headingIndex + 1)..<lines.count where lines[i].hasPrefix("## ") {
            sectionEnd = i
            break
        }

        var insertAt = headingIndex
        for i in (headingIndex + 1)..<sectionEnd where lines[i].hasPrefix("- ") {
            insertAt = i
        }

        lines.insert(contentsOf: entries.map(lineFor), at: insertAt + 1)

        let content = lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
