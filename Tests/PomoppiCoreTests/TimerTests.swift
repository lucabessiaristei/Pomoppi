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

    // 1. Skip focus mid-way (>= 60s of real elapsed time): logged as not
    // completed with the real actual duration and the pomodoro's start, the
    // dot still fills, and the short break starts running immediately
    // (skip() bypasses autoStartBreaks).
    func testSkipFocusMidwayFillsDotAndMovesToRunningShortBreak() {
        var current = Date(timeIntervalSince1970: 0)
        let pomodoroStart = current
        var completedEvents: [PhaseCompleteEvent] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })
        timer.onPhaseComplete = { completedEvents.append($0) }

        timer.start()
        current = current.addingTimeInterval(90) // well over the 60s floor
        let state = timer.skip()

        XCTAssertEqual(completedEvents.count, 1)
        XCTAssertFalse(completedEvents[0].completed)
        XCTAssertEqual(completedEvents[0].actualMs, 90_000, accuracy: 1)
        XCTAssertEqual(completedEvents[0].pomodoroStartedAt, pomodoroStart)

        XCTAssertEqual(state.phase, .shortBreak)
        XCTAssertTrue(state.running, "skip() bypasses autoStartBreaks and always moves on running")
        XCTAssertEqual(state.cycleIndex, 1)
        XCTAssertEqual(state.completedToday, 1)
    }

    // 2. Skip focus under 60s: the dot still fills (cycleIndex still
    // counts it as "done"), but it's not worth a completedToday credit.
    func testSkipFocusUnderAMinuteStillFillsDotButDoesNotCountForToday() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })

        timer.start()
        current = current.addingTimeInterval(30) // under the 60s floor
        let state = timer.skip()

        XCTAssertEqual(state.cycleIndex, 1)
        XCTAssertEqual(state.completedToday, 0)
    }

    // 3. Skipping the last focus of the pomodoro (with a skipped short
    // break in between) moves straight to the long break, dots staying
    // full at longBreakEvery.
    func testSkippingTheLastFocusMovesToLongBreakWithCycleIndexAtLongBreakEvery() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings(longBreakEvery: 2) }, now: { current })

        timer.start()
        current = current.addingTimeInterval(90)
        var state = timer.skip() // focus 1 -> shortBreak, cycleIndex 1
        XCTAssertEqual(state.phase, .shortBreak)
        XCTAssertEqual(state.cycleIndex, 1)

        current = current.addingTimeInterval(30)
        state = timer.skip() // shortBreak -> focus, running
        XCTAssertEqual(state.phase, .focus)
        XCTAssertTrue(state.running)

        current = current.addingTimeInterval(90)
        state = timer.skip() // focus 2 (the last one) -> longBreak

        XCTAssertEqual(state.phase, .longBreak)
        XCTAssertEqual(state.cycleIndex, 2, "the dots stay full through the long break")
        XCTAssertTrue(state.running)
    }

    // 4. Skipping the long break ends the pomodoro: back to idle, dots
    // emptied, task cleared, not running. The next start() begins a fresh
    // pomodoro with a new pomodoroStartedAt.
    func testSkippingTheLongBreakEndsThePomodoroAndTheNextStartGetsAFreshPomodoroStartedAt() {
        var current = Date(timeIntervalSince1970: 0)
        var completedEvents: [PhaseCompleteEvent] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings(longBreakEvery: 1) }, now: { current })
        timer.onPhaseComplete = { completedEvents.append($0) }

        timer.start()
        timer.setTask("write spec")
        current = current.addingTimeInterval(90)
        _ = timer.skip() // focus -> longBreak directly, longBreakEvery 1
        let firstPomodoroStart = completedEvents[0].pomodoroStartedAt

        current = current.addingTimeInterval(60)
        let state = timer.skip() // longBreak -> idle

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.cycleIndex, 0)
        XCTAssertEqual(state.task, "")
        XCTAssertFalse(state.running)

        current = current.addingTimeInterval(120) // some time passes before the next pomodoro
        timer.start()
        current = current.addingTimeInterval(90)
        _ = timer.skip()

        // completedEvents so far: [0] the focus just skipped into the long
        // break, [1] the long break itself being skipped (still carrying
        // the first pomodoro's start), [2] the new pomodoro's focus.
        XCTAssertEqual(completedEvents.count, 3)
        let secondPomodoroStart = completedEvents[2].pomodoroStartedAt
        XCTAssertNotNil(secondPomodoroStart)
        XCTAssertNotEqual(secondPomodoroStart, firstPomodoroStart)
    }

    // 5. Skipping a short break moves straight to a running focus.
    func testSkippingShortBreakMovesToRunningFocus() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })

        timer.start()
        current = current.addingTimeInterval(90)
        _ = timer.skip() // focus -> shortBreak
        current = current.addingTimeInterval(30)
        let state = timer.skip() // shortBreak -> focus

        XCTAssertEqual(state.phase, .focus)
        XCTAssertTrue(state.running)
    }

    // 6. A naturally completed long break ends the pomodoro once its ring
    // is dismissed, and never auto-starts the next focus even when
    // autoStartFocus is on -- a pomodoro only ever starts by the user.
    func testNaturalLongBreakCompletionReturnsToIdleEvenWithAutoStartFocusOn() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(
            settingsGetter: { self.defaultSettings(longBreakEvery: 1, autoStartBreaks: true, autoStartFocus: true) },
            now: { current })

        timer.start()
        current = current.addingTimeInterval(25 * 60)
        _ = timer.tick() // focus completes naturally -> rings
        timer.dismissRing() // -> longBreak, auto-started (it's a break)
        XCTAssertEqual(timer.getState().phase, .longBreak)
        XCTAssertTrue(timer.getState().running)

        current = current.addingTimeInterval(15 * 60)
        _ = timer.tick() // longBreak completes naturally -> rings
        let ringing = timer.getState()
        XCTAssertTrue(ringing.ringing)

        let state = timer.dismissRing() // -> idle, never auto-started

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.cycleIndex, 0)
        XCTAssertFalse(state.running)
    }

    // 7. The task name is the pomodoro's title: it survives focus -> break
    // -> focus within the same pomodoro, cleared only when the pomodoro
    // itself ends.
    func testTaskPersistsAcrossFocusAndBreakWithinAPomodoro() {
        var current = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })

        timer.start()
        timer.setTask("write spec")
        current = current.addingTimeInterval(25 * 60)
        _ = timer.tick()
        timer.dismissRing() // -> shortBreak
        XCTAssertEqual(timer.getState().phase, .shortBreak)
        XCTAssertEqual(timer.getState().task, "write spec")

        current = current.addingTimeInterval(5 * 60)
        _ = timer.tick()
        timer.dismissRing() // -> focus again, same pomodoro
        XCTAssertEqual(timer.getState().phase, .focus)
        XCTAssertEqual(timer.getState().task, "write spec")
    }

    func testTickCompletesFocusPhaseAndStartsRinging() {
        var current = Date(timeIntervalSince1970: 0)
        var completedEvents: [PhaseCompleteEvent] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })
        timer.onPhaseComplete = { completedEvents.append($0) }

        timer.start()
        current = current.addingTimeInterval(25 * 60) // full focus duration elapses
        let state = timer.tick()

        // The phase switch to shortBreak (and any auto-start of it) is held
        // back until the ring is silenced — see completePhase()/
        // advancePendingPhase() — so the break/Zzz animation never starts
        // while the end-of-session ring/shake is still playing.
        XCTAssertTrue(state.ringing)
        XCTAssertEqual(state.phase, .focus)
        XCTAssertEqual(state.cycleIndex, 1)
        XCTAssertEqual(state.completedToday, 1)
        XCTAssertEqual(completedEvents.count, 1)
        XCTAssertTrue(completedEvents[0].completed)

        current = current.addingTimeInterval(self.defaultSettings().ringSeconds)
        let afterRing = timer.tick()
        XCTAssertFalse(afterRing.ringing)
        XCTAssertEqual(afterRing.phase, .shortBreak)
        XCTAssertTrue(afterRing.running, "autoStartBreaks is true by default")
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

    // 8. reset() mid-pomodoro discards it: no phaseComplete event for the
    // reset itself, onPomodoroDiscarded fires once with the pomodoro's
    // start, and completedToday is given back whatever this pomodoro added.
    func testResetMidPomodoroDiscardsAndRollsBackCompletedToday() {
        var current = Date(timeIntervalSince1970: 0)
        let pomodoroStart = current
        var completedEvents: [PhaseCompleteEvent] = []
        var discarded: [Date] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { current })
        timer.onPhaseComplete = { completedEvents.append($0) }
        timer.onPomodoroDiscarded = { discarded.append($0) }

        timer.start()
        timer.setTask("write spec")
        current = current.addingTimeInterval(25 * 60)
        _ = timer.tick() // focus completes naturally
        timer.dismissRing() // -> shortBreak, auto-started
        XCTAssertEqual(timer.getState().completedToday, 1)
        let eventsBeforeReset = completedEvents.count

        current = current.addingTimeInterval(60)
        let state = timer.reset()

        XCTAssertEqual(completedEvents.count, eventsBeforeReset, "reset() must not emit a phaseComplete event")
        XCTAssertEqual(discarded, [pomodoroStart])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.cycleIndex, 0)
        XCTAssertEqual(state.task, "")
        XCTAssertEqual(state.completedToday, 0)
        XCTAssertFalse(state.running)
    }

    // 8b. reset() from idle, with no pomodoro under way, is a no-op and
    // never fires the discard callback.
    func testResetFromIdleIsANoOpAndFiresNoDiscardCallback() {
        var discarded = 0
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings() }, now: { Date(timeIntervalSince1970: 0) })
        timer.onPomodoroDiscarded = { _ in discarded += 1 }

        let state = timer.reset()

        XCTAssertEqual(discarded, 0)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.running)
    }

    func testEventsCarryFocusNumberFocusCountAndPausedTime() {
        var current = Date(timeIntervalSince1970: 0)
        var events: [PhaseCompleteEvent] = []
        let timer = PomodoroTimer(settingsGetter: { self.defaultSettings(longBreakEvery: 3) }, now: { current })
        timer.onPhaseComplete = { events.append($0) }

        timer.start()
        current = current.addingTimeInterval(120)
        timer.pause()
        current = current.addingTimeInterval(30)
        timer.start()
        current = current.addingTimeInterval(60)
        timer.skip() // focus 1 -> short break
        current = current.addingTimeInterval(10)
        timer.skip() // short break -> focus 2

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].phase, .focus)
        XCTAssertEqual(events[0].focusNumber, 1)
        XCTAssertEqual(events[0].focusCount, 3)
        XCTAssertEqual(events[0].pausedMs, 30_000, accuracy: 1)
        XCTAssertEqual(events[0].actualMs, 180_000, accuracy: 1)
        XCTAssertEqual(events[1].phase, .shortBreak)
        XCTAssertEqual(events[1].focusNumber, 1, "a break carries the focus it follows")
        XCTAssertEqual(events[1].pausedMs, 0, accuracy: 1)
    }
}
