// DiaryWindow.swift — the Diary's history viewer (SPEC.md §8b), this
// platform's counterpart to Sources/PomoppiApp/DiaryWindow.swift: its own
// resizable top-level window, one instance, reopened to the front rather than
// duplicated. The rows come from the log through DiaryHistory; sort, search
// and the two delete kinds all go back through it / SessionLogger, so this
// file holds no copy of that logic. Same hand-rolled shape as
// TaskPromptDialog/SettingsWindow: a registered class + WndProc over raw
// controls (two SysListView32s), themed light/dark through WindowsTheme.
import Foundation
import PomoppiCore
import PomoppiRender
import PomoppiStrings
import WinSDK

private func pomoppiDiaryWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = DiaryWindow.shared, let hwnd, window.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

// DarkMode_Explorer leaves a plain EDIT's sunken border bright white; fill
// it dark on WM_NCPAINT (same fix as TaskPromptDialog's edit).
private func pomoppiDiaryEditSubclassProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM, _ subclassID: UINT_PTR, _ refData: DWORD_PTR) -> LRESULT {
    guard let hwnd, message == UINT(WM_NCPAINT) else {
        return DefSubclassProc(hwnd, message, wParam, lParam)
    }
    var windowRect = RECT()
    GetWindowRect(hwnd, &windowRect)
    let width = windowRect.right - windowRect.left
    let height = windowRect.bottom - windowRect.top
    guard width > 4, height > 4, let hdc = GetWindowDC(hwnd), let brush = WindowsTheme.darkBackgroundBrush else { return 0 }
    defer { ReleaseDC(hwnd, hdc) }
    var edges = [
        RECT(left: 0, top: 0, right: width, bottom: 2), RECT(left: 0, top: height - 2, right: width, bottom: height),
        RECT(left: 0, top: 0, right: 2, bottom: height), RECT(left: width - 2, top: 0, right: width, bottom: height),
    ]
    for index in edges.indices { FillRect(hdc, &edges[index], brush) }
    return 0
}

// DarkMode_Explorer leaves the report header light, and its NM_CUSTOMDRAW goes
// to the list, not to us: so in dark mode the header paints itself here.
private func pomoppiDiaryHeaderSubclassProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM, _ subclassID: UINT_PTR, _ refData: DWORD_PTR) -> LRESULT {
    guard let hwnd else { return DefSubclassProc(hwnd, message, wParam, lParam) }
    switch Int32(message) {
    case WM_ERASEBKGND:
        return 1
    case WM_PAINT:
        paintDarkHeader(hwnd)
        return 0
    default:
        return DefSubclassProc(hwnd, message, wParam, lParam)
    }
}

private func paintDarkHeader(_ hwnd: HWND) {
    var ps = PAINTSTRUCT()
    guard let hdc = BeginPaint(hwnd, &ps) else { return }
    defer { EndPaint(hwnd, &ps) }
    var client = RECT()
    GetClientRect(hwnd, &client)
    if let brush = WindowsTheme.darkBackgroundBrush { FillRect(hdc, &client, brush) }
    if let font = GetStockObject(DEFAULT_GUI_FONT) { SelectObject(hdc, font) }
    SetBkMode(hdc, Int32(TRANSPARENT))
    let textColor = WindowsTheme.colorref(hex: WindowsTheme.darkTextHex)
    SetTextColor(hdc, textColor)
    let lineBrush = CreateSolidBrush(WindowsTheme.colorref(hex: "#404040"))
    let arrowBrush = CreateSolidBrush(textColor)
    defer {
        if let lineBrush { DeleteObject(lineBrush) }
        if let arrowBrush { DeleteObject(arrowBrush) }
    }
    let count = Int(SendMessageW(hwnd, UINT(HDM_GETITEMCOUNT), 0, 0))
    for index in 0..<max(0, count) {
        var cell = RECT()
        guard SendMessageW(hwnd, UINT(HDM_GETITEMRECT), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &cell) { $0 }))) != 0 else { continue }
        var buffer = [UInt16](repeating: 0, count: 128)
        var fmt: Int32 = 0
        buffer.withUnsafeMutableBufferPointer { buf in
            var item = HDITEMW()
            item.mask = UINT(HDI_TEXT | HDI_FORMAT)
            item.pszText = buf.baseAddress
            item.cchTextMax = Int32(buf.count)
            if SendMessageW(hwnd, UINT(HDM_GETITEMW), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 }))) != 0 {
                fmt = item.fmt
            }
        }
        var textRect = RECT(left: cell.left + 6, top: cell.top, right: cell.right - 4, bottom: cell.bottom)
        DrawTextW(hdc, buffer, -1, &textRect, UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX))
        if let lineBrush {
            var divider = RECT(left: cell.right - 1, top: cell.top + 2, right: cell.right, bottom: cell.bottom - 2)
            FillRect(hdc, &divider, lineBrush)
            var bottom = RECT(left: cell.left, top: cell.bottom - 1, right: cell.right, bottom: cell.bottom)
            FillRect(hdc, &bottom, lineBrush)
        }
        let up = (fmt & Int32(HDF_SORTUP)) != 0
        if up || (fmt & Int32(HDF_SORTDOWN)) != 0, let arrowBrush {
            // The arrow sits at the top centre of the cell, like the themed one.
            let cx = (cell.left + cell.right) / 2
            let top = cell.top + 3
            var points = up
                ? [POINT(x: cx - 4, y: top + 4), POINT(x: cx + 4, y: top + 4), POINT(x: cx, y: top)]
                : [POINT(x: cx - 4, y: top), POINT(x: cx + 4, y: top), POINT(x: cx, y: top + 4)]
            let oldBrush = SelectObject(hdc, arrowBrush)
            let oldPen = SelectObject(hdc, GetStockObject(NULL_PEN))
            Polygon(hdc, &points, Int32(points.count))
            SelectObject(hdc, oldPen)
            SelectObject(hdc, oldBrush)
        }
    }
}

