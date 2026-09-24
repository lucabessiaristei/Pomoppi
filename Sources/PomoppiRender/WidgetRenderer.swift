// WidgetRenderer.swift — port of drawCanvas() in renderer/widget.js: takes a
// timer state, settings, and a snapshot of already-advanced animation/
// interaction values, and composes one still frame. Deliberately does not
// own a clock or a mouse: advancing shakeTime/ringTime/wanderX frame to
// frame (WidgetAnimationController), and tracking hover/press from real
// mouse events (WidgetPixelView), both live elsewhere — this stays a pure
// function of its inputs so it can be tested headlessly.
// draw()'s CGImage-returning overload below is guarded the same way
// PixelCanvas+CoreGraphics.swift guards makeImage() — this file also
// defines WidgetAnimationSnapshot, which WidgetAnimationController.swift
// (otherwise platform-agnostic) depends on, so the whole file has to stay
// buildable on Windows even though only draw() itself is Apple-only.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import PomoppiCore
import PomoppiSprites

// The subset of widget.js's module-level animation variables that
// drawCanvas() actually reads. shakeOffset is taken pre-computed (rather
// than shakeTime) since the -1/0/1 wobble mapping is a one-line detail of
// the ring animation itself, not the render.
public struct WidgetAnimationSnapshot {
    public var shakeOffset: Int
    public var ringTime: Double
    public var animClock: Double
    public var zFrameIndex: Int
    public var wanderX: Int?
    public var wanderDir: Int
    public var wanderUp: Bool

    public init(
        shakeOffset: Int = 0, ringTime: Double = 0, animClock: Double = 0, zFrameIndex: Int = 0,
        wanderX: Int? = nil, wanderDir: Int = 1, wanderUp: Bool = true
    ) {
        self.shakeOffset = shakeOffset
        self.ringTime = ringTime
        self.animClock = animClock
        self.zFrameIndex = zFrameIndex
        self.wanderX = wanderX
        self.wanderDir = wanderDir
        self.wanderUp = wanderUp
    }
}

// Hover/press state for the button row and the clock steppers/dots row —
// set by WidgetPixelView's mouse handling; drawCanvas() only reads it to
// decide how to outline/invert a region.
public struct WidgetInteractionSnapshot {
    public var hoveredButton: String?
    public var pressedButton: String?
    public var hoveredRegion: String?
    public var pressedRegion: String?

    public init(hoveredButton: String? = nil, pressedButton: String? = nil, hoveredRegion: String? = nil, pressedRegion: String? = nil) {
        self.hoveredButton = hoveredButton
        self.pressedButton = pressedButton
        self.hoveredRegion = hoveredRegion
        self.pressedRegion = pressedRegion
    }
}

public enum WidgetRenderer {
#if canImport(CoreGraphics)
    public static func draw(
        state: TimerState,
        settings: PomoppiSettings,
        animation: WidgetAnimationSnapshot = WidgetAnimationSnapshot(),
        interaction: WidgetInteractionSnapshot = WidgetInteractionSnapshot()
    ) -> CGImage? {
        drawCanvas(state: state, settings: settings, animation: animation, interaction: interaction).makeImage()
    }
#endif

