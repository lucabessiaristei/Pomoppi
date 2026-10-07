// TransferCodec.swift — the offline transfer payload (SPEC.md §16): settings
// and/or the pomodoro log packed into one small binary blob that travels as
// a text code, a `.pomoppi` file, or (later) a QR. Foundation-only and
// byte-for-byte specified in SPEC.md so a phone app can read and write it.
// This file holds the container (header, checksum, text code, options,
// self-check) and the varint helpers; the two blocks live in
// TransferCodec+Settings.swift and TransferCodec+Log.swift.
import Foundation

public enum TransferError: Error, Equatable {
    case badChecksum
    case unsupportedVersion
    case malformed
    case notACode
    // The encoder decoded its own output and it didn't match the input.
    case selfCheckFailed
    // Header flag reserved for multi-part codes; a v1 decoder refuses it.
    case multipart
}

// The popup's toggles. titles / subMinuteSkips / details only matter when
// `log` is on; the last three are lossy by design (applied before encoding).
public struct TransferOptions: Equatable {
    public var settings: Bool
    public var log: Bool
    public var titles: Bool
    public var subMinuteSkips: Bool
    public var details: Bool

    public init(settings: Bool = true, log: Bool = true, titles: Bool = true,
                subMinuteSkips: Bool = true, details: Bool = true) {
        self.settings = settings
        self.log = log
        self.titles = titles
        self.subMinuteSkips = subMinuteSkips
        self.details = details
    }
}

public struct TransferPayload: Equatable {
    public var settings: PomoppiSettings?
    public var sessions: [SessionLogEntry]?
    // What the sender left out (header flags), for the import preview.
    public var titlesIncluded: Bool
    public var detailsIncluded: Bool
    public var subMinuteSkipsIncluded: Bool

    public init(settings: PomoppiSettings? = nil, sessions: [SessionLogEntry]? = nil,
                titlesIncluded: Bool = true, detailsIncluded: Bool = true,
                subMinuteSkipsIncluded: Bool = true) {
        self.settings = settings
        self.sessions = sessions
        self.titlesIncluded = titlesIncluded
        self.detailsIncluded = detailsIncluded
        self.subMinuteSkipsIncluded = subMinuteSkipsIncluded
    }
}

public struct TransferSize: Equatable {
    public let bytes: Int
    public let textCodeLength: Int
}

public enum TransferCodec {
    public static let formatVersion: UInt64 = 1
    public static let textPrefix = "pomoppi1-"
    public static let fileExtension = "pomoppi"

    // Header flags (SPEC.md §16). Bit 5 is reserved for multi-part codes.
    static let flagSettings: UInt64 = 1 << 0
    static let flagLog: UInt64 = 1 << 1
    static let flagTitlesOmitted: UInt64 = 1 << 2
    static let flagDetailsOmitted: UInt64 = 1 << 3
    static let flagSubMinuteSkipsOmitted: UInt64 = 1 << 4
    static let flagMultipart: UInt64 = 1 << 5
    static let knownFlags: UInt64 = (1 << 6) - 1

    public static func encode(
        settings: PomoppiSettings, sessions: [SessionLogEntry], options: TransferOptions = TransferOptions()
    ) throws -> Data {
        let sentSettings = options.settings ? try normalizedForTransfer(settings) : nil
        let sentSessions = options.log ? applyOptions(to: sessions, options) : nil

        var flags: UInt64 = 0
        if sentSettings != nil { flags |= flagSettings }
        if sentSessions != nil {
            flags |= flagLog
            if !options.titles { flags |= flagTitlesOmitted }
            if !options.details { flags |= flagDetailsOmitted }
            if !options.subMinuteSkips { flags |= flagSubMinuteSkipsOmitted }
        }

        var w = ByteWriter()
        w.varint(formatVersion)
        w.varint(flags)
        if let sentSettings {
            let block = try encodeSettings(sentSettings)
            w.varint(UInt64(block.count))
            w.bytes(block)
        }
        if let sentSessions {
            let block = try encodeLog(sentSessions)
            w.varint(UInt64(block.count))
            w.bytes(block)
        }
        w.bytes(Array(SHA256.hash(Data(w.out)).prefix(4)))
        let data = Data(w.out)

        guard let back = try? decode(data), back.settings == sentSettings, back.sessions == sentSessions else {
            throw TransferError.selfCheckFailed
        }
        return data
    }

