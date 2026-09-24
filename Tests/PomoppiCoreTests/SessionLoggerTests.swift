import XCTest
@testable import PomoppiCore

final class SessionLoggerTests: XCTestCase {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PomoppiSessionLoggerTests-\(UUID().uuidString)")
    }

    private func makeEntry(
        phase: Phase = .focus, plannedMs: Double = 25 * 60_000, actualMs: Double = 25 * 60_000,
        task: String = "", completed: Bool = true, pomodoroStart: Date? = nil
    ) -> PhaseCompleteEvent {
        var startComponents = DateComponents()
        startComponents.year = 2026; startComponents.month = 9; startComponents.day = 19
        startComponents.hour = 9; startComponents.minute = 0
        var endComponents = startComponents
        endComponents.minute = 25
        let cal = Calendar.current
        let started = cal.date(from: startComponents)!
        let ended = cal.date(from: endComponents)!
        return PhaseCompleteEvent(
            phase: phase, startedAt: started, endedAt: ended,
            plannedMs: plannedMs, actualMs: actualMs, task: task, completed: completed,
            pomodoroStartedAt: pomodoroStart)
    }

    private func readSessions(at dir: URL) -> [[String: Any]] {
        let data = try! Data(contentsOf: dir.appendingPathComponent("sessions.json"))
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["sessions"] as! [[String: Any]]
    }

    func testLogSessionWritesAnEntryWhenEnabled() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        let ok = await logger.logSession(makeEntry(task: "Write the report"))
        XCTAssertTrue(ok)

        let sessions = readSessions(at: dir)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["task"] as? String, "Write the report")
        XCTAssertEqual(sessions[0]["phase"] as? String, "focus")
        XCTAssertEqual(sessions[0]["day"] as? Int, 19)
        XCTAssertEqual(sessions[0]["month"] as? Int, 9)
        XCTAssertEqual(sessions[0]["year"] as? Int, 2026)
        XCTAssertEqual(sessions[0]["durationMinutes"] as? Int, 25)
        XCTAssertEqual(sessions[0]["completed"] as? Bool, true)
    }

    func testLogSessionDoesNothingWhenLoggingDisabled() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var settings = PomoppiSettings.defaults
        settings.loggingEnabled = false
        let logger = SessionLogger(getSettings: { settings }, storageDir: dir)

        let ok = await logger.logSession(makeEntry())
        XCTAssertFalse(ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions.json").path))
    }

    func testMultipleSessionsAppendRatherThanOverwrite() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        _ = await logger.logSession(makeEntry(task: "First"))
        _ = await logger.logSession(makeEntry(phase: .shortBreak, plannedMs: 5 * 60_000, actualMs: 5 * 60_000, task: ""))

        XCTAssertEqual(readSessions(at: dir).count, 2)
    }

    func testAbortedSessionUsesActualMsForDuration() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        _ = await logger.logSession(makeEntry(actualMs: 12 * 60_000, completed: false))

        let sessions = readSessions(at: dir)
        XCTAssertEqual(sessions[0]["durationMinutes"] as? Int, 12)
        XCTAssertEqual(sessions[0]["completed"] as? Bool, false)
    }

    func testEraseAllEmptiesTheFile() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        _ = await logger.logSession(makeEntry())
        XCTAssertEqual(readSessions(at: dir).count, 1)

        let erased = await logger.eraseAll()
        XCTAssertTrue(erased)
        XCTAssertEqual(readSessions(at: dir).count, 0)
    }

    func testEraseAllSyncEmptiesTheFile() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        _ = await logger.logSession(makeEntry())
        logger.eraseAllSync()
        XCTAssertEqual(readSessions(at: dir).count, 0)
    }

    func testFileSizeBytesReflectsARealWrite() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        XCTAssertEqual(logger.fileSizeBytes(), 0)
        _ = await logger.logSession(makeEntry(task: "Write the report"))
        XCTAssertGreaterThan(logger.fileSizeBytes(), 0)
    }

    // 9. New entries carry durationSeconds (the exact elapsed length) and
    // pomodoroStart (the pomodoro they belong to), round-tripped through
    // the same ISO8601-in-JSON path logSession/allSessionsSync use.
    func testNewEntriesCarryDurationSecondsAndPomodoroStart() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        let pomodoroStart = Date(timeIntervalSince1970: 1_758_267_300)
        _ = await logger.logSession(makeEntry(actualMs: 90_000, completed: false, pomodoroStart: pomodoroStart))

        let sessions = logger.allSessionsSync()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].durationSeconds, 90)
        XCTAssertEqual(
            sessions[0].pomodoroStart.map { Int($0.timeIntervalSince1970) },
            Int(pomodoroStart.timeIntervalSince1970))
    }

    // 10. discardPomodoro(startedAt:) removes only that pomodoro's entries
    // and causes a later append for the same pomodoro (arriving after the
    // discard, since both are async) to be dropped too. Other pomodoros are
    // untouched.
    func testDiscardPomodoroRemovesItsEntriesAndDropsLateAppends() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        let pomodoroA = Date(timeIntervalSince1970: 1000)
        let pomodoroB = Date(timeIntervalSince1970: 2000)

        _ = await logger.logSession(makeEntry(task: "A focus", pomodoroStart: pomodoroA))
        _ = await logger.logSession(makeEntry(phase: .shortBreak, task: "", pomodoroStart: pomodoroA))
        _ = await logger.logSession(makeEntry(task: "B focus", pomodoroStart: pomodoroB))
        XCTAssertEqual(logger.allSessionsSync().count, 3)

        let ok = await logger.discardPomodoro(startedAt: pomodoroA)
        XCTAssertTrue(ok)

        let remaining = logger.allSessionsSync()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].task, "B focus")

        let dropped = await logger.logSession(makeEntry(task: "late focus A", pomodoroStart: pomodoroA))
        XCTAssertFalse(dropped, "an append for a discarded pomodoro that lands after the discard must be dropped")
        XCTAssertEqual(logger.allSessionsSync().count, 1)
    }

    // moveLegacyEntriesOut() is the one-time cleanup that moves entries with
    // no pomodoroStart out of sessions.json into sessions-legacy.json next
    // to it, leaving only entries a pomodoro can be built from behind.
    func testMoveLegacyEntriesOutArchivesEntriesWithNoPomodoroStart() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        let pomodoroStart = Date(timeIntervalSince1970: 1_758_267_300)
        _ = await logger.logSession(makeEntry(task: "legacy 1"))
        _ = await logger.logSession(makeEntry(phase: .shortBreak, task: "legacy 2"))
        _ = await logger.logSession(makeEntry(task: "current", pomodoroStart: pomodoroStart))
        XCTAssertEqual(logger.allSessionsSync().count, 3)

        let moved = await logger.moveLegacyEntriesOut()
        XCTAssertEqual(moved, 2)

        let remaining = logger.allSessionsSync()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].task, "current")

        struct DecodedLogFile: Decodable { let sessions: [SessionLogEntry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyData = try Data(contentsOf: dir.appendingPathComponent("sessions-legacy.json"))
        let legacyFile = try decoder.decode(DecodedLogFile.self, from: legacyData)
        XCTAssertEqual(legacyFile.sessions.count, 2)
        XCTAssertEqual(Set(legacyFile.sessions.map(\.task)), ["legacy 1", "legacy 2"])

        // A second call is a no-op: nothing left to move, and the archive
        // keeps exactly what the first call put there (append, not
        // overwrite, so a second run must not double it up).
        let secondMoved = await logger.moveLegacyEntriesOut()
        XCTAssertEqual(secondMoved, 0)

        let legacyDataAfterSecondRun = try Data(contentsOf: dir.appendingPathComponent("sessions-legacy.json"))
        let legacyFileAfterSecondRun = try decoder.decode(DecodedLogFile.self, from: legacyDataAfterSecondRun)
        XCTAssertEqual(legacyFileAfterSecondRun.sessions.count, 2)
    }

    // An old-format sessions.json (written before durationSeconds/
    // pomodoroStart existed) still decodes; the missing fields read back nil
    // and `seconds` falls back to durationMinutes * 60.
    func testOldFormatJSONWithoutDurationSecondsOrPomodoroStartDecodes() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldJSON = """
        {"sessions": [{
          "phase": "focus",
          "task": "old style entry",
          "day": 19, "month": 9, "year": 2026,
          "startTime": "2026-09-19T09:00:00Z",
          "endTime": "2026-09-19T09:25:00Z",
          "durationMinutes": 25,
          "completed": true
        }]}
        """
        try! oldJSON.write(to: dir.appendingPathComponent("sessions.json"), atomically: true, encoding: .utf8)

        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)
        let sessions = logger.allSessionsSync()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].task, "old style entry")
        XCTAssertNil(sessions[0].durationSeconds)
        XCTAssertNil(sessions[0].pomodoroStart)
        XCTAssertEqual(sessions[0].seconds, 25 * 60, "falls back to durationMinutes x 60")
    }

    // Entries logged before pomodoroStart existed are moved to
    // sessions-legacy.json (appended), and a second run is a no-op.
    func testMoveLegacyEntriesOutArchivesEntriesWithNoPomodoroStart() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        let pomodoroStart = Date(timeIntervalSince1970: 1_758_267_300)
        _ = await logger.logSession(makeEntry(task: "legacy 1"))
        _ = await logger.logSession(makeEntry(phase: .shortBreak, task: "legacy 2"))
        _ = await logger.logSession(makeEntry(task: "current", pomodoroStart: pomodoroStart))
        XCTAssertEqual(logger.allSessionsSync().count, 3)

        let moved = await logger.moveLegacyEntriesOut()
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(logger.allSessionsSync().map(\.task), ["current"])

        struct DecodedLogFile: Decodable { let sessions: [SessionLogEntry] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyURL = dir.appendingPathComponent("sessions-legacy.json")
        XCTAssertEqual(try decoder.decode(DecodedLogFile.self, from: Data(contentsOf: legacyURL)).sessions.map(\.task), ["legacy 1", "legacy 2"])

        let movedAgain = await logger.moveLegacyEntriesOut()
        XCTAssertEqual(movedAgain, 0)
        XCTAssertEqual(try decoder.decode(DecodedLogFile.self, from: Data(contentsOf: legacyURL)).sessions.count, 2)
    }
}
