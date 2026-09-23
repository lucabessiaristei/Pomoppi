import AppKit
import PomoppiCore
import PomoppiRender
import PomoppiSprites

// The menu bar icon, ported from main.js's createTray()/updateTray()/
// buildTrayTemplate(). By default left-click raises the widget and
// right-click opens the menu — the standard menu-bar-app split; the
// `reverseTrayClick` setting swaps the two back to the original
// left=menu/right=raise mapping for anyone who prefers it (see
// `handleClick`). Both are bound directly on the status item's button rather
// than through `statusItem.menu`, which on macOS binds *both* clicks to the
// menu and would leave no click free to raise a widget hiding behind other
// windows.
final class TrayController: NSObject, NSMenuDelegate {
    private let timer: PomodoroTimer
    private let settingsStore: SettingsStore
    private let widgetWindow: WidgetWindow
    private let updateChecker: AppUpdateChecker
    private let focusedOwnWindow: () -> NSWindow?
    private let onOpenSettingsRequested: () -> Void
    private let onQuitRequested: () -> Void

    private let statusItem: NSStatusItem
    private var updateTimer: Timer?

    private var lastTitle: String?
    private var lastFrameIndex = -1
    private var lastTooltip: String?

    init(
        timer: PomodoroTimer, settingsStore: SettingsStore, widgetWindow: WidgetWindow, updateChecker: AppUpdateChecker,
        focusedOwnWindow: @escaping () -> NSWindow?,
        onOpenSettingsRequested: @escaping () -> Void, onQuitRequested: @escaping () -> Void
    ) {
        self.timer = timer
        self.settingsStore = settingsStore
        self.widgetWindow = widgetWindow
        self.updateChecker = updateChecker
        self.focusedOwnWindow = focusedOwnWindow
        self.onOpenSettingsRequested = onOpenSettingsRequested
        self.onQuitRequested = onQuitRequested
        // .variableLength, not .squareLength: the button shows the live
        // clock next to the icon, matching main.js's tray.setTitle.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = Self.trayImage(frameIndex: 0)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        refresh()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        updateTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        // Re-read at click time, not captured, so a settings change mid-
        // session takes effect on the very next click (same pattern as
        // handleToggleAlwaysOnTop).
        let reversed = settingsStore.get().reverseTrayClick
        let isRightClick = event.type == .rightMouseUp
        if isRightClick == reversed {
            widgetWindow.raise()
        } else {
            popMenu()
        }
    }

