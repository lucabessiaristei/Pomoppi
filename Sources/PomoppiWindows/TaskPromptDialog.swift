// TaskPromptDialog.swift — the Win32 modal StartCoordinator shows before a
// fresh focus session, standing in for macOS's NSAlert-based
// promptForTaskName (Sources/PomoppiApp/StartCoordinator.swift). This
// codebase has no dialog templates or resource-file UI anywhere
// (Pomoppi.rc carries only an icon + VERSIONINFO) — every window here is a
// registered class + WndProc, and this follows that shape too, rather than
// DialogBoxParamW. T1 built the mouse-driven light-mode shape; T2 adds
// dark mode (via WindowsTheme.swift), the cue banner,
// Return/Escape handling, Tab order, work-area clamping, the hidden-widget
// centering path and the isShowing re-entrancy guard.
import Foundation
import WinSDK

// WNDPROC can't capture, so it dispatches through whichever prompt is
// currently showing — same "shared instance" shape as
// pomoppiWidgetWndProc/pomoppiSettingsWndProc.
private func pomoppiTaskPromptWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let dialog = TaskPromptDialog.current, let hwnd, dialog.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return dialog.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

// SetWindowTheme's "DarkMode_Explorer" doesn't restyle a plain EDIT's own
// WS_EX_CLIENTEDGE sunken border, which stays bright system white —
// confirmed live for the exact same control shape in
// SettingsWindow.swift's stepper edit (see that file's
// pomoppiStepperSubclassProc/handleStepperEditNCPaint). Same fix here:
// take over WM_NCPAINT for the edit control only, and only in dark mode.
private func pomoppiTaskPromptEditSubclassProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM, _ subclassID: UINT_PTR, _ refData: DWORD_PTR) -> LRESULT {
    guard let dialog = TaskPromptDialog.current, let hwnd, dialog.editHwnd == hwnd, dialog.darkMode, message == UINT(WM_NCPAINT) else {
        return DefSubclassProc(hwnd, message, wParam, lParam)
    }
    return dialog.handleEditNCPaint()
}

enum TaskPromptResult {
    case started(String)
    case cancelled
}

// Owned by the widget's hwnd (WS_POPUP | WS_CAPTION | WS_SYSMENU, no
// WS_EX_TOPMOST of its own) so it always sits above the always-on-top
// widget without needing to out-rank it in z-order. Modal via the
// nested-loop kind: disables the owner for run()'s duration and pumps its
// own GetMessageW loop until Start/Cancel sets a result — the same
// "blocks this app's message loop" shape MessageBoxW already has at every
// other confirmation in this codebase (SettingsWindow's
// confirmEraseSessionLog/confirmResetToDefaults), just hand-rolled instead
// of a common dialog.
final class TaskPromptDialog {
    fileprivate static var current: TaskPromptDialog?

    // The re-entrancy guard StartCoordinator checks before ever calling
    // run() — WM_HOTKEY is posted to the widget's hwnd and is still
    // dispatched by the nested loop below even while that window is
    // disabled, so the startPause hotkey pressed twice fast can otherwise
    // re-enter requestStart while the first prompt is still up.
    static var isShowing: Bool { current != nil }

    // What the re-entrant call above actually does instead of stacking a
    // second prompt — just bring the existing one back to the foreground.
    static func refocus() {
        guard let current else { return }
        SetForegroundWindow(current.hwnd)
    }

    let hwnd: HWND
    // Non-private — pomoppiTaskPromptEditSubclassProc needs to identify
    // this HWND from outside the class, same reason SettingsWindow's
    // tabControl/isDarkModeActive aren't private themselves.
    var editHwnd: HWND!
    let darkMode: Bool
    private let owner: HWND
    private var startButton: HWND!
    private var cancelButton: HWND!
    private var result: TaskPromptResult?

