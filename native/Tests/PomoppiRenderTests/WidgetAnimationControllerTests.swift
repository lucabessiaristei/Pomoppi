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

    private func ringingTimerState() -> TimerState {
        var now = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: { self.settingsSnapshot() }, now: { now })
        timer.start()
        now = now.addingTimeInterval(25 * 60)
        return timer.tick()
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

    func testWanderStepsOnlyOnPoseChangeWhenPetMovementEnabled() {
        let controller = WidgetAnimationController()
        var settings = PomoppiSettings.defaults
        settings.petMovement = true

        controller.tick(dt: 1, state: idleTimerState(), settings: settings)
        let firstX = controller.snapshot.wanderX
        XCTAssertEqual(firstX, WidgetLayout.wanderMinX)

        controller.tick(dt: 520, state: idleTimerState(), settings: settings)
        XCTAssertNotEqual(controller.snapshot.wanderX, firstX, "a pose change should advance the wander position")
    }

    func testWanderNeverAdvancesWhenPetMovementDisabled() {
        let controller = WidgetAnimationController()
        controller.tick(dt: 1, state: idleTimerState(), settings: .defaults)
        controller.tick(dt: 1000, state: idleTimerState(), settings: .defaults)
        XCTAssertNil(controller.snapshot.wanderX)
    }
}
