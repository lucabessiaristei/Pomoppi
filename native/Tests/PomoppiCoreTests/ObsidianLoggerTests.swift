import XCTest
@testable import PomoppiCore

final class ObsidianLoggerTests: XCTestCase {
    private func makeEntry(
        phase: Phase = .focus, plannedMs: Double = 25 * 60_000, actualMs: Double = 25 * 60_000,
        task: String = "", completed: Bool = true
    ) -> PhaseCompleteEvent {
        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 1; startComponents.day = 1
        startComponents.hour = 9; startComponents.minute = 0
        var endComponents = startComponents
        endComponents.minute = 25
        let cal = Calendar.current
        let started = cal.date(from: startComponents)!
        let ended = cal.date(from: endComponents)!
        return PhaseCompleteEvent(
            phase: phase, startedAt: started, endedAt: ended,
            plannedMs: plannedMs, actualMs: actualMs, task: task, completed: completed)
    }

    func testBuildEntryLineForACompletedFocusSessionWithATask() {
        let entry = makeEntry(task: "Write the report")
        let line = ObsidianLogger.buildEntryLine(entry)
        XCTAssertEqual(line, "- 09:00–09:25 (25m) — Write the report ✅")
    }

    func testBuildEntryLineForACompletedBreakCarriesNoMark() {
        let entry = makeEntry(phase: .shortBreak, plannedMs: 5 * 60_000, actualMs: 5 * 60_000)
        let line = ObsidianLogger.buildEntryLine(entry)
        XCTAssertEqual(line, "- 09:00–09:25 (5m break)")
    }

    func testBuildEntryLineForAnAbortedFocusUsesActualMsAndXMark() {
        let entry = makeEntry(actualMs: 12 * 60_000, completed: false)
        let line = ObsidianLogger.buildEntryLine(entry)
        XCTAssertEqual(line, "- 09:00–09:25 (12m) ❌")
    }

    func testInsertEntryCreatesTheHeadingAndTotalLineWhenAbsent() {
        let entry = makeEntry()
        let result = ObsidianLogger.insertEntry(content: "", entry: entry, heading: "## Pomodoros")
        XCTAssertEqual(result, "## Pomodoros\n- 09:00–09:25 (25m) ✅\n\n**Total focus: 25m across 1 pomodoros**\n")
    }

    func testInsertEntryAppendsAfterExistingEntriesAndRecomputesTheTotal() {
        let existing = "## Pomodoros\n- 08:00–08:25 (25m) ✅\n\n**Total focus: 25m across 1 pomodoros**\n"
        let entry = makeEntry()
        let result = ObsidianLogger.insertEntry(content: existing, entry: entry, heading: "## Pomodoros")
        XCTAssertEqual(
            result,
            "## Pomodoros\n- 08:00–08:25 (25m) ✅\n- 09:00–09:25 (25m) ✅\n\n**Total focus: 50m across 2 pomodoros**\n")
    }

    func testInsertEntryDoesNotDisturbContentOutsideItsOwnSection() {
        let existing = "# Notes\n\nSome text.\n\n## Pomodoros\n- 08:00–08:25 (25m) ✅\n\n**Total focus: 25m across 1 pomodoros**\n\n## Later Section\nOther content.\n"
        let entry = makeEntry()
        let result = ObsidianLogger.insertEntry(content: existing, entry: entry, heading: "## Pomodoros")
        XCTAssertTrue(result.contains("## Later Section\nOther content.\n"))
        XCTAssertTrue(result.contains("**Total focus: 50m across 2 pomodoros**"))
    }
}
