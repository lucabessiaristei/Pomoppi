import XCTest
import PomoppiStrings
@testable import PomoppiCore

// Rewritten for the 2026-09-24 Diary redesign (SPEC.md §8b): Export and Sync
// are two different outputs built from DiaryExporter.pomodoros() grouping,
// not the old single "## Pomodoros" per-day merge / exportZip. A fixed UTC
// calendar is used everywhere a `calendar:` parameter is accepted, and
// dates are built in it, so these tests don't depend on the machine's own
// time zone.
final class DiaryExporterTests: XCTestCase {
    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private let diaryText = DiaryText(locale: Locale(identifier: "en_US_POSIX"), lookup: { L.t($0, args: $1) })

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiaryExporterTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func date(year: Int = 2026, month: Int = 9, day: Int = 24, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")
        return utcCalendar.date(from: c)!
    }

    private func makeEntry(
        phase: String = "focus", task: String = "", day: Int = 24, month: Int = 9, year: Int = 2026,
        hour: Int = 14, minute: Int = 29, durationMinutes: Int = 25, completed: Bool = true,
        durationSeconds: Int? = nil, pomodoroStart: Date? = nil
    ) -> SessionLogEntry {
        let start = date(year: year, month: month, day: day, hour: hour, minute: minute)
        let seconds = durationSeconds ?? durationMinutes * 60
        let end = start.addingTimeInterval(TimeInterval(seconds))
        return SessionLogEntry(
            phase: phase, task: task, day: day, month: month, year: year,
            startTime: start, endTime: end,
            durationMinutes: durationMinutes, completed: completed,
            durationSeconds: durationSeconds, pomodoroStart: pomodoroStart)
    }

    // -- 11. Grouping into pomodoros -----------------------------------------

    func testGroupingByExplicitPomodoroStartJoinsEntriesRegardlessOfOrder() {
        let startA = date(hour: 9, minute: 0)
        let startB = date(hour: 11, minute: 0)
        let entries = [
            makeEntry(task: "A", hour: 9, minute: 0, pomodoroStart: startA),
            makeEntry(task: "B", hour: 11, minute: 0, pomodoroStart: startB),
            makeEntry(phase: "shortBreak", hour: 9, minute: 25, durationMinutes: 5, pomodoroStart: startA),
        ]
        let pomodoros = DiaryExporter.pomodoros(entries, calendar: utcCalendar)
        XCTAssertEqual(pomodoros.count, 2)
        XCTAssertEqual(pomodoros[0].title, "A")
        XCTAssertEqual(pomodoros[0].entries.count, 2)
        XCTAssertEqual(pomodoros[1].title, "B")
        XCTAssertEqual(pomodoros[1].entries.count, 1)
    }

    // Entries written before pomodoroStart existed have no way to be
    // grouped and are simply left out of pomodoros() (no guessing by gap/
    // day/long-break inference anymore) — they still show up in the raw
    // JSON export, just never in a sync file or an export block.
    func testEntriesWithNoPomodoroStartProduceNoPomodoroButStayInJSONExport() throws {
        let entries = [
            makeEntry(task: "old entry", hour: 9, minute: 0),
            makeEntry(phase: "shortBreak", hour: 9, minute: 25, durationMinutes: 5),
        ]
        XCTAssertTrue(DiaryExporter.pomodoros(entries, calendar: utcCalendar).isEmpty)

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let written = try DiaryExporter.syncToFolder(dir, sessions: entries, text: diaryText, calendar: utcCalendar)
        XCTAssertEqual(written, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-09-24.md").path))

        let markdown = String(
            data: DiaryExporter.export(sessions: entries, format: .markdown, text: diaryText, now: date(hour: 10, minute: 0), calendar: utcCalendar),
            encoding: .utf8)!
        XCTAssertFalse(markdown.contains("old entry"), "no pomodoroStart means no export block either")

        struct DecodedLogFile: Decodable { let sessions: [SessionLogEntry] }
        let jsonData = DiaryExporter.export(sessions: entries, format: .json, text: diaryText, now: date(hour: 10, minute: 0), calendar: utcCalendar)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DecodedLogFile.self, from: jsonData)
        XCTAssertEqual(decoded.sessions.count, 2, "JSON export is the raw, unfiltered log")
    }

