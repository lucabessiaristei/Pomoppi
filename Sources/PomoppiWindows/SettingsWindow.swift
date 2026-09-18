// SettingsWindow.swift — a real titled top-level window (unlike
// WidgetWindow's layered popup) holding a SysTabControl32 with the same 6
// tabs/order as macOS's SettingsView.swift (Rhythm, Appearance, Window,
// Keys, Sound, Obsidian), bound directly to SettingsStore. Obsidian stays a
// placeholder page — deliberately deferred, see
// project-obsidian-logging-redesign. One singleton instance, mirroring
// macOS's single reused `Settings` scene; see WINDOWS_PORT_PLAN.md's W6/W7
// entry for how this file grew phase by phase.
import PomoppiCore
import PomoppiRender
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
// WM_KEYDOWN/WM_SYSKEYDOWN forward the same way, added in W7 for the Keys
// tab's shortcut recorder: unlike WM_COMMAND/WM_NOTIFY (always sent to a
// control's immediate parent regardless of focus), keyboard messages go
// straight to whichever HWND currently owns input focus — the settings
// window explicitly hands the Keys page that focus while a row is
// recording (see SettingsWindow.startRecording) specifically so its own
// keydown arrives here to forward, rather than silently going nowhere.
// WM_SYSKEYDOWN has to be included too: Windows reclassifies any key
// pressed while Alt is already held as a "system" keydown (normally meant
// for menu mnemonics), and every one of Shortcuts.actions' own default
// accelerators uses Alt — without it, no default binding could ever be
// re-recorded to a new Alt combo at all.
// WM_DRAWITEM forwards the same way, added in W7 for the Appearance tab's
// owner-drawn picker cards (BS_OWNERDRAW buttons showing a rendered
// PixelCanvas preview instead of stock button chrome) — like
// WM_COMMAND/WM_NOTIFY, Windows always sends WM_DRAWITEM to the control's
// immediate parent, never a grandparent.
private func pomoppiSettingsPageWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if message == UINT(WM_COMMAND) || message == UINT(WM_NOTIFY) || message == UINT(WM_KEYDOWN) || message == UINT(WM_SYSKEYDOWN) || message == UINT(WM_DRAWITEM),
       let hwnd, let parent = GetParent(hwnd) {
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
    // Owned by main.swift (WidgetWindow's own instance) — the Keys tab's
    // shortcut recorder needs to unregister every live global hotkey while
    // capturing a new one (see startRecording below), and reregisterShortcuts
    // re-applies the table afterward via main.swift's own registration logic.
    private let globalShortcutManager: GlobalShortcutManager
    private let reregisterShortcuts: () -> Void
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

    // Same HWND-keyed dispatch shape as the two above, for the Keys tab's
    // plain push buttons (Reset to Defaults, and each row's own recorder
    // button — its onClick just toggles recording, see buildKeysTab).
    private struct PushButtonControl {
        let hwnd: HWND
        let onClick: () -> Void
    }
    private var pushButtons: [PushButtonControl] = []

    // A shortcut row's own button, tracked separately from pushButtons so
    // refreshShortcutButtons can look one up by action id after a binding
    // changes (write, cancel, or Reset to Defaults all funnel through it).
    private struct ShortcutRecorderControl {
        let buttonHwnd: HWND
        let actionID: String
    }
    private var shortcutRecorders: [ShortcutRecorderControl] = []

    // The Appearance tab's picker-grid buttons (roommate/window-edge/
    // background — added in W7): BS_OWNERDRAW push buttons drawn via
    // handleDrawItem/drawPickerCard instead of stock button chrome. `kind`
    // says which PomoppiSettings field a card's own click (routed through
    // the ordinary pushButtons/BN_CLICKED dispatch, same as any other
    // button) and its selection-border check both read against; `itemID`
    // is that field's candidate value this specific card represents.
    private enum PickerKind {
        case friend, frameStyle, background
    }
    private struct PickerCardControl {
        let hwnd: HWND
        let kind: PickerKind
        let itemID: String
    }
    private var pickerCards: [PickerCardControl] = []
    // The Keys tab's own page — SetFocus target while recording, so the
    // capture keystroke's WM_(SYS)KEYDOWN has somewhere of ours to land
    // (see startRecording/handleShortcutRecorderKeyDown below).
    private var keysPage: HWND?
    // The action id currently listening for its next keydown, or nil — only
    // one row records at a time (see toggleShortcutRecording).
    private var recordingActionID: String?

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
    static func show(settingsStore: SettingsStore, globalShortcutManager: GlobalShortcutManager, reregisterShortcuts: @escaping () -> Void) {
        if let existing = shared {
            if IsIconic(existing.hwnd) {
                ShowWindow(existing.hwnd, SW_RESTORE)
            }
            SetForegroundWindow(existing.hwnd)
            return
        }
        let window = SettingsWindow(settingsStore: settingsStore, globalShortcutManager: globalShortcutManager, reregisterShortcuts: reregisterShortcuts)
        shared = window
        ShowWindow(window.hwnd, SW_SHOW)
        SetForegroundWindow(window.hwnd)
    }

    private init(settingsStore: SettingsStore, globalShortcutManager: GlobalShortcutManager, reregisterShortcuts: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.globalShortcutManager = globalShortcutManager
        self.reregisterShortcuts = reregisterShortcuts
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

        // Rhythm/Window/Sound/Keys/Appearance get real controls; Obsidian
        // stays the placeholder — deliberately deferred, see
        // project-obsidian-logging-redesign.
        switch title {
        case "Rhythm":
            buildRhythmTab(page: page, width: width)
        case "Appearance":
            buildAppearanceTab(page: page, width: width)
        case "Window":
            buildWindowTab(page: page, width: width)
        case "Sound":
            buildSoundTab(page: page, width: width)
        case "Keys":
            buildKeysTab(page: page, width: width)
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

    // -- Appearance tab content -----------------------------------------------

    // Mirrors macOS's AppearanceTab's three CardPickerGrid sections (roommate/
    // window-edge/background) — the theme-preset grid, ink/paper
    // ChooseColorW pickers, and the size/opacity controls are a separate,
    // later chunk of this phase (see WINDOWS_PORT_PLAN.md's W7 entry).
    private func buildAppearanceTab(page: HWND, width: Int32) {
        let rowWidth = width - 2 * Self.rowMargin
        var y = Self.rowMargin

        addLabel("Roommate", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20
        y += addPickerGrid(
            kind: .friend, items: PomoppiSettings.friendIDs, in: page,
            x: Self.rowMargin, y: y, availableWidth: rowWidth,
            cardWidth: 56, cardHeight: 56
        ) { [settingsStore] friend in
            settingsStore.update { $0.friend = friend }
        }
        y += Self.groupGap

        addLabel("Window edge", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20
        y += addPickerGrid(
            kind: .frameStyle, items: PomoppiSettings.frameStyles, in: page,
            x: Self.rowMargin, y: y, availableWidth: rowWidth,
            cardWidth: 62, cardHeight: 70
        ) { [settingsStore] style in
            settingsStore.update { $0.frameStyle = style }
        }
        y += Self.groupGap

        addLabel("Background", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20
        addPickerGrid(
            kind: .background, items: PomoppiSettings.backgroundIDs, in: page,
            x: Self.rowMargin, y: y, availableWidth: rowWidth,
            cardWidth: 96, cardHeight: 56
        ) { [settingsStore] background in
            settingsStore.update { $0.background = background }
        }
    }

    // A plain flow layout (left-to-right, wrapping at `availableWidth`) of
    // owner-drawn picker cards, one per item, each with a capitalized
    // STATIC label underneath — not a LazyVGrid-style adaptive column count
    // that re-centres per row, just enough to lay a handful of same-size
    // cards out legibly (every grid here fits on one row at this window's
    // fixed 560pt width, so wrapping is untested but kept as a safety net
    // rather than assumed away). Returns the total height consumed, so the
    // caller can advance its own running `y` past it.
    @discardableResult
    private func addPickerGrid(
        kind: PickerKind, items: [String], in page: HWND,
        x: Int32, y: Int32, availableWidth: Int32,
        cardWidth: Int32, cardHeight: Int32,
        onSelect: @escaping (String) -> Void
    ) -> Int32 {
        let gap: Int32 = 10
        let labelHeight: Int32 = 16
        let cellWidth = cardWidth + gap
        let columns = max(1, (availableWidth + gap) / cellWidth)
        let rowHeight = cardHeight + labelHeight + gap

        for (index, item) in items.enumerated() {
            let col = Int32(index) % columns
            let row = Int32(index) / columns
            let cardX = x + col * cellWidth
            let cardY = y + row * rowHeight
            addPickerCard(kind: kind, itemID: item, in: page, x: cardX, y: cardY, width: cardWidth, height: cardHeight, onSelect: onSelect)
            addLabel(displayName(item), in: page, x: cardX, y: cardY + cardHeight + 2, width: cardWidth, height: labelHeight)
        }

        let rowCount = (Int32(items.count) + columns - 1) / columns
        return rowCount * rowHeight
    }

    // A BS_OWNERDRAW push button: still fires the ordinary BN_CLICKED ->
    // WM_COMMAND that pushButtons/handleCommand already dispatch (owner-draw
    // only replaces painting, not click semantics), so selecting a card
    // reuses that exact path rather than a separate one. `onSelect` commits
    // the new setting; invalidateAllPickerCards then repaints every card so
    // the moved selection border (and, for a frameStyle change, the
    // background cards whose preview also depends on it) shows immediately.
    private func addPickerCard(
        kind: PickerKind, itemID: String, in page: HWND,
        x: Int32, y: Int32, width: Int32, height: Int32,
        onSelect: @escaping (String) -> Void
    ) {
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_VISIBLE | BS_OWNERDRAW),
                x, y, width, height,
                page, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (picker card) failed with error \(GetLastError())")
        }
        pickerCards.append(PickerCardControl(hwnd: button, kind: kind, itemID: itemID))
        pushButtons.append(PushButtonControl(hwnd: button, onClick: { [weak self] in
            onSelect(itemID)
            self?.invalidateAllPickerCards()
        }))
    }

    private func invalidateAllPickerCards() {
        for card in pickerCards {
            InvalidateRect(card.hwnd, nil, true)
        }
    }

    // id strings are already lowercase (PomoppiSettings.friendIDs etc.) —
    // just capitalize the first letter rather than pulling in Foundation's
    // .capitalized for one line.
    private func displayName(_ id: String) -> String {
        guard let first = id.first else { return id }
        return first.uppercased() + id.dropFirst()
    }

    // The WM_DRAWITEM handler (forwarded here via pomoppiSettingsPageWndProc
    // + this window's own handleMessage): looks up which picker card owns
    // the drawn HWND, builds its current preview (ink/paper/frameStyle read
    // fresh from settingsStore every time, not cached at button-creation
    // time, so a later theme/color change — once that lands — repaints
    // correctly without this code needing to change), and draws it plus a
    // selection border.
    private func handleDrawItem(lParam: LPARAM) -> LRESULT {
        guard let drawItem = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: UInt(bitPattern: Int(lParam))) else { return 0 }
        guard let control = pickerCards.first(where: { $0.hwnd == drawItem.pointee.hwndItem }) else { return 0 }
        drawPickerCard(control, drawItem: drawItem.pointee)
        return 1
    }

    private func drawPickerCard(_ control: PickerCardControl, drawItem: DRAWITEMSTRUCT) {
        let settings = settingsStore.get()
        let card: AppearancePreviews.Card
        let isSelected: Bool
        switch control.kind {
        case .friend:
            guard let built = AppearancePreviews.friendIcon(friendID: control.itemID, inkColor: settings.inkColor, paperColor: settings.paperColor) else { return }
            card = built
            isSelected = settings.friend == control.itemID
        case .frameStyle:
            card = AppearancePreviews.frameEdgeCard(frameStyle: control.itemID, inkColor: settings.inkColor, paperColor: settings.paperColor)
            isSelected = settings.frameStyle == control.itemID
        case .background:
            card = AppearancePreviews.backgroundPatternCard(
                backgroundID: control.itemID, frameStyle: settings.frameStyle, inkColor: settings.inkColor, paperColor: settings.paperColor)
            isSelected = settings.background == control.itemID
        }

        let hdc = drawItem.hDC
        var rect = drawItem.rcItem
        if let faceBrush = CreateSolidBrush(GetSysColor(COLOR_BTNFACE)) {
            FillRect(hdc, &rect, faceBrush)
            DeleteObject(faceBrush)
        }

        // Inset a little from the button edge so the selection border below
        // has room to draw outside the image itself.
        let margin: Int32 = 3
        let imageRect = RECT(left: rect.left + margin, top: rect.top + margin, right: rect.right - margin, bottom: rect.bottom - margin)
        card.canvas.draw(into: hdc, destRect: imageRect, cropX: card.cropX, cropY: card.cropY, cropWidth: card.cropWidth, cropHeight: card.cropHeight)

        if let borderPen = CreatePen(PS_SOLID, isSelected ? 2 : 1, GetSysColor(isSelected ? COLOR_HIGHLIGHT : COLOR_BTNSHADOW)) {
            let previousPen = SelectObject(hdc, borderPen)
            let previousBrush = SelectObject(hdc, GetStockObject(NULL_BRUSH))
            Rectangle(hdc, rect.left, rect.top, rect.right, rect.bottom)
            SelectObject(hdc, previousPen)
            SelectObject(hdc, previousBrush)
            DeleteObject(borderPen)
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

    // Mirrors macOS's KeysTab/ShortcutRow (SettingsView.swift): one row per
    // Shortcuts.action with a button showing its current binding (click to
    // record a new one), a Reset to Defaults button, then a static,
    // read-only list of the widget's own fixed keys. A single line per
    // shortcut row (label only, no hint underneath) — not a pixel match for
    // macOS's two-line LabeledContent rows, just enough to fit comfortably
    // alongside the informational list below.
    private func buildKeysTab(page: HWND, width: Int32) {
        keysPage = page
        let bindings = settingsStore.get().shortcuts
        let rowWidth = width - 2 * Self.rowMargin
        let labelWidth: Int32 = 300
        let buttonWidth: Int32 = 140
        var y = Self.rowMargin

        addLabel("Global shortcuts", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        for action in Shortcuts.actions {
            addLabel(action.label, in: page, x: Self.rowMargin, y: y + 3, width: labelWidth)
            let button = addButton(
                Shortcuts.displayWindows(bindings[action.id] ?? ""),
                in: page, x: Self.rowMargin + labelWidth + 8, y: y, width: buttonWidth, height: 22
            ) { [weak self] in
                self?.toggleShortcutRecording(actionID: action.id)
            }
            shortcutRecorders.append(ShortcutRecorderControl(buttonHwnd: button, actionID: action.id))
            y += Self.rowHeight
        }
        y += Self.groupGap

        addButton("Reset to Defaults", in: page, x: Self.rowMargin, y: y, width: 140, height: 24) { [weak self] in
            self?.resetShortcutsToDefaults()
        }
        y += 24 + Self.groupGap

        addLabel("While the widget is focused", in: page, x: Self.rowMargin, y: y, width: rowWidth)
        y += 20

        for binding in Self.widgetKeyBindings {
            addLabel(binding.keys, in: page, x: Self.rowMargin, y: y, width: 140)
            addLabel(binding.action, in: page, x: Self.rowMargin + 148, y: y, width: rowWidth - 148)
            y += 20
        }
    }

    private struct WidgetKeyBinding {
        let keys: String
        let action: String
    }

    // Mirrors macOS's widgetKeyBindings (SettingsView.swift), minus the T
    // (name-what-you're-working-on) and P (SVG snapshot) rows — neither
    // feature exists on Windows yet, so listing their keys here would be
    // informational noise about nothing actually bound.
    private static let widgetKeyBindings: [WidgetKeyBinding] = [
        WidgetKeyBinding(keys: "Space / Return", action: "Start / pause"),
        WidgetKeyBinding(keys: "S", action: "Skip phase"),
        WidgetKeyBinding(keys: "R", action: "Reset phase"),
        WidgetKeyBinding(keys: "O", action: "Keep on top"),
        WidgetKeyBinding(keys: ",", action: "Open settings"),
        WidgetKeyBinding(keys: "Esc", action: "Dismiss the ring, or hide the widget"),
        WidgetKeyBinding(keys: "Up / Down", action: "Adjust focus length, while idle"),
    ]

    // -- Keys tab: shortcut recording ------------------------------------------

    private func toggleShortcutRecording(actionID: String) {
        if recordingActionID == actionID {
            stopRecording()
            return
        }
        // Only one row records at a time — cancel whichever other row was
        // listening (no change committed for it) before starting this one.
        if recordingActionID != nil {
            stopRecording()
        }
        startRecording(actionID: actionID)
    }

    // Unregisters every live global hotkey up front: leaving the old combo
    // registered while capturing its replacement could either fire the
    // stale binding mid-capture, or block re-registering a combo the OS
    // already considers claimed (e.g. rebinding an action to its own
    // current key). handleShortcutRecorderKeyDown below watches for the
    // capture keystroke; stopRecording always re-applies the table
    // afterward, whether or not anything actually changed.
    private func startRecording(actionID: String) {
        recordingActionID = actionID
        globalShortcutManager.unregisterAll()
        if let recorder = shortcutRecorders.first(where: { $0.actionID == actionID }) {
            setWindowText(recorder.buttonHwnd, "Press a key…")
        }
        // Moves focus off the button that was just clicked (clicking a
        // BUTTON control focuses it as a side effect) onto the Keys page
        // itself, so the capture keystroke's WM_(SYS)KEYDOWN has somewhere
        // of ours to land — see pomoppiSettingsPageWndProc's forwarding and
        // handleMessage's WM_KEYDOWN/WM_SYSKEYDOWN case.
        if let keysPage {
            SetFocus(keysPage)
        }
    }

    // Ends whatever row is recording (a no-op on recordingActionID itself
    // if none was) and reapplies the shortcut table to the OS
    // unconditionally, since startRecording always unregistered everything
    // up front — reused by both an actual capture and Reset to Defaults.
    private func stopRecording() {
        let previousActionID = recordingActionID
        recordingActionID = nil
        refreshShortcutButtons()
        reregisterShortcuts()
        // Moves focus off the Keys page and back onto a real control now
        // that no keydown needs to land there — otherwise the page would
        // silently keep swallowing every future WM_KEYDOWN it's sent (see
        // handleMessage's WM_KEYDOWN/WM_SYSKEYDOWN case), for as long as it
        // keeps the focus startRecording gave it, even long after recording
        // itself has stopped.
        if let previousActionID, let recorder = shortcutRecorders.first(where: { $0.actionID == previousActionID }) {
            SetFocus(recorder.buttonHwnd)
        }
    }

    private func refreshShortcutButtons() {
        let bindings = settingsStore.get().shortcuts
        for recorder in shortcutRecorders {
            setWindowText(recorder.buttonHwnd, Shortcuts.displayWindows(bindings[recorder.actionID] ?? ""))
        }
    }

    private func resetShortcutsToDefaults() {
        settingsStore.update { $0.shortcuts = Shortcuts.defaults }
        stopRecording()
    }

    private func isKeyDown(_ vk: Int32) -> Bool {
        (GetKeyState(vk) & Int16(bitPattern: 0x8000)) != 0
    }

    private func liveModifiers() -> [String] {
        var mods: [String] = []
        if isKeyDown(VK_CONTROL) { mods.append("Control") }
        if isKeyDown(VK_MENU) { mods.append("Alt") }
        if isKeyDown(VK_SHIFT) { mods.append("Shift") }
        return mods
    }

    // Reverse of GlobalShortcutManager.keyCodes (private to that file, so
    // rebuilt here rather than exposed) — virtual-key code -> the key name
    // Shortcuts.normalize expects, for turning a captured keydown back into
    // a raw accelerator string.
    private static let virtualKeyNames: [Int32: String] = {
        var out: [Int32: String] = [:]
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            out[Int32(c.asciiValue!)] = String(c)
        }
        out[VK_OEM_3] = "`"
        out[VK_OEM_MINUS] = "-"
        out[VK_OEM_PLUS] = "="
        out[VK_OEM_4] = "["
        out[VK_OEM_6] = "]"
        out[VK_OEM_5] = "\\"
        out[VK_OEM_1] = ";"
        out[VK_OEM_7] = "'"
        out[VK_OEM_COMMA] = ","
        out[VK_OEM_PERIOD] = "."
        out[VK_OEM_2] = "/"
        out[VK_SPACE] = "Space"
        out[VK_RETURN] = "Return"
        out[VK_TAB] = "Tab"
        out[VK_BACK] = "Backspace"
        out[VK_DELETE] = "Delete"
        out[VK_INSERT] = "Insert"
        out[VK_ESCAPE] = "Escape"
        out[VK_UP] = "Up"
        out[VK_DOWN] = "Down"
        out[VK_LEFT] = "Left"
        out[VK_RIGHT] = "Right"
        out[VK_HOME] = "Home"
        out[VK_END] = "End"
        out[VK_PRIOR] = "PageUp"
        out[VK_NEXT] = "PageDown"
        out[VK_SNAPSHOT] = "PrintScreen"
        let fKeys: [Int32] = [
            VK_F1, VK_F2, VK_F3, VK_F4, VK_F5, VK_F6, VK_F7, VK_F8, VK_F9, VK_F10,
            VK_F11, VK_F12, VK_F13, VK_F14, VK_F15, VK_F16, VK_F17, VK_F18, VK_F19, VK_F20,
            VK_F21, VK_F22, VK_F23, VK_F24,
        ]
        for (i, vk) in fKeys.enumerated() { out[vk] = "F\(i + 1)" }
        return out
    }()

    // The next WM_KEYDOWN/WM_SYSKEYDOWN the Keys page receives while a row
    // is recording (forwarded here via pomoppiSettingsPageWndProc + this
    // window's own handleMessage — see both for why WM_SYSKEYDOWN has to be
    // included). Bare Escape cancels without changing the binding, same as
    // macOS's ShortcutRow.startRecording; any other key stops recording
    // whether or not it produced a usable combo (e.g. no modifier held),
    // mirroring that same method's unconditional `defer { stopRecording() }`.
    private func handleShortcutRecorderKeyDown(wParam: WPARAM) {
        guard let actionID = recordingActionID else { return }
        let vk = Int32(truncatingIfNeeded: wParam)

        // A modifier key press fires its own WM_(SYS)KEYDOWN on Windows
        // (unlike AppKit's separate flagsChanged) — wait for the actual key
        // instead of treating a bare modifier as the captured combo.
        if vk == VK_CONTROL || vk == VK_MENU || vk == VK_SHIFT || vk == VK_LWIN || vk == VK_RWIN {
            return
        }

        let mods = liveModifiers()
        if vk == VK_ESCAPE, mods.isEmpty {
            stopRecording()
            return
        }
        if !mods.isEmpty, let keyName = Self.virtualKeyNames[vk] {
            settingsStore.update { $0.shortcuts[actionID] = (mods + [keyName]).joined(separator: "+") }
        }
        stopRecording()
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

    // A plain BS_PUSHBUTTON (unlike addCheckbox's BS_AUTOCHECKBOX, no
    // persistent check state of its own) — used by the Keys tab for both
    // each row's own recorder button and Reset to Defaults.
    @discardableResult
    private func addButton(
        _ text: String, in page: HWND, x: Int32, y: Int32, width: Int32, height: Int32 = 24,
        onClick: @escaping () -> Void
    ) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let button = (Self.buttonClassName.withUnsafeBufferPointer { classNamePtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, textPtr.baseAddress,
                    DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON),
                    x, y, width, height,
                    page, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (button) failed with error \(GetLastError())")
        }
        applyDefaultFont(button)
        pushButtons.append(PushButtonControl(hwnd: button, onClick: onClick))
        return button
    }

    // Only setWindowTextW-based redraw a shortcut recorder button ever
    // needs (its own text is the whole displayed state, no separate check
    // mark or edit buddy) — SetWindowTextW repaints on its own.
    private func setWindowText(_ hwnd: HWND, _ text: String) {
        let wide = Array(text.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) }
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
        // Mirrors macOS's ShortcutRow.onDisappear(perform: stopRecording):
        // switching away from the Keys tab mid-recording must not leave
        // every global hotkey unregistered (startRecording's own
        // unregisterAll) with no way back short of returning to Keys and
        // finishing the capture.
        if recordingActionID != nil {
            stopRecording()
        }
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
        case WM_DRAWITEM:
            return handleDrawItem(lParam: lParam)
        case WM_KEYDOWN, WM_SYSKEYDOWN:
            // Always swallowed (return 0) rather than falling through to
            // DefWindowProcW: this only ever arrives forwarded from the
            // Keys page (see pomoppiSettingsPageWndProc — DefWindowProcW
            // would need the *page's* own HWND to mean anything here, not
            // this window's), and the Keys page never has keyboard focus
            // except while startRecording explicitly gave it that focus, so
            // there's no other default behavior worth preserving.
            handleShortcutRecorderKeyDown(wParam: wParam)
            return 0
        case WM_CLOSE:
            // Same reasoning as selectTab's own stopRecording call: closing
            // the window mid-recording must not leave every global hotkey
            // unregistered with no window left to finish the capture in.
            if recordingActionID != nil {
                stopRecording()
            }
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
        if notificationCode == BN_CLICKED, let button = pushButtons.first(where: { $0.hwnd == controlHwnd }) {
            button.onClick()
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
