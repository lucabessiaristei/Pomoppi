import AppKit
import PomoppiCore
import PomoppiRender

// AppKit, not a pure SwiftUI `WindowGroup`: SPEC.md §9b's window-layering
// rules — an idempotent always-on-top setter, `.accessory` activation,
// visible on every Space, and never full-screen-auxiliary — need direct
// NSWindow control that SwiftUI's scene APIs don't expose.
final class WidgetWindow: NSWindow {
    private var appliedAlwaysOnTop: Bool?
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
        if isVisible { alphaValue = settingsOpacity }

        let newSize = NSSize(
            width: WidgetLayout.canvasWidth * settings.scale,
            height: WidgetLayout.canvasHeight * settings.scale)
        if contentView?.frame.size != newSize {
            setContentSize(newSize)
        }
    }

    // Single entry point for every "bring the widget to front" caller
    // (later phases: tray right-click, raiseOnEnd, a second launch). No
    // temporary level bumps, no timers — a raise is not sticky by design.
    // Fades in from 0 to the opacity setting rather than snapping straight
    // to visible.
    func raise() {
        alphaValue = 0
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
        makeFirstResponder(pixelView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            self.animator().alphaValue = self.settingsOpacity
        }
    }

    // The show/hide counterpart to raise(): fades to transparent, then
    // actually orders the window out once the animation finishes, and
    // restores alphaValue for next time — orderOut(nil) alone would just
    // vanish the widget instantly.
    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.alphaValue = self.settingsOpacity
        })
    }

    private static let fadeDuration: TimeInterval = 0.12

    override var canBecomeKey: Bool { true }
}