    func testSubMinuteStoppedEarlyFocusIsExcludedAndAPomodoroWithNoFocusLeftIsDropped() {
        let pomodoroStart = date(hour: 9, minute: 0)
        let entries = [
            makeEntry(task: "kept", hour: 9, minute: 0, completed: true, pomodoroStart: pomodoroStart),
            makeEntry(task: "too short", hour: 9, minute: 25, completed: false, durationSeconds: 30, pomodoroStart: pomodoroStart),
        ]
        let pomodoros = DiaryExporter.pomodoros(entries, calendar: utcCalendar)
        XCTAssertEqual(pomodoros.count, 1)
        XCTAssertEqual(pomodoros[0].entries.count, 1, "the sub-minute stopped-early focus is excluded from the shown entries")
        XCTAssertEqual(pomodoros[0].sessions, 1)

        let onlyStart = date(hour: 12, minute: 0)
        let onlyAShortStoppedFocus = [
            makeEntry(task: "alone", hour: 12, minute: 0, completed: false, durationSeconds: 45, pomodoroStart: onlyStart),
        ]
        XCTAssertTrue(
            DiaryExporter.pomodoros(onlyAShortStoppedFocus, calendar: utcCalendar).isEmpty,
            "a pomodoro with no focus left to show is dropped entirely")
    }

    // -- 12. dayFile exact output ---------------------------------------------

    func testDayFileExactOutputForAPomodoroWithFourFocusOneStoppedEarly() {
        let entries = [
            makeEntry(task: "task 1", hour: 14, minute: 29, durationMinutes: 25),
            makeEntry(phase: "shortBreak", hour: 14, minute: 54, durationMinutes: 6),
            makeEntry(task: "task 1", hour: 15, minute: 0, durationMinutes: 25),
            makeEntry(phase: "shortBreak", hour: 15, minute: 25, durationMinutes: 6),
            makeEntry(task: "task 1", hour: 15, minute: 31, durationMinutes: 25),
            makeEntry(phase: "shortBreak", hour: 15, minute: 56, durationMinutes: 6),
            makeEntry(task: "task 1", hour: 16, minute: 2, durationMinutes: 17, completed: false),
        ]
        let pomodoro = DiaryExporter.Pomodoro(start: date(hour: 14, minute: 29), title: "task 1", entries: entries)

        let output = DiaryExporter.dayFile([pomodoro], text: diaryText, calendar: utcCalendar)

        XCTAssertEqual(output, "## 14:29 · task 1\n\n4 sessions · 1 stopped early\n\nFocus 1h 32m · Breaks 18m\n")
    }

    func testSessionsLineOmitsStoppedEarlyCountWhenZero() {
        let entries = [
            makeEntry(task: "t", hour: 9, minute: 0),
            makeEntry(task: "t", hour: 9, minute: 30),
        ]
        let pomodoro = DiaryExporter.Pomodoro(start: date(hour: 9, minute: 0), title: "t", entries: entries)
        let output = DiaryExporter.dayFile([pomodoro], text: diaryText, calendar: utcCalendar)
        XCTAssertTrue(output.contains("2 sessions\n\n"))
        XCTAssertFalse(output.contains("stopped early"))
    }

    func testSessionsLineUsesSingularWordingForOneSession() {
        let entries = [makeEntry(task: "t", hour: 9, minute: 0)]
        let pomodoro = DiaryExporter.Pomodoro(start: date(hour: 9, minute: 0), title: "t", entries: entries)
        let output = DiaryExporter.dayFile([pomodoro], text: diaryText, calendar: utcCalendar)
        XCTAssertTrue(output.contains("1 session\n\n"))
        XCTAssertFalse(output.contains("1 sessions"))
    }

    func testDurationBelowAMinuteRendersAsLessThanOneMinuteNeverZero() {
        let entries = [
            makeEntry(task: "t", hour: 9, minute: 0),
            makeEntry(phase: "shortBreak", hour: 9, minute: 25, durationSeconds: 30),
        ]
        let pomodoro = DiaryExporter.Pomodoro(start: date(hour: 9, minute: 0), title: "t", entries: entries)
        let output = DiaryExporter.dayFile([pomodoro], text: diaryText, calendar: utcCalendar)
        XCTAssertTrue(output.contains("Breaks <1m"))
        XCTAssertFalse(output.contains("Breaks 0m"))
    }

