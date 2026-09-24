// TrayController.swift — the Windows notification-area icon: setup, the
// 500ms icon/tooltip refresh, click dispatch, and the right-click context
// menu. Ported from Sources/PomoppiApp/TrayController.swift's structure and
// "only push what changed" discipline, onto Shell_NotifyIcon/Win32 menus.
// Kept as its own object (not a WidgetWindow extension) reusing the
// widget's own hwnd — no second hidden window needed, same separateness
// the macOS TrayController has from its WidgetWindow.
import Foundation
import PomoppiCore
import PomoppiRender
import PomoppiSprites
import WinSDK

final class TrayController {
    private let window: WidgetWindow

    // A different timer ID than WidgetWindow's own frame-loop timer (1) —
    // both share the same hwnd/WndProc, so WM_TIMER needs the ID to tell
    // them apart (see WidgetWindow.handleMessage's WM_TIMER case).
    static let timerID: UINT_PTR = 2

    // WM_APP-based custom message for Shell_NotifyIcon's callback — WM_APP
    // imports as a plain Int32 in this overlay (confirmed in the Phase W0
    // spike), so plain arithmetic on it is fine.
    static let callbackMessageID: UINT32 = UINT32(WM_APP + 1)

    private static let iconUID: UINT32 = 1
    // "Sessions per long break" submenu command IDs are this base plus the
    // session count (WidgetLayout.dotMin...dotMax = 2...10, i.e. IDs
    // 102...110) — well clear of CommandID's 1...7 range below.
    private static let longBreakBaseID: Int32 = 100

    // WM_COMMAND delivers the chosen item's ID in wParam's low word, not a
    // selector — this is that ID space for every static menu item.
    private enum CommandID: Int32 {
        case startPause = 1
        case skip = 2
        case reset = 3
        case toggleVisibility = 4
        case toggleAlwaysOnTop = 5
        case settings = 6
        case quit = 7
        case openUpdatePage = 8
    }

    private var nid = NOTIFYICONDATAW()
    // CreateIconIndirect copies the bits it's given but Shell_NotifyIcon
    // does not — the icon handle `nid.hIcon` points at has to outlive the
    // call and stay alive as long as the tray icon references it, so it's
    // tracked here and only destroyed once superseded by a newer frame (or
    // on teardown) — skipping this leaks an HICON every time the animation
    // advances.
    private var currentIcon: HICON?

    private var lastFrameIndex = -1
    private var lastTooltip: String?
    private var lastLightTaskbar: Bool?

    init(window: WidgetWindow) {
        self.window = window
        setUp()
    }

    private func setUp() {
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = window.hwnd
        nid.uID = Self.iconUID
        nid.uFlags = UINT(NIF_ICON) | UINT(NIF_MESSAGE) | UINT(NIF_TIP)
        nid.uCallbackMessage = Self.callbackMessageID

        lastFrameIndex = 0
        let lightTaskbar = Self.systemPrefersLightTaskbar()
        lastLightTaskbar = lightTaskbar
        let icon = Self.trayIcon(frameIndex: lastFrameIndex, lightTaskbar: lightTaskbar)
        nid.hIcon = icon
        currentIcon = icon

        let tooltip = currentTooltip()
        lastTooltip = tooltip
        setTip(tooltip)

        Shell_NotifyIconW(DWORD(NIM_ADD), &nid)

        // Try the modern callback semantics; a failed NIM_SETVERSION isn't
        // fatal, the icon still works under the default (v0) callback
        // shape — and handleTrayCallback below reads the mouse message the
        // same way regardless of which one is actually active (see its
        // comment).
        nid.uVersion = UINT(NOTIFYICON_VERSION_4)
        let versionOK: Bool = Shell_NotifyIconW(DWORD(NIM_SETVERSION), &nid)
        print("Pomoppi: tray NIM_SETVERSION(NOTIFYICON_VERSION_4) \(versionOK ? "succeeded" : "failed, falling back to legacy (v0) callback semantics")")

        SetTimer(window.hwnd, Self.timerID, 500, nil)
    }

