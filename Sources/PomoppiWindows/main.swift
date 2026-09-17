// main.swift — Phase W1 skeleton. Just enough Win32 to prove the toolchain
// and the message loop work: register a window class, create a window,
// pump messages, quit cleanly on WM_DESTROY. No rendering, no tray, no
// hotkeys yet — those are later phases (see WINDOWS_PORT_PLAN.md).
import WinSDK

// Wide-string buffers for the Win32 calls below. Kept as module-level `let`
// arrays (not built inline per-call) so their storage stays alive for the
// process's whole lifetime; pointers into them are still only taken inside
// scoped `withUnsafeBufferPointer` closures at each call site, never
// returned out of one (see WINDOWS_PORT_PLAN.md's WinSDK gotchas).
let className: [UInt16] = Array("PomoppiWindowClass".utf16) + [0]
let windowTitle: [UInt16] = Array("Pomoppi".utf16) + [0]

func pomoppiWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if message == UINT(WM_DESTROY) {
        PostQuitMessage(0)
        return 0
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

let hInstance = GetModuleHandleW(nil)

let registeredClass: ATOM = className.withUnsafeBufferPointer { classNamePtr in
    var windowClass = WNDCLASSW()
    windowClass.lpfnWndProc = pomoppiWndProc
    windowClass.hInstance = hInstance
    windowClass.lpszClassName = classNamePtr.baseAddress
    return RegisterClassW(&windowClass)
}

guard registeredClass != 0 else {
    fatalError("RegisterClassW failed with error \(GetLastError())")
}

let hwnd: HWND? = className.withUnsafeBufferPointer { classNamePtr in
    windowTitle.withUnsafeBufferPointer { titlePtr in
        CreateWindowExW(
            0,
            classNamePtr.baseAddress,
            titlePtr.baseAddress,
            DWORD(WS_OVERLAPPEDWINDOW),
            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT),
            Int32(CW_USEDEFAULT), Int32(CW_USEDEFAULT),
            nil, nil, hInstance, nil)
    }
}

guard let hwnd else {
    fatalError("CreateWindowExW failed with error \(GetLastError())")
}

ShowWindow(hwnd, SW_SHOWDEFAULT)
UpdateWindow(hwnd)
print("Pomoppi (Windows skeleton) window created, entering message loop")

// GetMessageW's BOOL return imports as Swift Bool here (audited Windows
// headers), not Int32/WindowsBool — so no "> 0" needed, just `while`.
var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}
print("Pomoppi (Windows skeleton) message loop exited")