    func testHeadingWithNoTitleIsJustTheStartTime() {
        let entries = [makeEntry(task: "", hour: 14, minute: 29)]
        let pomodoro = DiaryExporter.Pomodoro(start: date(hour: 14, minute: 29), title: "", entries: entries)
        let output = DiaryExporter.dayFile([pomodoro], text: diaryText, calendar: utcCalendar)
        XCTAssertTrue(output.hasPrefix("## 14:29\n\n"))
    }

    func testDayFileSeparatesMultiplePomodorosByExactlyOneBlankLine() {
        let p1 = DiaryExporter.Pomodoro(
            start: date(hour: 9, minute: 0), title: "first",
            entries: [makeEntry(task: "first", hour: 9, minute: 0)])
        let p2 = DiaryExporter.Pomodoro(
            start: date(hour: 11, minute: 0), title: "second",
            entries: [makeEntry(task: "second", hour: 11, minute: 0)])

        let output = DiaryExporter.dayFile([p1, p2], text: diaryText, calendar: utcCalendar)

        XCTAssertTrue(output.contains("Breaks <1m\n\n## 11:00 · second"), "exactly one blank line between pomodoros")
        XCTAssertFalse(output.contains("Breaks <1m\n\n\n"), "never more than one blank line")
    }

    // -- 13. syncToFolder -------------------------------------------------------

    func testSyncToFolderWritesNestedYearMonthDayFileIsIdempotentAndLeavesFlatLegacyFileAlone() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flatLegacyFile = dir.appendingPathComponent("2026-09-24.md")
        try "old flat layout, untouched".write(to: flatLegacyFile, atomically: true, encoding: .utf8)

        let sessions = [makeEntry(task: "write spec", hour: 14, minute: 29, pomodoroStart: date(hour: 14, minute: 29))]
        let written = try DiaryExporter.syncToFolder(dir, sessions: sessions, text: diaryText, calendar: utcCalendar)
        XCTAssertEqual(written, 1)

        let nestedFile = dir
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("09", isDirectory: true)
            .appendingPathComponent("2026-09-24.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedFile.path))

        let second = try DiaryExporter.syncToFolder(dir, sessions: sessions, text: diaryText, calendar: utcCalendar)
        XCTAssertEqual(second, 0, "an unchanged day writes nothing on a second run")

        XCTAssertEqual(try String(contentsOf: flatLegacyFile, encoding: .utf8), "old flat layout, untouched")
    }