final class DiaryWindow {
    static var shared: DiaryWindow?

    // Set once by main.swift. The session logger is an actor, so a delete
    // finishes off the message-loop thread; the refresh is marshaled back
    // onto it by posting this message to `notifyHwnd` (the same trick
    // AppUpdateChecker uses), handled in WidgetWindow.
    static let historyChangedMessage: UINT32 = UINT32(WM_APP + 3)
    private static var settingsStore: SettingsStore!
    private static var sessionLogger: SessionLogger!
    private static var currentPomodoroStart: () -> Date? = { nil }
    private static var notifyHwnd: HWND!

    static func configure(settingsStore: SettingsStore, sessionLogger: SessionLogger, currentPomodoroStart: @escaping () -> Date?, notifyHwnd: HWND) {
        self.settingsStore = settingsStore
        self.sessionLogger = sessionLogger
        self.currentPomodoroStart = currentPomodoroStart
        self.notifyHwnd = notifyHwnd
    }

    // Safe from any thread.
    static func notifyHistoryChanged() {
        PostMessageW(notifyHwnd, historyChangedMessage, 0, 0)
    }

    // On the message-loop thread: refresh every view of the log.
    static func historyChanged() {
        shared?.reload()
        SettingsWindow.refreshDiarySummary()
    }

    static func show() {
        if let existing = shared {
            existing.reload()
            if IsIconic(existing.hwnd) { ShowWindow(existing.hwnd, SW_RESTORE) }
            SetForegroundWindow(existing.hwnd)
            return
        }
        registerClassIfNeeded()
        let window = DiaryWindow()
        shared = window
        window.reload()
        ShowWindow(window.hwnd, SW_SHOW)
        SetForegroundWindow(window.hwnd)
    }

    // -- constants ----------------------------------------------------------

    private static let className: [UInt16] = Array("PomoppiDiaryWindowClass".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let editClassName: [UInt16] = Array("EDIT".utf16) + [0]
    private static let listClassName: [UInt16] = Array("SysListView32".utf16) + [0]
    private static let tooltipClassName: [UInt16] = Array("tooltips_class32".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)
    private static var classRegistered = false

    private static let windowStyle = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_THICKFRAME)
    // Same opening size and floor as the macOS window's content.
    private static let initialClientSize = SIZE(cx: 760, cy: 640)
    private static let minClientSize = SIZE(cx: 620, cy: 460)

    private static let margin: Int32 = 12
    private static let topRowHeight: Int32 = 26
    // 2x the 32px friend sprite, so the pixels stay square.
    private static let tileSize: Int32 = 64
    private static let buttonWidth: Int32 = 140
    private static let secondaryColorDarkHex = "#A0A0A0"

    // Control IDs (WM_COMMAND's low word).
    private static let searchID: Int32 = 101
    private static let exportID: Int32 = 102
    private static let deletePomodoroID: Int32 = 103
    private static let deleteEntryID: Int32 = 104

    // ListView / header / tooltip constants the overlay doesn't import
    // reliably (unsigned LVN_FIRST arithmetic, struct-flag macros).
    private static let lvnItemChanged = UINT(bitPattern: -101)
    private static let lvnColumnClick = UINT(bitPattern: -108)
    private static let cdPrePaint: DWORD = 0x1
    private static let cdItemPrePaint: DWORD = 0x10001
    private static let cdSubItemPrePaint: DWORD = 0x30001
    private static let cdrfNotifyItemDraw: LRESULT = 0x20
    private static let cdrfNotifySubItemDraw: LRESULT = 0x20
    private static let enChange: Int32 = 0x0300
    private static let ttmAddToolW = UINT(WM_USER + 50)
    private static let ttmUpdateTipTextW = UINT(WM_USER + 57)

