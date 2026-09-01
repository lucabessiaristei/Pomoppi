import XCTest
import PomoppiCore
@testable import PomoppiRender

final class WidgetAnimationControllerTests: XCTestCase {
    private func settingsSnapshot() -> TimerSettingsSnapshot {
        TimerSettingsSnapshot(
            focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakEvery: 4,
            autoStartBreaks: true, autoStartFocus: false, ringSeconds: 10)
    }

    private func idleTimerState() -> TimerState {
        PomodoroTimer(settingsGetter: { self.settingsSnapshot() }).getState()
    }

    private func runningTimerState() -> TimerState {
        let timer = PomodoroTimer(settingsGetter: { self.settingsSnapshot() })
        return timer.start()
    }

    private func ringingTimerState() -> TimerState {
        var now = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.settingsSnapshot() }, now: { now })
        timer.start()
        now = now.addingTimeInterval(25 * 60)
        return timer.tick()
    }

    private func pausedTimerState() -> TimerState {
        let timer = PomodoroTimer(settingsGetter: { self.settingsSnapshot() })
        timer.start()
        return timer.pause()
    }

    func testAnimClockAccumulatesRegardlessOfState() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 100, state: idleTimerState(), settings: .defaults)
        controller.tick(dt: 50, state: idleTimerState(), settings: .defaults)
        XCTAssertEqual(controller.snapshot.animClock, 150)
    }

    func testShakeOffsetCyclesWhileRinging() {
        let controller = WidgetAnimationController()
        let ringing = ringingTimerState()
        controller.tick(dt: 10, state: ringing, settings: .defaults)
        XCTAssertEqual(controller.snapshot.shakeOffset, -1)
        controller.tick(dt: 90, state: ringing, settings: .defaults)
        XCTAssertEqual(controller.snapshot.shakeOffset, 0)
        controller.tick(dt: 90, state: ringing, settings: .defaults)
        XCTAssertEqual(controller.snapshot.shakeOffset, 1)
    }

    func testShakeAndRingTimeResetWhenNotRinging() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 500, state: ringingTimerState(), settings: .defaults)
        XCTAssertGreaterThan(controller.snapshot.ringTime, 0)
        controller.tick(dt: 10, state: idleTimerState(), settings: .defaults)
        XCTAssertEqual(controller.snapshot.ringTime, 0)
        XCTAssertEqual(controller.snapshot.shakeOffset, 0)
    }

    func testWanderStepsOnlyOnPoseChangeWhileRunning() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 1, state: runningTimerState(), settings: .defaults)
        let firstX = controller.snapshot.wanderX
        XCTAssertEqual(firstX, WidgetLayout.wanderMinX)

        controller.tick(dt: 520, state: runningTimerState(), settings: .defaults)
        XCTAssertNotEqual(controller.snapshot.wanderX, firstX, "a pose change should advance the wander position")
    }

    func testWanderNeverAdvancesWhileIdle() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 1, state: idleTimerState(), settings: .defaults)
        controller.tick(dt: 1000, state: idleTimerState(), settings: .defaults)
        XCTAssertNil(controller.snapshot.wanderX)
    }

    func testWanderResetsToFreshStateWhenSessionStops() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 1, state: runningTimerState(), settings: .defaults)
        controller.tick(dt: 520, state: runningTimerState(), settings: .defaults)
        XCTAssertNotEqual(controller.snapshot.wanderX, WidgetLayout.wanderMinX, "should have taken at least one step")

        controller.tick(dt: 1, state: idleTimerState(), settings: .defaults)
        XCTAssertNil(controller.snapshot.wanderX, "stopping clears the wander position")

        controller.tick(dt: 1, state: runningTimerState(), settings: .defaults)
        XCTAssertEqual(controller.snapshot.wanderX, WidgetLayout.wanderMinX, "restarting begins from centre again")
    }

    // wanderUp used to be a flag toggled once per step and reset to `true`
    // whenever a session (re)started — but animClock keeps ticking even
    // while idle, so by the time a session restarts its pose parity could
    // already be odd, and forcing wanderUp back to `true` then drew the
    // "up" bob over the frame that actually reads as the down pose. It must
    // instead track the pose index's own parity so it always matches
    // whatever frame is actually on screen, restart timing notwithstanding.
    func testWanderUpTracksPoseParityEvenAfterAnIdleGapShiftsIt() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 341, state: idleTimerState(), settings: .defaults)

        controller.tick(dt: 1, state: runningTimerState(), settings: .defaults)
        XCTAssertEqual(controller.snapshot.animClock, 342)
        XCTAssertEqual(controller.snapshot.wanderUp, false, "pose 1 (odd) is the down frame, even though the session only just started")
    }

    func testPauseFreezesWanderInPlaceAndResumeContinuesFromThere() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 1, state: runningTimerState(), settings: .defaults)
        controller.tick(dt: 520, state: runningTimerState(), settings: .defaults)
        let steppedX = controller.snapshot.wanderX
        XCTAssertNotEqual(steppedX, WidgetLayout.wanderMinX, "should have taken at least one step")

        controller.tick(dt: 1, state: pausedTimerState(), settings: .defaults)
        XCTAssertEqual(controller.snapshot.wanderX, steppedX, "pausing should freeze the pet in place, not reset it")

        controller.tick(dt: 1, state: runningTimerState(), settings: .defaults)
        XCTAssertEqual(controller.snapshot.wanderX, steppedX, "resuming should continue from where it paused, not restart from the edge")
    }

    func testPauseFreezesZzzFrameDuringBreak() {
        let controller = WidgetAnimationController()
        let timer = PomodoroTimer(settingsGetter: { self.settingsSnapshot() })
        timer.start()
        let breakState = timer.skip() // focus -> short break, auto-running

        controller.tick(dt: 1, state: breakState, settings: .defaults)
        controller.tick(dt: 500, state: breakState, settings: .defaults)
        let frameBeforePause = controller.snapshot.zFrameIndex

        let pausedBreakState = timer.pause()
        controller.tick(dt: 1000, state: pausedBreakState, settings: .defaults)
        XCTAssertEqual(controller.snapshot.zFrameIndex, frameBeforePause, "pausing during a break should freeze the Zzz's, not keep animating them")

        controller.tick(dt: 500, state: timer.start(), settings: .defaults)
        XCTAssertNotEqual(controller.snapshot.zFrameIndex, frameBeforePause, "resuming should continue animating the Zzz's again")
    }
}
