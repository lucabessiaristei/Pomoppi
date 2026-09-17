// SettingsWindow.swift — Phase W6: a real titled top-level window (unlike
// WidgetWindow's layered popup) holding a SysTabControl32 with the same 6
// tabs/order as macOS's SettingsView.swift (Rhythm, Appearance, Window,
// Keys, Sound, Obsidian). Part 2 fills in real controls for Rhythm/Window/
// Sound, bound directly to SettingsStore; Appearance/Keys/Obsidian stay
// placeholder pages until W7 (their content needs more than raw common
// controls — owner-drawn art pickers, a shortcut recorder). One singleton
// instance, mirroring macOS's single reused `Settings` scene; see
// WINDOWS_PORT_PLAN.md's W6/W7 entry for the split.
import PomoppiCore
import WinSDK

// Same "WNDPROC can't capture, dispatch through a shared instance" shape as
// pomoppiWidgetWndProc in WidgetWindow.swift.
private func pomoppiSettingsWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = SettingsWindow.shared, let hwnd, window.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

// A page's real controls (checkboxes/steppers, added in part 2) are its own
// children, not the top-level settings window's — Win32 always sends
// WM_COMMAND (BN_CLICKED, EN_KILLFOCUS) and WM_NOTIFY (UDN_DELTAPOS) to a
// control's *immediate* parent, which is the page, never a grandparent.
// Plain DefWindowProcW (the page class's part-1 WndProc, back when a page
// only ever hosted one placeholder STATIC with nothing to route) just
// swallows both, so none of it ever reached pomoppiSettingsWndProc above —
// confirmed live: checkboxes still flipped their own visual check state
// (BS_AUTOCHECKBOX manages that itself, independent of whoever's listening)
// and stepper arrows still nudged the displayed number by the up-down's own
// unmodified default of 1 (also independent of any listener), but nothing
// ever reached handleCommand/handleUpDownDeltaPos, so settingsStore was
// never actually updated and ringSeconds' step-of-5 override never ran.
// Forwarding just these two message types up to the real parent (the
// settings window) is enough — handleMessage's own dispatch already
// resolves the sending control by its own HWND out of wParam/lParam, so it
// doesn't care which window physically received the message.
private func pomoppiSettingsPageWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if message == UINT(WM_COMMAND) || message == UINT(WM_NOTIFY), let hwnd, let parent = GetParent(hwnd) {
        return SendMessageW(parent, message, wParam, lParam)
    }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}

final class SettingsWindow {
    // Only one settings window ever exists at a time — show(settingsStore:)
    // is the sole entry point, mirroring macOS's single reused `Settings`
    // scene (see AppDelegate.showSettingsWindow's invariant in CLAUDE.md).
    static var shared: SettingsWindow?

    let hwnd: HWND
    private let settingsStore: SettingsStore
    private var tabControl: HWND?
    private var pages: [HWND] = []

    // WM_COMMAND's lParam is always the sending control's HWND regardless
    // of control type, and WM_NOTIFY's NMHDR.hwndFrom is the same for
    // common controls — both dispatch tables below are looked up by HWND
    // rather than by a hand-rolled resource ID, since there's no dialog
    // template/resource file in this codebase to hang IDs off of.
    private struct CheckboxControl {
        let hwnd: HWND
        let onToggle: (Bool) -> Void
    }

    // A numeric stepper is a buddy-paired EDIT + msctls_updown32; tracked
    // by both HWNDs since WM_COMMAND (EN_KILLFOCUS, from the edit) and
    // WM_NOTIFY (UDN_DELTAPOS, from the up-down) arrive on different HWNDs
    // for the same logical control.
    private struct StepperControl {
        let editHwnd: HWND
        let upDownHwnd: HWND
        let min: Int32
        let max: Int32
        let step: Int32
        let onChange: (Int32) -> Void
    }

    private var checkboxes: [CheckboxControl] = []
    private var steppers: [StepperControl] = []

    // Exact order macOS's SettingsView.swift uses.
    private static let tabTitles = ["Rhythm", "Appearance", "Window", "Keys", "Sound", "Obsidian"]

    // Not resizable this phase (see task scope) — a fixed client size in the
    // ballpark of macOS's idealWidth/idealHeight (520x400).
    private static let clientWidth: Int32 = 560
    private static let clientHeight: Int32 = 480