    public static func decode(_ data: Data) throws -> TransferPayload {
        let bytes = [UInt8](data)
        // Version first: a future format may checksum differently.
        var head = ByteReader(bytes)
        guard try head.varint() == formatVersion else { throw TransferError.unsupportedVersion }
        guard bytes.count >= 4 + 2 else { throw TransferError.malformed }
        let body = Array(bytes.dropLast(4))
        guard Array(SHA256.hash(Data(body)).prefix(4)) == Array(bytes.suffix(4)) else {
            throw TransferError.badChecksum
        }

        var r = ByteReader(body)
        _ = try r.varint()
        let flags = try r.varint()
        if flags & flagMultipart != 0 { throw TransferError.multipart }
        guard flags & ~knownFlags == 0 else { throw TransferError.malformed }

        var payload = TransferPayload(
            titlesIncluded: flags & flagTitlesOmitted == 0,
            detailsIncluded: flags & flagDetailsOmitted == 0,
            subMinuteSkipsIncluded: flags & flagSubMinuteSkipsOmitted == 0)
        if flags & flagSettings != 0 {
            payload.settings = try decodeSettings(try r.block())
        }
        if flags & flagLog != 0 {
            payload.sessions = try decodeLog(try r.block())
        }
        guard r.atEnd else { throw TransferError.malformed }
        return payload
    }

    // MARK: Text code

    public static func textCode(_ data: Data) -> String {
        textPrefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(fromTextCode text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(textPrefix) else { throw TransferError.notACode }
        var body = String(trimmed.dropFirst(textPrefix.count))
        guard !body.isEmpty,
              body.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw TransferError.notACode }
        body = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body) else { throw TransferError.notACode }
        return data
    }

    public static func size(of data: Data) -> TransferSize {
        TransferSize(bytes: data.count, textCodeLength: textCode(data).count)
    }

    // MARK: Options (lossy by design, applied before encoding)

    static func applyOptions(to sessions: [SessionLogEntry], _ options: TransferOptions) -> [SessionLogEntry] {
        var out = sessions
        if !options.subMinuteSkips {
            // Focus entries stopped under a minute (the complement of
            // SessionLogEntry.isRealFocus, for focus phases only).
            out.removeAll { $0.phase == "focus" && !$0.isRealFocus }
        }
        if !options.titles || !options.details {
            out = out.map { e in
                SessionLogEntry(
                    phase: e.phase, task: options.titles ? e.task : "",
                    day: e.day, month: e.month, year: e.year,
                    // Details off drops paused time, so the end moves in by
                    // it too: the end then follows from start + duration
                    // instead of costing an exception per paused entry.
                    startTime: e.startTime,
                    endTime: options.details ? e.endTime : e.endTime.addingTimeInterval(-Double(e.pausedSeconds ?? 0)),
                    durationMinutes: e.durationMinutes, completed: e.completed,
                    durationSeconds: e.durationSeconds, pomodoroStart: e.pomodoroStart,
                    plannedSeconds: e.plannedSeconds,
                    pausedSeconds: options.details ? e.pausedSeconds : nil,
                    focusNumber: e.focusNumber, focusCount: e.focusCount,
                    timeZone: options.details ? e.timeZone : nil,
                    appVersion: options.details ? e.appVersion : nil,
                    friend: e.friend)
            }
        }
        return out
    }
}

// MARK: Byte helpers

// LEB128 varints; signed values zigzag-encoded first.
struct ByteWriter {
    var out: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    mutating func int(_ value: Int64) {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func int(_ value: Int) { int(Int64(value)) }

    mutating func bytes(_ b: [UInt8]) { out.append(contentsOf: b) }

    mutating func string(_ s: String) {
        let b = Array(s.utf8)
        varint(UInt64(b.count))
        out.append(contentsOf: b)
    }

    // key = fieldNumber << 3 | wireType
    mutating func key(_ field: UInt64, _ wireType: UInt64) { varint(field << 3 | wireType) }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { pos >= bytes.count }
    var remaining: Int { bytes.count - pos }

    mutating func byte() throws -> UInt8 {
        guard pos < bytes.count else { throw TransferError.malformed }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            if shift == 63 && b > 1 { throw TransferError.malformed }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw TransferError.malformed }
        }
    }

    mutating func int() throws -> Int {
        let v = try varint()
        return Int(Int64(bitPattern: v >> 1 ^ (0 &- (v & 1))))
    }

    // A count that must be backed by at least `perItem` bytes each, so a
    // corrupt value can't allocate wildly.
    mutating func count(perItem: Int = 1) throws -> Int {
        let v = try varint()
        guard v <= UInt64(remaining / max(perItem, 1)) else { throw TransferError.malformed }
        return Int(v)
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= remaining else { throw TransferError.malformed }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    // A length-prefixed run of bytes.
    mutating func block() throws -> [UInt8] {
        let n = try varint()
        guard n <= UInt64(remaining) else { throw TransferError.malformed }
        return try take(Int(n))
    }

    mutating func string() throws -> String {
        guard let s = String(bytes: try block(), encoding: .utf8) else { throw TransferError.malformed }
        return s
    }
}
