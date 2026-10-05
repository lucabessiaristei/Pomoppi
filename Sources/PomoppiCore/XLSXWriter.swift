// XLSXWriter.swift — a minimal SpreadsheetML (.xlsx) writer for the Diary's
// export (SPEC.md §8b). No dependency, same precedent as ODTWriter: an .xlsx
// is a zip of a few XML parts, and ZipWriter already writes stored zips.
// Strings are inline (no shared-strings part), numbers are plain, and four
// cell styles cover everything the diary needs.
import Foundation

public enum XLSXWriter {

    public enum Cell: Equatable {
        case text(String)
        case number(Double)
        case date(Double)   // Excel serial day number
        case time(Double)   // fraction of a day
        case blank
    }

    public struct Sheet {
        public let name: String
        public let header: [String]
        public let columnWidths: [Double]   // in characters, one per column
        public let rows: [[Cell]]

        public init(name: String, header: [String], columnWidths: [Double], rows: [[Cell]]) {
            self.name = name
            self.header = header
            self.columnWidths = columnWidths
            self.rows = rows
        }
    }

    // cellXfs indexes in styles.xml below.
    private enum Style: Int { case normal = 0, header, date, time }

    public static func workbook(_ sheets: [Sheet], date: Date = Date()) -> Data {
        var entries = [
            ZipWriter.Entry(name: "[Content_Types].xml", data: Data(contentTypes(sheets.count).utf8)),
            ZipWriter.Entry(name: "_rels/.rels", data: Data(rootRels.utf8)),
            ZipWriter.Entry(name: "xl/workbook.xml", data: Data(workbookXML(sheets).utf8)),
            ZipWriter.Entry(name: "xl/_rels/workbook.xml.rels", data: Data(workbookRels(sheets.count).utf8)),
            ZipWriter.Entry(name: "xl/styles.xml", data: Data(styles.utf8)),
        ]
        for (i, sheet) in sheets.enumerated() {
            entries.append(ZipWriter.Entry(name: "xl/worksheets/sheet\(i + 1).xml", data: Data(sheetXML(sheet).utf8)))
        }
        return ZipWriter.zip(entries, date: date)
    }

    // -- dates --------------------------------------------------------------

    // Excel's day 0 is 1899-12-30 (the 1900 leap-year bug folded in).
    private static let epoch: Date = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return utc.date(from: DateComponents(year: 1899, month: 12, day: 30)) ?? Date(timeIntervalSince1970: -2_209_161_600)
    }()

    // The local calendar day, as a whole serial number.
    public static func serialDay(_ date: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let day = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) else { return 0 }
        return (day.timeIntervalSince(epoch) / 86400).rounded()
    }

    // The local time of day, as a fraction of a day.
    public static func serialTime(_ date: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds: Int = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return Double(seconds) / 86400
    }

    // -- XML ----------------------------------------------------------------

    // ODTWriter's escaping, after dropping the characters XML 1.0 forbids
    // outright (control codes other than tab/newline/return).
    static func escape(_ s: String) -> String {
        var clean = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where scalar.value >= 0x20 || scalar.value == 9 || scalar.value == 10 || scalar.value == 13 {
            clean.append(scalar)
        }
        return ODTWriter.escape(String(clean))
    }

    // Excel: at most 31 characters, none of []:*?/\ , not empty.
    static func sheetName(_ name: String) -> String {
        let cleaned = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
        return cleaned.isEmpty ? "Sheet" : cleaned
    }

    // 0 -> "A", 25 -> "Z", 26 -> "AA".
    static func columnLetters(_ index: Int) -> String {
        var n = index + 1
        var letters = ""
        while n > 0 {
            let r = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + r))) + letters
            n = (n - 1) / 26
        }
        return letters
    }

    private static func cellXML(_ cell: Cell, ref: String, header: Bool = false) -> String {
        switch cell {
        case .blank: return ""
        case .text(let s):
            let style = header ? " s=\"\(Style.header.rawValue)\"" : ""
            return "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(escape(s))</t></is></c>"
        case .number(let n): return "<c r=\"\(ref)\"><v>\(n)</v></c>"
        case .date(let n): return "<c r=\"\(ref)\" s=\"\(Style.date.rawValue)\"><v>\(n)</v></c>"
        case .time(let n): return "<c r=\"\(ref)\" s=\"\(Style.time.rawValue)\"><v>\(n)</v></c>"
        }
    }

    private static func sheetXML(_ sheet: Sheet) -> String {
        let cols = sheet.columnWidths.enumerated().map {
            "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>"
        }.joined()
        var rows = "<row r=\"1\">" + sheet.header.enumerated().map {
            cellXML(.text($0.element), ref: "\(columnLetters($0.offset))1", header: true)
        }.joined() + "</row>"
        for (i, row) in sheet.rows.enumerated() {
            let r = i + 2
            rows += "<row r=\"\(r)\">" + row.enumerated().map {
                cellXML($0.element, ref: "\(columnLetters($0.offset))\(r)")
            }.joined() + "</row>"
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
            <cols>\(cols)</cols>
            <sheetData>\(rows)</sheetData>
            </worksheet>

            """
    }

    private static func contentTypes(_ sheetCount: Int) -> String {
        let sheets = (0..<sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            \(sheets)
            </Types>

            """
    }

    private static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>

        """

    private static func workbookXML(_ sheets: [Sheet]) -> String {
        let list = sheets.enumerated().map {
            "<sheet name=\"\(escape(sheetName($0.element.name)))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets>\(list)</sheets>
            </workbook>

            """
    }

    private static func workbookRels(_ sheetCount: Int) -> String {
        let sheets = (0..<sheetCount).map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            \(sheets)
            <Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>

            """
    }

    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/><numFmt numFmtId="165" formatCode="hh:mm"/></numFmts>
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="4">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>

        """
}
