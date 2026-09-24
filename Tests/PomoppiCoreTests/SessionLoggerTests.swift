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

    // A pre-0.4.0 log (no "version") loses its entries without a
    // pomodoroStart once and gets stamped; from then on nothing is removed,
    // not even an entry that somehow lacks the field.
    func testMigrateLegacyLogDeletesOnceThenNeverAgain() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func entry(_ task: String, pomodoro: String?) -> String {
            let extra = pomodoro.map { ", \"pomodoroStart\": \"\($0)\"" } ?? ""
            return "{\"phase\": \"focus\", \"task\": \"\(task)\", \"day\": 19, \"month\": 9, \"year\": 2026, "
                + "\"startTime\": \"2026-09-19T09:00:00Z\", \"endTime\": \"2026-09-19T09:25:00Z\", "
                + "\"durationMinutes\": 25, \"completed\": true\(extra)}"
        }
        let url = dir.appendingPathComponent("sessions.json")
        let legacy = "{\"sessions\": [" + [
            entry("old 1", pomodoro: nil),
            entry("new", pomodoro: "2026-09-19T09:00:00Z"),
            entry("old 2", pomodoro: nil),
        ].joined(separator: ", ") + "]}"
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)
        let removed = await logger.migrateLegacyLog()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(logger.allSessionsSync().map(\.task), ["new"])
        let stamped = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(stamped["version"] as? Int, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sessions-legacy.json").path))

        // A versioned file is never cleaned, even with an entry lacking the field.
        let versioned = "{\"version\": 2, \"sessions\": [" + entry("kept", pomodoro: nil) + "]}"
        try versioned.write(to: url, atomically: true, encoding: .utf8)
        let removedAgain = await logger.migrateLegacyLog()
        XCTAssertEqual(removedAgain, 0)
        XCTAssertEqual(logger.allSessionsSync().map(\.task), ["kept"])
    }

    func testNewAndErasedLogsAreVersionedSoTheyAreNeverMigrated() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sessions.json")
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)

        _ = await logger.logSession(makeEntry(task: "fresh"))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 2)
        let removed = await logger.migrateLegacyLog()
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(logger.allSessionsSync().count, 1)

        logger.eraseAllSync()
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 2)
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

    func testEntriesRecordFocusNumberCountPlannedPausedZoneAndVersion() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = SessionLogger(getSettings: { PomoppiSettings.defaults.clamped() }, storageDir: dir)
        var event = makeEntry(plannedMs: 25 * 60_000, actualMs: 10 * 60_000, completed: false, pomodoroStart: Date(timeIntervalSince1970: 1_758_267_300))
        event = PhaseCompleteEvent(
            phase: event.phase, startedAt: event.startedAt, endedAt: event.endedAt,
            plannedMs: event.plannedMs, actualMs: event.actualMs, task: event.task, completed: event.completed,
            pomodoroStartedAt: event.pomodoroStartedAt, focusNumber: 2, focusCount: 4, pausedMs: 90_000)
        _ = await logger.logSession(event)

        let entry = logger.allSessionsSync()[0]
        XCTAssertEqual(entry.durationSeconds, 600)
        XCTAssertEqual(entry.plannedSeconds, 1500)
        XCTAssertEqual(entry.pausedSeconds, 90)
        XCTAssertEqual(entry.focusNumber, 2)
        XCTAssertEqual(entry.focusCount, 4)
        XCTAssertEqual(entry.timeZone, Calendar.current.timeZone.identifier)
        XCTAssertEqual(entry.appVersion, pomoppiVersion)
    }
}
