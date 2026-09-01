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
        XCTAssertEqual(controller.snapshot.wanderUp, true, "restarting always steps up first")
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
}
