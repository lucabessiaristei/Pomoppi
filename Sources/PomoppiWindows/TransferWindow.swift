// TransferWindow.swift — the Transfer popup (SPEC.md §16, TRANSFER_PLAN.md):
// Send (toggles, live weight line, QR, copy/save) and Receive (image, pasted
// code or file -> preview -> import), the counterpart of
// Sources/PomoppiApp/TransferSheet.swift. An owned popup (owner = the
// settings window, disabled while this is up) in the same hand-rolled
// class + WndProc shape as TaskPromptDialog, and the same dark-mode
// handling; but modeless in the message-loop sense — it runs on main.swift's
// loop rather than a nested one, since the log merge finishes off-thread and
// posts back to this window. All the format work is TransferCodec/QRCode/
// QRDecoder in PomoppiCore; image loading is TransferImageReader.
import Foundation
import PomoppiCore
import PomoppiRender
import PomoppiStrings
import WinSDK

private func pomoppiTransferWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = TransferWindow.current, let hwnd, window.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

final class TransferWindow {
    fileprivate static var current: TransferWindow?

    private enum Mode { case send, receive }

    // What Receive decoded and is waiting for the user to confirm.
    private struct Preview {
        let payload: TransferPayload
        let newPomodoros: Int
        let differingSettings: Int
    }

    let hwnd: HWND
    private let owner: HWND
    private let settingsStore: SettingsStore
    private let sessionLogger: SessionLogger
    private let darkMode: Bool

    // Snapshot taken at open (spec: Send encodes what was there then).
    private let snapshotSettings: PomoppiSettings
    private let snapshotSessions: [SessionLogEntry]

    private var mode = Mode.send
    private var preview: Preview?
    private var sendData: Data?
    private var sendCode: QRCode?
    private var qrBitmap: (hdc: HDC, bitmap: HBITMAP, previous: HGDIOBJ?, size: SIZE)?
    private var sendTooBig = false
    private var importedPomodoros = 0
    private var importedSettings = false

    // Controls.
    private var sendRadio: HWND!
    private var receiveRadio: HWND!
    private var settingsBox: HWND!
    private var logBox: HWND!
    private var titlesBox: HWND!
    private var subMinuteBox: HWND!
    private var detailsBox: HWND!
    private var sendMessageLabel: HWND!
    private var weightLabel: HWND!
    private var tooBigLabel: HWND!
    private var copyButton: HWND!
    private var saveImageButton: HWND!
    private var saveFileButton: HWND!
    private var receiveHint: HWND!
    private var receiveMessageLabel: HWND!
    private var receiveMessageIsError = false
    private var previewHeader: HWND!
    private var previewLogLabel: HWND!
    private var previewSettingsLabel: HWND!
    private var previewNoTitlesLabel: HWND!
    private var previewNoDetailsLabel: HWND!
    private var applySettingsBox: HWND!
    private var applyLogBox: HWND!
    private var importButton: HWND!
    private var cancelPreviewButton: HWND!
    private var closeButton: HWND!

    private var sendGroup: [HWND] = []
    private var receiveStartGroup: [HWND] = []
    private var previewGroup: [HWND] = []
    private var secondaryLabels: Set<HWND> = []
    private var checkboxes: [HWND] = []
    private var pushButtons: [HWND] = []
    private var actions: [HWND: () -> Void] = [:]

    private static let className: [UInt16] = Array("PomoppiTransferWindowClass".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)
    private static var classRegistered = false

    private static let windowStyle = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
    private static let clientWidth: Int32 = 460
    private static let clientHeight: Int32 = 716
    private static let margin: Int32 = 20
    private static let innerWidth: Int32 = 420
    // Sized for the largest code (v40: 177 + 8 quiet modules at 2 px = 370).
    private static let qrArea = RECT(left: 45, top: 252, right: 415, bottom: 622)
    private static let qrAreaSide: Int32 = 370
    private static let qrMaxSide = 420
    private static let controlHeight: Int32 = 26
    private static let checkHeight: Int32 = 22

    private static let importDoneMessage = UINT(WM_APP) + 1
    private static let copiedTimerID: UINT_PTR = 1
    private static let secondaryLightHex = "#6E6E6E"
    private static let secondaryDarkHex = "#A0A0A0"
    private static let errorLightHex = "#B3261E"
    private static let errorDarkHex = "#FF8A80"

    private static let boldFont: HFONT? = {
        guard let stockFont = GetStockObject(DEFAULT_GUI_FONT) else { return nil }
        var logFont = LOGFONTW()
        guard GetObjectW(stockFont, Int32(MemoryLayout<LOGFONTW>.size), &logFont) != 0 else { return nil }
        logFont.lfWeight = 700
        return CreateFontIndirectW(&logFont)
    }()

