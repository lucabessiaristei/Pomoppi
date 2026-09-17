// WidgetInput.swift — mouse/keyboard handling for WidgetWindow, wired from
// its WndProc (see WidgetWindow.handleMessage). A straight port of
// WidgetPixelView.swift's hit-testing, drag-vs-click decision, and key
// table — the geometry itself is already shared via WidgetLayout, only the
// Win32 event plumbing is new here.
import PomoppiCore
import PomoppiRender
import WinSDK

extension WidgetWindow {
    // -- coordinate conversion -----------------------------------------------

    // WM_MOUSEMOVE/WM_LBUTTONDOWN/WM_LBUTTONUP pack client-area coordinates
    // into lParam as two signed 16-bit words (the GET_X_LPARAM/GET_Y_LPARAM
    // macros, which don't import into Swift) — extract and sign-extend by
    // hand. Client coordinates here are already top-down/y-increases-
    // downward, matching PixelCanvas's own row-0-is-top convention, so
    // (unlike macOS's flipped NSView) no y-flip is needed.
    private func logicalPoint(fromLParam lParam: LPARAM) -> (x: Int, y: Int) {
        let raw = UInt32(truncatingIfNeeded: lParam)
        let cx = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        let cy = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw >> 16)))
        return (floorDiv(cx, scale), floorDiv(cy, scale))
    }

    private func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let q = value / divisor
        let r = value % divisor
        return r != 0 && (r < 0) != (divisor < 0) ? q - 1 : q
    }

    // -- hit-testing ----------------------------------------------------------

    // Exact priority order ported from WidgetPixelView.regionAt: pet, then
    // clock steppers (only while visible), then dots — which can OVERRIDE
    // whichever of those two just matched, since geometry can overlap — and
    // finally buttons, but only if nothing else already claimed the region.
    func regionAt(lx: Int, ly: Int) -> (region: String?, button: String?) {
        let pet = WidgetLayout.petPosition(
            isBreak: WidgetLayout.isBreak(state),
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

    // -- mouse ------------------------------------------------------------------

    func handleMouseMove(lParam: LPARAM) {
        // Win32 doesn't send WM_MOUSELEAVE the way AppKit's tracking areas
        // do — TrackMouseEvent has to be (re-)armed to get one. Tracking is
        // cancelled once a leave event fires, so this is called on every
        // move rather than trying to detect "first move after entry"; cheap
        // and always correct.
        var tme = TRACKMOUSEEVENT()
        tme.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
        tme.dwFlags = DWORD(TME_LEAVE)
        tme.hwndTrack = hwnd
        TrackMouseEvent(&tme)

        if isDragging {
            var cursor = POINT()
            GetCursorPos(&cursor)
            let dx = cursor.x - lastDragScreenPoint.x
            let dy = cursor.y - lastDragScreenPoint.y
            lastDragScreenPoint = cursor
            var rect = RECT()
            GetWindowRect(hwnd, &rect)
            SetWindowPos(hwnd, nil, rect.left + dx, rect.top + dy, 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER))
            return
        }

        let (lx, ly) = logicalPoint(fromLParam: lParam)
        let (region, button) = regionAt(lx: lx, ly: ly)
        hoveredRegion = region
        hoveredButton = button
    }

    func handleMouseLeave() {
        hoveredRegion = nil
        hoveredButton = nil
    }

    func handleLButtonDown(lParam: LPARAM) {
        // Explicit, mirroring macOS's makeFirstResponder(pixelView) call in
        // mouseDown — normal Win32 click-to-activate should already do
        // this, but the widget's keyboard shortcuts depend on it, so it's
        // asked for directly rather than assumed.
        SetFocus(hwnd)
        SetCapture(hwnd)

        var cursor = POINT()
        GetCursorPos(&cursor)
        dragStartScreenPoint = cursor
        lastDragScreenPoint = cursor

        let onControl = (hoveredRegion != nil && hoveredRegion != "pet") || hoveredButton != nil
        isDragging = !onControl

        pressedRegion = hoveredRegion
        pressedButton = hoveredButton
    }

    func handleLButtonUp(lParam: LPARAM) {
        ReleaseCapture()

        var cursor = POINT()
        GetCursorPos(&cursor)
        let dx = Double(cursor.x - dragStartScreenPoint.x)
        let dy = Double(cursor.y - dragStartScreenPoint.y)
        let moved = (dx * dx + dy * dy).squareRoot()

        let clickedRegion = pressedRegion
        let clickedButton = pressedButton
        pressedRegion = nil
        pressedButton = nil
        isDragging = false

        guard moved < 3 else { return }
        guard clickedRegion != nil || clickedButton != nil else { return }

        switch clickedRegion {
        case "clock-minus":
            stepFocusMinutes(-1)
        case "clock-plus":
            stepFocusMinutes(1)
        case "dots":
            let (lx, _) = logicalPoint(fromLParam: lParam)
            if let slot = WidgetLayout.dotSlot(at: lx, longBreakEvery: settings.longBreakEvery) {
                settings = settingsStore.update { $0.longBreakEvery = slot + 1 }
            }
        default:
            if let clickedButton { activateButton(clickedButton) }
        }
    }

    // -- keyboard -----------------------------------------------------------

    private func isKeyDown(_ vk: Int32) -> Bool {
        (GetKeyState(vk) & Int16(bitPattern: 0x8000)) != 0
    }

    private func isPlainModifierState() -> Bool {
        !isKeyDown(VK_CONTROL) && !isKeyDown(VK_MENU) && !isKeyDown(VK_SHIFT)
            && !isKeyDown(VK_LWIN) && !isKeyDown(VK_RWIN)
    }

    // Same key table as WidgetPixelView.keyDown. lParam's bit 30 is Win32's
    // "was already down" repeat flag, the equivalent of NSEvent.isARepeat.
    // The up/down-arrow stepper check deliberately runs before (and without)
    // the repeat guard, same as macOS — holding the arrow down is meant to
    // keep stepping.
    func handleKeyDown(wParam: WPARAM, lParam: LPARAM) {
        let vk = Int32(truncatingIfNeeded: wParam)
        let isRepeat = (lParam & 0x4000_0000) != 0
        let plain = isPlainModifierState()

        if plain, WidgetLayout.clockSteppersVisible(state) {
            if vk == VK_UP { stepFocusMinutes(1); return }
            if vk == VK_DOWN { stepFocusMinutes(-1); return }
        }

        guard plain, !isRepeat else { return }

        switch vk {
        case VK_SPACE, VK_RETURN:
            activateButton("play")
        case Int32(UnicodeScalar("S").value):
            activateButton("skip")
        case Int32(UnicodeScalar("R").value):
            activateButton("reset")
        case Int32(UnicodeScalar("O").value):
            toggleAlwaysOnTop()
        case VK_OEM_COMMA:
            // No settings window yet (Phase W6/W7) — harmless no-op for now.
            print("Pomoppi: settings requested, but there's no settings window on Windows yet")
        case VK_ESCAPE:
            if state.ringing {
                state = timer.dismissRing()
            } else {
                // No tray yet to un-hide from (Phase W4) — relaunching the
                // exe is the only way back until then, expected for this
                // dev/test phase.
                setVisible(false)
            }
        default:
            break
        }
    }

    // -- actions --------------------------------------------------------------

    func activateButton(_ id: String) {
        if state.ringing { state = timer.dismissRing() }
        switch id {
        case "play":
            if state.running {
                state = timer.pause()
            } else {
                // No task-name prompting on Windows yet (out of scope for
                // this phase; StartCoordinator's NSAlert-based prompt is
                // AppKit-only) — starts directly.
                state = timer.start()
            }
        case "reset":
            state = timer.reset()
        case "skip":
            state = timer.skip()
        case "settings":
            print("Pomoppi: settings requested, but there's no settings window on Windows yet")
        default:
            break
        }
    }

    func stepFocusMinutes(_ delta: Int) {
        let current = focusSeconds()
        let next = min(WidgetLayout.focusMaxSeconds, max(WidgetLayout.focusMinSeconds, current + delta * WidgetLayout.minuteStep))
        guard next != current else { return }
        settings = settingsStore.update { $0.focusMinutes = Double(next) / 60 }
    }

    private func focusSeconds() -> Int {
        let minutes = settings.focusMinutes
        guard minutes.isFinite else { return WidgetLayout.focusMinSeconds }
        return min(WidgetLayout.focusMaxSeconds, max(WidgetLayout.focusMinSeconds, Int((minutes * 60).rounded())))
    }

    func toggleAlwaysOnTop() {
        let updated = settingsStore.update { $0.alwaysOnTop.toggle() }
        settings = updated
        setAlwaysOnTop(updated.alwaysOnTop)
    }
}
