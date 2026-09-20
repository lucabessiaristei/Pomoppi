// ZipWriter.swift — a minimal, dependency-free ZIP writer (SPEC.md §8b).
// Neither platform's Foundation exposes a zip API, and shelling out to
// `zip`/`Compress-Archive` isn't acceptable here — so this hand-rolls just
// enough of the format: stored (uncompressed) entries only, no
// directories, no extra fields beyond the UTF-8-name flag. Diary exports
// are a handful of tiny per-day .md files; compression isn't worth the
// code. `DiaryExporter.exportZip(sessions:)` is the only caller.
import Foundation

public enum ZipWriter {
    public struct Entry {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    // Deterministic entry order (sorted by name), so the same session log
    // always produces byte-identical zip bytes — everything else (CRCs,
    // sizes, offsets) is already determined by the entries themselves;
    // only the DOS timestamp below varies run to run.
    public static func zip(_ entries: [Entry], date: Date = Date()) -> Data {
        let sorted = entries.sorted { $0.name < $1.name }
        let (dosTime, dosDate) = dosDateTime(date)
        var body = Data()
        var centralDirectory = Data()

        for entry in sorted {
            let nameBytes = Array(entry.name.utf8)
            let contentBytes = Array(entry.data)
            let crc = crc32(contentBytes)
            let size = UInt32(contentBytes.count)
            let localOffset = UInt32(body.count)

            // Local file header (30 bytes + name + data) — version 20 (2.0,
            // the minimum that supports stored entries), flag bit 11 set
            // for a UTF-8 name, method 0 (stored, no compression).
            var local = Data()
            local.appendUInt32(0x0403_4b50)
            local.appendUInt16(20)
            local.appendUInt16(0x0800)
            local.appendUInt16(0)
            local.appendUInt16(dosTime)
            local.appendUInt16(dosDate)
            local.appendUInt32(crc)
            local.appendUInt32(size) // compressed size == uncompressed: stored
            local.appendUInt32(size)
            local.appendUInt16(UInt16(nameBytes.count))
            local.appendUInt16(0) // extra field length
            local.append(contentsOf: nameBytes)
            local.append(contentsOf: contentBytes)
            body.append(local)

            // Central directory file header (46 bytes + name) — same
            // metadata as the local header, plus this entry's offset into
            // the archive so a reader can jump straight to it.
            var central = Data()
            central.appendUInt32(0x0201_4b50)
            central.appendUInt16(20) // version made by
            central.appendUInt16(20) // version needed to extract
            central.appendUInt16(0x0800)
            central.appendUInt16(0)
            central.appendUInt16(dosTime)
            central.appendUInt16(dosDate)
            central.appendUInt32(crc)
            central.appendUInt32(size)
            central.appendUInt32(size)
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0) // extra field length
            central.appendUInt16(0) // file comment length
            central.appendUInt16(0) // disk number start
            central.appendUInt16(0) // internal file attributes
            central.appendUInt32(0) // external file attributes
            central.appendUInt32(localOffset)
            central.append(contentsOf: nameBytes)
            centralDirectory.append(central)
        }

        // End of central directory record (22 bytes, no archive comment).
        var end = Data()
        end.appendUInt32(0x0605_4b50)
        end.appendUInt16(0) // number of this disk
        end.appendUInt16(0) // disk where central directory starts
        end.appendUInt16(UInt16(sorted.count))
        end.appendUInt16(UInt16(sorted.count))
        end.appendUInt32(UInt32(centralDirectory.count))
        end.appendUInt32(UInt32(body.count)) // offset of central directory
        end.appendUInt16(0) // comment length

        return body + centralDirectory + end
    }

    // DOS date/time, the format every local/central header stores a
    // timestamp in: time packs hour(5)/minute(6)/second(5, halved — 2s
    // resolution), date packs (year-1980)(7)/month(4)/day(5). Sourced from
    // `Date()` at the moment `zip(_:)` is called — used only for the
    // archive's own bookkeeping (Finder/Explorer's "date modified" on
    // extraction), nothing in this app ever reads it back.
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let year = max(1980, c.year ?? 1980)
        let dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, dosDate)
    }

    // Standard table-driven IEEE CRC-32 (polynomial 0xEDB88320) — the
    // checksum every ZIP entry's local/central header stores.
    private static let crcTable: [UInt32] = (0...255).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
