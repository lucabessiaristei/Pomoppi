// WidgetWindow.swift — the actual floating pixel widget: window creation,
// always-on-top, the per-frame render loop, and show/hide. Mouse/keyboard
// event handling lives in WidgetInput.swift as an extension on this same
// class (Win32 has no separate window/view split the way AppKit does — one
// HWND is both). Ported from WidgetWindow.swift + the frame-loop half of
// WidgetPixelView.swift on the macOS side; see WINDOWS_PORT_PLAN.md's W3
// part 2 entry for the full scope.
import Foundation
import PomoppiCore
import PomoppiRender
import WinSDK

// Win32's WNDPROC has to be a plain C function pointer (no captures), so it
// can't close over an instance directly — it dispatches through this single
// shared instance instead, same "one process, one widget window" shape as
// main.swift's module-level `let`s already used for the Phase W1 skeleton.
private func pomoppiWidgetWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = WidgetWindow.shared, let hwnd, window.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

final class WidgetWindow {
    static var shared: WidgetWindow?

    let hwnd: HWND
    let timer: PomodoroTimer
    let settingsStore: SettingsStore
    let animation = WidgetAnimationController()

    // Set by main.swift right after both objects exist (TrayController's
    // init needs an already-constructed WidgetWindow) — WM_TIMER/the tray
    // callback message/WM_COMMAND below all forward to it once set.
    var trayController: TrayController?

    // Set by main.swift, same pattern as trayController above — WM_HOTKEY
    // below forwards to it once set.
    var globalShortcutManager: GlobalShortcutManager?

    // Set by main.swift, same pattern as trayController/globalShortcutManager
    // above — WM_TIMER (its own 10s/24h schedule) and resultMessageID
    // (URLSession completions marshaled back onto this hwnd's thread) below
    // both forward to it once set.
    var updateChecker: AppUpdateChecker?

    // Set by main.swift right after construction — activateButton's
    // "settings" case (WidgetInput.swift) calls this rather than reaching
    // into SettingsWindow directly, same seam shape as the two properties
    // above.
    var onOpenSettingsRequested: (() -> Void)?

    var state: TimerState
    var settings: PomoppiSettings

    // Hover/press/drag state — read by WidgetInput.swift's hit-testing and
    // by renderFrame() below to decide how buttons/steppers outline or
    // invert, exactly like WidgetPixelView's equivalent ivars.
    var hoveredButton: String?
    var pressedButton: String?
    var hoveredRegion: String?
    var pressedRegion: String?
    var isDragging = false
    var dragStartScreenPoint = POINT()
    var lastDragScreenPoint = POINT()

    var scale: Int { max(1, settings.scale) }

    private var appliedAlwaysOnTop: Bool?
    private var appliedScale: Int
    private var lastTimestamp: TimeInterval?

    private static let timerID: UINT_PTR = 1
    private static let frameIntervalMs: UINT = 16 // ~60fps, same target cadence as WidgetPixelView's frame timer.

    private static let className: [UInt16] = Array("PomoppiWidgetWindowClass".utf16) + [0]
    private static let windowTitle: [UInt16] = Array("Pomoppi".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)
    private static var classRegistered = false

