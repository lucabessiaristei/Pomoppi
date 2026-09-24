import AppKit
import QuartzCore
import PomoppiCore
import PomoppiRender

// AppKit, not a pure SwiftUI `WindowGroup`: SPEC.md §9b's window-layering
// rules — an idempotent always-on-top setter, `.accessory` activation,
// visible on every Space, and never full-screen-auxiliary — need direct
// NSWindow control that SwiftUI's scene APIs don't expose.
final class WidgetWindow: NSWindow {
    private var appliedAlwaysOnTop: Bool?
    private var wantsAlwaysOnTop = false
    // True while Installer.app is open for an in-app update: a floating
    // widget would sit on top of the installer's window.
    private var yieldingLevel = false
    private let pixelView: WidgetPixelView
    // The opacity setting's actual target — kept separate from `alphaValue`
    // itself because raise()/hide() drive alphaValue down to/up from 0 for
    // the fade, and need something other than "whatever alphaValue currently
    // is mid-animation" to animate towards/restore afterward.
    private var settingsOpacity: CGFloat

    init(timer: PomodoroTimer, settingsStore: SettingsStore, onOpenSettingsRequested: @escaping () -> Void) {
        let settings = settingsStore.get()
        let scale = settings.scale
        let contentSize = NSSize(
            width: WidgetLayout.canvasWidth * scale,
            height: WidgetLayout.canvasHeight * scale)
        let frame = NSRect(origin: .zero, size: contentSize)
        pixelView = WidgetPixelView(frame: frame, timer: timer, settingsStore: settingsStore, onOpenSettingsRequested: onOpenSettingsRequested)
        settingsOpacity = CGFloat(settings.opacity)

        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        // Whether this window is on screen is owned solely by
        // settings.startHidden (at launch) and raise()/hide() calls
        // (afterward) — never by macOS's own window-restoration ("Resume"),
        // which would otherwise reopen it based on whatever was on screen
        // the last time the app quit.
        isRestorable = false
        // Visible on every Space so a menu-bar-style widget is never lost —
        // deliberately NOT .fullScreenAuxiliary: the widget must never be
        // able to join another app's full-screen Space and take its
        // auto-hidden menu bar along (SPEC.md §9b's accepted trade-off).
        collectionBehavior = [.canJoinAllSpaces]
        alphaValue = settingsOpacity

        contentView = pixelView

        center()
        setAlwaysOnTop(settings.alwaysOnTop)
    }

    // INVARIANT (SPEC.md §9b): nothing else in this app sets `level`
    // directly. On macOS, re-applying a window's level re-orders it even
    // when handed the value it already has, so a redundant call here would
    // silently sink the widget behind other windows.
    func setAlwaysOnTop(_ value: Bool) {
        wantsAlwaysOnTop = value
        applyLevel()
    }

    func yieldLevel(_ yielding: Bool) {
        yieldingLevel = yielding
        applyLevel()
    }

    private func applyLevel() {
        let value = wantsAlwaysOnTop && !yieldingLevel
        guard appliedAlwaysOnTop != value else { return }
        level = value ? .floating : .normal
        appliedAlwaysOnTop = value
    }

    // Called (via SettingsStore.onChange) whenever settings change from any
    // source — the widget's own interactions or the settings window. Only
    // covers the window-level properties this class applies once rather
    // than continuously; everything else the widget draws is already
    // re-read from settings every frame.
    func applyExternalSettingsChange(_ settings: PomoppiSettings) {
        setAlwaysOnTop(settings.alwaysOnTop)
        settingsOpacity = CGFloat(settings.opacity)
        // Only stomps the live value while actually on screen — while
        // hidden (or mid-fade-out on the way there) alphaValue is owned by
        // hide()'s animation, not the opacity slider.
        if isShown { alphaValue = settingsOpacity }

        let newSize = NSSize(
            width: WidgetLayout.canvasWidth * settings.scale,
            height: WidgetLayout.canvasHeight * settings.scale)
        if contentView?.frame.size != newSize {
            setContentSize(newSize)
        }
    }

    // Whether the widget is showing or on its way in. isVisible stays true
    // through a fade-out, so toggles read this instead: a second toggle
    // mid-fade-out brings it back rather than fading out again.
    private(set) var isShown = false
    // The fade is stepped by hand rather than through NSAnimationContext /
    // animator(): window-alpha animations there were unreliable (no visible
    // fade at all in practice), and a timer added in .common mode keeps
    // running while the tray menu is tracking. Starting a new fade cancels
    // the running one, completion included.
    private var fadeTimer: Timer?

    // Single entry point for every "bring the widget to front" caller
    // (tray, shortcut, raiseOnEnd, launch). No temporary level bumps — a
    // raise is not sticky by design. Fades in from wherever the alpha is:
    // 0 when hidden, the current value mid-fade, so raising an already
    // visible widget (raiseOnEnd) never blinks.
    func raise() {
        if !isVisible { alphaValue = 0 }
        isShown = true
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
        makeFirstResponder(pixelView)
        fade(to: settingsOpacity, duration: Self.fadeInDuration, easeOut: true, completion: nil)
    }

    // The show/hide counterpart to raise(): fades to transparent, then
    // orders the window out and restores alphaValue for next time.
    // `completion` runs once it's gone (or right away if it already was),
    // which is how quitting waits for the fade.
    func hide(completion: (() -> Void)? = nil) {
        guard isVisible, isShown else {
            completion?()
            return
        }
        isShown = false
        fade(to: 0, duration: Self.fadeOutDuration, easeOut: false) { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.alphaValue = self.settingsOpacity
            completion?()
        }
    }

    private func fade(to target: CGFloat, duration: TimeInterval, easeOut: Bool, completion: (() -> Void)?) {
        fadeTimer?.invalidate()
        let start = alphaValue
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let progress = min(1, (CACurrentMediaTime() - began) / duration)
            // Ease-out for appearing, ease-in for disappearing.
            let eased = easeOut ? 1 - (1 - progress) * (1 - progress) : progress * progress
            self.alphaValue = start + (target - start) * CGFloat(eased)
            guard progress >= 1 else { return }
            timer.invalidate()
            self.fadeTimer = nil
            completion?()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private static let fadeInDuration: TimeInterval = 0.22
    private static let fadeOutDuration: TimeInterval = 0.18

    override var canBecomeKey: Bool { true }
}
