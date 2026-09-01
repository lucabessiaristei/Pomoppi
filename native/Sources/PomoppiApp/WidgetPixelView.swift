import AppKit
import PomoppiCore
import PomoppiRender

// Owns the widget's live per-frame loop and all direct mouse/keyboard
// interaction — ported from renderer/widget.js's handleMouseDown/Move/Up,
// activateButton, stepFocusMinutes, and the fixed in-app key table.
// Deliberately always keeps the frame timer running rather than porting
// widget.js's start/stop-when-idle optimization: redrawing this small a
// canvas at 60fps is negligible, and it avoids an entire class of "did some
// interaction forget to restart the loop" bugs.
final class WidgetPixelView: NSView {
    private let timer: PomodoroTimer
    private let settingsStore: SettingsStore
    private let animation = WidgetAnimationController()
    private let onOpenSettingsRequested: () -> Void

    private var state: TimerState
    private var settings: PomoppiSettings

    private var frameTimer: Timer?
    private var lastTimestamp: TimeInterval?

    private var hoveredButton: String?
    private var pressedButton: String?
    private var hoveredRegion: String?
    private var pressedRegion: String?

    private var isDragging = false
    private var dragStartScreenPoint: NSPoint = .zero
    private var lastDragScreenPoint: NSPoint = .zero

    init(frame: NSRect, timer: PomodoroTimer, settingsStore: SettingsStore, onOpenSettingsRequested: @escaping () -> Void) {
        self.timer = timer
        self.settingsStore = settingsStore
        self.state = timer.getState()
        self.settings = settingsStore.get()
        self.onOpenSettingsRequested = onOpenSettingsRequested
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("WidgetPixelView does not support NSCoding")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // A floating utility widget should react to the very first click even
    // when it wasn't already key/active — AppKit's default "first click
    // just activates the window" convention (meant for document windows)
    // would otherwise swallow the click that was supposed to hit a button.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.acceptsMouseMovedEvents = true
            startFrameTimer()
        } else {
            stopFrameTimer()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // -- per-frame loop -----------------------------------------------------

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
        lastTimestamp = nil
    }

    private func step() {
        let now = Date().timeIntervalSinceReferenceDate
        let dt = lastTimestamp.map { min(100, (now - $0) * 1000) } ?? 16
        lastTimestamp = now

        settings = settingsStore.get()
        state = timer.tick()
        animation.tick(dt: dt, state: state, settings: settings)
        needsDisplay = true
    }

