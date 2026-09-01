// WidgetLayout.swift — the widget's geometry constants and the pure
// layout/derivation functions that both drawCanvas() and mouse hit-testing
// read from, ported from renderer/widget.js. Kept independent of
// PixelCanvas/WidgetRenderer so the same geometry can back both drawing and
// click handling without drifting apart, exactly as in the original file.
import PomoppiCore
import PomoppiSprites

public enum WidgetLayout {
    public static let canvasWidth = 118
    public static let canvasHeight = 132
    public static let frameWidth = 110
    public static let frameHeight = 124
    public static let frameX = 4
    public static let frameY = 4
    public static let friendSize = 32
    public static let friendX = centreX(friendSize)
    public static let friendY = 22
    public static let timeY = 61
    public static let timeScale = 1
    public static let progressY = 87
    public static let progressX = 25
    public static let progressWidth = 68
    public static let progressHeight = 7
    public static let cycleDotsY = 77

    public static let wanderEdgeInset = 5
    public static let wanderMinX = progressX + wanderEdgeInset
    public static let wanderMaxX = progressX + progressWidth - friendSize - wanderEdgeInset
    public static let wanderStepPx = 1
    public static let wanderStepHeightPx = 1

    public static let dotMin = 2
    public static let dotMax = 10
    public static let dotSize = 5
    public static let dotGap = 2
    public static let dotPitch = dotSize + dotGap
    public static let stepSize = 5
    public static let stepBoxPad = 1
    public static let stepBox = stepSize + stepBoxPad * 2
    public static let clockMinusX = progressX
    public static let clockPlusX = progressX + progressWidth - stepSize
    public static let minuteStep = 60
    public static let focusMinSeconds = 60
    public static let focusMaxSeconds = 5400

    public static let buttonsY = 96
    public static let buttonSize = GeneratedSprites.iconSize
    public static let buttonCount = 4
    public static let buttonRowX = progressX
    public static let buttonRowWidth = progressWidth
    public static let buttonIDs = ["reset", "play", "skip", "settings"]

    // One centring rule for every horizontally-centred element, so they all
    // land on the same axis.
    public static func centreX(_ w: Int) -> Int {
        (canvasWidth - w) / 2
    }

    // Four 13px boxes inside the bar's 68px leave 16px of gap across 3
    // slots, which does not divide evenly. Rounding the *running* offset
    // rather than each gap keeps every box on a whole pixel and pins the
    // last one to the bar's right edge exactly.
    public static func buttonPositions() -> [Int] {
        let slack = buttonRowWidth - buttonCount * buttonSize
        let gaps = buttonCount - 1
        var xs: [Int] = []
        for i in 0..<buttonCount {
            let offset = Int((Double(i * slack) / Double(gaps)).rounded())
            xs.append(buttonRowX + i * buttonSize + offset)
        }
        return xs
    }

    public static func buttonHitBoxes() -> [(id: String, x: Int)] {
        Array(zip(buttonIDs, buttonPositions()))
    }

    public static func dotCount(longBreakEvery: Int) -> Int {
        max(dotMin, min(dotMax, longBreakEvery))
    }

    public static func dotGeometry(longBreakEvery: Int) -> (count: Int, width: Int, x: Int) {
        let cycleLen = dotCount(longBreakEvery: longBreakEvery)
        let w = cycleLen * dotSize + (cycleLen - 1) * dotGap
        return (cycleLen, w, centreX(w))
    }

    // Which dot slot (if any) a logical x falls on.
    public static func dotSlot(at lx: Int, longBreakEvery: Int) -> Int? {
        let (count, _, dotsX) = dotGeometry(longBreakEvery: longBreakEvery)
        let rel = lx - dotsX
        guard rel >= 0 else { return nil }
        let i = rel / dotPitch
        guard i >= 0, i < count else { return nil }
        return rel % dotPitch < dotSize ? i : nil
    }

    public static func clockSteppers() -> (y: Int, minusX: Int, plusX: Int) {
        let y = timeY + (Digits.glyphHeight - stepSize) / 2
        return (y, clockMinusX, clockPlusX)
    }

    public static func clockSteppersVisible(_ state: TimerState) -> Bool {
        state.phase == .idle && !state.running
    }

    public static func stepperHit(lx: Int, ly: Int, x: Int, y: Int) -> Bool {
        lx >= x - 3 && lx < x + stepSize + 3 && ly >= y - 3 && ly < y + stepSize + 3
    }

    public static func isBreak(_ state: TimerState) -> Bool {
        state.phase == .shortBreak || state.phase == .longBreak
    }

    public static func isInverted(ringing: Bool, ringTime: Double) -> Bool {
        ringing && Int(ringTime / 300) % 2 == 1
    }

    public static func friendFrameIndex(state: TimerState, ringTime: Double, animClock: Double) -> Int {
        if state.ringing { return Int(ringTime / 150) }
        if state.phase == .idle { return Int(animClock / 520) }
        if !state.running { return 0 }
        return Int(animClock / (isBreak(state) ? 900 : 340))
    }

    // Before the first wander step has ever landed (idle, or freshly reset):
    // always friendX/friendY, unmirrored. Asleep on a break: also centred,
    // but `wanderX` itself stays untouched so wandering resumes from there
    // once the break ends. Otherwise (running, or paused mid-session):
    // wherever the wander accumulator last stepped it to — pausing freezes
    // it in place rather than snapping back to centre.
    public static func petPosition(
        isBreak: Bool, wanderX: Int?, wanderDir: Int, wanderUp: Bool
    ) -> (x: Int, y: Int, mirrored: Bool) {
        guard let wanderX, !isBreak else {
            return (friendX, friendY, false)
        }
        let y = friendY - (wanderUp ? wanderStepHeightPx : 0)
        return (wanderX, y, wanderDir == 1)
    }
}
