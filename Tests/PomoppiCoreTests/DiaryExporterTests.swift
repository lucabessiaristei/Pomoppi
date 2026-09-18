import XCTest
@testable import PomoppiCore

final class DiaryExporterTests: XCTestCase {
    private func makeEntry(
        phase: String = "focus", task: String = "", day: Int = 19, month: Int = 9, year: Int = 2026,
        hour: Int = 9, minute: Int = 0, durationMinutes: Int = 25, completed: Bool = true
    ) -> SessionLogEntry {
        var startComponents = DateComponents()
        startComponents.year = year; startComponents.month = month; startComponents.day = day
        startComponents.hour = hour; startComponents.minute = minute
        var endComponents = startComponents
        endComponents.minute = minute + durationMinutes
        let cal = Calendar.current
        return SessionLogEntry(
            phase: phase, task: task, day: day, month: month, year: year,
            startTime: cal.date(from: startComponents)!, endTime: cal.date(from: endComponents)!,
            durationMinutes: durationMinutes, completed: completed)
    }

    func testExportExcludesBreaksAndCountsOnlyCompletedTowardTotal() {
        let sessions = [
            makeEntry(task: "Write the report", hour: 9, minute: 0),
            makeEntry(phase: "shortBreak", hour: 9, minute: 25, durationMinutes: 5),
            makeEntry(task: "Fix the bug", hour: 9, minute: 30, durationMinutes: 12, completed: false),
        ]
        let markdown = DiaryExporter.exportMarkdown(sessions: sessions)

        XCTAssertTrue(markdown.contains("Write the report"))
        XCTAssertTrue(markdown.contains("Fix the bug"))
        XCTAssertTrue(markdown.contains("stopped early"))
        XCTAssertFalse(markdown.contains("shortBreak"))
        XCTAssertTrue(markdown.contains("## 2026-09-19"))
        // Only the completed 25m session counts toward the total; the
        // aborted 12m one gets its own line but isn't summed in.
        XCTAssertTrue(markdown.contains("**Total focus: 25m**"))
    }

    func testExportOnEmptyLogSaysSo() {
        let markdown = DiaryExporter.exportMarkdown(sessions: [])
        XCTAssertTrue(markdown.contains("No focus sessions logged yet"))
    }

    func testSyncCreatesADayFileWithHeadingAndEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let written = try DiaryExporter.syncToFolder(dir, newEntries: [makeEntry(task: "First")])
        XCTAssertEqual(written, 1)

        let content = try String(contentsOf: dir.appendingPathComponent("2026-09-19.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("## Pomodoros"))
        XCTAssertTrue(content.contains("First"))
    }

    func testSyncAppendsAfterExistingEntriesWithoutTouchingOtherContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("2026-09-19.md")
        let handWritten = "# Journal\n\nSome notes I wrote by hand.\n\n## Pomodoros\n- 08:00–08:25 (25m) — earlier task\n\n## Later section\nDon't touch this.\n"
        try handWritten.write(to: fileURL, atomically: true, encoding: .utf8)

        try DiaryExporter.syncToFolder(dir, newEntries: [makeEntry(task: "New session", hour: 9, minute: 0)])

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Some notes I wrote by hand."))
        XCTAssertTrue(content.contains("Don't touch this."))
        XCTAssertTrue(content.contains("earlier task"))
        XCTAssertTrue(content.contains("New session"))
        // The new line must land inside the Pomodoros section, before the
        // later, unrelated section — not appended at the very end of the file.
        let pomodorosRange = content.range(of: "## Pomodoros")!
        let laterRange = content.range(of: "## Later section")!
        let newEntryRange = content.range(of: "New session")!
        XCTAssertTrue(pomodorosRange.lowerBound < newEntryRange.lowerBound)
        XCTAssertTrue(newEntryRange.lowerBound < laterRange.lowerBound)
    }

    func testSyncWithNoFocusEntriesWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryExporterTests-\(UUID().uuidString)")
        let written = try DiaryExporter.syncToFolder(dir, newEntries: [makeEntry(phase: "longBreak", durationMinutes: 15)])
        XCTAssertEqual(written, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