    // Called from WidgetWindow.handleMessage's WM_TIMER case for any timer
    // ID that isn't its own frame-loop timer.
    func handleTimer(id: UINT_PTR) {
        guard id == Self.timerID else { return }
        refresh()
    }

    // Called from WidgetWindow.handleMessage for the custom callback
    // message set up above. lParam's encoding differs slightly between
    // NOTIFYICON_VERSION_4 (mouse/keyboard message in the LOWORD, icon ID
    // in the HIWORD) and legacy v0 behavior (lParam IS the message,
    // unpacked) — but since every message value here fits in 16 bits
    // either way, reading the low word recovers the right value under
    // both, no branch on `versionOK` needed.
    func handleTrayCallback(lParam: LPARAM) {
        let message = Int32(UInt16(truncatingIfNeeded: lParam))
        switch message {
        case WM_LBUTTONUP, WM_RBUTTONUP:
            let isRightClick = message == WM_RBUTTONUP
            // Re-read at click time, not captured, so a settings change
            // mid-session takes effect on the very next click (same
            // pattern as macOS's handleClick).
            let reversed = window.settingsStore.get().reverseTrayClick
            if isRightClick == reversed {
                window.setVisible(true)
            } else {
                showMenu()
            }
        default:
            break
        }
    }

    // Called from WidgetWindow.handleMessage's WM_COMMAND case.
    func handleCommand(wParam: WPARAM) {
        let id = Int32(truncatingIfNeeded: UInt16(truncatingIfNeeded: wParam))
        if let command = CommandID(rawValue: id) {
            switch command {
            case .startPause:
                window.activateButton("play")
            case .skip:
                window.activateButton("skip")
            case .reset:
                window.activateButton("reset")
            case .toggleVisibility:
                let visible: Bool = IsWindowVisible(window.hwnd)
                window.setVisible(!visible)
            case .toggleAlwaysOnTop:
                window.toggleAlwaysOnTop()
            case .settings:
                // Same single call site every "open settings" trigger goes
                // through — see WidgetWindow.onOpenSettingsRequested.
                window.activateButton("settings")
            case .quit:
                // Triggers WidgetWindow's existing WM_DESTROY handler, which
                // already calls PostQuitMessage — no need to call it again
                // here.
                DestroyWindow(window.hwnd)
            case .openUpdatePage:
                guard case .updateAvailable(_, let pageURL, _) = window.updateChecker?.latestResult else { return }
                Self.openURL(pageURL)
            }
            return
        }

        let n = Int(id - Self.longBreakBaseID)
        guard WidgetLayout.dotMin...WidgetLayout.dotMax ~= n else { return }
        window.settings = window.settingsStore.update { $0.longBreakEvery = n }
    }

    // Called from WidgetWindow.handleMessage's WM_DESTROY case, alongside
    // its own timer cleanup — a tray icon left registered after the
    // process exits is a well-known Win32 rough edge (a "ghost" icon
    // lingering in the tray until the user hovers over it).
    func tearDown() {
        KillTimer(window.hwnd, Self.timerID)
        Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
        if let currentIcon { DestroyIcon(currentIcon) }
        currentIcon = nil
    }

    // -- periodic refresh (icon animation, tooltip) --------------------------