    private static let className: [UInt16] = Array("PomoppiSettingsWindowClass".utf16) + [0]
    private static let windowTitle: [UInt16] = Array("Pomoppi Settings".utf16) + [0]
    private static let pageClassName: [UInt16] = Array("PomoppiSettingsPageClass".utf16) + [0]
    private static let tabClassName: [UInt16] = Array("SysTabControl32".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let editClassName: [UInt16] = Array("EDIT".utf16) + [0]
    private static let upDownClassName: [UInt16] = Array("msctls_updown32".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)

    // Shared row geometry for the plain vertical stacks the 3 real tabs
    // below use — not a pixel match for macOS's Form/Section layout (see
    // the task's stated philosophy), just enough spacing to read cleanly,
    // with a bit of extra gap between logical groups.
    private static let rowMargin: Int32 = 16
    private static let rowHeight: Int32 = 26
    private static let groupGap: Int32 = 14

    private static var classesRegistered = false
    private static var commonControlsInitialized = false

    // A normal titled window and a normal titled window's own child page —
    // neither is WidgetWindow's layered/tool-window popup, so both get a
    // plain background brush rather than being left to draw nothing.
    private static func registerClassesIfNeeded() {
        guard !classesRegistered else { return }

        let windowAtom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiSettingsWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            return RegisterClassW(&windowClass)
        }
        guard windowAtom != 0 else {
            fatalError("RegisterClassW (settings window) failed with error \(GetLastError())")
        }

        // The page container forwards WM_COMMAND/WM_NOTIFY up to the real
        // settings window (see pomoppiSettingsPageWndProc) — its own real
        // children (checkboxes, steppers) need that to ever be heard.
        let pageAtom: ATOM = pageClassName.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiSettingsPageWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            return RegisterClassW(&windowClass)
        }
        guard pageAtom != 0 else {
            fatalError("RegisterClassW (settings page) failed with error \(GetLastError())")
        }

