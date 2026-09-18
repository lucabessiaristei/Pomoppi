import XCTest
@testable import PomoppiCore

final class SessionLoggerTests: XCTestCase {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PomoppiSessionLoggerTests-\(UUID().uuidString)")
    }

    private func makeEntry(
        phase: Phase = .focus, plannedMs: Double = 25 * 60_000, actualMs: Double = 25 * 60_000,
        task: String = "", completed: Bool = true
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
            plannedMs: plannedMs, actualMs: actualMs, task: task, completed: completed)
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
}