    // -- drawing --------------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        let interaction = WidgetInteractionSnapshot(
            hoveredButton: hoveredButton, pressedButton: pressedButton,
            hoveredRegion: hoveredRegion, pressedRegion: pressedRegion)
        guard let image = WidgetRenderer.draw(state: state, settings: settings, animation: animation.snapshot, interaction: interaction),
              let ctx = NSGraphicsContext.current?.cgContext
        else { return }
        ctx.interpolationQuality = .none
        // CGContext.draw(image:in:) doesn't respect isFlipped the way fills
        // do — it always treats the image's row 0 as belonging at the
        // bottom of the current CTM, so in this already-flipped view it
        // comes out upside down unless counter-flipped right here, local to
        // just this call.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
    }

    // -- hit-testing -------------------------------------------------------

    private var scale: Int { max(1, settings.scale) }

    private func logicalPoint(from event: NSEvent) -> (x: Int, y: Int) {
        let p = convert(event.locationInWindow, from: nil)
        return (Int(floor(p.x / CGFloat(scale))), Int(floor(p.y / CGFloat(scale))))
    }

    private func regionAt(lx: Int, ly: Int) -> (region: String?, button: String?) {
        let pet = WidgetLayout.petPosition(
            petMovement: settings.petMovement, isBreak: WidgetLayout.isBreak(state),
            wanderX: animation.snapshot.wanderX, wanderDir: animation.snapshot.wanderDir, wanderUp: animation.snapshot.wanderUp)

        var region: String?
        var button: String?

        if lx >= pet.x, lx < pet.x + WidgetLayout.friendSize, ly >= pet.y, ly < pet.y + WidgetLayout.friendSize {
            region = "pet"
        } else if WidgetLayout.clockSteppersVisible(state) {
            let steppers = WidgetLayout.clockSteppers()
            if WidgetLayout.stepperHit(lx: lx, ly: ly, x: steppers.minusX, y: steppers.y) {
                region = "clock-minus"
            } else if WidgetLayout.stepperHit(lx: lx, ly: ly, x: steppers.plusX, y: steppers.y) {
                region = "clock-plus"
            }
        }

        let dots = WidgetLayout.dotGeometry(longBreakEvery: settings.longBreakEvery)
        if lx >= dots.x, lx < dots.x + dots.width, ly >= WidgetLayout.cycleDotsY - 2, ly < WidgetLayout.cycleDotsY + WidgetLayout.dotSize + 2 {
            region = "dots"
        }

        if region == nil {
            for box in WidgetLayout.buttonHitBoxes() {
                if lx >= box.x - 2, lx < box.x + WidgetLayout.buttonSize + 2,
                   ly >= WidgetLayout.buttonsY - 2, ly < WidgetLayout.buttonsY + WidgetLayout.buttonSize + 2 {
                    button = box.id
                    region = box.id
                    break
                }
            }
        }
        return (region, button)
    }

    // -- mouse ----------------------------------------------------------------

    override func mouseMoved(with event: NSEvent) {
        let p = logicalPoint(from: event)
        let (region, button) = regionAt(lx: p.x, ly: p.y)
        if region != hoveredRegion || button != hoveredButton {
            hoveredRegion = region
            hoveredButton = button
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredRegion != nil || hoveredButton != nil {
            hoveredRegion = nil
            hoveredButton = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screenPoint = NSEvent.mouseLocation
        dragStartScreenPoint = screenPoint
        lastDragScreenPoint = screenPoint

        let onControl = (hoveredRegion != nil && hoveredRegion != "pet") || hoveredButton != nil
        isDragging = !onControl

        pressedRegion = hoveredRegion
        pressedButton = hoveredButton
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let dx = screenPoint.x - lastDragScreenPoint.x
        let dy = screenPoint.y - lastDragScreenPoint.y
        lastDragScreenPoint = screenPoint

        var origin = window.frame.origin
        origin.x += dx
        origin.y += dy
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        let dx = screenPoint.x - dragStartScreenPoint.x
        let dy = screenPoint.y - dragStartScreenPoint.y
        let moved = (dx * dx + dy * dy).squareRoot()

        let clickedRegion = pressedRegion
        let clickedButton = pressedButton
        pressedRegion = nil
        pressedButton = nil
        isDragging = false
        needsDisplay = true

        guard moved < 3 else { return }
        guard clickedRegion != nil || clickedButton != nil else { return }

        switch clickedRegion {
        case "clock-minus":
            stepFocusMinutes(-1)
        case "clock-plus":
            stepFocusMinutes(1)
        case "dots":
            let p = logicalPoint(from: event)
            if let slot = WidgetLayout.dotSlot(at: p.x, longBreakEvery: settings.longBreakEvery) {
                settings = settingsStore.update { $0.longBreakEvery = slot + 1 }
            }
        default:
            if let clickedButton { activateButton(clickedButton) }
        }
    }

    // -- keyboard ---------------------------------------------------------------

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        let isRepeat = event.isARepeat

        if plain, WidgetLayout.clockSteppersVisible(state), let special = event.specialKey {
            if special == .upArrow { stepFocusMinutes(1); return }
            if special == .downArrow { stepFocusMinutes(-1); return }
        }

        guard plain, !isRepeat, let chars = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        switch chars {
        case " ", "\r":
            activateButton("play")
        case "s":
            activateButton("skip")
        case "r":
            activateButton("reset")
        case "o":
            toggleAlwaysOnTop()
        case ",":
            activateButton("settings")
        case "\u{1b}": // Escape
            if state.ringing {
                state = timer.dismissRing()
            } else {
                window?.orderOut(nil)
            }
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    // -- actions ------------------------------------------------------------------

    private func activateButton(_ id: String) {
        if state.ringing { state = timer.dismissRing() }
        switch id {
        case "play":
            state = state.running ? timer.pause() : timer.start()
        case "reset":
            state = timer.reset()
        case "skip":
            state = timer.skip()
        case "settings":
            onOpenSettingsRequested()
        default:
            break
        }
        needsDisplay = true
    }

    private func stepFocusMinutes(_ delta: Int) {
        let current = focusSeconds()
        let next = min(WidgetLayout.focusMaxSeconds, max(WidgetLayout.focusMinSeconds, current + delta * WidgetLayout.minuteStep))
        guard next != current else { return }
        settings = settingsStore.update { $0.focusMinutes = Double(next) / 60 }
        needsDisplay = true
    }

    private func focusSeconds() -> Int {
        let minutes = settings.focusMinutes
        guard minutes.isFinite else { return WidgetLayout.focusMinSeconds }
        return min(WidgetLayout.focusMaxSeconds, max(WidgetLayout.focusMinSeconds, Int((minutes * 60).rounded())))
    }

    private func toggleAlwaysOnTop() {
        let updated = settingsStore.update { $0.alwaysOnTop.toggle() }
        settings = updated
        (window as? WidgetWindow)?.setAlwaysOnTop(updated.alwaysOnTop)
        needsDisplay = true
    }
}
