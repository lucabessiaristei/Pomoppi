// SmoothScroll.swift — mouse-wheel scrolling shared by the Settings pages
// and the Transfer window: how far a wheel event moves (Windows' own
// "lines per notch" setting, or a page when it's "one screen at a time"),
// and the easing that glides there over ~100 ms instead of jumping.
// The owner keeps the actual offset and a timer; this only does the math.
import WinSDK

struct SmoothScroll {
    // Pixels one wheel "line" moves; Windows' default 3 lines per notch
    // makes a notch 48 px.
    static let linePixels: Double = 16
    // The owner's scroll timer interval while easing.
    static let tick: UINT = 10

    private(set) var target: Int32 = 0
    private(set) var animating = false
    // Touchpads send fractions of a notch; what doesn't add up to a whole
    // pixel yet carries over to the next event.
    private var remainder: Double = 0

    // A WM_MOUSEWHEEL's wParam. Returns where to go, or nil when the event
    // doesn't move a whole pixel yet. `animate` is false when Windows'
    // animations are off: then the owner jumps straight to the target.
    mutating func wheel(wParam: WPARAM, current: Int32, maxScroll: Int32, pageHeight: Int32) -> (target: Int32, animate: Bool)? {
        let highWord = UInt16(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
        let notches = Double(Int16(bitPattern: highWord)) / Double(WHEEL_DELTA)
        var lines: UINT = 3
        SystemParametersInfoW(UINT(SPI_GETWHEELSCROLLLINES), 0, &lines, 0)
        let perNotch = lines == UINT.max ? Double(pageHeight) : Double(lines) * Self.linePixels
        remainder += -notches * perNotch
        let delta = Int32(remainder.rounded(.towardZero))
        guard delta != 0 else { return nil }
        remainder -= Double(delta)
        target = min(max(0, (animating ? target : current) + delta), maxScroll)
        var enabled: WindowsBool = true
        SystemParametersInfoW(UINT(SPI_GETCLIENTAREAANIMATION), 0, &enabled, 0)
        animating = enabled.boolValue
        return (target, animating)
    }

    // One timer tick: a third of the remaining distance (at least a pixel).
    // Returns the next offset; `animating` turns false on arrival.
    mutating func step(from current: Int32) -> Int32 {
        let remaining = target - current
        guard animating, remaining != 0 else { animating = false; return current }
        let step = remaining / 3
        let next = current + (step != 0 ? step : (remaining > 0 ? 1 : -1))
        if next == target { animating = false }
        return next
    }

    // A direct jump (scrollbar, keyboard, layout clamp) cancels the easing.
    mutating func jump(to value: Int32) {
        target = value
        animating = false
        remainder = 0
    }
}