        classesRegistered = true
    }

    // Process-wide, once, before the first SysTabControl32/msctls_updown32
    // is created — ICC_TAB_CLASSES for the tab strip (part 1), plus
    // ICC_UPDOWN_CLASS for the Rhythm/Sound numeric steppers (part 2).
    private static func initCommonControlsIfNeeded() {
        guard !commonControlsInitialized else { return }
        var icc = INITCOMMONCONTROLSEX()
        icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
        icc.dwICC = DWORD(ICC_TAB_CLASSES) | DWORD(ICC_UPDOWN_CLASS)
        InitCommonControlsEx(&icc)
        commonControlsInitialized = true
    }

    // The single entry point every "open settings" trigger funnels through
    // (widget gear/`,` key, tray menu, global hotkey — see WidgetWindow's
    // onOpenSettingsRequested and main.swift's wiring): creates the window
    // on first call, or brings the existing one to front on every call
    // after that — never a second instance.
    static func show(settingsStore: SettingsStore) {
        if let existing = shared {
            if IsIconic(existing.hwnd) {
                ShowWindow(existing.hwnd, SW_RESTORE)
            }
            SetForegroundWindow(existing.hwnd)
            return
        }
        let window = SettingsWindow(settingsStore: settingsStore)
        shared = window
        ShowWindow(window.hwnd, SW_SHOW)
        SetForegroundWindow(window.hwnd)
    }

    private init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        Self.registerClassesIfNeeded()
        Self.initCommonControlsIfNeeded()

        // CreateWindowExW's width/height are the *window's* size, including
        // the title bar/borders the requested style adds — grow the desired
        // client rect through AdjustWindowRectEx rather than guessing a
        // margin by hand, same technique as any other fixed-content Win32
        // dialog-shaped window.
        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
        let style = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
        AdjustWindowRectEx(&rect, style, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top

        let screenWidth = GetSystemMetrics(SM_CXSCREEN)
        let screenHeight = GetSystemMetrics(SM_CYSCREEN)
        let x = (screenWidth - windowWidth) / 2
        let y = (screenHeight - windowHeight) / 2

        guard let createdHwnd = (Self.className.withUnsafeBufferPointer { classNamePtr in
            Self.windowTitle.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0,
                    classNamePtr.baseAddress,
                    titlePtr.baseAddress,
                    style,
                    x, y, windowWidth, windowHeight,
                    nil, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (settings window) failed with error \(GetLastError())")
        }
        hwnd = createdHwnd

        setUpTabsAndPages()
    }

    // -- tab control + pages -------------------------------------------------

    private func setUpTabsAndPages() {
        var clientRect = RECT()
        GetClientRect(hwnd, &clientRect)

        guard let tab = (Self.tabClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS),
                0, 0, clientRect.right - clientRect.left, clientRect.bottom - clientRect.top,
                hwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (tab control) failed with error \(GetLastError())")
        }
        tabControl = tab

        for (index, title) in Self.tabTitles.enumerated() {
            var wide = Array(title.utf16) + [0]
            wide.withUnsafeMutableBufferPointer { buf in
                var item = TCITEMW()
                item.mask = UINT(TCIF_TEXT)
                item.pszText = buf.baseAddress
                withUnsafeMutablePointer(to: &item) { itemPtr in
                    _ = SendMessageW(tab, UINT(TCM_INSERTITEMW), WPARAM(index), LPARAM(Int(bitPattern: itemPtr)))
                }
            }
        }

        // TCM_ADJUSTRECT with the tab control's own bounding rect (its own
        // full client rect, since it's already sized to the window's) gives
        // back the display area under the tab strip — the standard Win32
        // technique for laying out a tab control's content pages by hand
        // (no dialog-template/property-sheet machinery in this codebase).
        var displayRect = RECT(left: 0, top: 0, right: clientRect.right - clientRect.left, bottom: clientRect.bottom - clientRect.top)
        withUnsafeMutablePointer(to: &displayRect) { rectPtr in
            _ = SendMessageW(tab, UINT(TCM_ADJUSTRECT), WPARAM(0), LPARAM(Int(bitPattern: rectPtr)))
        }

        for (index, title) in Self.tabTitles.enumerated() {
            let page = createPage(title: title, rect: displayRect)
            pages.append(page)
            ShowWindow(page, index == 0 ? SW_SHOW : SW_HIDE)
        }
    }

    private func createPage(title: String, rect: RECT) -> HWND {
        let width = rect.right - rect.left
        let height = rect.bottom - rect.top
        guard let page = (Self.pageClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                // No WS_CLIPSIBLINGS here — all 6 pages share this exact
                // same rect (only one is ever SW_SHOW'd at a time via
                // selectTab/setUpTabsAndPages, the rest SW_HIDE'd) rather
                // than being laid out apart from each other. Confirmed live:
                // with WS_CLIPSIBLINGS set, Windows clips this page's own
                // paint region against the other 5 fully-overlapping sibling
                // pages regardless of whether those siblings are actually
                // WS_VISIBLE, leaving the visible page's effective clip
                // region empty — WM_PAINT/WM_ERASEBKGND/WM_NCPAINT all still
                // fire completely normally (bookkeeping is unaffected), but
                // every GDI draw call the page or any of its children make
                // (background fill, border, this page's own STATIC
                // placeholder text) silently lands outside that empty clip
                // region and never reaches the screen. WS_CLIPSIBLINGS only
                // matters when overlapping siblings can be visible at the
                // same time, which never happens here.
                DWORD(WS_CHILD),
                rect.left, rect.top, width, height,
                hwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (settings page) failed with error \(GetLastError())")
        }

        // Rhythm/Window/Sound get real controls this phase; Appearance/
        // Keys/Obsidian stay the placeholder built for part 1 (their real
        // content needs more than raw common controls — W7).
        switch title {
        case "Rhythm":
            buildRhythmTab(page: page, width: width)
        case "Window":
            buildWindowTab(page: page, width: width)
        case "Sound":
            buildSoundTab(page: page, width: width)
        default:
            buildPlaceholder(page: page, title: title, width: width, height: height)
        }
        return page
    }

    private func buildPlaceholder(page: HWND, title: String, width: Int32, height: Int32) {
        let text = Array("\(title) — coming in a later phase".utf16) + [0]
        let label = Self.staticClassName.withUnsafeBufferPointer { classNamePtr in
            text.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | SS_CENTER),
                    0, height / 2 - 10, width, 20,
                    page, nil, Self.hInstance, nil)
            }
        }
        applyDefaultFont(label)
    }

    // -- Rhythm/Window/Sound tab content --------------------------------------

    // Mirrors macOS's RhythmTab (SettingsView.swift): 3 minute steppers, a
    // sessions-per-long-break stepper, then 3 automation checkboxes.
    private func buildRhythmTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let labelWidth: Int32 = 220
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addStepper(
            "Default focus length (minutes)", in: page, value: Int32(settings.focusMinutes),
            min: 1, max: 180, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.focusMinutes = Double(newValue) }
        }
        y += Self.rowHeight

        addStepper(
            "Short break length (minutes)", in: page, value: Int32(settings.shortBreakMinutes),
            min: 1, max: 180, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.shortBreakMinutes = Double(newValue) }
        }
        y += Self.rowHeight

        addStepper(
            "Long break length (minutes)", in: page, value: Int32(settings.longBreakMinutes),
            min: 1, max: 180, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.longBreakMinutes = Double(newValue) }
        }
        y += Self.rowHeight

        addStepper(
            "Long break every (sessions)", in: page, value: Int32(settings.longBreakEvery),
            min: 2, max: 10, step: 1, x: Self.rowMargin, y: y, labelWidth: labelWidth
        ) { [settingsStore] newValue in
            settingsStore.update { $0.longBreakEvery = Int(newValue) }
        }
        y += Self.rowHeight + Self.groupGap

        addCheckbox(
            "Start breaks automatically", in: page, checked: settings.autoStartBreaks,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.autoStartBreaks = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Start the next focus automatically", in: page, checked: settings.autoStartFocus,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.autoStartFocus = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Ask what I’m working on before each focus", in: page, checked: settings.askForTaskName,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.askForTaskName = checked }
        }
    }

    // Mirrors macOS's WindowTab: widget behavior, the reverseTrayClick
    // swap (added in Phase W2b), then startup checkboxes.
    private func buildWindowTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addCheckbox(
            "Keep the widget on top of other windows", in: page, checked: settings.alwaysOnTop,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.alwaysOnTop = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Pop to the front when a session ends", in: page, checked: settings.raiseOnEnd,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.raiseOnEnd = checked }
        }
        y += Self.rowHeight + Self.groupGap

        // macOS's copy says "menu bar icon" — adapted to "tray icon" here,
        // the term this codebase's own TrayController already uses, since
        // Windows has no menu bar.
        addCheckbox(
            "Swap the tray icon's left and right clicks", in: page, checked: settings.reverseTrayClick,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.reverseTrayClick = checked }
        }
        y += Self.rowHeight + Self.groupGap

        addCheckbox(
            "Open Pomoppi when I log in", in: page, checked: settings.launchAtLogin,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.launchAtLogin = checked }
        }
        y += Self.rowHeight

        addCheckbox(
            "Start without showing the widget", in: page, checked: settings.startHidden,
            x: Self.rowMargin, y: y, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.startHidden = checked }
        }
    }

    // Mirrors macOS's SoundTab: a chime toggle plus a ring-length stepper
    // that's disabled whenever the chime itself is off — the stepper is
    // built first (code order only, not visual order) so its HWNDs exist
    // for the checkbox's onToggle closure to grey/re-enable live.
    private func buildSoundTab(page: HWND, width: Int32) {
        let settings = settingsStore.get()
        let rowWidth = width - 2 * Self.rowMargin
        let checkboxY = Self.rowMargin
        let stepperY = checkboxY + Self.rowHeight

        let (ringSecondsEdit, ringSecondsUpDown) = addStepper(
            "Keep ringing for (seconds)", in: page, value: Int32(settings.ringSeconds),
            min: 0, max: 60, step: 5, x: Self.rowMargin, y: stepperY, labelWidth: 220
        ) { [settingsStore] newValue in
            settingsStore.update { $0.ringSeconds = Double(newValue) }
        }
        // Matches macOS's `.disabled(!viewModel.settings.soundEnabled)`.
        EnableWindow(ringSecondsEdit, settings.soundEnabled)
        EnableWindow(ringSecondsUpDown, settings.soundEnabled)

        addCheckbox(
            "Play a chime when a session ends", in: page, checked: settings.soundEnabled,
            x: Self.rowMargin, y: checkboxY, width: rowWidth
        ) { [settingsStore] checked in
            settingsStore.update { $0.soundEnabled = checked }
            EnableWindow(ringSecondsEdit, checked)
            EnableWindow(ringSecondsUpDown, checked)
        }
    }

    // -- raw control helpers ---------------------------------------------------

    // Every raw control created below needs this or it renders in the
    // ancient stock system font — SysTabControl32 (setUpTabsAndPages above)
    // is the only control in this window that manages its own font.
    private func applyDefaultFont(_ hwnd: HWND?) {
        guard let hwnd, let font = GetStockObject(DEFAULT_GUI_FONT) else { return }
        SendMessageW(hwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
    }

    @discardableResult
    private func addLabel(_ text: String, in page: HWND, x: Int32, y: Int32, width: Int32, height: Int32 = 18) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let label = (Self.staticClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE),
                    x, y, width, height,
                    page, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (label) failed with error \(GetLastError())")
        }
        applyDefaultFont(label)
        return label
    }

    // BS_AUTOCHECKBOX toggles its own visual check state on click and fires
    // BN_CLICKED via WM_COMMAND (handleCommand below) — the button's own
    // text is the control's label, no separate STATIC needed.
    private func addCheckbox(
        _ text: String, in page: HWND, checked: Bool,
        x: Int32, y: Int32, width: Int32, height: Int32 = 22,
        onToggle: @escaping (Bool) -> Void
    ) {
        let wide = Array(text.utf16) + [0]
        guard let checkbox = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX),
                    x, y, width, height,
                    page, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (checkbox) failed with error \(GetLastError())")
        }
        applyDefaultFont(checkbox)
        SendMessageW(checkbox, UINT(BM_SETCHECK), WPARAM(checked ? BST_CHECKED : BST_UNCHECKED), 0)
        checkboxes.append(CheckboxControl(hwnd: checkbox, onToggle: onToggle))
    }

    // The standard Win32 numeric-stepper idiom: an EDIT paired with an
    // msctls_updown32 "buddy" via UDM_SETBUDDY. UDS_SETBUDDYINT keeps the
    // edit's displayed text in sync whenever the up-down's position changes
    // (arrows, or our own UDM_SETPOS32 calls) — but that sync is one-way,
    // reading the edit back after direct typing is on us (see
    // commitTypedStepperValue below).
    @discardableResult
    private func addStepper(
        _ label: String, in page: HWND, value: Int32, min: Int32, max: Int32, step: Int32,
        x: Int32, y: Int32, labelWidth: Int32, editWidth: Int32 = 55, height: Int32 = 22,
        onChange: @escaping (Int32) -> Void
    ) -> (edit: HWND, upDown: HWND) {
        addLabel(label, in: page, x: x, y: y + 3, width: labelWidth)

        let editX = x + labelWidth + 8
        guard let editHwnd = (Self.editClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                DWORD(WS_EX_CLIENTEDGE), classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | ES_NUMBER),
                editX, y, editWidth, height,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (stepper edit) failed with error \(GetLastError())")
        }
        applyDefaultFont(editHwnd)

        // Zero size/position: UDS_ALIGNRIGHT docks it against the buddy's
        // own right edge once UDM_SETBUDDY below runs.
        guard let upDownHwnd = (Self.upDownClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | UDS_SETBUDDYINT | UDS_ALIGNRIGHT | UDS_ARROWKEYS | UDS_NOTHOUSANDS),
                0, 0, 0, 0,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (stepper updown) failed with error \(GetLastError())")
        }
        applyDefaultFont(upDownHwnd)

        SendMessageW(upDownHwnd, UINT(UDM_SETBUDDY), WPARAM(UInt(bitPattern: editHwnd)), 0)
        SendMessageW(upDownHwnd, UINT(UDM_SETRANGE32), WPARAM(Int(min)), LPARAM(Int(max)))
        SendMessageW(upDownHwnd, UINT(UDM_SETPOS32), 0, LPARAM(Int(value)))

        steppers.append(StepperControl(editHwnd: editHwnd, upDownHwnd: upDownHwnd, min: min, max: max, step: step, onChange: onChange))
        return (editHwnd, upDownHwnd)
    }

    private func selectTab(_ index: Int) {
        for (i, page) in pages.enumerated() {
            ShowWindow(page, i == index ? SW_SHOW : SW_HIDE)
        }
    }

    // -- WndProc dispatch -----------------------------------------------------

    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_NOTIFY:
            let header = UnsafeMutablePointer<NMHDR>(bitPattern: UInt(bitPattern: Int(lParam)))
            guard let header else { return 0 }
            if let tabControl, header.pointee.hwndFrom == tabControl, header.pointee.code == TCN_SELCHANGE {
                selectTab(Int(SendMessageW(tabControl, UINT(TCM_GETCURSEL), 0, 0)))
                return 0
            }
            if header.pointee.code == UDN_DELTAPOS,
               let stepper = steppers.first(where: { $0.upDownHwnd == header.pointee.hwndFrom }) {
                return handleUpDownDeltaPos(lParam: lParam, stepper: stepper)
            }
            return 0
        case WM_COMMAND:
            handleCommand(wParam: wParam, lParam: lParam)
            return 0
        case WM_CLOSE:
            // Closing the settings window must never quit the app — only
            // WidgetWindow's own WM_DESTROY calls PostQuitMessage.
            DestroyWindow(hwnd)
            return 0
        case WM_DESTROY:
            Self.shared = nil
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    // -- checkbox / stepper notification dispatch -----------------------------

    // BN_CLICKED (checkboxes) and EN_KILLFOCUS (stepper edits, after direct
    // typing) both arrive here — wParam's high word is the notification
    // code, lParam is always the sending control's own HWND.
    private func handleCommand(wParam: WPARAM, lParam: LPARAM) {
        let notificationCode = Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
        guard let controlHwnd = HWND(bitPattern: Int(lParam)) else { return }

        if notificationCode == BN_CLICKED, let checkbox = checkboxes.first(where: { $0.hwnd == controlHwnd }) {
            let checked = SendMessageW(controlHwnd, UINT(BM_GETCHECK), 0, 0) == BST_CHECKED
            checkbox.onToggle(checked)
            return
        }
        if notificationCode == EN_KILLFOCUS, let stepper = steppers.first(where: { $0.editHwnd == controlHwnd }) {
            commitTypedStepperValue(stepper)
        }
    }

    // Reads whatever the user actually typed into a stepper's buddy edit,
    // clamps it the same way PomoppiSettings.clampInPlace would, and pushes
    // it back through both UDM_SETPOS32 (so the displayed text normalizes,
    // e.g. an out-of-range or empty value snaps back) and the stored
    // setting. UDS_SETBUDDYINT only syncs up-down position -> edit text,
    // never the other way, so this is the only path that notices typing.
    private func commitTypedStepperValue(_ stepper: StepperControl) {
        let length = GetWindowTextLengthW(stepper.editHwnd)
        var buffer = [UInt16](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(stepper.editHwnd, &buffer, Int32(buffer.count))
        let text = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)

        let newValue: Int32
        if let typed = Int32(text) {
            newValue = min(stepper.max, max(stepper.min, typed))
        } else {
            // Not parseable (e.g. left empty) — snap back to whatever the
            // up-down control still thinks its position is.
            newValue = Int32(SendMessageW(stepper.upDownHwnd, UINT(UDM_GETPOS32), 0, 0))
        }
        SendMessageW(stepper.upDownHwnd, UINT(UDM_SETPOS32), 0, LPARAM(Int(newValue)))
        stepper.onChange(newValue)
    }

    // UDS_SETBUDDYINT's own default arrow-click behavior steps by 1 — this
    // intercepts the notification (sent before the position actually
    // changes, per NMUPDOWN.iPos/iDelta) to scale the delta by the
    // stepper's own step size instead, applies the clamped result ourselves
    // via UDM_SETPOS32, and returns nonzero to suppress the control's
    // default single-step application.
    private func handleUpDownDeltaPos(lParam: LPARAM, stepper: StepperControl) -> LRESULT {
        guard let details = UnsafeMutablePointer<NMUPDOWN>(bitPattern: UInt(bitPattern: Int(lParam))) else { return 0 }
        let newValue = min(stepper.max, max(stepper.min, details.pointee.iPos + details.pointee.iDelta * stepper.step))
        SendMessageW(stepper.upDownHwnd, UINT(UDM_SETPOS32), 0, LPARAM(Int(newValue)))
        stepper.onChange(newValue)
        return 1
    }
}