    private func popMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    // macOS gives event focus to the status bar for as long as the menu is
    // up, and hands activation back to whichever *application* was
    // frontmost when it closes. Pomoppi is an accessory app, so it's never
    // that application — any window of ours that was in front ends up
    // behind whatever is. Restore only activation here, never the window
    // level (SPEC.md §9b owns that solely through the alwaysOnTop setting).
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        guard let restore = focusedOwnWindow() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A menu item may have deliberately moved focus (Settings…) or
            // taken the window away (Quit) — leave that alone.
            if self.focusedOwnWindow() != nil { return }
            guard restore.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            restore.makeKeyAndOrderFront(nil)
        }
    }

    // -- menu -----------------------------------------------------------------

    private func buildMenu() -> NSMenu {
        let state = timer.getState()
        let settings = settingsStore.get()
        let idle = state.phase == .idle
        let widgetVisible = widgetWindow.isVisible

        let menu = NSMenu()

        // Only present at all when a check has actually resolved to a newer
        // release (release/update plan, phase R6) — no greyed-out "no
        // update" placeholder item the rest of the time.
        if case .updateAvailable(let tag, _) = updateChecker.latestResult {
            menu.addItem(makeItem(title: "Update available: \(tag)", action: #selector(handleOpenUpdatePage)))
            menu.addItem(.separator())
        }

        menu.addItem(makeItem(
            title: state.running ? "Pause" : "Start", action: #selector(handleStartPause),
            shortcut: settings.shortcuts["startPause"]))
        menu.addItem(makeItem(
            title: "Skip", action: #selector(handleSkip), enabled: !idle, shortcut: settings.shortcuts["skip"]))
        menu.addItem(makeItem(
            title: "Reset", action: #selector(handleReset), enabled: !idle, shortcut: settings.shortcuts["reset"]))
        menu.addItem(.separator())

        let sessionsItem = NSMenuItem(title: "Sessions per long break", action: nil, keyEquivalent: "")
        sessionsItem.submenu = buildSessionsSubmenu(current: settings.longBreakEvery)
        menu.addItem(sessionsItem)
        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: widgetVisible ? "Hide Pomoppi" : "Show Pomoppi", action: #selector(handleToggleVisibility),
            shortcut: settings.shortcuts["toggleWidget"]))
        let keepOnTop = makeItem(
            title: "Keep on top", action: #selector(handleToggleAlwaysOnTop), shortcut: settings.shortcuts["toggleOnTop"])
        keepOnTop.state = settings.alwaysOnTop ? .on : .off
        menu.addItem(keepOnTop)
        menu.addItem(.separator())

        menu.addItem(makeItem(
            title: "Settings…", action: #selector(handleOpenSettings), shortcut: settings.shortcuts["openSettings"]))
        menu.addItem(makeItem(title: "Quit", action: #selector(handleQuit)))

        return menu
    }

    private func buildSessionsSubmenu(current: Int) -> NSMenu {
        let menu = NSMenu()
        for n in WidgetLayout.dotMin...WidgetLayout.dotMax {
            let item = makeItem(title: "\(n)", action: #selector(handleSetLongBreakEvery(_:)))
            item.state = n == current ? .on : .off
            item.tag = n
            menu.addItem(item)
        }
        return menu
    }

    // Wired through NSMenuItem's own keyEquivalent/keyEquivalentModifierMask
    // rather than appended text, so the combo renders the same dimmed,
    // right-aligned way every other macOS app's menu shortcuts do. Safe
    // alongside the already-live GlobalShortcutManager binding: this menu is
    // a transient, freshly-built popup (never installed as NSApp.mainMenu),
    // so AppKit only ever consults its keyEquivalents while it's the one
    // actually open and tracking — never as a second, competing system-wide
    // binding the way it would if this were a persistent menu bar item.
    private func makeItem(title: String, action: Selector, enabled: Bool = true, shortcut: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if let shortcut, let (glyph, mask) = Self.keyEquivalent(for: shortcut) {
            item.keyEquivalent = glyph
            item.keyEquivalentModifierMask = mask
        }
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // Only the handful of key names Shortcuts.canonicalKey can actually
    // produce that aren't already a single displayable character.
    private static let namedKeyGlyphs: [String: String] = [
        "Space": " ", "Return": "\r", "Enter": "\r", "Tab": "\t",
        "Backspace": "\u{8}", "Delete": "\u{7f}", "Escape": "\u{1b}", "Plus": "+",
        "Up": "\u{F700}", "Down": "\u{F701}", "Left": "\u{F702}", "Right": "\u{F703}",
    ]

    // "Alt+Shift+P" -> (" p", [.option, .shift]) etc. Returns nil for a
    // combo with no modifier or a key this table doesn't know how to render
    // (there are none among today's defaults) — better a plain, unhinted
    // item than a wrong or crashing keyEquivalent.
    private static func keyEquivalent(for accel: String) -> (String, NSEvent.ModifierFlags)? {
        guard !accel.isEmpty else { return nil }
        let parts = accel.split(separator: "+").map(String.init)
        guard let key = parts.last else { return nil }

        var mask: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "Command", "CommandOrControl": mask.insert(.command)
            case "Control": mask.insert(.control)
            case "Alt": mask.insert(.option)
            case "Shift": mask.insert(.shift)
            default: break
            }
        }
        guard !mask.isEmpty else { return nil }

        if let glyph = namedKeyGlyphs[key] { return (glyph, mask) }
        if key.count == 1 { return (key.lowercased(), mask) }
        return nil
    }

    // -- actions --------------------------------------------------------------

    @objc private func handleStartPause() {
        if timer.getState().running {
            timer.pause()
        } else {
            StartCoordinator.requestStart(timer: timer, settingsStore: settingsStore)
        }
    }

    @objc private func handleSkip() { timer.skip() }
    @objc private func handleReset() { timer.reset() }

    @objc private func handleToggleVisibility() {
        if widgetWindow.isVisible { widgetWindow.hide() } else { widgetWindow.raise() }
    }

    @objc private func handleToggleAlwaysOnTop() {
        settingsStore.update { $0.alwaysOnTop.toggle() }
    }

    @objc private func handleSetLongBreakEvery(_ sender: NSMenuItem) {
        settingsStore.update { $0.longBreakEvery = sender.tag }
    }

    @objc private func handleOpenSettings() { onOpenSettingsRequested() }
    @objc private func handleQuit() { onQuitRequested() }

    @objc private func handleOpenUpdatePage() {
        guard case .updateAvailable(_, let pageURL) = updateChecker.latestResult else { return }
        NSWorkspace.shared.open(pageURL)
    }

    // -- periodic refresh (icon animation, clock, tooltip) ---------------------

    private func refresh() {
        let state = timer.getState()

        let clock = Self.formatClock(state.remainingMs)
        if clock != lastTitle {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            statusItem.button?.attributedTitle = NSAttributedString(string: clock, attributes: [.font: font])
            lastTitle = clock
        }

        let frames = GeneratedSprites.trayFrames
        if frames.count > 1 {
            let frameIndex = Int(Date().timeIntervalSince1970 * 1000 / 500) % frames.count
            if frameIndex != lastFrameIndex {
                statusItem.button?.image = Self.trayImage(frameIndex: frameIndex)
                lastFrameIndex = frameIndex
            }
        }

        let tooltip = "\(Self.phaseLabel(state.phase)) — \(clock)"
        if tooltip != lastTooltip {
            statusItem.button?.toolTip = tooltip
            lastTooltip = tooltip
        }
    }

    private static func formatClock(_ ms: Double) -> String {
        let totalSeconds = max(0, Int((ms / 1000).rounded(.up)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func phaseLabel(_ phase: Phase) -> String {
        switch phase {
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        case .idle: return "Idle"
        }
    }

    private static func trayImage(frameIndex: Int) -> NSImage? {
        let frames = GeneratedSprites.trayFrames
        guard !frames.isEmpty else { return nil }
        let frame = frames[frameIndex % frames.count]
        let canvas = PixelCanvas(width: 16, height: 16)
        canvas.drawIcon(frame, 0, 0, "#000000")
        guard let cgImage = canvas.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }
}
