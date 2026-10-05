// DiaryHistory.swift — the model behind the Diary's history viewer
// (SPEC.md §8b), shared by both platforms' tables: one row per pomodoro,
// sorting, title search and totals. Pure value logic, no UI. The pomodoros
// are the ones DiaryExporter shows, but each row also carries every raw log
// entry (the sub-minute skipped focuses too), so any of them can be deleted
// on its own.
import Foundation

public enum DiaryHistory {

    public struct Item: Equatable {
        public let entry: SessionLogEntry
        // A focus the diary leaves out (stopped early under a minute): it
        // counts in none of the row's figures.
        public let isHiddenFromDiary: Bool
    }

    public struct Row: Equatable {
        public let id: Date           // the pomodoro's start (pomodoroStart)
        public let start: Date
        public let end: Date
        public let title: String
        public let focusCount: Int    // focus sessions the diary shows
        public let focusSeconds: Int
        public let breakSeconds: Int
        public let stoppedEarlyCount: Int
        public let entries: [Item]    // every raw entry, in time order

        // `current` is the timer's pomodoroStartedAt, nil when none runs.
        public func isInProgress(current: Date?) -> Bool {
            guard let current else { return false }
            return pomodoroKey(current) == pomodoroKey(id)
        }
    }

    public enum SortColumn: CaseIterable {
        case start, title, focusCount, focusSeconds, breakSeconds
    }

    public struct Totals: Equatable {
        public let pomodoroCount: Int
        public let focusSeconds: Int
    }

    // Default order: newest first.
    public static func rows(_ sessions: [SessionLogEntry], calendar: Calendar = .current) -> [Row] {
        var raw: [Int64: [SessionLogEntry]] = [:]
        for entry in sessions {
            guard let start = entry.pomodoroStart else { continue }
            raw[pomodoroKey(start), default: []].append(entry)
        }
        let rows = DiaryExporter.pomodoros(sessions, calendar: calendar).map { pomodoro -> Row in
            let all = (raw[pomodoroKey(pomodoro.start)] ?? []).sorted { $0.startTime < $1.startTime }
            return Row(
                id: pomodoro.start, start: pomodoro.start,
                end: all.map(\.endTime).max() ?? pomodoro.start,
                title: pomodoro.title, focusCount: pomodoro.sessions,
                focusSeconds: pomodoro.focusSeconds, breakSeconds: pomodoro.breakSeconds,
                stoppedEarlyCount: pomodoro.stoppedEarly,
                entries: all.map { Item(entry: $0, isHiddenFromDiary: !DiaryExporter.isShown($0)) })
        }
        return sorted(rows, by: .start, ascending: false)
    }

    // Untitled rows stay last in either direction; ties fall back to the
    // newest start first.
    public static func sorted(_ rows: [Row], by column: SortColumn, ascending: Bool, locale: Locale = .current) -> [Row] {
        rows.sorted { a, b in
            let order: ComparisonResult
            switch column {
            case .start: order = compare(a.start, b.start)
            case .title:
                if a.title.isEmpty != b.title.isEmpty { return !a.title.isEmpty }
                order = a.title.isEmpty ? .orderedSame
                    : a.title.compare(b.title, options: [.caseInsensitive], range: nil, locale: locale)
            case .focusCount: order = compare(a.focusCount, b.focusCount)
            case .focusSeconds: order = compare(a.focusSeconds, b.focusSeconds)
            case .breakSeconds: order = compare(a.breakSeconds, b.breakSeconds)
            }
            if order == .orderedSame { return a.start > b.start }
            return (order == .orderedAscending) == ascending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    // Case- and diacritic-insensitive substring match on the title; a blank
    // query keeps everything.
    public static func filtered(_ rows: [Row], query: String) -> [Row] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return rows }
        return rows.filter { fold($0.title).contains(needle) }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func totals(_ rows: [Row]) -> Totals {
        Totals(pomodoroCount: rows.count, focusSeconds: rows.reduce(0) { $0 + $1.focusSeconds })
    }
}
