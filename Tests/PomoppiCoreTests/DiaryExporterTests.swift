import XCTest
@testable import PomoppiCore

final class DiaryExporterTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryExporterTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    // -- Sync ---------------------------------------------------------------

    func testSyncCreatesADayFileWithHeadingAndEntry() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let written = try DiaryExporter.syncToFolder(dir, sessions: [makeEntry(task: "First")])
        XCTAssertEqual(written, 1)

        let content = try String(contentsOf: dir.appendingPathComponent("2026-09-19.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("## Pomodoros"))
        XCTAssertTrue(content.contains("First"))
    }

    // Running the exact same sync twice must add nothing the second time,
    // and must leave the file's bytes identical — the whole point of
    // dropping the cursor for an idempotent, content-diffed sync.
    func testSyncIsIdempotentOnASecondRun() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = [
            makeEntry(task: "Write the report", hour: 9, minute: 0),
            makeEntry(task: "Fix the bug", day: 20, hour: 14, minute: 0),
        ]

        let firstRun = try DiaryExporter.syncToFolder(dir, sessions: sessions)
        XCTAssertEqual(firstRun, 2)
        let dayOneAfterFirst = try String(contentsOf: dir.appendingPathComponent("2026-09-19.md"), encoding: .utf8)
        let dayTwoAfterFirst = try String(contentsOf: dir.appendingPathComponent("2026-09-20.md"), encoding: .utf8)

        let secondRun = try DiaryExporter.syncToFolder(dir, sessions: sessions)
        XCTAssertEqual(secondRun, 0)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("2026-09-19.md"), encoding: .utf8), dayOneAfterFirst)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("2026-09-20.md"), encoding: .utf8), dayTwoAfterFirst)
    }

    // Hand-written notes before/after the section, and other unrelated
    // sections, are never touched. An existing line whose task text was
    // hand-edited afterward is recognized by its clock-range key, not its
    // text, so a later sync must not duplicate it.
    func testSyncPreservesHandWrittenContentAndDoesNotDuplicateAnEditedLine() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("2026-09-19.md")
        let handWritten = """
        # Journal

        Some notes I wrote by hand.

        ## Pomodoros
        - 08:00–08:25 (25m) — a task I renamed later

        ## Later section
        Don't touch this.
        """
        try handWritten.write(to: fileURL, atomically: true, encoding: .utf8)

        // Same session as the 08:00–08:25 line above (same clock range),
        // but with the original task text the logger actually recorded —
        // the on-disk edit must win, not get overwritten or duplicated.
        let sessions = [
            makeEntry(task: "original task text", hour: 8, minute: 0),
            makeEntry(task: "New session", hour: 9, minute: 0),
        ]
        let written = try DiaryExporter.syncToFolder(dir, sessions: sessions)
        XCTAssertEqual(written, 1)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Some notes I wrote by hand."))
        XCTAssertTrue(content.contains("Don't touch this."))
        XCTAssertTrue(content.contains("a task I renamed later"))
        XCTAssertFalse(content.contains("original task text"))
        XCTAssertEqual(content.components(separatedBy: "08:00–08:25").count - 1, 1)

        // The new line must land inside the Pomodoros section, before the
        // later, unrelated section.
        let pomodorosRange = content.range(of: "## Pomodoros")!
        let laterRange = content.range(of: "## Later section")!
        let newEntryRange = content.range(of: "New session")!
        XCTAssertTrue(pomodorosRange.lowerBound < newEntryRange.lowerBound)
        XCTAssertTrue(newEntryRange.lowerBound < laterRange.lowerBound)
    }

    // A session older than everything already in the file (e.g. restored
    // from an older backup) is inserted in chronological order, not just
    // appended at the bottom.
    func testSyncInsertsAnOlderSessionBeforeExistingLaterOnes() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try DiaryExporter.syncToFolder(dir, sessions: [makeEntry(task: "Later task", hour: 14, minute: 0)])
        _ = try DiaryExporter.syncToFolder(
            dir, sessions: [makeEntry(task: "Later task", hour: 14, minute: 0), makeEntry(task: "Earlier task", hour: 9, minute: 0)])

        let content = try String(contentsOf: dir.appendingPathComponent("2026-09-19.md"), encoding: .utf8)
        let earlierRange = content.range(of: "Earlier task")!
        let laterRange = content.range(of: "Later task")!
        XCTAssertTrue(earlierRange.lowerBound < laterRange.lowerBound)
    }

    func testSyncWithNoFocusEntriesWritesNothing() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let written = try DiaryExporter.syncToFolder(dir, sessions: [makeEntry(phase: "longBreak", durationMinutes: 15)])
        XCTAssertEqual(written, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-09-19.md").path))
    }

    // -- Export ---------------------------------------------------------------

    func testExportZipContainsOneEntryPerDayMatchingWhatSyncWouldWrite() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessions = [
            makeEntry(task: "Write the report", hour: 9, minute: 0),
            makeEntry(phase: "shortBreak", hour: 9, minute: 25, durationMinutes: 5),
            makeEntry(task: "Fix the bug", day: 20, hour: 14, minute: 0, durationMinutes: 12, completed: false),
        ]

        _ = try DiaryExporter.syncToFolder(dir, sessions: sessions)
        let dayOneSynced = try String(contentsOf: dir.appendingPathComponent("2026-09-19.md"), encoding: .utf8)
        let dayTwoSynced = try String(contentsOf: dir.appendingPathComponent("2026-09-20.md"), encoding: .utf8)

        let zipData = DiaryExporter.exportZip(sessions: sessions)
        let entries = try readZipEntries(zipData)
        XCTAssertEqual(Set(entries.keys), ["2026-09-19.md", "2026-09-20.md"])
        XCTAssertEqual(String(data: entries["2026-09-19.md"]!, encoding: .utf8), dayOneSynced)
        XCTAssertEqual(String(data: entries["2026-09-20.md"]!, encoding: .utf8), dayTwoSynced)
        XCTAssertTrue(dayTwoSynced.contains("stopped early"))
        XCTAssertFalse(dayOneSynced.contains("shortBreak"))
    }

    // Minimal reader for this test's own purposes: stored-only entries,
    // walks the local file headers directly rather than the central
    // directory (both agree for a well-formed archive; ZipWriterTests
    // covers the central directory/EOCD structure itself).
    private func readZipEntries(_ data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var offset = 0
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func u32(_ at: Int) -> Int { u16(at) | (u16(at + 2) << 16) }
        while offset + 4 <= bytes.count, u32(offset) == 0x0403_4b50 {
            let nameLength = u16(offset + 26)
            let extraLength = u16(offset + 28)
            let size = u32(offset + 22)
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            result[name] = Data(bytes[dataStart..<(dataStart + size)])
            offset = dataStart + size
        }
        return result
    }
}
