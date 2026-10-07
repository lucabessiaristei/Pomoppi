import XCTest
@testable import PomoppiCore

final class DiaryHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(_ phase: String = "focus", task: String = "", at minute: Int, seconds: Int = 1500, completed: Bool = true, pomodoro: Int) -> SessionLogEntry {
        let start = base.addingTimeInterval(TimeInterval(minute * 60))
        return SessionLogEntry(
            phase: phase, task: task, day: 1, month: 1, year: 2026,
            startTime: start, endTime: start.addingTimeInterval(TimeInterval(seconds)),
            durationMinutes: seconds / 60, completed: completed, durationSeconds: seconds,
            pomodoroStart: base.addingTimeInterval(TimeInterval(pomodoro * 60)))
    }

    // Three pomodoros: "Écrire" (2 focus, 40 min focus), "banana" (1 focus
    // 25 min, 5 min break), untitled (1 focus 10 min stopped early).
    private func sample() -> [SessionLogEntry] {
        [
            entry(task: "Écrire", at: 0, pomodoro: 0),
            entry("shortBreak", at: 25, seconds: 300, pomodoro: 0),
            entry(task: "Écrire", at: 30, seconds: 900, pomodoro: 0),
            entry(task: "banana", at: 100, pomodoro: 100),
            entry("shortBreak", at: 125, seconds: 300, pomodoro: 100),
            entry(at: 200, seconds: 600, completed: false, pomodoro: 200),
        ]
    }

    func testRowsCarryTotalsAndDefaultToNewestFirst() {
        let rows = DiaryHistory.rows(sample())
        XCTAssertEqual(rows.map(\.title), ["", "banana", "Écrire"])
        let ecrire = rows[2]
        XCTAssertEqual(ecrire.focusCount, 2)
        XCTAssertEqual(ecrire.focusSeconds, 2400)
        XCTAssertEqual(ecrire.breakSeconds, 300)
        XCTAssertEqual(ecrire.end, base.addingTimeInterval((30 + 15) * 60))
        XCTAssertEqual(rows[0].stoppedEarlyCount, 1)
    }

    func testRowFriendIsTheLatestEntrysThatHasOne() {
        func withFriend(_ e: SessionLogEntry, _ friend: String?) -> SessionLogEntry {
            SessionLogEntry(
                phase: e.phase, task: e.task, day: e.day, month: e.month, year: e.year,
                startTime: e.startTime, endTime: e.endTime, durationMinutes: e.durationMinutes,
                completed: e.completed, durationSeconds: e.durationSeconds,
                pomodoroStart: e.pomodoroStart, friend: friend)
        }
        let sessions = [
            withFriend(entry(at: 0, pomodoro: 0), "namidappi"),
            withFriend(entry("shortBreak", at: 25, seconds: 300, pomodoro: 0), "utsupon"),
            withFriend(entry("shortBreak", at: 55, seconds: 300, pomodoro: 0), nil),
            entry(at: 100, pomodoro: 100),
        ]
        let rows = DiaryHistory.rows(sessions)
        XCTAssertNil(rows[0].friend)
        XCTAssertEqual(rows[1].friend, "utsupon")
    }

    func testRowsKeepSkippedFocusesAsHiddenRawEntries() {
        var log = sample()
        log.append(entry(at: 40, seconds: 20, completed: false, pomodoro: 0))
        let rows = DiaryHistory.rows(log)
        let ecrire = rows.first { $0.title == "Écrire" }!
        XCTAssertEqual(ecrire.entries.count, 4)
        XCTAssertEqual(ecrire.entries.filter(\.isHiddenFromDiary).count, 1)
        XCTAssertEqual(ecrire.focusCount, 2, "the skipped focus isn't counted")
        XCTAssertEqual(ecrire.entries.map(\.entry.startTime), ecrire.entries.map(\.entry.startTime).sorted())
        // A pomodoro with only skipped focuses is not a row.
        log.append(entry(at: 300, seconds: 10, completed: false, pomodoro: 300))
        XCTAssertEqual(DiaryHistory.rows(log).count, 3)
    }

    func testInProgress() {
        let row = DiaryHistory.rows(sample())[1]
        XCTAssertTrue(row.isInProgress(current: base.addingTimeInterval(100 * 60 + 0.4)))
        XCTAssertFalse(row.isInProgress(current: base))
        XCTAssertFalse(row.isInProgress(current: nil))
    }

    func testSortByTitleIsCaseInsensitiveWithUntitledLastBothWays() {
        let rows = DiaryHistory.rows(sample() + [entry(task: "apple", at: 400, pomodoro: 400)])
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(DiaryHistory.sorted(rows, by: .title, ascending: true, locale: locale).map(\.title),
                       ["apple", "banana", "Écrire", ""])
        XCTAssertEqual(DiaryHistory.sorted(rows, by: .title, ascending: false, locale: locale).map(\.title),
                       ["Écrire", "banana", "apple", ""])
    }

    func testSortByNumbersTiesFallBackToNewestStart() {
        let rows = DiaryHistory.rows(sample())
        XCTAssertEqual(DiaryHistory.sorted(rows, by: .focusSeconds, ascending: true).map(\.title), ["", "banana", "Écrire"])
        XCTAssertEqual(DiaryHistory.sorted(rows, by: .focusCount, ascending: false).map(\.title), ["Écrire", "", "banana"],
                       "1-focus ties: newest first")
        XCTAssertEqual(DiaryHistory.sorted(rows, by: .breakSeconds, ascending: false).map(\.title), ["banana", "Écrire", ""],
                       "300s tie: newest first")
        XCTAssertEqual(DiaryHistory.sorted(rows, by: .start, ascending: true).map(\.title), ["Écrire", "banana", ""])
    }

    func testSearchIgnoresCaseAndDiacriticsAndBlankKeepsAll() {
        let rows = DiaryHistory.rows(sample())
        XCTAssertEqual(DiaryHistory.filtered(rows, query: "ECRIRE").map(\.title), ["Écrire"])
        XCTAssertEqual(DiaryHistory.filtered(rows, query: "nan").map(\.title), ["banana"])
        XCTAssertEqual(DiaryHistory.filtered(rows, query: "  ").count, 3)
        XCTAssertTrue(DiaryHistory.filtered(rows, query: "zzz").isEmpty)
    }

    func testTotalsCoverTheFilteredSet() {
        let rows = DiaryHistory.rows(sample())
        XCTAssertEqual(DiaryHistory.totals(rows), .init(pomodoroCount: 3, focusSeconds: 2400 + 1500 + 600))
        XCTAssertEqual(DiaryHistory.totals(DiaryHistory.filtered(rows, query: "ecr")), .init(pomodoroCount: 1, focusSeconds: 2400))
        XCTAssertEqual(DiaryHistory.totals([]), .init(pomodoroCount: 0, focusSeconds: 0))
    }
}
