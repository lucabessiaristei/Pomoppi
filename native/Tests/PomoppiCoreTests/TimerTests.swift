import XCTest
@testable import PomoppiCore

final class TimerTests: XCTestCase {
    private func defaultSettings(
        longBreakEvery: Int = 4,
        autoStartBreaks: Bool = true,
        autoStartFocus: Bool = false,
        ringSeconds: Double = 10
    ) -> TimerSettingsSnapshot {
        TimerSettingsSnapshot(
            focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15,
            longBreakEvery: longBreakEvery, autoStartBreaks: autoStartBreaks,
            autoStartFocus: autoStartFocus, ringSeconds: ringSeconds)
    }

    func testIdleReportsFocusDurationAsPreview() {
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { Date(timeIntervalSince1970: 0) })
        let state = timer.getState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.remainingMs, 25 * 60_000)
        XCTAssertEqual(state.totalMs, 25 * 60_000)
    }

    func testPauseThenResumePreservesRemainingTimeAcrossAGap() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })

        timer.start()
        current = current.addingTimeInterval(60) // 1 minute of focus elapses
        let paused = timer.pause()
        XCTAssertEqual(paused.remainingMs, 24 * 60_000, accuracy: 1)

        current = current.addingTimeInterval(3600) // an hour passes while paused
        XCTAssertEqual(timer.getState().remainingMs, 24 * 60_000, accuracy: 1)

        timer.start() // resume
        current = current.addingTimeInterval(30)
        XCTAssertEqual(timer.getState().remainingMs, 24 * 60_000 - 30_000, accuracy: 1)
    }

    func testSkipDuringFocusGivesNoCycleCreditAndMovesToShortBreak() {
        var current = Date(timeIntervalSince1970: 0)
        var completedEvents: [PhaseCompleteEvent] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })
        timer.onPhaseComplete = { completedEvents.append($0) }

        timer.start()
        current = current.addingTimeInterval(120)
        let state = timer.skip()

        XCTAssertEqual(state.phase, .shortBreak)
        XCTAssertEqual(state.cycleIndex, 0)
        XCTAssertEqual(state.completedToday, 0)
        XCTAssertEqual(completedEvents.count, 1)
        XCTAssertFalse(completedEvents[0].completed)
        XCTAssertEqual(completedEvents[0].actualMs, 120_000, accuracy: 1)
    }

    func testTickCompletesFocusPhaseAndStartsRinging() {
        var current = Date(timeIntervalSince1970: 0)
        var completedEvents: [PhaseCompleteEvent] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })
        timer.onPhaseComplete = { completedEvents.append($0) }

        timer.start()
        current = current.addingTimeInterval(25 * 60) // full focus duration elapses
        let state = timer.tick()

        XCTAssertTrue(state.ringing)
        XCTAssertEqual(state.phase, .shortBreak)
        XCTAssertEqual(state.cycleIndex, 1)
        XCTAssertEqual(state.completedToday, 1)
        XCTAssertEqual(completedEvents.count, 1)
        XCTAssertTrue(completedEvents[0].completed)
    }

    func testDayRolloverResetsCompletedToday() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })

        timer.start()
        current = current.addingTimeInterval(25 * 60)
        _ = timer.tick() // completes one focus session "today"
        XCTAssertEqual(timer.getState().completedToday, 1)

        current = current.addingTimeInterval(24 * 60 * 60) // next calendar day
        XCTAssertEqual(timer.getState().completedToday, 0)
    }
}
