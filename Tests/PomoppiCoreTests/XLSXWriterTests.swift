import XCTest
import PomoppiStrings
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import PomoppiCore

final class XLSXWriterTests: XCTestCase {
    private let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private let diaryText = DiaryText(locale: Locale(identifier: "en_US_POSIX"), lookup: { L.t($0, args: $1) })

    // Reads a stored-only zip's local headers back into name -> content.
    private func unzip(_ data: Data) -> [(name: String, content: String)] {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var out: [(String, String)] = []
        var i = 0
        while i + 30 <= b.count, u32(i) == 0x0403_4b50 {
            let size = u32(i + 18), nameLen = u16(i + 26)
            let name = String(decoding: b[(i + 30)..<(i + 30 + nameLen)], as: UTF8.self)
            let start = i + 30 + nameLen
            out.append((name, String(decoding: b[start..<(start + size)], as: UTF8.self)))
            i = start + size
        }
        return out
    }

    private func date(day: Int = 24, hour: Int, minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = day; c.hour = hour; c.minute = minute
        c.timeZone = TimeZone(identifier: "UTC")
        return utc.date(from: c)!
    }

    private func entry(_ phase: String, task: String = "", hour: Int, minute: Int, seconds: Int, completed: Bool = true, pomodoro: Date) -> SessionLogEntry {
        let start = date(hour: hour, minute: minute)
        return SessionLogEntry(
            phase: phase, task: task, day: 24, month: 9, year: 2026,
            startTime: start, endTime: start.addingTimeInterval(TimeInterval(seconds)),
            durationMinutes: seconds / 60, completed: completed, durationSeconds: seconds,
            pomodoroStart: pomodoro, plannedSeconds: 1500, pausedSeconds: 30, focusNumber: 1)
    }

    private func sampleExport(title: String = "Write <spec> & \"test\"") -> [(name: String, content: String)] {
        let p = date(hour: 9, minute: 0)
        let sessions = [
            entry("focus", task: title, hour: 9, minute: 0, seconds: 1500, pomodoro: p),
            entry("shortBreak", hour: 9, minute: 25, seconds: 300, pomodoro: p),
        ]
        return unzip(DiaryExporter.export(sessions: sessions, format: .xlsx, text: diaryText, calendar: utc))
    }

    func testWorkbookHasTheRequiredPartsInOrder() {
        let names = sampleExport().map(\.name)
        XCTAssertEqual(names, [
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
            "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml",
        ])
    }

    func testEveryPartIsWellFormedXML() {
        for part in sampleExport() {
            let parser = XMLParser(data: Data(part.content.utf8))
            XCTAssertTrue(parser.parse(), "\(part.name): \(String(describing: parser.parserError))")
        }
    }

    func testSheetNamesAndHeadersAreLocalizedAndCellsAreTyped() {
        let parts = Dictionary(uniqueKeysWithValues: sampleExport().map { ($0.name, $0.content) })
        XCTAssertTrue(parts["xl/workbook.xml"]!.contains("name=\"Pomodoros\""))
        XCTAssertTrue(parts["xl/workbook.xml"]!.contains("name=\"Sessions\""))
        let sheet1 = parts["xl/worksheets/sheet1.xml"]!
        XCTAssertTrue(sheet1.contains("<t xml:space=\"preserve\">Focus sessions</t>"))
        XCTAssertTrue(sheet1.contains("state=\"frozen\""))
        // Focus 25 min, break 5 min.
        XCTAssertTrue(sheet1.contains("<c r=\"G2\"><v>25.0</v></c>"))
        XCTAssertTrue(sheet1.contains("<c r=\"H2\"><v>5.0</v></c>"))
        XCTAssertTrue(parts["xl/worksheets/sheet2.xml"]!.contains(">Yes</t>"))
    }

    func testDateSerialIsDaysSince1899_12_30InLocalTime() {
        // 2026-09-24 is serial 46289 (2026-01-01 is 46023; +266 days).
        XCTAssertEqual(XLSXWriter.serialDay(date(hour: 9, minute: 0), calendar: utc), 46289)
        XCTAssertEqual(XLSXWriter.serialDay(date(hour: 23, minute: 59), calendar: utc), 46289)
        XCTAssertEqual(XLSXWriter.serialTime(date(hour: 12, minute: 0), calendar: utc), 0.5, accuracy: 1e-12)

        // The same instant is the next local day further east.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(XLSXWriter.serialDay(date(hour: 20, minute: 0), calendar: tokyo), 46290)
        XCTAssertEqual(XLSXWriter.serialTime(date(hour: 20, minute: 0), calendar: tokyo), 5.0 / 24, accuracy: 1e-12)
    }

    func testTextIsEscapedAndInvalidControlCharactersAreDropped() {
        let sheet = sampleExport()[5].content
        XCTAssertTrue(sheet.contains("Write &lt;spec&gt; &amp; &quot;test&quot;"))
        XCTAssertFalse(sheet.contains("<spec>"))
        XCTAssertEqual(XLSXWriter.escape("a\u{0}b\u{8}c\td"), "abc\td")
    }

    func testSheetNameIsSanitizedAndColumnLettersRollOver() {
        XCTAssertEqual(XLSXWriter.sheetName("a/b:c*d?[e]\\f"), "abcdef")
        XCTAssertEqual(XLSXWriter.sheetName(String(repeating: "x", count: 40)).count, 31)
        XCTAssertEqual(XLSXWriter.sheetName("///"), "Sheet")
        XCTAssertEqual(XLSXWriter.columnLetters(0), "A")
        XCTAssertEqual(XLSXWriter.columnLetters(25), "Z")
        XCTAssertEqual(XLSXWriter.columnLetters(26), "AA")
    }

    func testXlsxIsOfferedByTheFormatPickers() {
        XCTAssertTrue(DiaryFormat.allCases.contains(.xlsx))
        XCTAssertEqual(DiaryFormat.xlsx.fileExtension, "xlsx")
    }
}