    // Same 500ms cadence and "hold the last pushed value, no-op if
    // unchanged" discipline as macOS's TrayController.refresh() — only
    // difference is a manually-built HICON has to be disposed once
    // superseded, which NSImage never required. Also polls the taskbar
    // light/dark setting here rather than listening for
    // WM_SETTINGCHANGE("ImmersiveColorSet") — this timer already fires
    // every 500ms regardless, so re-reading one more cheap registry value
    // alongside it is simpler than wiring a second notification path for
    // something that changes this rarely.
    private func refresh() {
        let frameCount = GeneratedSprites.trayFrames.count
        guard frameCount > 0 else { return }
        let frameIndex = Int(Date().timeIntervalSince1970 * 1000 / 500) % frameCount
        let tooltip = currentTooltip()
        let lightTaskbar = Self.systemPrefersLightTaskbar()

        var changed = false
        var newIcon: HICON?
        if frameIndex != lastFrameIndex || lightTaskbar != lastLightTaskbar {
            newIcon = Self.trayIcon(frameIndex: frameIndex, lightTaskbar: lightTaskbar)
            nid.hIcon = newIcon
            lastFrameIndex = frameIndex
            lastLightTaskbar = lightTaskbar
            changed = true
        }
        if tooltip != lastTooltip {
            setTip(tooltip)
            lastTooltip = tooltip
            changed = true
        }
        guard changed else { return }

        Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
        if let newIcon {
            if let old = currentIcon, old != newIcon { DestroyIcon(old) }
            currentIcon = newIcon
        }
    }

    private func currentTooltip() -> String {
        let state = window.state
        return "\(Self.phaseLabel(state.phase)) — \(Self.formatClock(state.remainingMs))"
    }

