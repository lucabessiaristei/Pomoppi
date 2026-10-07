import XCTest
@testable import PomoppiCore

final class TransferCodecTests: XCTestCase {
    private let rome = "Europe/Rome"

    private func date(_ s: Int64) -> Date { Date(timeIntervalSince1970: Double(s)) }

    private func ymd(_ s: Int64, _ tz: String?) -> (Int, Int, Int) {
        let r = TransferCodec.CalendarCache().ymd(s, tz)
        return (r.year, r.month, r.day)
    }

    // One entry built the way SessionLogger.logSession derives it.
    private func entry(
        _ phase: String = "focus", start: Int64, planned: Int = 1500, actual: Int? = nil, paused: Int = 0,
        task: String = "writing", number: Int = 1, count: Int? = 4, pomodoro: Int64, tz: String? = "Europe/Rome",
        version: String? = "0.5.0", friend: String? = "namidappi"
    ) -> SessionLogEntry {
        let completed = actual == nil
        let length = actual ?? planned
        let (y, m, d) = ymd(start, tz)
        return SessionLogEntry(
            phase: phase, task: task, day: d, month: m, year: y,
            startTime: date(start), endTime: date(start + Int64(length + paused)),
            durationMinutes: Int((Double(length) / 60).rounded()), completed: completed,
            durationSeconds: length, pomodoroStart: date(pomodoro), plannedSeconds: planned,
            pausedSeconds: paused, focusNumber: number, focusCount: count,
            timeZone: tz, appVersion: version, friend: friend)
    }

    // A normal 4-focus pomodoro with breaks, optionally with a pause and a skipped last focus.
    private func pomodoro(at start: Int64, task: String, friend: String? = "namidappi", skipLast: Bool = false) -> [SessionLogEntry] {
        var t = start
        var out: [SessionLogEntry] = []
        for n in 1...4 {
            let last = n == 4
            let skipped = last && skipLast
            let e = entry("focus", start: t, actual: skipped ? 400 : nil, paused: n == 2 ? 120 : 0,
                          task: task, number: n, pomodoro: start, friend: friend)
            out.append(e)
            t = Int64(e.endTime.timeIntervalSince1970)
            if !skipped {
                let b = entry(last ? "longBreak" : "shortBreak", start: t, planned: last ? 900 : 300,
                              task: task, number: n, pomodoro: start, friend: friend)
                out.append(b)
                t = Int64(b.endTime.timeIntervalSince1970)
            }
        }
        return out
    }

    private func roundTrip(_ sessions: [SessionLogEntry], options: TransferOptions = TransferOptions(settings: false)) throws -> [SessionLogEntry] {
        let data = try TransferCodec.encode(settings: .defaults, sessions: sessions, options: options)
        return try XCTUnwrap(TransferCodec.decode(data).sessions)
    }

    private func settingsRoundTrip(_ s: PomoppiSettings) throws -> PomoppiSettings {
        let data = try TransferCodec.encode(settings: s, sessions: [], options: TransferOptions(log: false))
        return try XCTUnwrap(TransferCodec.decode(data).settings)
    }

    // MARK: Settings

    func testDefaultsOnlySettingsAreTiny() throws {
        let data = try TransferCodec.encode(settings: .defaults, sessions: [], options: TransferOptions(log: false))
        XCTAssertLessThanOrEqual(data.count, 8)
        let back = try TransferCodec.decode(data)
        XCTAssertEqual(back.settings, PomoppiSettings.defaults)
        XCTAssertNil(back.sessions)
    }

