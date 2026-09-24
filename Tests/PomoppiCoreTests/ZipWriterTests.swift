import XCTest
@testable import PomoppiCore

final class ZipWriterTests: XCTestCase {
    private func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | (Int(bytes[at + 1]) << 8) }
    private func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    func testSingleEntryStructureSignaturesCRCAndStoredSize() {
        let data = ZipWriter.zip([ZipWriter.Entry(name: "hello.txt", data: Data("hello".utf8))])
        let bytes = [UInt8](data)

        // Local file header.
        XCTAssertEqual(u32(bytes, 0), 0x0403_4b50)
        let method = u16(bytes, 8)
        XCTAssertEqual(method, 0, "stored (uncompressed) entries only")
        let crc = u32(bytes, 14)
        XCTAssertEqual(crc, 0x3610_A686, "known CRC-32 of the ASCII string \"hello\"")
        let compressedSize = u32(bytes, 18)
        let uncompressedSize = u32(bytes, 22)
        XCTAssertEqual(compressedSize, 5)
        XCTAssertEqual(uncompressedSize, 5, "stored: compressed size == raw size")
        let nameLength = u16(bytes, 26)
        XCTAssertEqual(nameLength, 9)
        let nameStart = 30
        XCTAssertEqual(String(decoding: bytes[nameStart..<(nameStart + 9)], as: UTF8.self), "hello.txt")
        let contentStart = nameStart + 9
        XCTAssertEqual(String(decoding: bytes[contentStart..<(contentStart + 5)], as: UTF8.self), "hello")

        // Central directory + end-of-central-directory record follow the
        // one local entry (30-byte header + 9-byte name + 5 bytes of data).
        let centralOffset = 30 + 9 + 5
        XCTAssertEqual(u32(bytes, centralOffset), 0x0201_4b50)
        let eocdOffset = bytes.count - 22
        XCTAssertEqual(u32(bytes, eocdOffset), 0x0605_4b50)
        let entryCount = u16(bytes, eocdOffset + 10)
        XCTAssertEqual(entryCount, 1)
    }

    func testMultipleEntriesKeepTheOrderGiven() {
        let entries = [
            ZipWriter.Entry(name: "2026-09-20.md", data: Data("later day".utf8)),
            ZipWriter.Entry(name: "2026-09-19.md", data: Data("earlier day".utf8)),
        ]
        let data = ZipWriter.zip(entries)
        let bytes = [UInt8](data)

        // Insertion order, not name order: ODT needs `mimetype` first.
        let nameLength = u16(bytes, 26)
        let nameStart = 30
        XCTAssertEqual(String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self), "2026-09-20.md")

        let eocdOffset = bytes.count - 22
        XCTAssertEqual(u16(bytes, eocdOffset + 10), 2)
    }

    #if os(macOS)
    // Confirms a real unzip implementation accepts what this writer
    // produces, not just that this test's own byte-offset reading agrees
    // with itself.
    func testArchiveOpensWithSystemUnzip() throws {
        let entries = [
            ZipWriter.Entry(name: "2026-09-19.md", data: Data("## Pomodoros\n- 09:00–09:25 (25m) — test\n".utf8)),
            ZipWriter.Entry(name: "2026-09-20.md", data: Data("## Pomodoros\n".utf8)),
        ]
        let data = ZipWriter.zip(entries)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("ZipWriterTests-\(UUID().uuidString).zip")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", fileURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    #endif
}