    private static func registerClassIfNeeded() {
        guard !classRegistered else { return }
        let atom: ATOM = className.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiTransferWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            windowClass.hIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON))
            return RegisterClassW(&windowClass)
        }
        guard atom != 0 else {
            fatalError("RegisterClassW (transfer window) failed with error \(GetLastError())")
        }
        classRegistered = true
    }

    // The one entry point: the Pomoppi tab's Transfer button. A second call
    // just brings the open window forward.
    static func show(owner: HWND, settingsStore: SettingsStore, sessionLogger: SessionLogger) {
        if let existing = current {
            SetForegroundWindow(existing.hwnd)
            return
        }
        registerClassIfNeeded()
        let window = TransferWindow(owner: owner, settingsStore: settingsStore, sessionLogger: sessionLogger)
        current = window
        EnableWindow(owner, false)
        window.updateVisibility()
        window.refreshSend()
        ShowWindow(window.hwnd, SW_SHOW)
        SetForegroundWindow(window.hwnd)
    }

    private init(owner: HWND, settingsStore: SettingsStore, sessionLogger: SessionLogger) {
        self.owner = owner
        self.settingsStore = settingsStore
        self.sessionLogger = sessionLogger
        self.snapshotSettings = settingsStore.get()
        self.snapshotSessions = sessionLogger.allSessionsSync()
        self.darkMode = WindowsTheme.resolveDarkMode(colorScheme: snapshotSettings.colorScheme)

        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        let windowWidth = rect.right - rect.left
        let windowHeight = rect.bottom - rect.top

        var workArea = RECT(left: 0, top: 0, right: 0, bottom: 0)
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &workArea, 0)
        var ownerRect = RECT()
        GetWindowRect(owner, &ownerRect)
        var x = ownerRect.left + ((ownerRect.right - ownerRect.left) - windowWidth) / 2
        var y = ownerRect.top + ((ownerRect.bottom - ownerRect.top) - windowHeight) / 2
        x = max(workArea.left, min(x, workArea.right - windowWidth))
        y = max(workArea.top, min(y, workArea.bottom - windowHeight))

        let title = Array(L.t("transfer.windowTitle").utf16) + [0]
        guard let createdHwnd = (Self.className.withUnsafeBufferPointer { classNamePtr in
            title.withUnsafeBufferPointer { titlePtr in
                CreateWindowExW(
                    0, classNamePtr.baseAddress, titlePtr.baseAddress,
                    Self.windowStyle,
                    x, y, windowWidth, windowHeight,
                    owner, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (transfer window) failed with error \(GetLastError())")
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
        DragAcceptFiles(hwnd, true)

        buildControls()
    }

    // -- controls -----------------------------------------------------------

    private func buildControls() {
        let m = Self.margin
        let w = Self.innerWidth

        // Segmented Send / Receive: two push-like radios, driven by hand.
        sendRadio = makeRadio(L.t("transfer.mode.send"), x: m, y: 16, width: 110) { [weak self] in self?.setMode(.send) }
        receiveRadio = makeRadio(L.t("transfer.mode.receive"), x: m + 116, y: 16, width: 110) { [weak self] in self?.setMode(.receive) }
        SendMessageW(sendRadio, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)

        // Send pane.
        let includeHeader = makeLabel(L.t("transfer.include.header"), x: m, y: 62, width: w, height: 18)
        if let boldFont = Self.boldFont {
            SendMessageW(includeHeader, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: boldFont)), LPARAM(1))
        }
        settingsBox = makeCheckbox(L.t("transfer.include.settings"), x: m, y: 84, width: w) { [weak self] in self?.refreshSend() }
        logBox = makeCheckbox(L.t("transfer.include.log"), x: m, y: 108, width: w) { [weak self] in self?.refreshSend() }
        titlesBox = makeCheckbox(L.t("transfer.include.titles"), x: m + 20, y: 132, width: w - 20) { [weak self] in self?.refreshSend() }
        subMinuteBox = makeCheckbox(L.t("transfer.include.subMinute"), x: m + 20, y: 156, width: w - 20) { [weak self] in self?.refreshSend() }
        detailsBox = makeCheckbox(L.t("transfer.include.details"), x: m + 20, y: 180, width: w - 20) { [weak self] in self?.refreshSend() }
        sendMessageLabel = makeLabel("", x: m, y: 206, width: w, height: 18)
        weightLabel = makeLabel("", x: m, y: 228, width: w, height: 18)
        tooBigLabel = makeLabel(L.t("transfer.tooBig.message"), x: m, y: 392, width: w, height: 80, centered: true)
        secondaryLabels.insert(sendMessageLabel)
        secondaryLabels.insert(weightLabel)
        copyButton = makePushButton(L.t("transfer.copyCode"), x: m, y: 634, width: 130) { [weak self] in self?.copyCode() }
        saveImageButton = makePushButton(L.t("transfer.saveImage"), x: m + 138, y: 634, width: 150) { [weak self] in self?.saveImage() }
        saveFileButton = makePushButton(L.t("transfer.saveFile"), x: m + 296, y: 634, width: 124) { [weak self] in self?.saveFile() }
        sendGroup = [includeHeader, settingsBox, logBox, titlesBox, subMinuteBox, detailsBox, sendMessageLabel, weightLabel,
                     copyButton, saveImageButton, saveFileButton]
        for box in [settingsBox, logBox, titlesBox, subMinuteBox, detailsBox] {
            SendMessageW(box, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
        }

        // Receive pane, start state.
        receiveHint = makeLabel(L.t("transfer.receive.hint"), x: m, y: 64, width: w, height: 60)
        secondaryLabels.insert(receiveHint)
        let openImage = makePushButton(L.t("transfer.openImage"), x: m, y: 134, width: 130) { [weak self] in self?.openImage() }
        let pasteCode = makePushButton(L.t("transfer.pasteCode"), x: m + 138, y: 134, width: 130) { [weak self] in self?.pasteCode() }
        let openFile = makePushButton(L.t("transfer.openFile"), x: m + 276, y: 134, width: 130) { [weak self] in self?.openFile() }
        receiveMessageLabel = makeLabel("", x: m, y: 176, width: w, height: 60)
        receiveStartGroup = [receiveHint, openImage, pasteCode, openFile, receiveMessageLabel]

        // Receive pane, preview state.
        previewHeader = makeLabel(L.t("transfer.preview.header"), x: m, y: 64, width: w, height: 18)
        if let boldFont = Self.boldFont {
            SendMessageW(previewHeader, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: boldFont)), LPARAM(1))
        }
        previewLogLabel = makeLabel("", x: m, y: 90, width: w, height: 18)
        previewSettingsLabel = makeLabel("", x: m, y: 112, width: w, height: 18)
        previewNoTitlesLabel = makeLabel(L.t("transfer.preview.noTitles"), x: m, y: 134, width: w, height: 18)
        previewNoDetailsLabel = makeLabel(L.t("transfer.preview.noDetails"), x: m, y: 154, width: w, height: 18)
        secondaryLabels.insert(previewNoTitlesLabel)
        secondaryLabels.insert(previewNoDetailsLabel)
        applySettingsBox = makeCheckbox(L.t("transfer.apply.settings"), x: m, y: 186, width: w) { [weak self] in self?.updateImportEnabled() }
        applyLogBox = makeCheckbox(L.t("transfer.apply.log"), x: m, y: 210, width: w) { [weak self] in self?.updateImportEnabled() }
        importButton = makePushButton(L.t("transfer.import"), x: m, y: 246, width: 110) { [weak self] in self?.performImport() }
        cancelPreviewButton = makePushButton(L.t("common.cancel"), x: m + 118, y: 246, width: 110) { [weak self] in self?.cancelPreview() }
        previewGroup = [previewHeader, previewLogLabel, previewSettingsLabel, previewNoTitlesLabel, previewNoDetailsLabel,
                        applySettingsBox, applyLogBox, importButton, cancelPreviewButton]

        closeButton = makePushButton(L.t("common.close"), x: Self.clientWidth - m - 90, y: 676, width: 90) { [weak self] in
            self?.close()
        }

        if darkMode {
            for button in pushButtons { Self.setTheme(button, subAppName: "DarkMode_Explorer") }
            // A themed checkbox ignores the text color WM_CTLCOLORBTN hands
            // back; turning visual styles off is what lets it take
            // (SettingsWindow.setControlClassicTheme has the full finding).
            for box in checkboxes { Self.setTheme(box, subAppName: "") }
        }
    }

    private func makeControl(_ cls: [UInt16], _ text: String, _ style: DWORD, x: Int32, y: Int32, width: Int32, height: Int32) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let control = (cls.withUnsafeBufferPointer { clsPtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, clsPtr.baseAddress, textPtr.baseAddress,
                    style, x, y, width, height,
                    hwnd, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (transfer control) failed with error \(GetLastError())")
        }
        if let font = GetStockObject(DEFAULT_GUI_FONT) {
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
        }
        return control
    }

    // SS_NOPREFIX: a bare '&' would otherwise be eaten as a mnemonic.
    private func makeLabel(_ text: String, x: Int32, y: Int32, width: Int32, height: Int32, centered: Bool = false) -> HWND {
        let style = DWORD(WS_CHILD | WS_VISIBLE | SS_NOPREFIX | (centered ? SS_CENTER : 0))
        return makeControl(Self.staticClassName, text, style, x: x, y: y, width: width, height: height)
    }

    private func makeCheckbox(_ text: String, x: Int32, y: Int32, width: Int32, onClick: @escaping () -> Void) -> HWND {
        let box = makeControl(Self.buttonClassName, text, DWORD(WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX), x: x, y: y, width: width, height: Self.checkHeight)
        checkboxes.append(box)
        actions[box] = onClick
        return box
    }

    private func makePushButton(_ text: String, x: Int32, y: Int32, width: Int32, onClick: @escaping () -> Void) -> HWND {
        let button = makeControl(Self.buttonClassName, text, DWORD(WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON), x: x, y: y, width: width, height: Self.controlHeight)
        pushButtons.append(button)
        actions[button] = onClick
        return button
    }

    private func makeRadio(_ text: String, x: Int32, y: Int32, width: Int32, onClick: @escaping () -> Void) -> HWND {
        let radio = makeControl(Self.buttonClassName, text, DWORD(WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON | BS_PUSHLIKE), x: x, y: y, width: width, height: Self.controlHeight)
        pushButtons.append(radio)
        actions[radio] = onClick
        return radio
    }

    private func setText(_ control: HWND, _ text: String) {
        let wide = Array(text.utf16) + [0]
        _ = wide.withUnsafeBufferPointer { SetWindowTextW(control, $0.baseAddress) }
    }

    private func isChecked(_ box: HWND) -> Bool {
        SendMessageW(box, UINT(BM_GETCHECK), 0, 0) == LRESULT(BST_CHECKED)
    }

    private func setChecked(_ box: HWND, _ checked: Bool) {
        SendMessageW(box, UINT(BM_SETCHECK), WPARAM(checked ? BST_CHECKED : BST_UNCHECKED), 0)
    }

    private func setEnabled(_ control: HWND, _ enabled: Bool) {
        EnableWindow(control, enabled)
    }

    // -- dark mode ----------------------------------------------------------

    private typealias SetWindowThemeProc = @convention(c) (HWND?, LPCWSTR?, LPCWSTR?) -> HRESULT
    private static let setWindowThemeProc: SetWindowThemeProc? = {
        let moduleName: [UInt16] = Array("uxtheme.dll".utf16) + [0]
        guard let module = (moduleName.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }) else { return nil }
        guard let proc = GetProcAddress(module, "SetWindowTheme") else { return nil }
        return unsafeBitCast(proc, to: SetWindowThemeProc.self)
    }()

    // "DarkMode_Explorer" restyles push buttons; "" (both names empty) turns
    // visual styles off for one control.
    private static func setTheme(_ control: HWND, subAppName: String) {
        guard let setWindowThemeProc else { return }
        let name: [UInt16] = Array(subAppName.utf16) + [0]
        _ = name.withUnsafeBufferPointer { namePtr in
            subAppName.isEmpty ? setWindowThemeProc(control, namePtr.baseAddress, namePtr.baseAddress) : setWindowThemeProc(control, namePtr.baseAddress, nil)
        }
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
        guard let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))) else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        let source = HWND(bitPattern: Int(bitPattern: UInt(lParam)))
        let hex: String?
        if let source, source == receiveMessageLabel, receiveMessageIsError {
            hex = darkMode ? Self.errorDarkHex : Self.errorLightHex
        } else if let source, secondaryLabels.contains(source) {
            hex = darkMode ? Self.secondaryDarkHex : Self.secondaryLightHex
        } else {
            hex = nil
        }
        if darkMode, let brush = WindowsTheme.darkBackgroundBrush {
            SetTextColor(hdc, WindowsTheme.colorref(hex: hex ?? WindowsTheme.darkTextHex))
            SetBkColor(hdc, WindowsTheme.colorref(hex: WindowsTheme.darkBackgroundHex))
            return LRESULT(Int(bitPattern: brush))
        }
        guard let hex, let brush = GetSysColorBrush(COLOR_BTNFACE) else {
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
        SetTextColor(hdc, WindowsTheme.colorref(hex: hex))
        SetBkColor(hdc, GetSysColor(COLOR_BTNFACE))
        return LRESULT(Int(bitPattern: brush))
    }

    // -- mode / visibility --------------------------------------------------

    private func setMode(_ newMode: Mode) {
        mode = newMode
        SendMessageW(sendRadio, UINT(BM_SETCHECK), WPARAM(newMode == .send ? BST_CHECKED : BST_UNCHECKED), 0)
        SendMessageW(receiveRadio, UINT(BM_SETCHECK), WPARAM(newMode == .receive ? BST_CHECKED : BST_UNCHECKED), 0)
        updateVisibility()
        var area = Self.qrArea
        InvalidateRect(hwnd, &area, true)
    }

    private func updateVisibility() {
        let showSend = mode == .send
        let showStart = mode == .receive && preview == nil
        let showPreview = mode == .receive && preview != nil
        for control in sendGroup { ShowWindow(control, showSend ? SW_SHOW : SW_HIDE) }
        ShowWindow(tooBigLabel, showSend && sendTooBig ? SW_SHOW : SW_HIDE)
        for control in receiveStartGroup { ShowWindow(control, showStart ? SW_SHOW : SW_HIDE) }
        for control in previewGroup { ShowWindow(control, showPreview ? SW_SHOW : SW_HIDE) }
        if let preview, showPreview {
            ShowWindow(applySettingsBox, preview.payload.settings != nil ? SW_SHOW : SW_HIDE)
            ShowWindow(applyLogBox, preview.payload.sessions != nil ? SW_SHOW : SW_HIDE)
            let hasLog = preview.payload.sessions != nil
            ShowWindow(previewNoTitlesLabel, hasLog && !preview.payload.titlesIncluded ? SW_SHOW : SW_HIDE)
            ShowWindow(previewNoDetailsLabel, hasLog && !preview.payload.detailsIncluded ? SW_SHOW : SW_HIDE)
        }
    }

    // -- Send ---------------------------------------------------------------

    private func disposeQR() {
        guard let qr = qrBitmap else { return }
        SelectObject(qr.hdc, qr.previous)
        DeleteObject(qr.bitmap)
        DeleteDC(qr.hdc)
        qrBitmap = nil
    }

    // Re-encodes from the toggles and repaints everything Send shows.
    private func refreshSend() {
        let settingsOn = isChecked(settingsBox)
        let logOn = isChecked(logBox)
        for box in [titlesBox!, subMinuteBox!, detailsBox!] { setEnabled(box, logOn) }

        sendData = nil
        sendCode = nil
        sendTooBig = false
        disposeQR()
        setText(weightLabel, "")

        if !settingsOn && !logOn {
            setText(sendMessageLabel, L.t("transfer.nothingSelected"))
        } else {
            let options = TransferOptions(
                settings: settingsOn, log: logOn, titles: isChecked(titlesBox),
                subMinuteSkips: isChecked(subMinuteBox), details: isChecked(detailsBox))
            do {
                let data = try TransferCodec.encode(settings: snapshotSettings, sessions: snapshotSessions, options: options)
                sendData = data
                let lossy = logOn && (!options.titles || !options.subMinuteSkips || !options.details)
                setText(sendMessageLabel, lossy ? L.t("transfer.lossyNote") : "")

                let size = TransferCodec.size(of: data)
                var parts = ["≈ " + SettingsWindow.formatHistorySize(Int64(size.bytes))]
                if let side = size.qrSide, let code = QRCode.encode(data) {
                    parts.append(L.t("transfer.weight.qr", side))
                    sendCode = code
                    buildQRBitmap(code)
                } else {
                    parts.append(L.t("transfer.weight.tooBig"))
                    sendTooBig = true
                }
                parts.append(L.t("transfer.weight.characters", Self.grouped(size.textCodeLength)))
                setText(weightLabel, parts.joined(separator: " · "))
            } catch {
                setText(sendMessageLabel, L.t("transfer.error.encode"))
            }
        }

        setEnabled(copyButton, sendData != nil)
        setEnabled(saveFileButton, sendData != nil)
        setEnabled(saveImageButton, sendCode != nil)
        setText(copyButton, L.t("transfer.copyCode"))
        KillTimer(hwnd, Self.copiedTimerID)
        updateVisibility()
        var area = Self.qrArea
        InvalidateRect(hwnd, &area, true)
    }

    private static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: L.current)
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    // Whole pixels per module, 2...8, as large as fits qrMaxSide, so the
    // blit stays 1:1 and the modules stay crisp.
    private func buildQRBitmap(_ code: QRCode) {
        let modules = code.size + 2 * PixelCanvas.qrQuietZone
        let scale = min(8, max(2, Self.qrMaxSide / modules))
        let canvas = PixelCanvas.qrCanvas(code, scale: scale)
        if let bitmap = canvas.makeLayeredBitmap(scale: 1) {
            qrBitmap = (bitmap.hdc, bitmap.bitmap, bitmap.previousBitmap, bitmap.size)
        }
    }

    private func paintQR() {
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        guard mode == .send, let qr = qrBitmap else { return }
        let x = Self.qrArea.left + (Self.qrAreaSide - qr.size.cx) / 2
        let y = Self.qrArea.top + (Self.qrAreaSide - qr.size.cy) / 2
        BitBlt(hdc, x, y, qr.size.cx, qr.size.cy, qr.hdc, 0, 0, DWORD(SRCCOPY))
    }

    private func copyCode() {
        guard let data = sendData else { return }
        let wide = Array(TransferCodec.textCode(data).utf16) + [0]
        let bytes = wide.count * MemoryLayout<UInt16>.size
        guard OpenClipboard(hwnd) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)), let memory = GlobalLock(handle) else { return }
        wide.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(handle)
        guard SetClipboardData(UINT(CF_UNICODETEXT), handle) != nil else {
            GlobalFree(handle)
            return
        }
        setText(copyButton, L.t("transfer.copied"))
        SetTimer(hwnd, Self.copiedTimerID, 2000, nil)
    }

    private func saveImage() {
        guard let code = sendCode,
              let path = promptPath(save: true, defaultName: "Pomoppi Transfer.png", filterLabel: "PNG (.png)", pattern: "*.png", defExt: "png")
        else { return }
        writeSaved(TransferPNG.encode(code, scale: 8), to: path)
    }

    private func saveFile() {
        guard let data = sendData,
              let path = promptPath(save: true, defaultName: "Pomoppi Transfer.pomoppi", filterLabel: "Pomoppi (.\(TransferCodec.fileExtension))", pattern: "*.\(TransferCodec.fileExtension)", defExt: TransferCodec.fileExtension)
        else { return }
        writeSaved(data, to: path)
    }

    private func writeSaved(_ data: Data, to path: String) {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            setText(sendMessageLabel, L.t("diary.export.failed"))
        }
    }

    // GetSaveFileNameW / GetOpenFileNameW with one filter pair, the same
    // OPENFILENAMEW shape as SettingsWindow's Diary export prompts. Returns
    // the path with the default extension appended if the user typed none.
    private func promptPath(save: Bool, defaultName: String, filterLabel: String, pattern: String, defExt: String) -> String? {
        var pathBuffer = [UInt16](repeating: 0, count: 1024)
        for (index, unit) in Array(defaultName.utf16).enumerated() where save {
            pathBuffer[index] = unit
        }
        let filter = Array("\(filterLabel)\0\(pattern)\0\0".utf16)
        let defExtWide = Array(defExt.utf16) + [0]

        var dialog = OPENFILENAMEW()
        dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        dialog.hwndOwner = hwnd
        dialog.Flags = save
            ? DWORD(OFN_OVERWRITEPROMPT) | DWORD(OFN_HIDEREADONLY)
            : DWORD(OFN_FILEMUSTEXIST) | DWORD(OFN_PATHMUSTEXIST) | DWORD(OFN_HIDEREADONLY)
        dialog.nFilterIndex = 1

        let picked = filter.withUnsafeBufferPointer { filterPtr in
            defExtWide.withUnsafeBufferPointer { defExtPtr in
                pathBuffer.withUnsafeMutableBufferPointer { bufferPtr -> Bool in
                    dialog.lpstrFilter = filterPtr.baseAddress
                    dialog.lpstrDefExt = defExtPtr.baseAddress
                    dialog.lpstrFile = bufferPtr.baseAddress
                    dialog.nMaxFile = DWORD(bufferPtr.count)
                    return save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog)
                }
            }
        }
        guard picked else { return nil }
        var path = pathBuffer.withUnsafeBufferPointer { String(decodingCString: $0.baseAddress!, as: UTF16.self) }
        if save, !path.lowercased().hasSuffix("." + defExt) { path += "." + defExt }
        return path
    }

    // -- Receive ------------------------------------------------------------

    private func showReceiveMessage(_ text: String, isError: Bool) {
        receiveMessageIsError = isError
        setText(receiveMessageLabel, text)
        InvalidateRect(receiveMessageLabel, nil, true)
    }

    private func fail(_ key: String) {
        showReceiveMessage(L.t(key) + "\n" + L.t("transfer.error.nothingChanged"), isError: true)
    }

    // Picking any source starts clean: no old error, no old preview.
    private func beginReceive() {
        preview = nil
        showReceiveMessage("", isError: false)
        updateVisibility()
    }

    private func openImage() {
        let pattern = "*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff"
        guard let path = promptPath(save: false, defaultName: "", filterLabel: pattern, pattern: pattern, defExt: "png") else { return }
        receiveImage(at: path)
    }

    private func openFile() {
        guard let path = promptPath(save: false, defaultName: "", filterLabel: "Pomoppi (.\(TransferCodec.fileExtension))", pattern: "*.\(TransferCodec.fileExtension)", defExt: TransferCodec.fileExtension) else { return }
        receiveFile(at: path)
    }

    private func pasteCode() {
        beginReceive()
        var text = ""
        if OpenClipboard(hwnd) {
            defer { CloseClipboard() }
            if let handle = GetClipboardData(UINT(CF_UNICODETEXT)), let memory = GlobalLock(handle) {
                text = String(decodingCString: memory.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
                GlobalUnlock(handle)
            }
        }
        do {
            decodePayload(try TransferCodec.data(fromTextCode: text))
        } catch {
            fail(Self.errorKey(error))
        }
    }

    private func receiveFile(at path: String) {
        beginReceive()
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            fail("transfer.error.file")
            return
        }
        // A text code saved to a file is still a text code.
        if let text = String(data: bytes, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(TransferCodec.textPrefix) {
            do {
                decodePayload(try TransferCodec.data(fromTextCode: text))
            } catch {
                fail(Self.errorKey(error))
            }
            return
        }
        decodePayload(bytes)
    }

    private func receiveImage(at path: String) {
        beginReceive()
        guard let luma = TransferImageReader.luma(fromFileAt: path) else {
            fail("transfer.error.file")
            return
        }
        do {
            decodePayload(try QRDecoder.decode(luma: luma.pixels, width: luma.width, height: luma.height))
        } catch {
            fail(Self.errorKey(error))
        }
    }

    // A dropped file: .pomoppi (or .txt) is a payload file, anything else is
    // tried as an image.
    private func receiveDropped(_ path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == TransferCodec.fileExtension || ext == "txt" {
            receiveFile(at: path)
        } else {
            receiveImage(at: path)
        }
    }

    private static func errorKey(_ error: Error) -> String {
        if let error = error as? QRDecoder.Error {
            switch error {
            case .notFound: return "transfer.error.noQR"
            case .unreadable, .unsupported: return "transfer.error.unreadableQR"
            }
        }
        if let error = error as? TransferError {
            switch error {
            case .notACode: return "transfer.error.notACode"
            case .unsupportedVersion, .multipart: return "transfer.error.newerVersion"
            default: return "transfer.error.damaged"
            }
        }
        return "transfer.error.damaged"
    }

    private func decodePayload(_ data: Data) {
        do {
            let payload = try TransferCodec.decode(data)
            showPreview(payload)
        } catch {
            fail(Self.errorKey(error))
        }
    }

    // -- Preview / import ---------------------------------------------------

    private func showPreview(_ payload: TransferPayload) {
        var newPomodoros = 0
        if let sessions = payload.sessions {
            let result = sessionLogger.previewImport(sessions)
            newPomodoros = result.newPomodoros
            setText(previewLogLabel, result.totalPomodoros == 1
                ? L.t("transfer.preview.pomodoros.one", result.newPomodoros)
                : L.t("transfer.preview.pomodoros.other", result.totalPomodoros, result.newPomodoros))
        } else {
            setText(previewLogLabel, L.t("transfer.preview.noLog"))
        }
        var differing = 0
        if let sent = payload.settings {
            differing = TransferCodec.differingSettingsCount(sent, settingsStore.get())
            setText(previewSettingsLabel, differing == 0
                ? L.t("transfer.preview.settingsSame")
                : L.t(differing == 1 ? "transfer.preview.settings.one" : "transfer.preview.settings.other", differing))
        } else {
            setText(previewSettingsLabel, L.t("transfer.preview.noSettings"))
        }
        setChecked(applySettingsBox, differing > 0)
        setChecked(applyLogBox, newPomodoros > 0)
        setEnabled(applyLogBox, newPomodoros > 0)
        preview = Preview(payload: payload, newPomodoros: newPomodoros, differingSettings: differing)
        updateImportEnabled()
        updateVisibility()
    }

    private func updateImportEnabled() {
        guard let preview else { return }
        let settings = preview.payload.settings != nil && isChecked(applySettingsBox)
        let log = preview.payload.sessions != nil && preview.newPomodoros > 0 && isChecked(applyLogBox)
        setEnabled(importButton, settings || log)
    }

    private func cancelPreview() {
        preview = nil
        updateVisibility()
    }

    private func performImport() {
        guard let preview else { return }
        importedSettings = false
        importedPomodoros = 0

        if preview.payload.settings != nil, let sent = preview.payload.settings, isChecked(applySettingsBox) {
            // Full replace through the store's normal update path, so
            // onChange re-applies widget, shortcuts and language live.
            settingsStore.update { $0 = TransferCodec.applying(sent, to: $0) }
            importedSettings = true
            SettingsWindow.reloadAfterSettingsImport()
        }
        if let sessions = preview.payload.sessions, preview.newPomodoros > 0, isChecked(applyLogBox) {
            setEnabled(importButton, false)
            setEnabled(cancelPreviewButton, false)
            let logger = sessionLogger
            let target = hwnd
            Task { [weak self] in
                let added = await logger.mergeImported(sessions)
                self?.importedPomodoros = added.addedPomodoros
                DiaryWindow.notifyHistoryChanged()
                PostMessageW(target, Self.importDoneMessage, 0, 0)
            }
        } else {
            finishImport()
        }
    }

    private func finishImport() {
        var lines: [String] = []
        if importedPomodoros > 0 {
            lines.append(importedPomodoros == 1
                ? L.t("transfer.done.pomodoros.one")
                : L.t("transfer.done.pomodoros.other", importedPomodoros))
        }
        if importedSettings { lines.append(L.t("transfer.done.settings")) }
        if lines.isEmpty { lines.append(L.t("transfer.done.nothing")) }
        preview = nil
        setEnabled(cancelPreviewButton, true)
        showReceiveMessage(lines.joined(separator: "\n"), isError: false)
        updateVisibility()
    }

    // -- lifecycle / dispatch -----------------------------------------------

    private func close() {
        // Re-enable the owner before destroying, or activation goes to some
        // other app's window.
        EnableWindow(owner, true)
        DestroyWindow(hwnd)
    }

    func handleMessage(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        if message == Self.importDoneMessage {
            finishImport()
            return 0
        }
        switch Int32(message) {
        case WM_COMMAND:
            let notificationCode = Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
            guard notificationCode == BN_CLICKED, let control = HWND(bitPattern: Int(lParam)), let action = actions[control] else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            action()
            return 0
        case WM_DROPFILES:
            handleDrop(wParam: wParam)
            return 0
        case WM_TIMER:
            if UINT_PTR(wParam) == Self.copiedTimerID {
                KillTimer(hwnd, Self.copiedTimerID)
                setText(copyButton, L.t("transfer.copyCode"))
            }
            return 0
        case WM_PAINT:
            paintQR()
            return 0
        case WM_ERASEBKGND:
            return handleEraseBackground(wParam: wParam)
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT:
            return handleCtlColor(message: message, wParam: wParam, lParam: lParam)
        case WM_CLOSE:
            close()
            return 0
        case WM_DESTROY:
            KillTimer(hwnd, Self.copiedTimerID)
            disposeQR()
            Self.current = nil
            return 0
        default:
            return DefWindowProcW(hwnd, message, wParam, lParam)
        }
    }

    private func handleDrop(wParam: WPARAM) {
        guard let drop = HDROP(bitPattern: Int(bitPattern: UInt(wParam))) else { return }
        defer { DragFinish(drop) }
        // The whole Receive pane is the target; Send has nothing to drop on.
        guard mode == .receive else { return }
        var buffer = [UInt16](repeating: 0, count: 1024)
        let length = DragQueryFileW(drop, 0, &buffer, UINT(buffer.count))
        guard length > 0 else { return }
        receiveDropped(String(decoding: buffer.prefix(Int(length)), as: UTF16.self))
    }
}

