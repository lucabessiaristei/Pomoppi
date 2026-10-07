// FeedbackHandledDialog.swift — the "How this email is handled" sheet: a
// small modal Win32 window owned by the Settings window, plain text and one
// Close button. Same shape as TaskPromptDialog.swift (registered class,
// nested modal loop, dark chrome via WindowsTheme, Return/Escape close).
import Foundation
import PomoppiStrings
import WinSDK

private func pomoppiFeedbackHandledWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let dialog = FeedbackHandledDialog.current, let hwnd, dialog.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return dialog.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

final class FeedbackHandledDialog {
    fileprivate static var current: FeedbackHandledDialog?

    let hwnd: HWND
    private let owner: HWND
    private let darkMode: Bool
    private var closeButton: HWND!
    private var done = false

    private static let className: [UInt16] = Array("PomoppiFeedbackHandledClass".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)
    private static var classRegistered = false
    private static let clientWidth: Int32 = 380
    private static let margin: Int32 = 16
    private static let windowStyle = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)

    private static func registerClassIfNeeded() {
        guard !classRegistered else { return }
        let atom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiFeedbackHandledWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            windowClass.hIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON))
            return RegisterClassW(&windowClass)
        }
        guard atom != 0 else {
            fatalError("RegisterClassW (feedback handled) failed with error \(GetLastError())")
        }
        classRegistered = true
    }

    static func run(owner: HWND, darkMode: Bool) {
        guard current == nil else { return }
        registerClassIfNeeded()
        let dialog = FeedbackHandledDialog(owner: owner, darkMode: darkMode)
        current = dialog
        defer { current = nil }
        dialog.runModal()
    }

    private init(owner: HWND, darkMode: Bool) {
        self.owner = owner
        self.darkMode = darkMode

        let lines = (1...4).map { L.t("feedback.handled.\($0)") }
        let textWidth = Self.clientWidth - 2 * Self.margin
        let heights = lines.map { Self.measuredHeight($0, width: textWidth) }
        let bodyHeight = heights.reduce(0, +) + 8 * Int32(lines.count - 1)
        // margin, body, gap, signature row, gap, button row, margin
        let clientHeight = Self.margin + bodyHeight + 12 + 18 + 16 + 26 + Self.margin

        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: clientHeight)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top

        var workArea = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &workArea, 0)
        var ownerRect = RECT()
        GetWindowRect(owner, &ownerRect)
        var x = ownerRect.left + ((ownerRect.right - ownerRect.left) - windowWidth) / 2
        var y = ownerRect.top + ((ownerRect.bottom - ownerRect.top) - windowHeight) / 2
        x = max(workArea.left, min(x, workArea.right - windowWidth))
        y = max(workArea.top, min(y, workArea.bottom - windowHeight))

        let title = Array(L.t("feedback.handled.link").utf16) + [0]
        guard let createdHwnd = (Self.className.withUnsafeBufferPointer { classNamePtr in
            title.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, titlePtr.baseAddress,
                    Self.windowStyle,
                    x, y, windowWidth, windowHeight,
                    owner, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (feedback handled) failed with error \(GetLastError())")
        }
        hwnd = createdHwnd

        if let bigIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON)) {
            SendMessageW(createdHwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_BIG)), LPARAM(Int(bitPattern: bigIcon)))
        }
        if let smallIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXSMICON), height: GetSystemMetrics(SM_CYSMICON)) {
            SendMessageW(createdHwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_SMALL)), LPARAM(Int(bitPattern: smallIcon)))
        }
        if darkMode {
            var useDarkMode: Int32 = 1
            _ = DwmSetWindowAttribute(hwnd, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &useDarkMode, DWORD(MemoryLayout<Int32>.size))
        }

        var rowY = Self.margin
        for (line, height) in zip(lines, heights) {
            addLabel(line, x: Self.margin, y: rowY, width: textWidth, height: height)
            rowY += height + 8
        }
        rowY += 4
        addLabel(L.t("feedback.handled.signature"), x: Self.margin, y: rowY, width: textWidth, height: 18)
        rowY += 18 + 16
        closeButton = addButton(L.t("common.close"), x: Self.clientWidth - Self.margin - 80, y: rowY, width: 80, height: 26)
        if darkMode { Self.applyDarkExplorerTheme(closeButton) }
    }

    // Height of `text` word-wrapped at `width` in the stock GUI font.
    private static func measuredHeight(_ text: String, width: Int32) -> Int32 {
        guard let hdc = GetDC(nil) else { return 36 }
        defer { ReleaseDC(nil, hdc) }
        let previous = GetStockObject(DEFAULT_GUI_FONT).map { SelectObject(hdc, $0) }
        defer { if let previous { SelectObject(hdc, previous) } }
        var rect = RECT(left: 0, top: 0, right: width, bottom: 0)
        var wide = Array(text.utf16)
        DrawTextW(hdc, &wide, Int32(wide.count), &rect, UINT(DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX))
        return max(rect.bottom, 16) + 2
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
            fatalError("CreateWindowExW (feedback handled label) failed with error \(GetLastError())")
        }
        applyDefaultFont(label)
        return label
    }

    private func addButton(_ text: String, x: Int32, y: Int32, width: Int32, height: Int32) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON),
                    x, y, width, height,
                    hwnd, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (feedback handled button) failed with error \(GetLastError())")
        }
        applyDefaultFont(button)
        return button
    }

    private func applyDefaultFont(_ hwnd: HWND?) {
        guard let hwnd, let font = GetStockObject(DEFAULT_GUI_FONT) else { return }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
    }

    // -- dark mode (small local copy, like TaskPromptDialog's) ---------------

    private typealias SetWindowThemeProc = @convention(c) (HWND?, LPCWSTR?, LPCWSTR?) -> HRESULT
    private static let setWindowThemeProc: SetWindowThemeProc? = {
        let moduleName: [UInt16] = Array("uxtheme.dll".utf16) + [0]
        guard let module = (moduleName.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }) else { return nil }
        guard let proc = GetProcAddress(module, "SetWindowTheme") else { return nil }
        return unsafeBitCast(proc, to: SetWindowThemeProc.self)
    }()

    private static func applyDarkExplorerTheme(_ hwnd: HWND) {
        guard let setWindowThemeProc else { return }
        let subAppName: [UInt16] = Array("DarkMode_Explorer".utf16) + [0]
        _ = subAppName.withUnsafeBufferPointer { setWindowThemeProc(hwnd, $0.baseAddress, nil) }
    }

    private func handleEraseBackground(wParam: WPARAM) -> LRESULT {
        guard darkMode, let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))), let brush = WindowsTheme.darkBackgroundBrush else {
            return DefWindowProcW(hwnd, UINT(WM_ERASEBKGND), wParam, 0)
        }
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        FillRect(hdc, &rect, brush)
        return 1
    }

    private func handleCtlColor(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        guard darkMode, let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))), let brush = WindowsTheme.darkBackgroundBrush else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        SetTextColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkTextHex))
        SetBkColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex))
        return LRESULT(Int(bitPattern: brush))
    }

    // -- modal loop ---------------------------------------------------------

    private func runModal() {
        EnableWindow(owner, false)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
        SetFocus(closeButton)

        var message = MSG()
        while !done, GetMessageW(&message, nil, 0, 0) {
            if message.message == UINT(WM_KEYDOWN) {
                let vk = Int32(truncatingIfNeeded: message.wParam)
                if vk == VK_RETURN || vk == VK_ESCAPE {
                    done = true
                    continue
                }
            }
            if !IsDialogMessageW(hwnd, &message) {
                TranslateMessage(&message)
                DispatchMessageW(&message)
            }
        }

        EnableWindow(owner, true)
        DestroyWindow(hwnd)
    }

    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_COMMAND:
            if HWND(bitPattern: Int(lParam)) == closeButton { done = true }
            return 0
        case WM_CLOSE:
            done = true
            return 0
        case WM_ERASEBKGND:
            return handleEraseBackground(wParam: wParam)
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN:
            return handleCtlColor(message: message, wParam: wParam, lParam: lParam)
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }
}