    private static func registerClassIfNeeded() {
        guard !classRegistered else { return }
        var icc = INITCOMMONCONTROLSEX()
        icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
        icc.dwICC = DWORD(ICC_LISTVIEW_CLASSES) | DWORD(ICC_WIN95_CLASSES)
        InitCommonControlsEx(&icc)
        let atom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiDiaryWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            windowClass.hIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON))
            return RegisterClassW(&windowClass)
        }
        guard atom != 0 else {
            fatalError("RegisterClassW (diary window) failed with error \(GetLastError())")
        }
        classRegistered = true
    }

    // -- state --------------------------------------------------------------

    let hwnd: HWND
    private let darkMode: Bool
    private var totalsLabel: HWND!
    private var statusLabel: HWND!
    private var searchEdit: HWND!
    private var exportButton: HWND!
    private var emptyLabel: HWND!
    private var rowList: HWND!
    private var friendTile: HWND!
    private var tooltip: HWND!
    private var titleLabel: HWND!
    private var noteLabel: HWND!
    private var deletePomodoroButton: HWND!
    private var entryList: HWND!
    private var deleteEntryButton: HWND!
    private var selectPromptLabel: HWND!
    private var boldFont: HFONT?

    private var rows: [DiaryHistory.Row] = []
    private var displayed: [DiaryHistory.Row] = []
    private var selection: Date?
    private var query = ""
    private var sortColumnIndex = 0      // the Date column, newest first
    private var sortAscending = false
    private var isFilling = false

    private var selectedRow: DiaryHistory.Row? { displayed.first { $0.id == selection } }

    private var text: DiaryText {
        DiaryText(locale: Locale(identifier: L.current), lookup: { key, args in L.t(key, args: args) })
    }

    // -- creation -----------------------------------------------------------

    private init() {
        darkMode = WindowsTheme.resolveDarkMode(colorScheme: Self.settingsStore.get().colorScheme)

        var rect = RECT(left: 0, top: 0, right: Self.initialClientSize.cx, bottom: Self.initialClientSize.cy)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top
        let x = (GetSystemMetrics(SM_CXSCREEN) - windowWidth) / 2
        let y = max(0, (GetSystemMetrics(SM_CYSCREEN) - windowHeight) / 2)

        let title = Array(L.t("diary.viewer.windowTitle").utf16) + [0]
        guard let created = (Self.className.withUnsafeBufferPointer { classNamePtr in
            title.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(0, classNamePtr.baseAddress, titlePtr.baseAddress, Self.windowStyle,
                                x, y, windowWidth, windowHeight, nil, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (diary window) failed with error \(GetLastError())")
        }
        hwnd = created

        if let bigIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON)) {
            SendMessageW(created, UINT(WM_SETICON), WPARAM(UInt(ICON_BIG)), LPARAM(Int(bitPattern: bigIcon)))
        }
        if let smallIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXSMICON), height: GetSystemMetrics(SM_CYSMICON)) {
            SendMessageW(created, UINT(WM_SETICON), WPARAM(UInt(ICON_SMALL)), LPARAM(Int(bitPattern: smallIcon)))
        }
        if darkMode {
            var useDarkMode: Int32 = 1
            _ = DwmSetWindowAttribute(created, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &useDarkMode, DWORD(MemoryLayout<Int32>.size))
        }

        buildControls()
        layout()
    }

    private func buildControls() {
        totalsLabel = makeStatic("", extraStyle: DWORD(SS_ENDELLIPSIS))
        statusLabel = makeStatic("", extraStyle: DWORD(SS_ENDELLIPSIS))

        searchEdit = makeControl(Self.editClassName, "", style: DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL), exStyle: DWORD(WS_EX_CLIENTEDGE), id: Self.searchID)
        if darkMode {
            Self.applyDarkExplorerTheme(searchEdit)
            _ = SetWindowSubclass(searchEdit, pomoppiDiaryEditSubclassProc, 1, 0)
        }
        var cue = Array(L.t("diary.viewer.search").utf16) + [0]
        cue.withUnsafeMutableBufferPointer { buf in
            _ = SendMessageW(searchEdit, UINT(EM_SETCUEBANNER), WPARAM(0), LPARAM(Int(bitPattern: buf.baseAddress)))
        }
        exportButton = makeButton(L.t("diary.viewer.exportExcel"), id: Self.exportID)

        emptyLabel = makeStatic("", extraStyle: DWORD(SS_CENTER))
        rowList = makeList(headers: true)
        if darkMode, let header = HWND(bitPattern: Int(SendMessageW(rowList, UINT(LVM_GETHEADER), 0, 0))) {
            _ = SetWindowSubclass(header, pomoppiDiaryHeaderSubclassProc, 2, 0)
        }

        friendTile = makeControl(Self.staticClassName, "", style: DWORD(WS_CHILD | SS_OWNERDRAW))
        tooltip = Self.tooltipClassName.withUnsafeBufferPointer { namePtr in
            CreateWindowExW(0, namePtr.baseAddress, nil, DWORD(WS_POPUP) | DWORD(TTS_ALWAYSTIP),
                            0, 0, 0, 0, hwnd, nil, Self.hInstance, nil)
        }
        var tool = TTTOOLINFOW()
        tool.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
        tool.uFlags = UINT(TTF_IDISHWND) | UINT(TTF_SUBCLASS)
        tool.hwnd = hwnd
        tool.uId = UINT_PTR(UInt(bitPattern: Int(bitPattern: friendTile)))
        _ = SendMessageW(tooltip, Self.ttmAddToolW, 0, LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &tool) { $0 })))

        titleLabel = makeStatic("", extraStyle: DWORD(SS_ENDELLIPSIS), visible: false)
        if let base = GetStockObject(DEFAULT_GUI_FONT) {
            var logFont = LOGFONTW()
            if GetObjectW(base, Int32(MemoryLayout<LOGFONTW>.size), &logFont) != 0 {
                logFont.lfWeight = 700
                boldFont = CreateFontIndirectW(&logFont)
                if let boldFont { SendMessageW(titleLabel, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: boldFont)), LPARAM(1)) }
            }
        }
        noteLabel = makeStatic(L.t("diary.viewer.inProgress"), extraStyle: DWORD(SS_ENDELLIPSIS), visible: false)
        deletePomodoroButton = makeButton(L.t("diary.viewer.deletePomodoro"), id: Self.deletePomodoroID, visible: false)
        entryList = makeList(headers: false)
        ShowWindow(entryList, SW_HIDE)
        addColumns()
        deleteEntryButton = makeButton(L.t("diary.viewer.deleteEntry"), id: Self.deleteEntryID, visible: false)
        selectPromptLabel = makeStatic(L.t("diary.viewer.selectPrompt"), extraStyle: DWORD(SS_CENTER), visible: false)
    }

    private func addColumns() {
        let titles = [
            L.t("diary.viewer.column.date"), L.t("diary.viewer.column.start"), L.t("diary.viewer.column.title"),
            L.t("diary.viewer.column.sessions"), L.t("diary.viewer.column.focus"), L.t("diary.viewer.column.breaks"),
        ]
        let widths: [Int32] = [110, 70, 200, 110, 90, 90]
        for (index, title) in titles.enumerated() {
            var wide = Array(title.utf16) + [0]
            wide.withUnsafeMutableBufferPointer { buf in
                var column = LVCOLUMNW()
                column.mask = UINT(LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM)
                column.cx = widths[index]
                column.pszText = buf.baseAddress
                column.iSubItem = Int32(index)
                _ = SendMessageW(rowList, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &column) { $0 })))
            }
        }
        // Entries: phase, focus number, start-end, duration, stopped early.
        for (index, width) in [90, 40, 130, 90, 150].enumerated() {
            var entryColumn = LVCOLUMNW()
            entryColumn.mask = UINT(LVCF_WIDTH | LVCF_SUBITEM)
            entryColumn.cx = Int32(width)
            entryColumn.iSubItem = Int32(index)
            _ = SendMessageW(entryList, UINT(LVM_INSERTCOLUMNW), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &entryColumn) { $0 })))
        }
        updateSortArrow()
    }

    private func makeControl(_ className: [UInt16], _ text: String, style: DWORD, exStyle: DWORD = 0, id: Int32 = 0) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let control = (className.withUnsafeBufferPointer { classPtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(exStyle, classPtr.baseAddress, textPtr.baseAddress, style, 0, 0, 10, 10,
                                hwnd, HMENU(bitPattern: Int(id)), Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (diary control) failed with error \(GetLastError())")
        }
        if let font = GetStockObject(DEFAULT_GUI_FONT) {
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
        }
        return control
    }

    private func makeStatic(_ text: String, extraStyle: DWORD = 0, visible: Bool = true) -> HWND {
        makeControl(Self.staticClassName, text, style: DWORD(WS_CHILD | SS_NOPREFIX) | extraStyle | (visible ? DWORD(WS_VISIBLE) : 0))
    }

    private func makeButton(_ text: String, id: Int32, visible: Bool = true) -> HWND {
        let button = makeControl(Self.buttonClassName, text, style: DWORD(WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON) | (visible ? DWORD(WS_VISIBLE) : 0), id: id)
        if darkMode { Self.applyDarkExplorerTheme(button) }
        return button
    }

    private func makeList(headers: Bool) -> HWND {
        var style = DWORD(WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS)
        if !headers { style |= DWORD(LVS_NOCOLUMNHEADER) }
        let list = makeControl(Self.listClassName, "", style: style)
        let extended = LPARAM(LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER)
        SendMessageW(list, UINT(LVM_SETEXTENDEDLISTVIEWSTYLE), 0, extended)
        if darkMode {
            Self.applyDarkExplorerTheme(list)
            SendMessageW(list, UINT(LVM_SETBKCOLOR), 0, LPARAM(WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex)))
            SendMessageW(list, UINT(LVM_SETTEXTBKCOLOR), 0, LPARAM(WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex)))
            SendMessageW(list, UINT(LVM_SETTEXTCOLOR), 0, LPARAM(WindowsTheme.colorref(hex: WindowsTheme.darkTextHex)))
        }
        return list
    }

    // -- layout -------------------------------------------------------------

    private func layout() {
        var client = RECT()
        GetClientRect(hwnd, &client)
        let width = client.right
        let height = client.bottom
        let m = Self.margin
        let inner = width - 2 * m

        let exportWidth: Int32 = 140
        let searchWidth: Int32 = 200
        let exportX = width - m - exportWidth
        let searchX = exportX - 8 - searchWidth
        move(exportButton, exportX, m, exportWidth, Self.topRowHeight)
        move(searchEdit, searchX, m, searchWidth, Self.topRowHeight)
        let labelY = m + 5
        let leftWidth = max(0, searchX - 8 - m)
        let totalsWidth = min(leftWidth, max(leftWidth / 2, 220))
        move(totalsLabel, m, labelY, totalsWidth, 18)
        move(statusLabel, m + totalsWidth + 8, labelY, max(0, leftWidth - totalsWidth - 8), 18)

        let contentTop = m + Self.topRowHeight + m
        let contentHeight = max(0, height - contentTop - m)
        move(emptyLabel, m, contentTop + contentHeight / 2 - 10, inner, 20)

        // A fixed proportion between the table and the detail.
        let upperHeight = max(120, contentHeight * 45 / 100)
        move(rowList, m, contentTop, inner, upperHeight)
        resizeTitleColumn(inner)

        let lowerTop = contentTop + upperHeight + 10
        let lowerHeight = max(0, height - m - lowerTop)
        move(selectPromptLabel, m, lowerTop + lowerHeight / 2 - 10, inner, 20)
        let rightEdge = width - m
        // Above the sprite and the entries: only the title (and the in-progress
        // note) and the delete button.
        move(deletePomodoroButton, rightEdge - Self.buttonWidth, lowerTop, Self.buttonWidth, Self.topRowHeight)
        let titleWidth = max(0, (rightEdge - Self.buttonWidth - 8 - m) / 2)
        move(titleLabel, m, lowerTop + 4, titleWidth, 20)
        move(noteLabel, m + titleWidth + 8, lowerTop + 5, max(0, rightEdge - Self.buttonWidth - 8 - (m + titleWidth + 8)), 18)
        let listTop = lowerTop + Self.topRowHeight + 8
        let x0 = m + Self.tileSize + m
        move(friendTile, m, listTop, Self.tileSize, Self.tileSize)
        let buttonY = height - m - Self.topRowHeight
        move(deleteEntryButton, rightEdge - Self.buttonWidth, buttonY, Self.buttonWidth, Self.topRowHeight)
        move(entryList, x0, listTop, max(0, rightEdge - x0), max(0, buttonY - 8 - listTop))
        InvalidateRect(hwnd, nil, true)
    }

    private func move(_ control: HWND?, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
        SetWindowPos(control, nil, x, y, w, h, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))
    }

    // Title takes whatever the other columns leave of the table's width.
    private func resizeTitleColumn(_ listWidth: Int32) {
        let others: Int32 = 110 + 70 + 110 + 90 + 90
        SendMessageW(rowList, UINT(LVM_SETCOLUMNWIDTH), 2, LPARAM(max(100, listWidth - others - 4)))
        // Breaks takes what's left, so the header has no bright filler past it.
        SendMessageW(rowList, UINT(LVM_SETCOLUMNWIDTH), 5, LPARAM(-2))
    }

    // -- data ---------------------------------------------------------------

    func reload() {
        rows = DiaryHistory.rows(Self.sessionLogger.allSessionsSync())
        refreshTable()
    }

    private func sortKey() -> DiaryHistory.SortColumn {
        switch sortColumnIndex {
        case 2: return .title
        case 3: return .focusCount
        case 4: return .focusSeconds
        case 5: return .breakSeconds
        default: return .start
        }
    }

    private func refreshTable() {
        displayed = DiaryHistory.sorted(
            DiaryHistory.filtered(rows, query: query), by: sortKey(), ascending: sortAscending,
            locale: Locale(identifier: L.current))
        let totals = DiaryHistory.totals(displayed)
        let count = totals.pomodoroCount
        let line = (count == 1 ? L.t("diary.pomodoros.one") : L.t("diary.pomodoros.other", count))
            + " · " + L.t("diary.focusTotal", DiaryExporter.duration(totals.focusSeconds, text))
        setText(totalsLabel, line)
        EnableWindow(exportButton, !rows.isEmpty)

        let locale = Locale(identifier: L.current)
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)

        isFilling = true
        SendMessageW(rowList, UINT(WM_SETREDRAW), 0, 0)
        SendMessageW(rowList, UINT(LVM_DELETEALLITEMS), 0, 0)
        for (index, row) in displayed.enumerated() {
            let cells = [
                row.start.formatted(dateStyle), row.start.formatted(timeStyle),
                row.title.isEmpty ? L.t("diary.viewer.untitled") : row.title,
                "\(row.focusCount)", DiaryExporter.duration(row.focusSeconds, text),
                DiaryExporter.duration(row.breakSeconds, text),
            ]
            setCells(rowList, index, cells)
        }
        if let selection, let index = displayed.firstIndex(where: { $0.id == selection }) {
            var item = LVITEMW()
            item.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
            item.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
            SendMessageW(rowList, UINT(LVM_SETITEMSTATE), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 })))
            SendMessageW(rowList, UINT(LVM_ENSUREVISIBLE), WPARAM(index), 0)
        } else {
            selection = nil
        }
        SendMessageW(rowList, UINT(WM_SETREDRAW), 1, 0)
        InvalidateRect(rowList, nil, true)
        isFilling = false

        let empty = displayed.isEmpty
        setText(emptyLabel, rows.isEmpty ? L.t("diary.viewer.empty") : L.t("diary.viewer.noMatch"))
        ShowWindow(emptyLabel, empty ? SW_SHOW : SW_HIDE)
        ShowWindow(rowList, empty ? SW_HIDE : SW_SHOW)
        refreshDetail()
    }

    // One report row: item text, then each further cell as a sub-item.
    private func setCells(_ list: HWND, _ index: Int, _ cells: [String]) {
        for (column, cell) in cells.enumerated() {
            var wide = Array(cell.utf16) + [0]
            wide.withUnsafeMutableBufferPointer { buf in
                var item = LVITEMW()
                item.iItem = Int32(index)
                item.iSubItem = Int32(column)
                item.pszText = buf.baseAddress
                if column == 0 {
                    item.mask = UINT(LVIF_TEXT)
                    SendMessageW(list, UINT(LVM_INSERTITEMW), 0, LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 })))
                } else {
                    SendMessageW(list, UINT(LVM_SETITEMTEXTW), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 })))
                }
            }
        }
    }

    private func isInProgress(_ row: DiaryHistory.Row) -> Bool {
        row.isInProgress(current: Self.currentPomodoroStart())
    }

    private func refreshDetail() {
        let row = displayed.isEmpty ? nil : selectedRow
        let showDetail = row != nil
        ShowWindow(selectPromptLabel, (!displayed.isEmpty && row == nil) ? SW_SHOW : SW_HIDE)
        for control in [friendTile, titleLabel, deletePomodoroButton, entryList, deleteEntryButton] {
            ShowWindow(control, showDetail ? SW_SHOW : SW_HIDE)
        }
        guard let row else {
            ShowWindow(noteLabel, SW_HIDE)
            return
        }
        let inProgress = isInProgress(row)
        setText(titleLabel, row.title.isEmpty ? L.t("diary.viewer.untitled") : row.title)
        ShowWindow(noteLabel, inProgress ? SW_SHOW : SW_HIDE)
        EnableWindow(deletePomodoroButton, !inProgress)

        let locale = Locale(identifier: L.current)
        let clock = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        SendMessageW(entryList, UINT(LVM_DELETEALLITEMS), 0, 0)
        for (index, item) in row.entries.enumerated() {
            let entry = item.entry
            let cells = [
                DiaryExporter.phaseName(entry.phase, text),
                entry.focusNumber.map { "#\($0)" } ?? "",
                "\(entry.startTime.formatted(clock))–\(entry.endTime.formatted(clock))",
                DiaryExporter.duration(entry.seconds, text),
                entry.completed ? "" : L.t("diary.stoppedEarly"),
            ]
            setCells(entryList, index, cells)
        }
        EnableWindow(deleteEntryButton, false)

        let tip = (friendImage(row.friend) != nil) ? (row.friend ?? "").capitalized : L.t("diary.viewer.friendUnknown")
        var wide = Array(tip.utf16) + [0]
        wide.withUnsafeMutableBufferPointer { buf in
            var tool = TTTOOLINFOW()
            tool.cbSize = UINT(MemoryLayout<TTTOOLINFOW>.size)
            tool.uFlags = UINT(TTF_IDISHWND)
            tool.hwnd = hwnd
            tool.uId = UINT_PTR(UInt(bitPattern: Int(bitPattern: friendTile)))
            tool.lpszText = buf.baseAddress
            _ = SendMessageW(tooltip, Self.ttmUpdateTipTextW, 0, LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &tool) { $0 })))
        }
        InvalidateRect(friendTile, nil, true)
    }

    private func setText(_ control: HWND?, _ string: String) {
        let wide = Array(string.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { SetWindowTextW(control, $0.baseAddress) }
    }

    private func friendImage(_ id: String?) -> AppearancePreviews.Card? {
        guard let id else { return nil }
        let settings = Self.settingsStore.get()
        return AppearancePreviews.friendIcon(friendID: id, inkColor: settings.inkColor, paperColor: settings.paperColor)
    }

    // -- sorting ------------------------------------------------------------

    private func columnClicked(_ index: Int) {
        if index == sortColumnIndex {
            sortAscending.toggle()
        } else {
            sortColumnIndex = index
            sortAscending = true
        }
        updateSortArrow()
        refreshTable()
    }

    private func updateSortArrow() {
        guard let header = HWND(bitPattern: Int(SendMessageW(rowList, UINT(LVM_GETHEADER), 0, 0))) else { return }
        for index in 0..<6 {
            var item = HDITEMW()
            item.mask = UINT(HDI_FORMAT)
            guard SendMessageW(header, UINT(HDM_GETITEMW), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 }))) != 0 else { continue }
            item.fmt &= ~(Int32(HDF_SORTUP) | Int32(HDF_SORTDOWN))
            if index == sortColumnIndex { item.fmt |= Int32(sortAscending ? HDF_SORTUP : HDF_SORTDOWN) }
            _ = SendMessageW(header, UINT(HDM_SETITEMW), WPARAM(index), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 })))
        }
    }

    // -- deleting / exporting -----------------------------------------------

    private func confirm(title: String, caption: String) -> Bool {
        let body = Array((title + "\n\n" + L.t("diary.history.eraseConfirm.message")).utf16) + [0]
        let captionWide = Array(caption.utf16) + [0]
        let result = body.withUnsafeBufferPointer { bodyPtr in
            captionWide.withUnsafeBufferPointer { captionPtr in
                MessageBoxW(hwnd, bodyPtr.baseAddress, captionPtr.baseAddress, UINT(MB_YESNO) | UINT(MB_ICONWARNING))
            }
        }
        return result == IDYES
    }

    private func deleteSelectedPomodoro() {
        guard let row = selectedRow, !isInProgress(row),
              confirm(title: L.t("diary.viewer.deletePomodoroConfirm.title"), caption: L.t("diary.viewer.deletePomodoro")) else { return }
        Task {
            _ = await Self.sessionLogger.deletePomodoro(startedAt: row.id)
            Self.notifyHistoryChanged()
        }
    }

    private func deleteSelectedEntry() {
        let index = Int(SendMessageW(entryList, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED)))
        guard let row = selectedRow, !isInProgress(row), index >= 0, index < row.entries.count,
              confirm(title: L.t("diary.viewer.deleteEntryConfirm.title"), caption: L.t("diary.viewer.deleteEntry")) else { return }
        let entry = row.entries[index].entry
        Task {
            _ = await Self.sessionLogger.deleteEntry(startTime: entry.startTime, phase: entry.phase)
            Self.notifyHistoryChanged()
        }
    }

    // The complete log, as Settings' Export does, always as .xlsx.
    private func exportExcel() {
        var pathBuffer = [UInt16](repeating: 0, count: 260)
        for (index, unit) in Array("Pomoppi Diary.\(DiaryFormat.xlsx.fileExtension)".utf16).enumerated() {
            pathBuffer[index] = unit
        }
        let filter = Array("\(L.t("diary.format.xlsx"))\0*.\(DiaryFormat.xlsx.fileExtension)\0\0".utf16)
        let defExt = Array(DiaryFormat.xlsx.fileExtension.utf16) + [0]
        var dialog = OPENFILENAMEW()
        dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        dialog.hwndOwner = hwnd
        dialog.Flags = DWORD(OFN_OVERWRITEPROMPT) | DWORD(OFN_HIDEREADONLY)
        dialog.nFilterIndex = 1
        let picked = filter.withUnsafeBufferPointer { filterPtr in
            defExt.withUnsafeBufferPointer { defExtPtr in
                pathBuffer.withUnsafeMutableBufferPointer { bufferPtr -> Bool in
                    dialog.lpstrFilter = filterPtr.baseAddress
                    dialog.lpstrDefExt = defExtPtr.baseAddress
                    dialog.lpstrFile = bufferPtr.baseAddress
                    dialog.nMaxFile = DWORD(bufferPtr.count)
                    return GetSaveFileNameW(&dialog)
                }
            }
        }
        guard picked else { return }
        let path = pathBuffer.withUnsafeBufferPointer { String(decodingCString: $0.baseAddress!, as: UTF16.self) }
        let url = URL(fileURLWithPath: path)
        let data = DiaryExporter.export(sessions: Self.sessionLogger.allSessionsSync(), format: .xlsx, text: text)
        do {
            try data.write(to: url, options: .atomic)
            setText(statusLabel, L.t("diary.export.success", url.lastPathComponent))
        } catch {
            setText(statusLabel, L.t("diary.export.failed"))
        }
    }

    // -- dark mode ----------------------------------------------------------

    // SetWindowTheme (uxtheme.dll) needs the manual LoadLibraryW/GetProcAddress
    // load: a small local copy, like TaskPromptDialog's (see its comment).
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

    // Secondary text (totals, status, notes, empty states) is muted; the
    // rest follows the theme. Light mode keeps the system colors.
    private func handleCtlColor(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        guard let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))) else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        let source = HWND(bitPattern: Int(lParam))
        let muted = source != nil && (source == totalsLabel || source == statusLabel || source == noteLabel
            || source == emptyLabel || source == selectPromptLabel)
        if darkMode, let brush = WindowsTheme.darkBackgroundBrush {
            SetTextColor(hdc, WindowsTheme.colorref(hex: muted ? Self.secondaryColorDarkHex : WindowsTheme.darkTextHex))
            SetBkColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex))
            return LRESULT(Int(bitPattern: brush))
        }
        guard muted, let brush = GetSysColorBrush(COLOR_BTNFACE) else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        SetTextColor(hdc, GetSysColor(COLOR_GRAYTEXT))
        SetBkColor(hdc, GetSysColor(COLOR_BTNFACE))
        return LRESULT(Int(bitPattern: brush))
    }

    // The friend's resting pose in the current theme colours, the Appearance
    // picker's icon; a dimmed "?" tile when the id wasn't recorded or is
    // unknown.
    private func handleDrawItem(lParam: LPARAM) -> LRESULT {
        guard let drawItem = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: UInt(bitPattern: Int(lParam)))?.pointee,
              drawItem.hwndItem == friendTile, let hdc = drawItem.hDC else { return 0 }
        var rect = drawItem.rcItem
        if let card = friendImage(selectedRow?.friend) {
            card.canvas.draw(into: hdc, destRect: rect, cropX: card.cropX, cropY: card.cropY, cropWidth: card.cropWidth, cropHeight: card.cropHeight)
            return 1
        }
        let fill = darkMode ? WindowsTheme.colorref(hex: "#333333") : WindowsTheme.colorref(hex: "#E4E4E4")
        if let brush = CreateSolidBrush(fill) {
            FillRect(hdc, &rect, brush)
            DeleteObject(brush)
        }
        var glyph = Array("?".utf16) + [0]
        SetBkMode(hdc, Int32(TRANSPARENT))
        SetTextColor(hdc, darkMode ? WindowsTheme.colorref(hex: "#777777") : WindowsTheme.colorref(hex: "#9A9A9A"))
        if let boldFont { SelectObject(hdc, boldFont) }
        DrawTextW(hdc, &glyph, -1, &rect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        return 1
    }

    // Greys what the viewer dims: an untitled pomodoro's placeholder title
    // and the entries the diary leaves out. Sub-item stage so only that cell
    // changes; every cell sets its colour, since the previous one carries over.
    private func handleCustomDraw(_ draw: UnsafeMutablePointer<NMLVCUSTOMDRAW>) -> LRESULT {
        let list = draw.pointee.nmcd.hdr.hwndFrom
        switch draw.pointee.nmcd.dwDrawStage {
        case Self.cdPrePaint:
            return Self.cdrfNotifyItemDraw
        case Self.cdItemPrePaint:
            return Self.cdrfNotifySubItemDraw
        case Self.cdSubItemPrePaint:
            let index = Int(draw.pointee.nmcd.dwItemSpec)
            var dim = false
            if list == rowList {
                dim = draw.pointee.iSubItem == 2 && index < displayed.count && displayed[index].title.isEmpty
            } else if list == entryList, let row = selectedRow, index < row.entries.count {
                dim = row.entries[index].isHiddenFromDiary
            }
            if dim {
                draw.pointee.clrText = darkMode ? WindowsTheme.colorref(hex: "#808080") : GetSysColor(COLOR_GRAYTEXT)
            } else {
                draw.pointee.clrText = darkMode ? WindowsTheme.colorref(hex: WindowsTheme.darkTextHex) : GetSysColor(COLOR_WINDOWTEXT)
            }
            return 0
        default:
            return 0
        }
    }

    private func handleNotify(lParam: LPARAM) -> LRESULT {
        guard let header = UnsafeMutablePointer<NMHDR>(bitPattern: UInt(bitPattern: Int(lParam))) else { return 0 }
        let code = header.pointee.code
        let from = header.pointee.hwndFrom
        if code == NM_CUSTOMDRAW && (from == rowList || from == entryList) {
            guard let draw = UnsafeMutablePointer<NMLVCUSTOMDRAW>(bitPattern: UInt(bitPattern: Int(lParam))) else { return 0 }
            return handleCustomDraw(draw)
        }
        if from == rowList {
            if code == Self.lvnColumnClick,
               let info = UnsafeMutablePointer<NMLISTVIEW>(bitPattern: UInt(bitPattern: Int(lParam))) {
                columnClicked(Int(info.pointee.iSubItem))
            } else if code == Self.lvnItemChanged, !isFilling {
                let index = Int(SendMessageW(rowList, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED)))
                // A click on blank space deselects in the control; keep the last
                // selected pomodoro (as macOS does) and put the highlight back.
                if index < 0 {
                    if let selection, let kept = displayed.firstIndex(where: { $0.id == selection }) {
                        isFilling = true
                        var item = LVITEMW()
                        item.stateMask = UINT(LVIS_SELECTED | LVIS_FOCUSED)
                        item.state = UINT(LVIS_SELECTED | LVIS_FOCUSED)
                        SendMessageW(rowList, UINT(LVM_SETITEMSTATE), WPARAM(kept), LPARAM(Int(bitPattern: withUnsafeMutablePointer(to: &item) { $0 })))
                        isFilling = false
                    }
                    return 0
                }
                let id = index < displayed.count ? displayed[index].id : nil
                if id != selection {
                    selection = id
                    refreshDetail()
                }
            }
        } else if from == entryList, code == Self.lvnItemChanged {
            let index = Int(SendMessageW(entryList, UINT(LVM_GETNEXTITEM), WPARAM(bitPattern: -1), LPARAM(LVNI_SELECTED)))
            if let row = selectedRow {
                EnableWindow(deleteEntryButton, index >= 0 && !isInProgress(row))
            }
        }
        return 0
    }

    private func handleCommand(wParam: WPARAM) {
        let id = Int32(truncatingIfNeeded: UInt16(truncatingIfNeeded: wParam))
        let code = Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
        switch id {
        case Self.searchID where code == Self.enChange:
            let length = GetWindowTextLengthW(searchEdit)
            var buffer = [UInt16](repeating: 0, count: Int(length) + 1)
            GetWindowTextW(searchEdit, &buffer, Int32(buffer.count))
            query = String(decoding: buffer.prefix(Int(length)), as: UTF16.self)
            refreshTable()
        case Self.exportID where code == BN_CLICKED:
            exportExcel()
        case Self.deletePomodoroID where code == BN_CLICKED:
            deleteSelectedPomodoro()
        case Self.deleteEntryID where code == BN_CLICKED:
            deleteSelectedEntry()
        default:
            break
        }
    }

    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        switch Int32(message) {
        case WM_SIZE:
            if wParam != WPARAM(SIZE_MINIMIZED) { layout() }
            return 0
        case WM_GETMINMAXINFO:
            guard let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(bitPattern: Int(lParam))) else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            var minRect = RECT(left: 0, top: 0, right: Self.minClientSize.cx, bottom: Self.minClientSize.cy)
            AdjustWindowRectEx(&minRect, Self.windowStyle, false, 0)
            info.pointee.ptMinTrackSize = POINT(x: minRect.right - minRect.left, y: minRect.bottom - minRect.top)
            return 0
        case WM_NOTIFY:
            return handleNotify(lParam: lParam)
        case WM_COMMAND:
            handleCommand(wParam: wParam)
            return 0
        case WM_DRAWITEM:
            return handleDrawItem(lParam: lParam)
        case WM_ERASEBKGND:
            return handleEraseBackground(wParam: wParam)
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT:
            return handleCtlColor(message: message, wParam: wParam, lParam: lParam)
        case WM_CLOSE:
            DestroyWindow(hwnd)
            return 0
        case WM_DESTROY:
            if let boldFont { DeleteObject(boldFont) }
            Self.shared = nil
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }
}