    func testEveryFieldNonDefault() throws {
        var s = PomoppiSettings.defaults
        s.focusMinutes = 50; s.shortBreakMinutes = 7.5; s.longBreakMinutes = 30; s.longBreakEvery = 3
        s.autoStartBreaks = false; s.autoStartFocus = true; s.loggingEnabled = false
        s.raiseOnEnd = false; s.reverseTrayClick = true; s.checkForUpdates = false
        s.soundEnabled = false; s.askForTaskName = false
        s.friend = "utsupon"; s.frameStyle = "wavey"; s.background = "tatami"
        s.inkColor = "#112233"; s.paperColor = "#FFEEDD"; s.colorScheme = "dark"
        s.scale = 4; s.opacity = 0.35; s.language = "it"; s.chime = "soft"; s.ringSeconds = 12.5
        s.shortcuts["startPause"] = "Control+Shift+F5"
        let back = try settingsRoundTrip(s)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.friend, "utsupon")
        XCTAssertEqual(back.opacity, 0.35)
    }

    func testUnknownEnumIdUsesStringFallback() throws {
        var s = PomoppiSettings.defaults
        s.friend = "newpal"          // set after init: not clamped
        s.language = "pt"
        let back = try settingsRoundTrip(s)
        XCTAssertEqual(back.friend, "newpal")
        XCTAssertEqual(back.language, "pt")
        // applying clamps what this build doesn't know
        let applied = TransferCodec.applying(back, to: .defaults)
        XCTAssertEqual(applied.friend, PomoppiSettings.defaults.friend)
        XCTAssertEqual(applied.language, "system")
    }

    func testShortcutsChangedClearedAndRaw() throws {
        var s = PomoppiSettings.defaults
        s.shortcuts["skip"] = "Command+Alt+Left"
        s.shortcuts["reset"] = ""
        s.shortcuts["toggleOnTop"] = "Shift+Plus"
        s.shortcuts["customAction"] = "Alt+Shift+Q"
        s.shortcuts["weird"] = "Hyper+Q"            // not canonical: raw string path
        let back = try settingsRoundTrip(s)
        XCTAssertEqual(back.shortcuts, s.shortcuts)
        XCTAssertEqual(back.shortcuts["reset"], "")
        XCTAssertEqual(back.shortcuts["toggleWidget"], Shortcuts.defaults["toggleWidget"])
    }

    func testMachineLocalSettingsAreNotTransferred() throws {
        var sent = PomoppiSettings.defaults
        sent.diaryFolderPath = "/Users/a/Notes"; sent.launchAtLogin = true
        sent.startHidden = true; sent.alwaysOnTop = false; sent.focusMinutes = 40
        let back = try settingsRoundTrip(sent)
        XCTAssertEqual(back.diaryFolderPath, "")
        XCTAssertFalse(back.launchAtLogin)
        XCTAssertTrue(back.alwaysOnTop)

        var local = PomoppiSettings.defaults
        local.diaryFolderPath = "/mine"; local.launchAtLogin = true; local.startHidden = true; local.alwaysOnTop = false
        let applied = TransferCodec.applying(back, to: local)
        XCTAssertEqual(applied.focusMinutes, 40)
        XCTAssertEqual(applied.diaryFolderPath, "/mine")
        XCTAssertTrue(applied.launchAtLogin)
        XCTAssertTrue(applied.startHidden)
        XCTAssertFalse(applied.alwaysOnTop)
        XCTAssertEqual(TransferCodec.differingSettingsCount(back, local), 1)
    }

    func testUnknownSettingsFieldsAreSkipped() throws {
        // Hand-built block: unknown varint (field 40), fixed (41), delimited (42), then focus = 30 min.
        var w = ByteWriter()
        w.key(40, 0); w.varint(300)
        w.key(41, 1); w.bytes([1, 2, 3])
        w.key(42, 2); w.string("future")
        w.key(1, 0); w.varint(1800)
        let s = try TransferCodec.decodeSettings(w.out)
        XCTAssertEqual(s.focusMinutes, 30)
    }

    // MARK: Log

    func testRealisticLogRoundTrip() throws {
        var log: [SessionLogEntry] = []
        let base: Int64 = 1_787_000_000
        log += pomodoro(at: base, task: "writing")
        log += pomodoro(at: base + 9000, task: "writing", friend: "onanippi")
        log += pomodoro(at: base + 90_000, task: "email", skipLast: true)
        log += pomodoro(at: base + 99_000, task: "")
        let back = try roundTrip(log)
        XCTAssertEqual(back, log)
    }

    func testBreakingEachDerivationRule() throws {
        let base: Int64 = 1_787_000_000
        let good = entry(start: base, pomodoro: base)
        func variant(_ e: SessionLogEntry, day: Int? = nil, minutes: Int? = nil, end: Date? = nil,
                     durationSeconds: Int?? = nil, number: Int?? = nil, task: String? = nil,
                     tz: String?? = nil, friend: String?? = nil, count: Int?? = nil,
                     planned: Int?? = nil, paused: Int?? = nil) -> SessionLogEntry {
            SessionLogEntry(
                phase: e.phase, task: task ?? e.task, day: day ?? e.day, month: e.month, year: e.year,
                startTime: e.startTime, endTime: end ?? e.endTime, durationMinutes: minutes ?? e.durationMinutes,
                completed: e.completed, durationSeconds: durationSeconds ?? e.durationSeconds,
                pomodoroStart: e.pomodoroStart, plannedSeconds: planned ?? e.plannedSeconds,
                pausedSeconds: paused ?? e.pausedSeconds, focusNumber: number ?? e.focusNumber,
                focusCount: count ?? e.focusCount, timeZone: tz ?? e.timeZone, appVersion: e.appVersion,
                friend: friend ?? e.friend)
        }
        let second = entry("shortBreak", start: base + 1500, planned: 300, pomodoro: base)
        let cases: [(String, SessionLogEntry)] = [
            ("day", variant(good, day: 3)),
            ("minutes", variant(good, minutes: 99)),
            ("end", variant(good, end: date(base + 7777))),
            ("durationSeconds nil", variant(good, durationSeconds: .some(nil))),
            ("length != planned", variant(good, durationSeconds: 1499, planned: 1500)),
            ("planned nil", variant(good, planned: .some(nil))),
            ("paused nil", variant(good, paused: .some(nil))),
            ("focus number", variant(good, number: 9)),
            ("focus number nil", variant(good, number: .some(nil))),
            ("task", variant(good, task: "other")),
            ("friend", variant(good, friend: "gemuppin")),
            ("friend unknown", variant(good, friend: "newpal")),
            ("friend nil", variant(good, friend: .some(nil))),
            ("timeZone", variant(good, tz: "Asia/Tokyo")),
            ("timeZone nil", variant(good, tz: .some(nil))),
            ("focus count", variant(good, count: 6)),
            ("focus count nil", variant(good, count: .some(nil))),
        ]
        for (name, broken) in cases {
            // second entry carries the pomodoro defaults; broken one is first and second in turn
            for log in [[broken, second], [good, variant(second, day: 31, number: 5, task: "x")], [second, broken]] {
                XCTAssertEqual(try roundTrip(log), log, name)
            }
        }
    }

    func testLegacyishEntriesWithoutOptionals() throws {
        let legacy = SessionLogEntry(
            phase: "focus", task: "old", day: 19, month: 9, year: 2026,
            startTime: date(1_787_000_000), endTime: date(1_787_001_500),
            durationMinutes: 25, completed: true)
        let other = SessionLogEntry(
            phase: "longBreak", task: "", day: 20, month: 9, year: 2026,
            startTime: date(1_787_090_000), endTime: date(1_787_090_900),
            durationMinutes: 15, completed: false)
        let odd = SessionLogEntry(
            phase: "custom", task: "ø ünïcode ✓", day: 1, month: 1, year: 1999,
            startTime: date(1_787_100_000), endTime: date(1_787_100_100),
            durationMinutes: 0, completed: false, durationSeconds: 100, friend: "")
        let log = [legacy, other, odd]
        XCTAssertEqual(try roundTrip(log), log)
        XCTAssertNil(try roundTrip(log).first?.pomodoroStart)
        XCTAssertEqual(try roundTrip([]), [])
    }

    func testFractionalDateIsRefused() {
        var e = entry(start: 1_787_000_000, pomodoro: 1_787_000_000)
        e = SessionLogEntry(
            phase: e.phase, task: e.task, day: e.day, month: e.month, year: e.year,
            startTime: Date(timeIntervalSince1970: 1_787_000_000.5), endTime: e.endTime,
            durationMinutes: e.durationMinutes, completed: e.completed)
        XCTAssertThrowsError(try TransferCodec.encode(settings: .defaults, sessions: [e])) {
            XCTAssertEqual($0 as? TransferError, .selfCheckFailed)
        }
    }

    // MARK: Options

    func testOptions() throws {
        let base: Int64 = 1_787_000_000
        let log = pomodoro(at: base, task: "writing", skipLast: true)
            + [entry("focus", start: base + 20_000, actual: 20, task: "tiny", pomodoro: base + 20_000)]
        let all = try TransferCodec.encode(settings: .defaults, sessions: log)
        XCTAssertEqual(try TransferCodec.decode(all).sessions, log)

        let noSettings = try TransferCodec.decode(try TransferCodec.encode(settings: .defaults, sessions: log, options: TransferOptions(settings: false)))
        XCTAssertNil(noSettings.settings)
        let noLog = try TransferCodec.decode(try TransferCodec.encode(settings: .defaults, sessions: log, options: TransferOptions(log: false)))
        XCTAssertNil(noLog.sessions)

        let noTitles = try TransferCodec.decode(try TransferCodec.encode(settings: .defaults, sessions: log, options: TransferOptions(titles: false)))
        XCTAssertFalse(noTitles.titlesIncluded)
        XCTAssertTrue(try XCTUnwrap(noTitles.sessions).allSatisfy { $0.task.isEmpty })
        XCTAssertEqual(noTitles.sessions?.count, log.count)

        let noSkips = try TransferCodec.decode(try TransferCodec.encode(settings: .defaults, sessions: log, options: TransferOptions(subMinuteSkips: false)))
        XCTAssertFalse(noSkips.subMinuteSkipsIncluded)
        XCTAssertFalse(try XCTUnwrap(noSkips.sessions).contains { $0.task == "tiny" })
        XCTAssertEqual(noSkips.sessions?.count, log.count - 1)

        let noDetails = try TransferCodec.decode(try TransferCodec.encode(settings: .defaults, sessions: log, options: TransferOptions(details: false)))
        XCTAssertFalse(noDetails.detailsIncluded)
        for e in try XCTUnwrap(noDetails.sessions) {
            XCTAssertNil(e.pausedSeconds); XCTAssertNil(e.appVersion); XCTAssertNil(e.timeZone)
        }
        // day/month/year survive details being off; the end moves in by the
        // dropped paused time
        XCTAssertEqual(noDetails.sessions?.map(\.day), log.map(\.day))
        XCTAssertEqual(noDetails.sessions?.map(\.endTime), log.map { $0.endTime.addingTimeInterval(-Double($0.pausedSeconds ?? 0)) })
    }

    // MARK: Container

    func testCorruptedByteIsBadChecksum() throws {
        var data = [UInt8](try TransferCodec.encode(settings: .defaults, sessions: pomodoro(at: 1_787_000_000, task: "a")))
        data[data.count / 2] ^= 0x10
        XCTAssertThrowsError(try TransferCodec.decode(Data(data))) { XCTAssertEqual($0 as? TransferError, .badChecksum) }
        XCTAssertThrowsError(try TransferCodec.decode(Data())) { XCTAssertEqual($0 as? TransferError, .malformed) }
    }

    private func sealed(_ body: [UInt8]) -> Data {
        Data(body + SHA256.hash(Data(body)).prefix(4))
    }

    func testVersionTwoIsUnsupported() {
        XCTAssertThrowsError(try TransferCodec.decode(sealed([2, 0]))) { XCTAssertEqual($0 as? TransferError, .unsupportedVersion) }
    }

    func testMultipartBitAndUnknownFlags() {
        XCTAssertThrowsError(try TransferCodec.decode(sealed([1, 1 << 5]))) { XCTAssertEqual($0 as? TransferError, .multipart) }
        XCTAssertThrowsError(try TransferCodec.decode(sealed([1, 1 << 6]))) { XCTAssertEqual($0 as? TransferError, .malformed) }
    }

    func testTextCode() throws {
        let data = try TransferCodec.encode(settings: .defaults, sessions: pomodoro(at: 1_787_000_000, task: "a"))
        let code = TransferCodec.textCode(data)
        XCTAssertTrue(code.hasPrefix("pomoppi1-"))
        XCTAssertFalse(code.contains(where: { "+/= \n".contains($0) }))
        XCTAssertEqual(try TransferCodec.data(fromTextCode: "  \n" + code + "\n "), data)
        for bad in ["", "hello", "pomoppi1-", "pomoppi1-!!!", "pomoppi1-ab cd", String(code.dropFirst(9)), "pomoppi2-AAAA"] {
            XCTAssertThrowsError(try TransferCodec.data(fromTextCode: bad), bad) { XCTAssertEqual($0 as? TransferError, .notACode) }
        }
        XCTAssertEqual(TransferCodec.size(of: data), TransferSize(bytes: data.count, textCodeLength: code.count))
    }

    // MARK: Merge

    func testMergeIsIdempotentAndKeepsLocalPomodoros() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PomoppiTransferTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { .defaults }, storageDir: dir)
        let base: Int64 = 1_787_000_000
        let local = pomodoro(at: base + 50_000, task: "local only")
        let shared = pomodoro(at: base + 100_000, task: "shared")
        let remoteOnly = pomodoro(at: base, task: "remote")

        // seed the local log through a first merge
        let seeded = await logger.mergeImported(local + shared)
        XCTAssertEqual(seeded.addedPomodoros, 2)

        let preview = logger.previewImport(shared + remoteOnly)
        XCTAssertEqual(preview.totalPomodoros, 2)
        XCTAssertEqual(preview.newPomodoros, 1)
        XCTAssertEqual(preview.newEntries, remoteOnly.count)

        let first = await logger.mergeImported(shared + remoteOnly)
        XCTAssertEqual(first.addedPomodoros, 1)
        XCTAssertEqual(first.addedEntries, remoteOnly.count)
        let after = logger.allSessionsSync()
        XCTAssertEqual(after.count, local.count + shared.count + remoteOnly.count)
        XCTAssertEqual(after.map(\.startTime), after.map(\.startTime).sorted())
        XCTAssertEqual(after.first?.task, "remote")
        XCTAssertTrue(after.contains { $0.task == "local only" })

        let again = await logger.mergeImported(shared + remoteOnly)
        XCTAssertEqual(again.addedPomodoros, 0)
        XCTAssertEqual(again.addedEntries, 0)
        XCTAssertEqual(logger.allSessionsSync(), after)
    }

    // MARK: Sizes

    func testSizeReportOnDevSample() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".dev-app-support/sessions.json")
        guard let json = try? Data(contentsOf: url) else { throw XCTSkip("no dev sample") }
        struct File: Decodable { let sessions: [SessionLogEntry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = try decoder.decode(File.self, from: json).sessions

        let data = try TransferCodec.encode(settings: .defaults, sessions: sessions)
        print("TRANSFER dev sample: \(sessions.count) entries, \(data.count) bytes, text code \(TransferCodec.textCode(data).count) chars")
        XCTAssertLessThan(data.count, 3 * 1024)
        XCTAssertEqual(try TransferCodec.decode(data).sessions, sessions)

        for (name, o) in [("no titles", TransferOptions(titles: false)), ("no details", TransferOptions(details: false)),
                          ("no titles/details", TransferOptions(titles: false, details: false))] {
            print("TRANSFER dev sample \(name): \(try TransferCodec.encode(settings: .defaults, sessions: sessions, options: o).count) bytes")
        }
        let s = try TransferCodec.encode(settings: .defaults, sessions: [], options: TransferOptions(log: false))
        print("TRANSFER defaults-only settings: \(s.count) bytes")
    }
}