    // Same composition as draw(), minus the final CoreGraphics export — lets
    // tests read pixels straight out of the PixelCanvas buffer without going
    // through CGImage, and is the Windows widget window's rendering entry
    // point (PomoppiWindows/WidgetWindow.swift) since draw() -> CGImage?
    // isn't available there.
    public static func drawCanvas(
        state: TimerState,
        settings: PomoppiSettings,
        animation: WidgetAnimationSnapshot = WidgetAnimationSnapshot(),
        interaction: WidgetInteractionSnapshot = WidgetInteractionSnapshot()
    ) -> PixelCanvas {
        let canvas = PixelCanvas(width: WidgetLayout.canvasWidth, height: WidgetLayout.canvasHeight)

        let inverted = WidgetLayout.isInverted(ringing: state.ringing, ringTime: animation.ringTime)
        let themeInk = settings.inkColor
        let themePaper = settings.paperColor
        let ink = inverted ? themePaper : themeInk
        let paper = inverted ? themeInk : themePaper

        let frameStyle = FrameStyle(rawValue: settings.frameStyle) ?? .scallopy
        let frameGrid = WindowFrame.grid(style: frameStyle, w: WidgetLayout.frameWidth, h: WidgetLayout.frameHeight)
        canvas.drawGrid(frameGrid, WidgetLayout.frameX, WidgetLayout.frameY, colorMap: ["#": ink, "w": paper])

        // Pattern lives inside the card only, masked pixel-by-pixel against
        // the frame's own interior ('w') cells so it's cropped to the
        // frame's shape instead of a plain rectangle.
        let pattern = GeneratedSprites.backgroundPatterns[settings.background]
            ?? GeneratedSprites.backgroundPatterns[GeneratedSprites.defaultBackgroundID]
        if let pattern {
            let bgColor = mixHex(paper, ink, 0.3)
            for y in 0..<pattern.count {
                let row = Array(pattern[y])
                let frameRowIndex = y - WidgetLayout.frameY
                guard frameRowIndex >= 0, frameRowIndex < frameGrid.count else { continue }
                let frameRow = Array(frameGrid[frameRowIndex])
                for x in 0..<row.count {
                    guard row[x] == "#" else { continue }
                    let frameCol = x - WidgetLayout.frameX
                    guard frameCol >= 0, frameCol < frameRow.count, frameRow[frameCol] == "w" else { continue }
                    canvas.fillRect(x, y, 1, 1, bgColor)
                }
            }
        }

        let isBreak = WidgetLayout.isBreak(state)
        let pet = WidgetLayout.petPosition(
            isBreak: isBreak,
            wanderX: animation.wanderX, wanderDir: animation.wanderDir, wanderUp: animation.wanderUp)
        let rawFrame = friendFrame(settings: settings, state: state, animation: animation)
        let petFrame = pet.mirrored ? mirrorGridH(rawFrame) : rawFrame
        canvas.drawGrid(petFrame, pet.x + animation.shakeOffset, pet.y, colorMap: ["#": ink, "w": paper])

        if isBreak {
            let frames = GeneratedSprites.zzzFrames
            if !frames.isEmpty {
                let n = frames.count
                let idx = ((animation.zFrameIndex % n) + n) % n
                let zzzFrame = frames[idx]
                let zx = 79 + zzzFrame.dx
                let zy = WidgetLayout.friendY + 7 + zzzFrame.dy
                canvas.drawGrid(zzzFrame.grid, zx, zy, colorMap: ["#": ink])
            } else {
                canvas.drawGrid(GeneratedSprites.zzz, 79, WidgetLayout.friendY + 7, colorMap: ["#": ink])
            }
        }

        let timeStr = formatTime(state.remainingMs)
        let timeWidth = PixelCanvas.measureText(timeStr, scale: WidgetLayout.timeScale, glyphs: Digits.glyphs, gap: Digits.digitGap)
        let timeX = WidgetLayout.centreX(timeWidth)
        canvas.drawText(timeStr, timeX, WidgetLayout.timeY, scale: WidgetLayout.timeScale, ink, glyphs: Digits.glyphs, gap: Digits.digitGap)

        if WidgetLayout.clockSteppersVisible(state) {
            let steppers = WidgetLayout.clockSteppers()
            drawStepperControl(canvas, steppers.minusX, steppers.y, isPlus: false, region: "clock-minus", ink: ink, paper: paper, interaction: interaction)
            drawStepperControl(canvas, steppers.plusX, steppers.y, isPlus: true, region: "clock-plus", ink: ink, paper: paper, interaction: interaction)
        }

        canvas.drawRoundRect(WidgetLayout.progressX, WidgetLayout.progressY, WidgetLayout.progressWidth, WidgetLayout.progressHeight, ink, filled: false)
        if state.totalMs > 0 {
            let done = 1 - min(1, max(0, state.remainingMs / state.totalMs))
            let fillWidth = Int((Double(WidgetLayout.progressWidth - 2) * done).rounded())
            if fillWidth > 0 {
                canvas.fillRect(WidgetLayout.progressX + 1, WidgetLayout.progressY + 1, fillWidth, WidgetLayout.progressHeight - 2, ink)
            }
        }

        let dots = WidgetLayout.dotGeometry(longBreakEvery: settings.longBreakEvery)
        for i in 0..<dots.count {
            let x = dots.x + i * WidgetLayout.dotPitch
            if i < state.cycleIndex {
                canvas.fillRect(x, WidgetLayout.cycleDotsY, WidgetLayout.dotSize, WidgetLayout.dotSize, ink)
            } else {
                canvas.drawBorder(x, WidgetLayout.cycleDotsY, WidgetLayout.dotSize, WidgetLayout.dotSize, ink)
            }
        }

        for button in buttonLayout(state: state) {
            // Reset has nothing to throw away while idle (SPEC.md §3): drawn
            // in the background token, and hit-testing skips it.
            if !WidgetLayout.isButtonEnabled(button.id, state: state) {
                canvas.drawIcon(button.icon, button.x, WidgetLayout.buttonsY, mixHex(paper, ink, 0.3))
                continue
            }
            if interaction.pressedButton == button.id {
                canvas.fillRect(button.x, WidgetLayout.buttonsY, WidgetLayout.buttonSize, WidgetLayout.buttonSize, ink)
                canvas.drawIcon(button.icon, button.x, WidgetLayout.buttonsY, paper)
            } else {
                if interaction.hoveredButton == button.id {
                    canvas.drawBorder(button.x, WidgetLayout.buttonsY, WidgetLayout.buttonSize, WidgetLayout.buttonSize, ink)
                }
                canvas.drawIcon(button.icon, button.x, WidgetLayout.buttonsY, ink)
            }
        }

        return canvas
    }