    private static let className: [UInt16] = Array("PomoppiTaskPromptClass".utf16) + [0]
    private static let windowTitle: [UInt16] = Array("Pomoppi".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let editClassName: [UInt16] = Array("EDIT".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)
    private static var classRegistered = false

    // ~340x150 client, per the plan — wide enough for the two-line
    // mandatory hint, short enough to read as a small prompt rather than a
    // window in its own right.
    private static let clientWidth: Int32 = 340
    private static let clientHeight: Int32 = 150
    // WS_POPUP imports as UInt32 (its raw value doesn't fit Int32, unlike
    // WS_CAPTION/WS_SYSMENU) — same "convert each to DWORD before ORing"
    // workaround addLabel's alignmentStyle needs, just with no bitPattern:
    // involved since WS_POPUP is already unsigned.
    private static let windowStyle = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)

    private static func registerClassIfNeeded() {
        guard !classRegistered else { return }
        let atom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiTaskPromptWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            windowClass.hIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON))
            return RegisterClassW(&windowClass)
        }
        guard atom != 0 else {
            fatalError("RegisterClassW (task prompt) failed with error \(GetLastError())")
        }
        classRegistered = true
    }

    // The only entry point — StartCoordinator is the only caller, and only
    // once it has already checked isShowing itself. Builds the window,
    // runs the modal loop to completion, tears the window down, and
    // returns what the user did. darkMode is resolved by the caller
    // (WindowsTheme.resolveDarkMode) rather than read from a SettingsStore
    // here — this dialog stays a fixed, short-lived snapshot rather than
    // reacting live to a theme change mid-prompt, unlike SettingsWindow.
    static func run(owner: HWND, mandatory: Bool, darkMode: Bool) -> TaskPromptResult {
        registerClassIfNeeded()
        let dialog = TaskPromptDialog(owner: owner, mandatory: mandatory, darkMode: darkMode)
        current = dialog
        defer { current = nil }
        return dialog.runModal()
    }

    private init(owner: HWND, mandatory: Bool, darkMode: Bool) {
        self.owner = owner
        self.darkMode = darkMode

        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top

        // The primary monitor's work area (screen minus taskbar) — both the
        // hidden-widget fallback center point and the clamp every placement
        // goes through below, so the prompt can never land partly
        // off-screen even when the widget itself is sitting hard against an
        // edge.
        var workArea = RECT(left: 0, top: 0, right: 0, bottom: 0)
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &workArea, 0)

        var x: Int32
        var y: Int32
        if IsWindowVisible(owner) {
            var ownerRect = RECT()
            GetWindowRect(owner, &ownerRect)
            x = ownerRect.left + ((ownerRect.right - ownerRect.left) - windowWidth) / 2
            y = ownerRect.top + ((ownerRect.bottom - ownerRect.top) - windowHeight) / 2
        } else {
            // The startPause global hotkey can start a session while the
            // widget is hidden (startHidden, or Escape) — GetWindowRect on
            // a hidden owner still returns its old rect, so center on the
            // work area instead; runModal's own SetForegroundWindow is what
            // actually brings this to the front in that case, since nothing
            // of Pomoppi's is foreground then.
            x = workArea.left + ((workArea.right - workArea.left) - windowWidth) / 2
            y = workArea.top + ((workArea.bottom - workArea.top) - windowHeight) / 2
        }
        x = max(workArea.left, min(x, workArea.right - windowWidth))
        y = max(workArea.top, min(y, workArea.bottom - windowHeight))

        guard let createdHwnd = (Self.className.withUnsafeBufferPointer { classNamePtr in
            Self.windowTitle.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, titlePtr.baseAddress,
                    Self.windowStyle,
                    x, y, windowWidth, windowHeight,
                    owner, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (task prompt) failed with error \(GetLastError())")
        }
        hwnd = createdHwnd

        // The titlebar shows the small icon; without WM_SETICON it falls
        // back to the generic window icon (same pair SettingsWindow sets).
        if let bigIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON)) {
            SendMessageW(createdHwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_BIG)), LPARAM(Int(bitPattern: bigIcon)))
        }
        if let smallIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXSMICON), height: GetSystemMetrics(SM_CYSMICON)) {
            SendMessageW(createdHwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_SMALL)), LPARAM(Int(bitPattern: smallIcon)))
        }

        if darkMode {
            // DWMWA_USE_IMMERSIVE_DARK_MODE before the first ShowWindow
            // (runModal, not here) so the titlebar never flashes light —
            // same attribute SettingsWindow.applyTheme() sets, just once
            // here rather than live-reapplied, since this dialog's theme
            // never changes mid-prompt.
            var useDarkMode: Int32 = 1
            _ = DwmSetWindowAttribute(hwnd, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &useDarkMode, DWORD(MemoryLayout<Int32>.size))
        }

        buildControls(mandatory: mandatory)
    }

    // -- controls ---------------------------------------------------------

    private func buildControls(mandatory: Bool) {
        addLabel("What are you working on?", x: 16, y: 16, width: 308, height: 20)

        guard let edit = (Self.editClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                DWORD(WS_EX_CLIENTEDGE), classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL),
                16, 42, 308, 24,
                hwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (task prompt edit) failed with error \(GetLastError())")
        }
        applyDefaultFont(edit)
        editHwnd = edit
        // SetWindowTheme first, cue banner second — confirmed live the
        // other way around: SetWindowTheme posts WM_THEMECHANGED, which
        // resets the edit's own cue-banner state set moments earlier, so
        // the banner never renders even with the wParam fix above.
        if darkMode { Self.applyDarkExplorerTheme(edit) }
        applyCueBanner(edit)
        // WM_NCPAINT only fires for the edit's own subclass, gated on
        // darkMode there — installed unconditionally here, same as
        // SettingsWindow's own subclasses, since there's only ever one edit
        // control in this window for it to matter for.
        _ = SetWindowSubclass(edit, pomoppiTaskPromptEditSubclassProc, 1, 0)

        // Same two strings macOS's promptForTaskName uses for
        // alert.informativeText, mandatory vs. optional.
        let hintText = mandatory
            ? "Session logging is on, so this session needs a task name to log a useful line."
            : "Optional — leave blank to skip."
        addLabel(hintText, x: 16, y: 74, width: 308, height: 40)

        // Same right-to-left order as macOS's NSAlert (Start added first,
        // ends up rightmost/default; Cancel to its left) — also this
        // window's own Tab order (edit -> Cancel -> Start -> wraps), which
        // reads left to right on screen.
        cancelButton = addButton("Cancel", x: 156, y: 114, width: 80, height: 26)
        startButton = addButton("Start", x: 244, y: 114, width: 80, height: 26, isDefault: true)

        if darkMode {
            Self.applyDarkExplorerTheme(cancelButton)
            Self.applyDarkExplorerTheme(startButton)
        }
    }

    // EM_SETCUEBANNER. wParam must be zero — confirmed live: passing 1
    // (the documented fDrawFocused flag some later comctl32 versions
    // support, meant to keep the banner visible even while focused) makes
    // this whole call a silent no-op on this build, so the banner never
    // shows at all, focused or not. Plain wParam=0 is the form guaranteed
    // since Vista and does show correctly once focus leaves the field —
    // the cost is that it stays hidden while runModal's own initial
    // SetFocus(editHwnd) has focus here, which is an acceptable trade for
    // a control that's actually visible.
    private func applyCueBanner(_ edit: HWND) {
        var wide = Array("Task or project name".utf16) + [0]
        wide.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = SendMessageW(edit, UINT(EM_SETCUEBANNER), WPARAM(0), LPARAM(Int(bitPattern: base)))
        }
    }

    @discardableResult
    private func addLabel(_ text: String, x: Int32, y: Int32, width: Int32, height: Int32) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let label = (Self.staticClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | SS_NOPREFIX),
                    x, y, width, height,
                    hwnd, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (task prompt label) failed with error \(GetLastError())")
        }
        applyDefaultFont(label)
        return label
    }

    private func addButton(_ text: String, x: Int32, y: Int32, width: Int32, height: Int32, isDefault: Bool = false) -> HWND {
        let wide = Array(text.utf16) + [0]
        let buttonStyle = isDefault ? BS_DEFPUSHBUTTON : BS_PUSHBUTTON
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | buttonStyle),
                    x, y, width, height,
                    hwnd, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (task prompt button) failed with error \(GetLastError())")
        }
        applyDefaultFont(button)
        return button
    }

    private func applyDefaultFont(_ hwnd: HWND?) {
        guard let hwnd, let font = GetStockObject(DEFAULT_GUI_FONT) else { return }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
    }

    // -- dark mode ----------------------------------------------------------

    // SetWindowTheme (uxtheme.dll) needs its own manual LoadLibraryW/
    // GetProcAddress load — not one of the libraries a plain MSVC-linked
    // exe gets by default (see SettingsWindow.swift's own identical copy of
    // this dance for the full finding). A second, small local copy rather
    // than reaching into SettingsWindow's private one — this file stands on
    // its own the same way every other Windows-side file in this port does
    // (CLAUDE.md's "duplicated small amounts of logic" precedent, applied
    // within this port rather than across the mac/Windows boundary here).
    private typealias SetWindowThemeProc = @convention(c) (HWND?, LPCWSTR?, LPCWSTR?) -> HRESULT
    private static let setWindowThemeProc: SetWindowThemeProc? = {
        let moduleName: [UInt16] = Array("uxtheme.dll".utf16) + [0]
        guard let module = (moduleName.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }) else { return nil }
        guard let proc = GetProcAddress(module, "SetWindowTheme") else { return nil }
        return unsafeBitCast(proc, to: SetWindowThemeProc.self)
    }()

    // "DarkMode_Explorer" restyles a BS_PUSHBUTTON with a dark face + light
    // text and an EDIT's own interior background — verified live for these
    // same two control types in SettingsWindow.swift (setControlDarkTheme's
    // own comment). The edit's text color still needs handleCtlColor's
    // WM_CTLCOLOREDIT case below; the buttons need nothing further.
    private static func applyDarkExplorerTheme(_ hwnd: HWND) {
        guard let setWindowThemeProc else { return }
        let subAppName: [UInt16] = Array("DarkMode_Explorer".utf16) + [0]
        _ = subAppName.withUnsafeBufferPointer { setWindowThemeProc(hwnd, $0.baseAddress, nil) }
    }

    // The WS_EX_CLIENTEDGE sunken border DefWindowProc draws on WM_NCPAINT
    // stays bright system white even with DarkMode_Explorer applied to the
    // edit above — confirmed for the identical control shape in
    // SettingsWindow's stepper edit. Fills just the 2px border itself
    // (GetClientRect's interior is left untouched) so a live repaint here
    // never overwrites whatever the user has already typed. Simpler than
    // SettingsWindow's own two-tone ring (darkElevatedHex outline over
    // darkBackgroundHex) — a flat single-color border reading as "blended
    // into the dialog" is enough for this one small control.
    func handleEditNCPaint() -> LRESULT {
        var windowRect = RECT()
        GetWindowRect(editHwnd, &windowRect)
        let width = windowRect.right - windowRect.left
        let height = windowRect.bottom - windowRect.top
        guard width > 4, height > 4, let hdc = GetWindowDC(editHwnd), let brush = WindowsTheme.darkBackgroundBrush else { return 0 }
        defer { ReleaseDC(editHwnd, hdc) }
        var topEdge = RECT(left: 0, top: 0, right: width, bottom: 2)
        var bottomEdge = RECT(left: 0, top: height - 2, right: width, bottom: height)
        var leftEdge = RECT(left: 0, top: 0, right: 2, bottom: height)
        var rightEdge = RECT(left: width - 2, top: 0, right: width, bottom: height)
        FillRect(hdc, &topEdge, brush)
        FillRect(hdc, &bottomEdge, brush)
        FillRect(hdc, &leftEdge, brush)
        FillRect(hdc, &rightEdge, brush)
        return 0
    }

    // hbrBackground (registerClassIfNeeded) is fixed at class-registration
    // time and can't be swapped live — this is what actually paints this
    // window's own client area dark instead. Light mode falls through to
    // DefWindowProcW unchanged, the class's own COLOR_BTNFACE brush, same
    // as before dark mode existed.
    private func handleEraseBackground(wParam: WPARAM) -> LRESULT {
        // Int(bitPattern:) rather than a range-checked Int(wParam) — a bare
        // Int(_:) traps live on a real HDC value (confirmed via a crash
        // dump for the identical conversion in SettingsWindow's own
        // handleEraseBackground).
        guard darkMode, let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))), let brush = WindowsTheme.darkBackgroundBrush else {
            return DefWindowProcW(hwnd, UINT(WM_ERASEBKGND), wParam, 0)
        }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        FillRect(hdc, &rect, brush)
        return 1
    }

    // SetWindowTheme above doesn't restyle a plain STATIC label's text, nor
    // an EDIT's own text color (see applyDarkExplorerTheme's own comment) —
    // this is what does, for whichever of the two sent WM_CTLCOLORSTATIC/
    // WM_CTLCOLOREDIT/WM_CTLCOLORBTN (all three arrive here since this
    // window is the direct parent of every control). Light mode falls
    // through unchanged.
    private func handleCtlColor(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        guard darkMode, let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))), let brush = WindowsTheme.darkBackgroundBrush else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        SetTextColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkTextHex))
        SetBkColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex))
        return LRESULT(Int(bitPattern: brush))
    }

    // -- modal loop ---------------------------------------------------------

    // EnableWindow(owner, false) + a GetMessageW loop until Start/Cancel
    // sets a result, then re-enable the owner BEFORE DestroyWindow — doing
    // it after hands activation to some other app's window instead of back
    // to Pomoppi. GetMessageW's nil hwnd filter (not just this window's own
    // messages) is also what keeps the widget's ~60fps WM_TIMER repaint
    // pumping while this is up, since that timer belongs to the (disabled
    // but not hidden) owner, not to this dialog.
    private func runModal() -> TaskPromptResult {
        EnableWindow(owner, false)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
        SetFocus(editHwnd)

        var message = MSG()
        while result == nil, GetMessageW(&message, nil, 0, 0) {
            // VK_RETURN/VK_ESCAPE are intercepted here, on WM_KEYDOWN,
            // before TranslateMessage/IsDialogMessageW — a single-line EDIT
            // beeps at a WM_CHAR carrying Return otherwise, and relying on
            // IsDialogMessageW's own DM_GETDEFID path for a non-dialog
            // window class is the kind of thing that works until it
            // doesn't. Return activates whichever button currently has
            // focus (matching a real dialog's own Enter behavior) and
            // falls back to the default button (Start) when focus is on
            // the edit field; Escape always cancels regardless of focus.
            if message.message == UINT(WM_KEYDOWN) {
                let vk = Int32(truncatingIfNeeded: message.wParam)
                if vk == VK_RETURN {
                    result = (GetFocus() == cancelButton) ? .cancelled : .started(readTask())
                    continue
                }
                if vk == VK_ESCAPE {
                    result = .cancelled
                    continue
                }
            }
            // IsDialogMessageW still runs for everything else, for Tab/
            // Shift+Tab navigation between the edit and the two buttons
            // (WS_TABSTOP on all three, set in buildControls).
            if !IsDialogMessageW(hwnd, &message) {
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
        }

        EnableWindow(owner, true)
        DestroyWindow(hwnd)
        return result ?? .cancelled
    }

    private func readTask() -> String {
        let length = GetWindowTextLengthW(editHwnd)
        var buffer = [UInt16](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(editHwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // -- WndProc dispatch ---------------------------------------------------

    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_COMMAND:
            let notificationCode = Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
            guard notificationCode == BN_CLICKED, let controlHwnd = HWND(bitPattern: Int(lParam)) else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            if controlHwnd == startButton {
                result = .started(readTask())
            } else if controlHwnd == cancelButton {
                result = .cancelled
            }
            return 0
        case WM_CLOSE:
            // The system menu's Close item / Alt-F4 — same as Cancel
            // rather than letting DefWindowProcW destroy the window out
            // from under runModal's own loop.
            result = .cancelled
            return 0
        case WM_ERASEBKGND:
            return handleEraseBackground(wParam: wParam)
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT:
            return handleCtlColor(message: message, wParam: wParam, lParam: lParam)
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }
}