    // nid.szTip is a fixed-size inline WCHAR array (a tuple in the imported
    // struct, not a pointer) — the actual field size is read straight off
    // the struct's own memory rather than hardcoded, since headers have
    // shipped both 64- and 128-char versions of this field over the years.
    private func setTip(_ text: String) {
        withUnsafeMutableBytes(of: &nid.szTip) { raw in
            let slots = raw.bindMemory(to: UInt16.self)
            for i in slots.indices { slots[i] = 0 }
            for (i, unit) in text.utf16.prefix(slots.count - 1).enumerated() {
                slots[i] = unit
            }
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

    // Same 16x16 canvas + drawIcon(frame, 0, 0, ...) shape as macOS's
    // TrayController.trayImage(frameIndex:) — the tray frame grids are
    // already 16x16, drawn flush at the canvas origin. Unlike macOS (where
    // NSImage.isTemplate lets AppKit auto-tint the glyph for the current
    // menu-bar appearance), Win32 has no equivalent for a Shell_NotifyIcon
    // HICON — the ink color has to be picked explicitly to match the
    // taskbar's own light/dark setting, or a black icon disappears into a
    // dark taskbar (and vice versa for white-on-light).
    private static func trayIcon(frameIndex: Int, lightTaskbar: Bool) -> HICON? {
        let frames = GeneratedSprites.trayFrames
        guard !frames.isEmpty else { return nil }
        let canvas = PixelCanvas(width: 16, height: 16)
        canvas.drawIcon(frames[frameIndex % frames.count], 0, 0, lightTaskbar ? "#000000" : "#FFFFFF")
        return canvas.makeIcon()
    }

    // SystemUsesLightTheme (1 = light taskbar/Start/tray, 0 = dark) is the
    // same registry value Windows' own theme picker writes; defaults to
    // light (black icon) if the key/value is missing, matching this app's
    // "clamp rather than fail" stance elsewhere for absent settings.
    // HKEY_CURRENT_USER imports fine as a usable symbol in this WinSDK
    // overlay (confirmed by LoginItem.swift's RegOpenKeyExW call) — unlike
    // HWND_TOPMOST and friends elsewhere in this port, no bitPattern
    // reconstruction needed here.
    private static func systemPrefersLightTaskbar() -> Bool {
        var value: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".withCString(encodedAs: UTF16.self) { subKey in
            "SystemUsesLightTheme".withCString(encodedAs: UTF16.self) { valueName in
                RegGetValueW(HKEY_CURRENT_USER, subKey, valueName, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        guard status == ERROR_SUCCESS else { return true }
        return value != 0
    }

    // -- menu -----------------------------------------------------------------

    // Win32's NSWorkspace.shared.open(_:) equivalent — no extra linking
    // needed, shell32 is already in MSVC's default link set (confirmed by
    // Shell_NotifyIconW above, from the same DLL, already working with no
    // explicit linkerSettings entry the way winmm needed one).
    private static func openURL(_ url: URL) {
        let operation = Array("open".utf16) + [0]
        let target = Array(url.absoluteString.utf16) + [0]
        _ = operation.withUnsafeBufferPointer { opPtr in
            target.withUnsafeBufferPointer { targetPtr in
                ShellExecuteW(nil, opPtr.baseAddress, targetPtr.baseAddress, nil, nil, SW_SHOWNORMAL)
            }
        }
    }

    // Built fresh every time it's shown, mirroring macOS's buildMenu() —
    // no incremental checkbox syncing needed since it's a transient popup.
    private func showMenu() {
        let state = window.state
        let settings = window.settings
        let idle = state.phase == .idle
        let widgetVisible: Bool = IsWindowVisible(window.hwnd)

        guard let menu = CreatePopupMenu() else { return }
        var sessionsMenu: HMENU?
        defer {
            if let sessionsMenu { DestroyMenu(sessionsMenu) }
            DestroyMenu(menu)
        }

        // Only present at all when a check has actually resolved to a newer
        // release — no greyed-out "no
        // update" placeholder item the rest of the time.
        if case .updateAvailable(let tag, _, _) = window.updateChecker?.latestResult {
            appendItem(menu, .openUpdatePage, "Update available: \(tag)")
            appendSeparator(menu)
        }

        appendItem(menu, .startPause, state.running ? "Pause" : "Start")
        appendItem(menu, .skip, "Skip", enabled: !idle)
        appendItem(menu, .reset, "Reset", enabled: !idle)
        appendSeparator(menu)

        if let built = CreatePopupMenu() {
            sessionsMenu = built
            for n in WidgetLayout.dotMin...WidgetLayout.dotMax {
                appendItem(built, Self.longBreakBaseID + Int32(n), "\(n)", checked: n == settings.longBreakEvery)
            }
            appendSubmenu(menu, built, "Sessions per long break")
        }
        appendSeparator(menu)

        appendItem(menu, .toggleVisibility, widgetVisible ? "Hide Pomoppi" : "Show Pomoppi")
        appendItem(menu, .toggleAlwaysOnTop, "Keep on top", checked: settings.alwaysOnTop)
        appendSeparator(menu)

        appendItem(menu, .settings, "Settings…")
        appendItem(menu, .quit, "Quit")

        // The classic dismiss dance: without the trailing WM_NULL post, the
        // menu doesn't reliably dismiss on a click outside it.
        var cursor = POINT()
        GetCursorPos(&cursor)
        SetForegroundWindow(window.hwnd)
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), cursor.x, cursor.y, 0, window.hwnd, nil)
        PostMessageW(window.hwnd, UINT(WM_NULL), 0, 0)
    }

    private func appendItem(_ menu: HMENU, _ id: CommandID, _ title: String, enabled: Bool = true, checked: Bool = false) {
        appendItem(menu, id.rawValue, title, enabled: enabled, checked: checked)
    }

    private func appendItem(_ menu: HMENU, _ id: Int32, _ title: String, enabled: Bool = true, checked: Bool = false) {
        var flags = UINT(MF_STRING)
        if !enabled { flags |= UINT(MF_GRAYED) }
        if checked { flags |= UINT(MF_CHECKED) }
        let wide = Array(title.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { buf in
            AppendMenuW(menu, flags, UINT_PTR(id), buf.baseAddress)
        }
    }

    private func appendSeparator(_ menu: HMENU) {
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }

    private func appendSubmenu(_ menu: HMENU, _ submenu: HMENU, _ title: String) {
        let wide = Array(title.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { buf in
            AppendMenuW(menu, UINT(MF_STRING) | UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: submenu)), buf.baseAddress)
        }
    }
}
