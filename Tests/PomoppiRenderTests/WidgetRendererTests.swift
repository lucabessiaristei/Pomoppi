import XCTest
import PomoppiCore
@testable import PomoppiRender

final class WidgetRendererTests: XCTestCase {
    private func settingsSnapshot() -> TimerSettingsSnapshot {
        TimerSettingsSnapshot(
            focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakEvery: 4,
            autoStartBreaks: true, autoStartFocus: false, ringSeconds: 10)
    }

    func testRendersAtCanvasDimensions() {
        let timer = PomodoroTimer(settingsGetter: settingsSnapshot)
        let image = WidgetRenderer.draw(state: timer.getState(), settings: .defaults)
        XCTAssertEqual(image?.width, WidgetLayout.canvasWidth)
        XCTAssertEqual(image?.height, WidgetLayout.canvasHeight)
    }

    func testRenderIsNotBlank() {
        let timer = PomodoroTimer(settingsGetter: settingsSnapshot)
        let canvas = WidgetRenderer.drawCanvas(state: timer.getState(), settings: .defaults)

        var foundDrawnPixel = false
        outer: for y in stride(from: 0, to: canvas.height, by: 2) {
            for x in stride(from: 0, to: canvas.width, by: 2) {
                if let p = canvas.pixel(x: x, y: y), p.a > 0 {
                    foundDrawnPixel = true
                    break outer
                }
            }
        }
        XCTAssertTrue(foundDrawnPixel, "expected at least some drawn pixels")
    }

    func testRingingInvertsInkAndPaperOnTheProgressBarBorder() {
        var now = Date(timeIntervalSince1970: 0)
        let timer = PomodoroTimer(settingsGetter: settingsSnapshot, now: { now })
        timer.start()
        now = now.addingTimeInterval(25 * 60) // full focus duration elapses
        let ringingState = timer.tick()
        XCTAssertTrue(ringingState.ringing)

        // ringTime = 0 -> floor(0/300) % 2 == 0 -> not inverted.
        let normalCanvas = WidgetRenderer.drawCanvas(state: ringingState, settings: .defaults, animation: WidgetAnimationSnapshot(ringTime: 0))
        // ringTime = 300 -> floor(300/300) % 2 == 1 -> inverted.
        let invertedCanvas = WidgetRenderer.drawCanvas(state: ringingState, settings: .defaults, animation: WidgetAnimationSnapshot(ringTime: 300))

        // (progressX, progressY) itself is the rounded rect's omitted corner
        // pixel — drawRoundRect's border mode starts the top edge at x+1, so
        // that corner shows whatever the frame/background drew underneath
        // (paper), not the bar's own ink. Sample a pixel that's actually
        // part of the drawn top edge instead.
        let normalBorder = normalCanvas.pixel(x: WidgetLayout.progressX + 1, y: WidgetLayout.progressY)!
        let invertedBorder = invertedCanvas.pixel(x: WidgetLayout.progressX + 1, y: WidgetLayout.progressY)!

        // Default theme is black ink on white paper, so the progress bar's
        // border (always drawn in "ink") should swap accordingly.
        XCTAssertEqual(normalBorder.r, 0)
        XCTAssertEqual(invertedBorder.r, 255)
    }
}