    private static func registerClassIfNeeded() {
        guard !classRegistered else { return }
        let atom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiWidgetWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            // IDC_ARROW is MAKEINTRESOURCE(32512), and (like IDI_APPLICATION,
            // see WINDOWS_PORT_PLAN.md's WinSDK gotchas) doesn't import as a
            // usable symbol in this overlay — go through the raw resource ID
            // instead. Without this the widget would keep whatever cursor
            // happened to be active before it got focus.
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            return RegisterClassW(&windowClass)
        }
        guard atom != 0 else {
            fatalError("RegisterClassW failed with error \(GetLastError())")
        }
        classRegistered = true
    }

    init(timer: PomodoroTimer, settingsStore: SettingsStore) {
        self.timer = timer
        self.settingsStore = settingsStore
        self.state = timer.getState()
        self.settings = settingsStore.get()
        self.appliedScale = settings.scale

        Self.registerClassIfNeeded()

        let scale = max(1, settings.scale)
        let width = Int32(WidgetLayout.canvasWidth * scale)
        let height = Int32(WidgetLayout.canvasHeight * scale)
        let screenWidth = GetSystemMetrics(SM_CXSCREEN)
        let screenHeight = GetSystemMetrics(SM_CYSCREEN)
        let x = (screenWidth - width) / 2
        let y = (screenHeight - height) / 2

        guard let createdHwnd = (Self.className.withUnsafeBufferPointer { classNamePtr in
            Self.windowTitle.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    DWORD(WS_EX_LAYERED | WS_EX_TOOLWINDOW),
                    classNamePtr.baseAddress,
                    titlePtr.baseAddress,
                    DWORD(WS_POPUP),
                    x, y, width, height,
                    nil, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW failed with error \(GetLastError())")
        }
        hwnd = createdHwnd

        Self.shared = self
        setAlwaysOnTop(settings.alwaysOnTop)
        SetTimer(hwnd, Self.timerID, Self.frameIntervalMs, nil)
    }

    // Single show/hide entry point main.swift (startup) and the Escape key
    // (WidgetInput.swift) call — no fade animation this phase (see
    // WINDOWS_PORT_PLAN.md's scope note), a plain ShowWindow/SW_HIDE is
    // enough for now. Kept as one narrow method rather than exposing
    // raise()/hide() separately so a later phase (tray, global hotkeys) has
    // one obvious seam to hook into instead of two half-built ones.
    func setVisible(_ visible: Bool) {
        ShowWindow(hwnd, visible ? SW_SHOW : SW_HIDE)
    }

    // HWND_TOPMOST/HWND_NOTOPMOST are `#define`d as `((HWND)-1)`/`((HWND)-2)`
    // — a cast, not a plain integer literal, so (like HWND_TOPMOST's cousins
    // IDI_APPLICATION/IDC_ARROW above) they don't import as usable symbols;
    // reconstruct them from their raw bit patterns instead.
    private static let hwndTopmost = HWND(bitPattern: -1)
    private static let hwndNotopmost = HWND(bitPattern: -2)

    // INVARIANT mirrored from the macOS WidgetWindow: nothing else in this
    // file sets topmost/non-topmost directly, and this only re-applies when
    // the value actually changed — SetWindowPos's topmost swap is a real
    // z-order operation, redundant calls would needlessly churn it.
    func setAlwaysOnTop(_ value: Bool) {
        guard appliedAlwaysOnTop != value else { return }
        SetWindowPos(hwnd, value ? Self.hwndTopmost : Self.hwndNotopmost, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE))
        appliedAlwaysOnTop = value
    }

    // Called from settingsStore.onChange (main.swift) whenever settings
    // change from any source — same role as the macOS
    // applyExternalSettingsChange: only the window-level properties applied
    // once rather than re-read every frame live here.
    func applyExternalSettingsChange(_ settings: PomoppiSettings) {
        setAlwaysOnTop(settings.alwaysOnTop)
        guard settings.scale != appliedScale else { return }
        appliedScale = settings.scale
        let scale = max(1, settings.scale)
        let width = Int32(WidgetLayout.canvasWidth * scale)
        let height = Int32(WidgetLayout.canvasHeight * scale)
        SetWindowPos(hwnd, nil, 0, 0, width, height, UINT(SWP_NOMOVE | SWP_NOZORDER))
    }

    // -- per-frame loop -----------------------------------------------------

    private func tick() {
        let now = Date().timeIntervalSinceReferenceDate
        let dt = lastTimestamp.map { min(100, (now - $0) * 1000) } ?? 16
        lastTimestamp = now

        settings = settingsStore.get()
        state = timer.tick()
        animation.tick(dt: dt, state: state, settings: settings)
        renderFrame()
    }

    // Builds one frame via the shared WidgetRenderer, exports it as a GDI
    // layered bitmap (PixelCanvas+GDI.swift), and pushes it with
    // UpdateLayeredWindow — layered windows don't repaint via WM_PAINT, every
    // frame has to be pushed this way. Every GDI object makeLayeredBitmap
    // hands back is disposed before returning, every tick, per its ownership
    // contract — skipping this leaks a handle every ~16ms and exhausts the
    // process's GDI quota within seconds.
    private func renderFrame() {
        let interaction = WidgetInteractionSnapshot(
            hoveredButton: hoveredButton, pressedButton: pressedButton,
            hoveredRegion: hoveredRegion, pressedRegion: pressedRegion)
        let canvas = WidgetRenderer.drawCanvas(state: state, settings: settings, animation: animation.snapshot, interaction: interaction)
        guard let (hdc, bitmap, previousBitmap, size) = canvas.makeLayeredBitmap(scale: scale) else { return }
        defer {
            SelectObject(hdc, previousBitmap)
            DeleteObject(bitmap)
            DeleteDC(hdc)
        }

        guard let screenDC = GetDC(nil) else { return }
        defer { ReleaseDC(nil, screenDC) }

        var srcPoint = POINT(x: 0, y: 0)
        var sizeVar = size
        // The window-wide opacity setting is a uniform multiplier on top of
        // the per-pixel alpha the bitmap already carries — same purpose as
        // macOS's NSWindow.alphaValue.
        var blend = BLENDFUNCTION(
            BlendOp: UInt8(AC_SRC_OVER), BlendFlags: 0,
            SourceConstantAlpha: UInt8(max(0, min(255, Int((settings.opacity * 255).rounded())))),
            AlphaFormat: UInt8(AC_SRC_ALPHA))

        UpdateLayeredWindow(hwnd, screenDC, nil, &sizeVar, hdc, &srcPoint, 0, &blend, DWORD(ULW_ALPHA))
    }

    // -- WndProc dispatch ---------------------------------------------------

    // Mouse/keyboard cases below are handled by WidgetInput.swift's
    // extension methods on this same class.
    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_TIMER:
            // WidgetWindow's own ~60fps frame loop, (once set)
            // TrayController's 500ms icon/tooltip refresh, and (once set)
            // AppUpdateChecker's 10s/24h schedule all share this hwnd's
            // WndProc, so WM_TIMER fires for any of them — dispatch on
            // which timer ID actually fired rather than assuming it's
            // always this window's own; the other two each ignore an ID
            // that isn't theirs.
            if wParam == Self.timerID {
                tick()
            } else {
                trayController?.handleTimer(id: wParam)
                updateChecker?.handleTimer(id: wParam)
            }
            return 0
        case WM_DESTROY:
            KillTimer(hwnd, Self.timerID)
            trayController?.tearDown()
            updateChecker?.stop()
            // A hotkey left registered after the process exits doesn't
            // linger the way a tray icon does (Windows auto-releases them
            // once the owning window/thread is gone), but explicit,
            // symmetric cleanup is still the correct thing to do here.
            globalShortcutManager?.unregisterAll()
            PostQuitMessage(0)
            return 0
        case Int32(TrayController.callbackMessageID):
            guard let trayController else { return DefWindowProcW(hwnd, message, wParam, lParam) }
            trayController.handleTrayCallback(lParam: lParam)
            return 0
        case Int32(AppUpdateChecker.resultMessageID):
            guard let updateChecker else { return DefWindowProcW(hwnd, message, wParam, lParam) }
            updateChecker.handleResultMessage(lParam: lParam)
            return 0
        case WM_COMMAND:
            guard let trayController else { return DefWindowProcW(hwnd, message, wParam, lParam) }
            trayController.handleCommand(wParam: wParam)
            return 0
        case WM_HOTKEY:
            guard let globalShortcutManager else { return DefWindowProcW(hwnd, message, wParam, lParam) }
            globalShortcutManager.handleHotKey(id: wParam)
            return 0
        case WM_MOUSEMOVE:
            handleMouseMove(lParam: lParam)
            return 0
        case WM_MOUSELEAVE:
            handleMouseLeave()
            return 0
        case WM_LBUTTONDOWN:
            handleLButtonDown(lParam: lParam)
            return 0
        case WM_LBUTTONUP:
            handleLButtonUp(lParam: lParam)
            return 0
        case WM_KEYDOWN:
            handleKeyDown(wParam: wParam, lParam: lParam)
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }
}
