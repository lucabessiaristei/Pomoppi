// DiaryExporter.swift — the Diary tab's export/sync logic (SPEC.md §8b),
// shared by both platforms. Reads from SessionLogger's sessions.json and
// writes plain Markdown into per-day `<dateKey>.md` files — either into a
// user-chosen folder (Sync, e.g. an Obsidian vault, though Pomoppi doesn't
// need to know that's what it is — just a folder to drop date-named .md
// files into) or bundled into a single `.zip` (Export), both built from the
// exact same per-day content so the two shapes never drift apart.
//
// Both directions exclude breaks entirely (a diary is "what did I work
// on", not a break-timing log) and include aborted focus sessions, marked
// distinctly rather than dropped — an honest diary includes the sessions
// given up on, not just the finished ones.
//
// Redesigned 2026-09-20: dropped the old exportMarkdown single-file
// snapshot and the diaryLastSyncedCount cursor. Sync is now idempotent —
// every call walks the *whole* session log and, per day, diffs against
// whatever's already on disk by each line's own "HH:MM–HH:MM" clock-range
// key, so a restored backup or a freshly chosen folder simply gets filled
// in rather than skipped or duplicated (see SPEC.md §8's reinstall/upgrade
// paragraph).
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

    private static let heading = "## Pomodoros"

    // The "HH:MM–HH:MM" clock-range key at the front of one of this
    // format's own "- " lines — the identity a day's file is diffed by,
    // not the line's whole text, so editing the task portion of a line by
    // hand afterward is recognized as the same session rather than
    // duplicated on the next sync. Anything that isn't shaped like one of
    // our own lines (a hand-written bullet, a blank line) returns nil and
    // is simply left where it is, never touched.
    private static func timeRangeKey(_ line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        let rest = line.dropFirst(2)
        guard rest.count >= 11 else { return nil }
        let key = String(rest.prefix(11))
        let parts = key.components(separatedBy: "–")
        guard parts.count == 2, isClockString(parts[0]), isClockString(parts[1]) else { return nil }
        return key
    }

    private static func isClockString(_ s: String) -> Bool {
        guard s.count == 5 else { return false }
        let colonIndex = s.index(s.startIndex, offsetBy: 2)
        return s[colonIndex] == ":" && s.allSatisfy { $0.isNumber || $0 == ":" }
    }

    // One day's `## Pomodoros` section, merged with whatever's already
    // there. Pure: takes the day's existing file content (or "" if there
    // is none) and that day's focus sessions, returns the new content and
    // how many lines were actually added — sync calls this with the real
    // file on disk, export calls it with "" per day, so the zip's files
    // are exactly what a fresh sync into an empty folder would write.
    //
    // Existing lines are never rewritten or reordered — only lines whose
    // clock-range key isn't already present get inserted, each right
    // before the first existing entry that starts later (so a session
    // restored from an older backup lands where it chronologically
    // belongs) or right after the last existing entry — never past
    // whatever trailing content follows it (a blank separator, a later
    // unrelated `## ` heading) — if it's the newest one seen so far.
    // Everything outside the section, and every line inside it this
    // function doesn't touch, survives byte-for-byte.
    private static func dayContent(existing: String, entries: [SessionLogEntry]) -> (content: String, addedCount: Int) {
        var lines = existing.isEmpty ? [] : existing.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if !existing.isEmpty, let last = lines.last, last.isEmpty { lines.removeLast() }

        var headingIndex = lines.firstIndex(of: heading)
        if headingIndex == nil {
            if !lines.isEmpty { lines.append("") }
            lines.append(heading)
            headingIndex = lines.count - 1
        }
        guard let headingIndex else { return (existing, 0) }

        // The section runs until the next top-level heading, or EOF —
        // never past a "## " that isn't ours, so other content in the
        // same note (before or after) is left exactly where it was.
        var sectionEnd = lines.count
        for i in (headingIndex + 1)..<lines.count where lines[i].hasPrefix("## ") {
            sectionEnd = i
            break
        }

        func dashKey(_ i: Int) -> String? {
            lines[i].hasPrefix("- ") ? timeRangeKey(lines[i]) : nil
        }
        var existingKeys = Set((headingIndex + 1..<sectionEnd).compactMap(dashKey))

        // Sorted so a run backfilling several missing sessions inserts
        // them in chronological order relative to each other, not just
        // relative to whatever was already on disk.
        let missing = entries
            .map { ($0, "\(clockString($0.startTime))–\(clockString($0.endTime))") }
            .filter { !existingKeys.contains($0.1) }
            .sorted { $0.1 < $1.1 }

        var addedCount = 0
        for (entry, key) in missing {
            guard !existingKeys.contains(key) else { continue }
            let firstLater = (headingIndex + 1..<sectionEnd).first { dashKey($0).map { $0 > key } ?? false }
            let insertIndex: Int
            if let firstLater {
                insertIndex = firstLater
            } else {
                let lastDash = (headingIndex + 1..<sectionEnd).last { dashKey($0) != nil }
                insertIndex = (lastDash ?? headingIndex) + 1
            }
            lines.insert(lineFor(entry), at: insertIndex)
            sectionEnd += 1
            existingKeys.insert(key)
            addedCount += 1
        }

        let content = lines.joined(separator: "\n") + "\n"
        return (content, addedCount)
    }

    // -- Sync: idempotent per-day merge, no cursor -------------------------

    // Every day present in `sessions` (not just newly logged ones) is
    // considered on every call — there's no cursor to advance, so this is
    // safe to call with the *whole* session log every time (SPEC.md §8's
    // reinstall/upgrade paragraph): a session log restored from an older
    // backup, or a diary folder switched to a fresh one, is simply filled
    // in on the next sync rather than silently skipped or duplicated. A
    // day's file is only written if a line was actually added to it —
    // not merely because `dayContent` normalized its line endings or
    // trailing newline, so a file the user hasn't got new sessions for is
    // never rewritten at all.
    // Returns the total number of lines added across every day touched;
    // throws the first write failure hit (folder unmounted, permission
    // lost, etc.) — there's no lingering cursor left to get out of sync.
    @discardableResult
    public static func syncToFolder(_ folderURL: URL, sessions: [SessionLogEntry]) throws -> Int {
        let focus = focusEntries(sessions)
        guard !focus.isEmpty else { return 0 }
        var totalAdded = 0
        for (dateKey, dayEntries) in groupedByDay(focus) {
            let fileURL = folderURL.appendingPathComponent("\(dateKey).md")
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let (content, addedCount) = dayContent(existing: existing, entries: dayEntries)
            guard addedCount > 0 else { continue }
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            totalAdded += addedCount
        }
        return totalAdded
    }

    // -- Export: a .zip of exactly the files a fresh sync would write -----

    // Calls the same `dayContent` sync uses, with "" as the "existing
    // file" for every day — so the zip's per-day files are byte-identical
    // to what syncing into an empty folder would produce, by construction
    // rather than by keeping two formats in sync by hand. Entries sit at
    // the zip root (no wrapper folder).
    public static func exportZip(sessions: [SessionLogEntry]) -> Data {
        let focus = focusEntries(sessions)
        let entries = groupedByDay(focus).map { dateKey, dayEntries in
            ZipWriter.Entry(name: "\(dateKey).md", data: Data(dayContent(existing: "", entries: dayEntries).content.utf8))
        }
        return ZipWriter.zip(entries)
    }
}