    // The Diary Archive zips exactly the files Sync writes, at the same paths.
    func testExportArchiveHoldsTheSyncDayFilesAtTheirNestedPaths() throws {
        let sessions = [makeEntry(task: "write spec", hour: 14, minute: 29, pomodoroStart: date(hour: 14, minute: 29))]
        let data = DiaryExporter.exportArchive(sessions: sessions, text: diaryText, calendar: utcCalendar)
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes[0..<4]), [0x50, 0x4b, 0x03, 0x04])
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        XCTAssertEqual(String(decoding: bytes[30..<(30 + nameLength)], as: UTF8.self), "2026/09/2026-09-24.md")

        let dataStart = 30 + nameLength + extraLength
        let size = Int(bytes[18]) | Int(bytes[19]) << 8 | Int(bytes[20]) << 16 | Int(bytes[21]) << 24
        let content = String(decoding: bytes[dataStart..<(dataStart + size)], as: UTF8.self)
        let day = DiaryExporter.pomodoros(sessions, calendar: utcCalendar)
        XCTAssertEqual(content, DiaryExporter.dayFile(day, text: diaryText, calendar: utcCalendar))
    }

    // -- 14. Export ---------------------------------------------------------------

    private func makeExportSessions() -> [SessionLogEntry] {
        let start = date(hour: 14, minute: 29)
        return [
            makeEntry(task: "R&D <plan>", hour: 14, minute: 29, durationMinutes: 25, pomodoroStart: start),
            makeEntry(phase: "shortBreak", hour: 14, minute: 54, durationMinutes: 5, pomodoroStart: start),
            makeEntry(task: "R&D <plan>", hour: 14, minute: 59, durationMinutes: 8, completed: false, pomodoroStart: start),
            // Sub-minute stopped-early focus: excluded from md/txt/odt, but
            // still present in the raw JSON export.
            makeEntry(task: "R&D <plan>", hour: 15, minute: 7, completed: false, durationSeconds: 30, pomodoroStart: start),
        ]
    }

    func testExportMarkdownStructureAndStoppedEarlyMarker() {
        let sessions = makeExportSessions()
        let data = DiaryExporter.export(
            sessions: sessions, format: .markdown, text: diaryText, now: date(hour: 15, minute: 2), calendar: utcCalendar)
        let markdown = String(data: data, encoding: .utf8)!

        XCTAssertTrue(markdown.hasPrefix("# Pomoppi: full session log"))
        XCTAssertTrue(markdown.contains("\n## "), "a day heading")
        XCTAssertTrue(markdown.contains("### 14:29 · R&D <plan>"), "a pomodoro heading")
        XCTAssertTrue(markdown.contains("- 14:29–14:54 · Focus · 25m"))
        XCTAssertTrue(markdown.contains("- 14:54–14:59 · Short Break · 5m"))
        XCTAssertTrue(markdown.contains("- 14:59–15:07 · Focus · 8m · stopped early"))
        XCTAssertFalse(markdown.contains("<1m"), "the sub-minute stopped-early focus is left out of the diary")
    }

    func testExportTextHasNoMarkdownHeadingsAndUnderlinesTheTitle() {
        let sessions = makeExportSessions()
        let data = DiaryExporter.export(
            sessions: sessions, format: .text, text: diaryText, now: date(hour: 15, minute: 2), calendar: utcCalendar)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertFalse(text.contains("#"))
        XCTAssertTrue(text.hasPrefix("Pomoppi: full session log\n="))
        XCTAssertTrue(text.contains(String(repeating: "=", count: "Pomoppi: full session log".count)))
    }

    func testExportJSONDecodesBackToEverySessionIncludingTheSubMinuteOne() throws {
        let sessions = makeExportSessions()
        let data = DiaryExporter.export(
            sessions: sessions, format: .json, text: diaryText, now: date(hour: 15, minute: 2), calendar: utcCalendar)

        struct DecodedLogFile: Decodable { let sessions: [SessionLogEntry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DecodedLogFile.self, from: data)

        XCTAssertEqual(decoded.sessions.count, sessions.count, "JSON export is the raw, unfiltered log")
    }

    private struct ZipLocalEntry { let name: String; let method: Int; let data: Data }

    // Minimal reader for this test's own purposes, per the local file header
    // layout ZipWriter writes: signature (u32 @0), method (u16 @8), CRC/size
    // fields, name length (u16 @26), extra length (u16 @28), name (@30).
    private func readZipLocalEntries(_ data: Data) -> [ZipLocalEntry] {
        var result: [ZipLocalEntry] = []
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
        func u32(_ at: Int) -> Int { u16(at) | (u16(at + 2) << 16) }
        var offset = 0
        while offset + 4 <= bytes.count, u32(offset) == 0x0403_4b50 {
            let method = u16(offset + 8)
            let size = u32(offset + 22) // stored: compressed size == uncompressed size
            let nameLength = u16(offset + 26)
            let extraLength = u16(offset + 28)
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            result.append(ZipLocalEntry(name: name, method: method, data: Data(bytes[dataStart..<(dataStart + size)])))
            offset = dataStart + size
        }
        return result
    }

    func testExportODTIsAValidZipWithMimetypeFirstStoredAndEscapedContent() {
        let sessions = makeExportSessions()
        let data = DiaryExporter.export(
            sessions: sessions, format: .odt, text: diaryText, now: date(hour: 15, minute: 2), calendar: utcCalendar)
        let entries = readZipLocalEntries(data)

        XCTAssertEqual(entries.first?.name, "mimetype")
        XCTAssertEqual(entries.first?.method, 0, "mimetype must be stored, not compressed")
        XCTAssertEqual(
            entries.first.map { String(decoding: $0.data, as: UTF8.self) },
            "application/vnd.oasis.opendocument.text")

        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["META-INF/manifest.xml", "content.xml", "styles.xml"]))

        let contentXML = String(decoding: entries.first(where: { $0.name == "content.xml" })!.data, as: UTF8.self)
        XCTAssertTrue(contentXML.contains("R&amp;D &lt;plan&gt;"), "the task title is XML-escaped")
    }
}