// A minimal PNG writer for the QR image: 8-bit grayscale, stored (uncompressed)
// deflate blocks. Dependency-free, same from-scratch precedent as
// ZipWriter/SHA256.
private enum TransferPNG {
    static func encode(_ code: QRCode, scale: Int) -> Data {
        let quiet = PixelCanvas.qrQuietZone
        let side = PixelCanvas.qrCanvasSide(modules: code.size, scale: scale)
        var raw = [UInt8]()
        raw.reserveCapacity((side + 1) * side)
        for py in 0..<side {
            raw.append(0)  // filter: none
            let row = py / scale - quiet
            for px in 0..<side {
                let col = px / scale - quiet
                let dark = row >= 0 && row < code.size && col >= 0 && col < code.size && code[col, row]
                raw.append(dark ? 0 : 255)
            }
        }

        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        while offset < raw.count {
            let count = min(65535, raw.count - offset)
            zlib.append(offset + count == raw.count ? 1 : 0)
            zlib += [UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            zlib += raw[offset..<offset + count]
            offset += count
        }
        zlib += bigEndian(adler32(raw))

        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var header = bigEndian(UInt32(side)) + bigEndian(UInt32(side))
        header += [8, 0, 0, 0, 0]  // 8-bit, grayscale, deflate, no filter, no interlace
        out += chunk("IHDR", header)
        out += chunk("IDAT", zlib)
        out += chunk("IEND", [])
        return Data(out)
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in bytes { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
