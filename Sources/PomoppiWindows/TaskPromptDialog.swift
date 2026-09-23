// TaskPromptDialog.swift — the Win32 modal StartCoordinator shows before a
// fresh focus session, standing in for macOS's NSAlert-based
// promptForTaskName (Sources/PomoppiApp/StartCoordinator.swift). This
// codebase has no dialog templates or resource-file UI anywhere
// (Pomoppi.rc carries only an icon + VERSIONINFO) — every window here is a
// registered class + WndProc, and this follows that shape too, rather than
// DialogBoxParamW. T1 scope only (SETTINGS_PLAN.md): light mode, centred
// on the owner, mouse-driven Start/Cancel — dark mode, the cue banner,
// Return/Escape, Tab order, work-area clamping, the hidden-widget path and
// the re-entrancy guard are all T2.
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

    let hwnd: HWND
    private let owner: HWND
    private var editHwnd: HWND!
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
            return RegisterClassW(&windowClass)
        }
        guard atom != 0 else {
            fatalError("RegisterClassW (task prompt) failed with error \(GetLastError())")
        }
        classRegistered = true
    }

    // The only entry point — StartCoordinator is the only caller. Builds
    // the window, runs the modal loop to completion, tears the window
    // down, and returns what the user did.
    static func run(owner: HWND, mandatory: Bool) -> TaskPromptResult {
        registerClassIfNeeded()
        let dialog = TaskPromptDialog(owner: owner, mandatory: mandatory)
        current = dialog
        defer { current = nil }
        return dialog.runModal()
    }

    private init(owner: HWND, mandatory: Bool) {
        self.owner = owner

        var ownerRect = RECT()
        GetWindowRect(owner, &ownerRect)
        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top
        let x = ownerRect.left + ((ownerRect.right - ownerRect.left) - windowWidth) / 2
        let y = ownerRect.top + ((ownerRect.bottom - ownerRect.top) - windowHeight) / 2

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

        buildControls(mandatory: mandatory)
    }

    // -- controls ---------------------------------------------------------

    private func buildControls(mandatory: Bool) {
        addLabel("What are you working on?", x: 16, y: 16, width: 308, height: 20)

        guard let edit = (Self.editClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                DWORD(WS_EX_CLIENTEDGE), classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL),
                16, 42, 308, 24,
                hwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (task prompt edit) failed with error \(GetLastError())")
        }
        applyDefaultFont(edit)
        editHwnd = edit

        // Same two strings macOS's promptForTaskName uses for
        // alert.informativeText, mandatory vs. optional.
        let hintText = mandatory
            ? "Session logging is on, so this session needs a task name to log a useful line."
            : "Optional — leave blank to skip."
        addLabel(hintText, x: 16, y: 74, width: 308, height: 40)

        // Same right-to-left order as macOS's NSAlert (Start added first,
        // ends up rightmost/default; Cancel to its left).
        cancelButton = addButton("Cancel", x: 156, y: 114, width: 80, height: 26)
        startButton = addButton("Start", x: 244, y: 114, width: 80, height: 26, isDefault: true)
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
                    DWORD(WS_CHILD | WS_VISIBLE | buttonStyle),
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

    // -- modal loop ---------------------------------------------------------

    // EnableWindow(owner, false) + a plain GetMessageW loop until Start/
    // Cancel sets a result, then re-enable the owner BEFORE DestroyWindow —
    // doing it after hands activation to some other app's window instead
    // of back to Pomoppi.
    private func runModal() -> TaskPromptResult {
        EnableWindow(owner, false)
        ShowWindow(hwnd, SW_SHOW)
        SetForegroundWindow(hwnd)
        SetFocus(editHwnd)

        var message = MSG()
        while result == nil, GetMessageW(&message, nil, 0, 0) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
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
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }
}