    // -- pure derivations that stay local to rendering (not needed by hit-testing) ----

    private static func friendFrame(settings: PomoppiSettings, state: TimerState, animation: WidgetAnimationSnapshot) -> [String] {
        let frames = GeneratedSprites.friendFrames[settings.friend] ?? GeneratedSprites.friendFrames[GeneratedSprites.defaultFriendID] ?? []
        guard !frames.isEmpty else { return [] }
        let n = frames.count
        let i = WidgetLayout.friendFrameIndex(state: state, ringTime: animation.ringTime, animClock: animation.animClock)
        return frames[((i % n) + n) % n]
    }

    private static func mirrorGridH(_ grid: [String]) -> [String] {
        grid.map { String($0.reversed()) }
    }

    private static func formatTime(_ ms: Double) -> String {
        let totalSeconds = max(0, Int((ms / 1000).rounded(.up)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // reset - play/pause - skip - heart.
    private static func buttonLayout(state: TimerState) -> [(x: Int, id: String, icon: [String])] {
        let playIcon = state.running ? GeneratedSprites.icons["pause"]! : GeneratedSprites.icons["play"]!
        // reset/skip swap icon artwork with each other, each mirrored — the
        // bar-and-arrow glyph (originally skip's) now reads "back to start"
        // pointing left in reset's own slot, and the double-chevron
        // (originally reset's) now reads "fast forward" pointing right in
        // skip's slot. A pure design choice, not a hit-testing change —
        // each button's id/action is untouched, only which artwork renders
        // where.
        let icons: [String: [String]] = [
            "reset": mirrorGridH(GeneratedSprites.icons["skip"]!), "play": playIcon,
            "skip": mirrorGridH(GeneratedSprites.icons["reset"]!), "settings": GeneratedSprites.icons["heart"]!,
        ]
        return WidgetLayout.buttonHitBoxes().map { (x: $0.x, id: $0.id, icon: icons[$0.id]!) }
    }

    private static func drawStepper(_ canvas: PixelCanvas, _ x: Int, _ y: Int, isPlus: Bool, _ color: String) {
        canvas.fillRect(x, y + 2, WidgetLayout.stepSize, 1, color)
        if isPlus { canvas.fillRect(x + 2, y, 1, WidgetLayout.stepSize, color) }
    }

    private static func drawStepperControl(
        _ canvas: PixelCanvas, _ x: Int, _ y: Int, isPlus: Bool, region: String,
        ink: String, paper: String, interaction: WidgetInteractionSnapshot
    ) {
        let bx = x - WidgetLayout.stepBoxPad
        let by = y - WidgetLayout.stepBoxPad
        if interaction.pressedRegion == region {
            canvas.fillRect(bx, by, WidgetLayout.stepBox, WidgetLayout.stepBox, ink)
            drawStepper(canvas, x, y, isPlus: isPlus, paper)
            return
        }
        if interaction.hoveredRegion == region {
            canvas.drawBorder(bx, by, WidgetLayout.stepBox, WidgetLayout.stepBox, ink)
        }
        drawStepper(canvas, x, y, isPlus: isPlus, ink)
    }

    private static func hexToRgb(_ hex: String) -> (r: Int, g: Int, b: Int) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let n = UInt32(h, radix: 16) ?? 0
        return (Int((n >> 16) & 0xFF), Int((n >> 8) & 0xFF), Int(n & 0xFF))
    }

    private static func mixHex(_ base: String, _ tint: String, _ amount: Double) -> String {
        let a = hexToRgb(base)
        let b = hexToRgb(tint)
        func mixed(_ from: Int, _ to: Int) -> String {
            let value = Double(from) + Double(to - from) * amount
            let clamped = min(255, max(0, value))
            return String(format: "%02X", Int(clamped.rounded()))
        }
        return "#" + mixed(a.r, b.r) + mixed(a.g, b.g) + mixed(a.b, b.b)
    }
}
