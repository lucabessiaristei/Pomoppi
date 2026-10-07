// TransferWindow.swift — the Transfer window (SPEC.md §16):
// Send (QR card, toggles, live weight line, copy/save) and Receive (drop zone:
// image, pasted code or file -> preview -> import), the counterpart of
// Sources/PomoppiApp/TransferView.swift. An owned, user-resizable popup
// (owner = the settings window, disabled while this is up) in the same
// hand-rolled class + WndProc shape as TaskPromptDialog, and the same
// dark-mode handling; but modeless in the message-loop sense — it runs on
// main.swift's loop rather than a nested one, since the log merge finishes
// off-thread and posts back to this window. All the format work is
// TransferCodec/QRCode/QRDecoder in PomoppiCore; image loading is
// TransferImageReader.
//
// Layout: the Send/Receive switch is pinned on top, the pinned bottom bar
// (weight line + Copy/Save buttons, or the preview's Import/Cancel) sits at
// the bottom, and everything between lives in a child "viewport" window with
// its own native WS_VSCROLL bar (SettingsWindow's page pattern). Every
// control and card is placed in content coordinates by layout() and shifted
// by the scroll offset when applied, so a toggle change, a mode switch and a
// resize all just call layout() again.
import Foundation
import PomoppiCore
import PomoppiRender
import PomoppiSprites
import PomoppiStrings
import WinSDK

private func pomoppiTransferWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = TransferWindow.current, let hwnd, window.hwnd == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    return window.handleMessage(message: message, wParam: wParam, lParam: lParam)
}

// The viewport's own children (checkboxes, buttons, labels) notify their
// parent, which is the viewport, not the window: WM_COMMAND, WM_CTLCOLOR*
// and WM_DROPFILES are forwarded up. Its scrollbar's WM_VSCROLL arrives
// here with lParam == 0 and is handled with the viewport's own HWND.
private func pomoppiTransferViewportWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let window = TransferWindow.current, let hwnd, window.viewport == hwnd else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    switch Int32(message) {
    case WM_VSCROLL where lParam == 0:
        window.handleVScroll(wParam: wParam)
        return 0
    case WM_PAINT:
        window.paintViewport()
        return 0
    case WM_ERASEBKGND:
        return window.eraseViewport(wParam: wParam)
    case WM_COMMAND, WM_NOTIFY, WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT, WM_DROPFILES:
        return SendMessageW(window.hwnd, message, wParam, lParam)
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
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

    // A scrolled control at its un-scrolled (content) position.
    private struct Placement {
        let hwnd: HWND
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32
    }

    let hwnd: HWND
    fileprivate let viewport: HWND
    private let owner: HWND
    private let settingsStore: SettingsStore
    private let sessionLogger: SessionLogger
    private let darkMode: Bool

    // Snapshot taken at open (spec: Send encodes what was there then).
    private var snapshotSettings: PomoppiSettings
    private var snapshotSessions: [SessionLogEntry]

    private var mode = Mode.send
    private var preview: Preview?
    private var sendData: Data?
    private var sendCode: QRCode?
    private var qrBitmap: (hdc: HDC, bitmap: HBITMAP, previous: HGDIOBJ?, size: SIZE)?
    private var sendTooBig = false
    private var importedPomodoros = 0
    private var importedSettings = false

    // Controls pinned on the main window.
    private var sendRadio: HWND!
    private var receiveRadio: HWND!
    private var weightLabel: HWND!
    private var copyButton: HWND!
    private var saveImageButton: HWND!
    private var saveFileButton: HWND!
    private var importButton: HWND!
    private var cancelPreviewButton: HWND!

    // Controls in the scrolling viewport.
    private var includeHeader: HWND!
    private var settingsBox: HWND!
    private var logBox: HWND!
    private var titlesBox: HWND!
    private var subMinuteBox: HWND!
    private var detailsBox: HWND!
    private var sendMessageLabel: HWND!
    private var sendHintLabel: HWND!
    private var zoneTitle: HWND!
    private var zoneHint: HWND!
    private var zoneOr: HWND!
    private var pasteCodeButton: HWND!
    private var openFileButton: HWND!
    private var receiveMessageLabel: HWND!
    private var receiveMessageIsError = false
    private var previewHeader: HWND!
    private var previewLogLabel: HWND!
    private var previewSettingsLabel: HWND!
    private var previewNoTitlesLabel: HWND!
    private var previewNoDetailsLabel: HWND!
    private var applySettingsBox: HWND!
    private var applyLogBox: HWND!

    private var viewportControls: [HWND] = []
    private var barControls: [HWND] = []
    private var secondaryLabels: Set<HWND> = []
    private var checkboxes: [HWND] = []
    private var pushButtons: [HWND] = []
    private var actions: [HWND: () -> Void] = [:]
    private var texts: [HWND: String] = [:]
    private var labelFonts: [HWND: HFONT] = [:]
    private var built = false

    // Layout results, in content coordinates (the scroll offset is applied
    // when placing / painting).
    private var placements: [Placement] = []
    private var contentHeight: Int32 = 0
    private var viewportHeight: Int32 = 0
    private var scrollY: Int32 = 0
    private var barTop: Int32 = 0
    private var cardRect: RECT?
    private var zoneRect: RECT?
    private var critterRect: RECT?
    private var critterFrames: [(hdc: HDC, bitmap: HBITMAP, previous: HGDIOBJ?, size: SIZE)] = []
    private var critterFrame = 0
    private var critterTimerOn = false
    private var previewRect: RECT?

    private static let className: [UInt16] = Array("PomoppiTransferWindowClass".utf16) + [0]
    private static let viewportClassName: [UInt16] = Array("PomoppiTransferViewportClass".utf16) + [0]
    private static let staticClassName: [UInt16] = Array("STATIC".utf16) + [0]
    private static let buttonClassName: [UInt16] = Array("BUTTON".utf16) + [0]
    private static let hInstance = GetModuleHandleW(nil)
    private static var classRegistered = false

    // WS_THICKFRAME makes it user-resizable (SettingsWindow's windowStyle
    // precedent); WS_CLIPCHILDREN keeps the main erase off the viewport.
    private static let windowStyle = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_THICKFRAME) | DWORD(WS_CLIPCHILDREN)
    private static let clientWidth: Int32 = 480
    private static let clientHeight: Int32 = 760
    private static let minClientWidth: Int32 = 460
    private static let minClientHeight: Int32 = 480
    private static let margin: Int32 = 20
    private static let topBarHeight: Int32 = 50
    private static let cardPadding: Int32 = 16
    private static let zonePadding: Int32 = 16
    private static let zoneMinHeight: Int32 = 220
    private static let tooBigCardHeight: Int32 = 150
    private static let qrMaxSide = 380
    private static let controlHeight: Int32 = 26
    private static let checkHeight: Int32 = 22
    private static let labelHeight: Int32 = 18
    private static let scrollLine: Int32 = 24

    private static let importDoneMessage = UINT(WM_APP) + 1
    private static let copiedTimerID: UINT_PTR = 1
    private static let critterTimerID: UINT_PTR = 2
    private static let critterInterval: UINT = 600
    private static let critterSide: Int32 = 64
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff"]
    private static let secondaryLightHex = "#6E6E6E"
    private static let secondaryDarkHex = "#A0A0A0"
    private static let errorLightHex = "#B3261E"
    private static let errorDarkHex = "#FF8A80"
    private static let borderLightHex = "#B8B8B8"
    private static let borderDarkHex = "#6A6A6A"
    private static let dashLightHex = "#8C8C8C"
    private static let dashDarkHex = "#8A8A8A"
    private static let separatorLightHex = "#D0D0D0"
    private static let separatorDarkHex = "#3A3A3A"

    private static func scaledFont(bold: Bool, scale: Int32) -> HFONT? {
        guard let stockFont = GetStockObject(DEFAULT_GUI_FONT) else { return nil }
        var logFont = LOGFONTW()
        guard GetObjectW(stockFont, Int32(MemoryLayout<LOGFONTW>.size), &logFont) != 0 else { return nil }
        if bold { logFont.lfWeight = 700 }
        logFont.lfHeight = logFont.lfHeight * scale / 2
        return CreateFontIndirectW(&logFont)
    }

    private static let boldFont: HFONT? = scaledFont(bold: true, scale: 2)
    private static let titleFont: HFONT? = scaledFont(bold: true, scale: 3)

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
        let viewportAtom: ATOM = viewportClassName.withUnsafeBufferPointer { classNamePtr in
            var windowClass = WNDCLASSW()
            windowClass.lpfnWndProc = pomoppiTransferViewportWndProc
            windowClass.hInstance = hInstance
            windowClass.lpszClassName = classNamePtr.baseAddress
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hbrBackground = HBRUSH(bitPattern: Int(COLOR_BTNFACE + 1))
            return RegisterClassW(&windowClass)
        }
        guard viewportAtom != 0 else {
            fatalError("RegisterClassW (transfer viewport) failed with error \(GetLastError())")
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

        var workArea = RECT(left: 0, top: 0, right: 0, bottom: 0)
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &workArea, 0)
        var rect = RECT(left: 0, top: 0, right: Self.clientWidth, bottom: Self.clientHeight)
        AdjustWindowRectEx(&rect, Self.windowStyle, false, 0)
        // Taller than the old fixed sheet, but never taller than the screen.
        let windowWidth = min(rect.right - rect.left, workArea.right - workArea.left)
        let windowHeight = min(rect.bottom - rect.top, workArea.bottom - workArea.top)

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

        guard let createdViewport = (Self.viewportClassName.withUnsafeBufferPointer { classNamePtr in
            CreateWindowExW(
                0, classNamePtr.baseAddress, nil,
                DWORD(WS_CHILD | WS_CLIPCHILDREN | WS_VISIBLE | WS_VSCROLL),
                0, Self.topBarHeight, 100, 100,
                createdHwnd, nil, Self.hInstance, nil)
        }) else {
            fatalError("CreateWindowExW (transfer viewport) failed with error \(GetLastError())")
        }
        viewport = createdViewport

        if let bigIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXICON), height: GetSystemMetrics(SM_CYICON)) {
            SendMessageW(createdHwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_BIG)), LPARAM(Int(bitPattern: bigIcon)))
        }
        if let smallIcon = SettingsWindow.loadAppIcon(width: GetSystemMetrics(SM_CXSMICON), height: GetSystemMetrics(SM_CYSMICON)) {
            SendMessageW(createdHwnd, UINT(WM_SETICON), WPARAM(UInt(ICON_SMALL)), LPARAM(Int(bitPattern: smallIcon)))
        }
        if darkMode {
            var useDarkMode: Int32 = 1
            _ = DwmSetWindowAttribute(hwnd, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &useDarkMode, DWORD(MemoryLayout<Int32>.size))
            // The viewport's own scrollbar (SettingsWindow's page bars do the same).
            Self.setTheme(createdViewport, subAppName: "DarkMode_Explorer")
        }
        DragAcceptFiles(hwnd, true)
        DragAcceptFiles(viewport, true)

        buildCritterFrames()
        buildControls()
    }

    // -- controls -----------------------------------------------------------

    private func buildControls() {
        // Segmented Send / Receive: two push-like radios, driven by hand.
        sendRadio = makeRadio(L.t("transfer.mode.send"), width: 110) { [weak self] in self?.setMode(.send) }
        receiveRadio = makeRadio(L.t("transfer.mode.receive"), width: 110) { [weak self] in self?.setMode(.receive) }
        SendMessageW(sendRadio, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)

        // Send pane (scrolling part).
        sendHintLabel = makeLabel(L.t("transfer.send.hint"), centered: true, secondary: true)
        sendMessageLabel = makeLabel("", centered: true, secondary: true)
        includeHeader = makeLabel(L.t("transfer.include.header"), font: Self.boldFont)
        settingsBox = makeCheckbox(L.t("transfer.include.settings")) { [weak self] in self?.refreshSend() }
        logBox = makeCheckbox(L.t("transfer.include.log")) { [weak self] in self?.refreshSend() }
        titlesBox = makeCheckbox(L.t("transfer.include.titles")) { [weak self] in self?.refreshSend() }
        subMinuteBox = makeCheckbox(L.t("transfer.include.subMinute")) { [weak self] in self?.refreshSend() }
        detailsBox = makeCheckbox(L.t("transfer.include.details")) { [weak self] in self?.refreshSend() }
        for box in [settingsBox, logBox, titlesBox, subMinuteBox, detailsBox] {
            SendMessageW(box, UINT(BM_SETCHECK), WPARAM(BST_CHECKED), 0)
        }

        // Send pane (pinned bar).
        weightLabel = makeLabel("", secondary: true, parent: hwnd, bar: true)
        copyButton = makePushButton(L.t("transfer.copyCode"), parent: hwnd, bar: true) { [weak self] in self?.copyCode() }
        saveImageButton = makePushButton(L.t("transfer.saveImage"), parent: hwnd, bar: true) { [weak self] in self?.saveImage() }
        saveFileButton = makePushButton(L.t("transfer.saveFile"), parent: hwnd, bar: true) { [weak self] in self?.saveFile() }

        // Receive pane: the drop zone.
        zoneTitle = makeLabel(L.t("transfer.drop.title"), centered: true, font: Self.titleFont)
        zoneHint = makeLabel(L.t("transfer.drop.hint"), centered: true, secondary: true)
        zoneOr = makeLabel(L.t("transfer.drop.or"), centered: true, secondary: true)
        pasteCodeButton = makePushButton(L.t("transfer.pasteCode")) { [weak self] in self?.pasteCode() }
        openFileButton = makePushButton(L.t("transfer.openFile")) { [weak self] in self?.openFile() }
        receiveMessageLabel = makeLabel("", centered: true)

        // Receive pane: the preview card.
        previewHeader = makeLabel(L.t("transfer.preview.header"), font: Self.boldFont)
        previewLogLabel = makeLabel("")
        previewSettingsLabel = makeLabel("")
        previewNoTitlesLabel = makeLabel(L.t("transfer.preview.noTitles"), secondary: true)
        previewNoDetailsLabel = makeLabel(L.t("transfer.preview.noDetails"), secondary: true)
        applySettingsBox = makeCheckbox(L.t("transfer.apply.settings")) { [weak self] in self?.updateImportEnabled() }
        applyLogBox = makeCheckbox(L.t("transfer.apply.log")) { [weak self] in self?.updateImportEnabled() }
        importButton = makePushButton(L.t("transfer.import"), parent: hwnd, bar: true) { [weak self] in self?.performImport() }
        cancelPreviewButton = makePushButton(L.t("common.cancel"), parent: hwnd, bar: true) { [weak self] in self?.cancelPreview() }

        if darkMode {
            for button in pushButtons { Self.setTheme(button, subAppName: "DarkMode_Explorer") }
            // A themed checkbox ignores the text color WM_CTLCOLORBTN hands
            // back; turning visual styles off is what lets it take
            // (SettingsWindow.setControlClassicTheme has the full finding).
            for box in checkboxes { Self.setTheme(box, subAppName: "") }
        }
        built = true
    }

    private func makeControl(_ cls: [UInt16], _ text: String, _ style: DWORD, parent: HWND?) -> HWND {
        let wide = Array(text.utf16) + [0]
        guard let control = (cls.withUnsafeBufferPointer { clsPtr in
            wide.withUnsafeBufferPointer { textPtr in
                CreateWindowExW(
                    0, clsPtr.baseAddress, textPtr.baseAddress,
                    style, 0, 0, 10, 10,
                    parent ?? viewport, nil, Self.hInstance, nil)
            }
        }) else {
            fatalError("CreateWindowExW (transfer control) failed with error \(GetLastError())")
        }
        if let font = GetStockObject(DEFAULT_GUI_FONT) {
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
        }
        texts[control] = text
        return control
    }

    private func register(_ control: HWND, bar: Bool) {
        if bar { barControls.append(control) } else { viewportControls.append(control) }
    }

    // SS_NOPREFIX: a bare '&' would otherwise be eaten as a mnemonic.
    private func makeLabel(_ text: String, centered: Bool = false, secondary: Bool = false, font: HFONT? = nil, parent: HWND? = nil, bar: Bool = false) -> HWND {
        let style = DWORD(WS_CHILD | SS_NOPREFIX | (centered ? SS_CENTER : 0))
        let label = makeControl(Self.staticClassName, text, style, parent: parent)
        if secondary { secondaryLabels.insert(label) }
        if let font {
            SendMessageW(label, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: font)), LPARAM(1))
            labelFonts[label] = font
        }
        register(label, bar: bar)
        return label
    }

    private func makeCheckbox(_ text: String, onClick: @escaping () -> Void) -> HWND {
        let box = makeControl(Self.buttonClassName, text, DWORD(WS_CHILD | BS_AUTOCHECKBOX), parent: nil)
        checkboxes.append(box)
        actions[box] = onClick
        register(box, bar: false)
        return box
    }

    private func makePushButton(_ text: String, parent: HWND? = nil, bar: Bool = false, onClick: @escaping () -> Void) -> HWND {
        let button = makeControl(Self.buttonClassName, text, DWORD(WS_CHILD | BS_PUSHBUTTON), parent: parent)
        pushButtons.append(button)
        actions[button] = onClick
        register(button, bar: bar)
        return button
    }

    // The two mode radios are always shown, so they stay out of both lists.
    private func makeRadio(_ text: String, width: Int32, onClick: @escaping () -> Void) -> HWND {
        let radio = makeControl(Self.buttonClassName, text, DWORD(WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON | BS_PUSHLIKE), parent: hwnd)
        pushButtons.append(radio)
        actions[radio] = onClick
        return radio
    }

    private func setText(_ control: HWND, _ text: String) {
        texts[control] = text
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

    // msimg32's AlphaBlend, loaded like SetWindowTheme above (it isn't in the
    // default link set either).
    private typealias AlphaBlendProc = @convention(c) (HDC?, Int32, Int32, Int32, Int32, HDC?, Int32, Int32, Int32, Int32, BLENDFUNCTION) -> Int32
    private static let alphaBlendProc: AlphaBlendProc? = {
        let moduleName: [UInt16] = Array("msimg32.dll".utf16) + [0]
        guard let module = (moduleName.withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }) else { return nil }
        guard let proc = GetProcAddress(module, "AlphaBlend") else { return nil }
        return unsafeBitCast(proc, to: AlphaBlendProc.self)
    }()

    // Gemuppin's line art alone: only the '#' pixels, in the secondary text
    // gray, at 2 px per sprite pixel; everything else stays alpha 0.
    private func buildCritterFrames() {
        let hex = darkMode ? Self.secondaryDarkHex : Self.secondaryLightHex
        for grid in GeneratedSprites.friendFrames["gemuppin"] ?? [] {
            let canvas = PixelCanvas(width: GeneratedSprites.friendWidth, height: GeneratedSprites.friendHeight)
            canvas.drawGrid(grid, 0, 0, colorMap: ["#": hex])
            if let bitmap = canvas.makeLayeredBitmap(scale: 2) {
                critterFrames.append((bitmap.hdc, bitmap.bitmap, bitmap.previousBitmap, bitmap.size))
            }
        }
    }

    private func disposeCritter() {
        for frame in critterFrames {
            SelectObject(frame.hdc, frame.previous)
            DeleteObject(frame.bitmap)
            DeleteDC(frame.hdc)
        }
        critterFrames = []
    }

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

    fileprivate func eraseViewport(wParam: WPARAM) -> LRESULT {
        guard darkMode, let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam))), let brush = WindowsTheme.darkBackgroundBrush else {
            return DefWindowProcW(viewport, UINT(WM_ERASEBKGND), wParam, 0)
        }
        var rect = RECT()
        GetClientRect(viewport, &rect)
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

    // -- layout -------------------------------------------------------------

    // Height `text` takes wrapped to `width` in a label's font.
    private func textHeight(_ text: String, width: Int32, font: HFONT? = nil) -> Int32 {
        guard !text.isEmpty, let hdc = GetDC(hwnd) else { return text.isEmpty ? 0 : Self.labelHeight }
        defer { ReleaseDC(hwnd, hdc) }
        let object: HGDIOBJ? = font.map { HGDIOBJ(OpaquePointer($0)) } ?? GetStockObject(DEFAULT_GUI_FONT)
        let previous = SelectObject(hdc, object)
        defer { SelectObject(hdc, previous) }
        var rect = RECT(left: 0, top: 0, right: max(1, width), bottom: 0)
        let wide = Array(text.utf16) + [0]
        _ = wide.withUnsafeBufferPointer {
            DrawTextW(hdc, $0.baseAddress, -1, &rect, UINT(DT_CALCRECT) | UINT(DT_WORDBREAK) | UINT(DT_NOPREFIX))
        }
        return max(Self.labelHeight, rect.bottom - rect.top)
    }

    private func labelHeight(_ label: HWND, width: Int32) -> Int32 {
        textHeight(texts[label] ?? "", width: width, font: labelFonts[label])
    }

    // Recomputes where everything goes for the current mode, state and window
    // size, shows/hides controls accordingly, and re-applies the scroll offset.
    private func layout() {
        guard built else { return }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let clientWidth = client.right - client.left
        let clientHeight = client.bottom - client.top
        let m = Self.margin
        let barWidth = clientWidth - 2 * m

        // Pinned top: the mode switch.
        pin(sendRadio, x: m, y: 12, width: 110, height: Self.controlHeight)
        pin(receiveRadio, x: m + 116, y: 12, width: 110, height: Self.controlHeight)

        // Pinned bottom bar.
        let previewing = mode == .receive && preview != nil
        let barHeight: Int32 = mode == .send ? 66 : (previewing ? 46 : 0)
        barTop = clientHeight - barHeight
        var barShown: Set<HWND> = []
        func pinBar(_ control: HWND, x: Int32, y: Int32, width: Int32, height: Int32) {
            barShown.insert(control)
            pin(control, x: x, y: y, width: width, height: height)
        }
        if mode == .send {
            pinBar(weightLabel, x: m, y: barTop + 8, width: barWidth, height: Self.labelHeight)
            pinBar(copyButton, x: m, y: barTop + 32, width: 130, height: Self.controlHeight)
            pinBar(saveImageButton, x: m + 138, y: barTop + 32, width: 150, height: Self.controlHeight)
            pinBar(saveFileButton, x: m + 296, y: barTop + 32, width: 124, height: Self.controlHeight)
        } else if previewing {
            pinBar(importButton, x: m, y: barTop + 10, width: 110, height: Self.controlHeight)
            pinBar(cancelPreviewButton, x: m + 118, y: barTop + 10, width: 110, height: Self.controlHeight)
        }
        for control in barControls where !barShown.contains(control) { ShowWindow(control, SW_HIDE) }

        // The viewport.
        let viewportTop = Self.topBarHeight
        viewportHeight = max(0, barTop - viewportTop)
        SetWindowPos(viewport, nil, 0, viewportTop, clientWidth, viewportHeight, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE))

        // Content, in content coordinates. The width is fixed against the
        // scrollbar gutter being always reserved, so showing or hiding the
        // bar never reflows the text.
        let contentWidth = max(200, clientWidth - GetSystemMetrics(SM_CXVSCROLL) - 2 * m)
        var items: [Placement] = []
        cardRect = nil
        zoneRect = nil
        critterRect = nil
        previewRect = nil
        func put(_ control: HWND, x: Int32, y: Int32, width: Int32, height: Int32) {
            items.append(Placement(hwnd: control, x: x, y: y, width: width, height: height))
        }
        var y: Int32 = 12

        if mode == .send {
            let logOn = isChecked(logBox)
            if let qr = qrBitmap, sendCode != nil {
                let cardWidth = qr.size.cx + 2 * Self.cardPadding
                let cardHeight = qr.size.cy + 2 * Self.cardPadding
                let x = m + (contentWidth - cardWidth) / 2
                cardRect = RECT(left: x, top: y, right: x + cardWidth, bottom: y + cardHeight)
                y += cardHeight + 10
                let hintHeight = labelHeight(sendHintLabel, width: contentWidth)
                put(sendHintLabel, x: m, y: y, width: contentWidth, height: hintHeight)
                y += hintHeight + 12
            } else if sendTooBig {
                cardRect = RECT(left: m, top: y, right: m + contentWidth, bottom: y + Self.tooBigCardHeight)
                y += Self.tooBigCardHeight + 12
            }
            if !(texts[sendMessageLabel] ?? "").isEmpty {
                let messageHeight = labelHeight(sendMessageLabel, width: contentWidth)
                put(sendMessageLabel, x: m, y: y, width: contentWidth, height: messageHeight)
                y += messageHeight + 12
            }
            put(includeHeader, x: m, y: y, width: contentWidth, height: Self.labelHeight)
            y += 26
            put(settingsBox, x: m, y: y, width: contentWidth, height: Self.checkHeight)
            y += 24
            put(logBox, x: m, y: y, width: contentWidth, height: Self.checkHeight)
            y += 24
            // Collapsed, not greyed out, while the history is off.
            if logOn {
                for box in [titlesBox!, subMinuteBox!, detailsBox!] {
                    put(box, x: m + 20, y: y, width: contentWidth - 20, height: Self.checkHeight)
                    y += 24
                }
            }
        } else if let preview {
            let inset: Int32 = 14
            let innerX = m + inset
            let innerWidth = contentWidth - 2 * inset
            let top = y
            y += inset
            put(previewHeader, x: innerX, y: y, width: innerWidth, height: Self.labelHeight)
            y += 26
            for label in [previewLogLabel!, previewSettingsLabel!] {
                let height = labelHeight(label, width: innerWidth)
                put(label, x: innerX, y: y, width: innerWidth, height: height)
                y += height + 6
            }
            let hasLog = preview.payload.sessions != nil
            if hasLog && !preview.payload.titlesIncluded {
                put(previewNoTitlesLabel, x: innerX, y: y, width: innerWidth, height: Self.labelHeight)
                y += 22
            }
            if hasLog && !preview.payload.detailsIncluded {
                put(previewNoDetailsLabel, x: innerX, y: y, width: innerWidth, height: Self.labelHeight)
                y += 22
            }
            y += 6
            if preview.payload.settings != nil {
                put(applySettingsBox, x: innerX, y: y, width: innerWidth, height: Self.checkHeight)
                y += 26
            }
            // Hidden (not greyed out) when the log brings nothing new.
            if hasLog && preview.newPomodoros > 0 {
                put(applyLogBox, x: innerX, y: y, width: innerWidth, height: Self.checkHeight)
                y += 26
            }
            y += inset - 4
            previewRect = RECT(left: m, top: top, right: m + contentWidth, bottom: y)
            y += 12
        } else {
            let inner = contentWidth - 2 * Self.zonePadding
            let titleHeight = labelHeight(zoneTitle, width: inner)
            let hintHeight = labelHeight(zoneHint, width: inner)
            let critterBlock = critterFrames.isEmpty ? 0 : Self.critterSide + 12
            let total = critterBlock + titleHeight + 6 + hintHeight + 16 + Self.labelHeight + 10 + Self.controlHeight
            // Fills the viewport's visible height, minus what the error / done
            // lines below it need.
            var reserved: Int32 = 0
            if !(texts[receiveMessageLabel] ?? "").isEmpty {
                reserved = labelHeight(receiveMessageLabel, width: contentWidth) + 12
            }
            let available = viewportHeight - y - 12 - 8 - reserved
            let zoneHeight = max(Self.zoneMinHeight, total + 2 * 24, available)
            zoneRect = RECT(left: m, top: y, right: m + contentWidth, bottom: y + zoneHeight)
            var zy = y + (zoneHeight - total) / 2
            if !critterFrames.isEmpty {
                let cx = m + (contentWidth - Self.critterSide) / 2
                critterRect = RECT(left: cx, top: zy, right: cx + Self.critterSide, bottom: zy + Self.critterSide)
                zy += critterBlock
            }
            put(zoneTitle, x: m + Self.zonePadding, y: zy, width: inner, height: titleHeight)
            zy += titleHeight + 6
            put(zoneHint, x: m + Self.zonePadding, y: zy, width: inner, height: hintHeight)
            zy += hintHeight + 16
            put(zoneOr, x: m + Self.zonePadding, y: zy, width: inner, height: Self.labelHeight)
            zy += Self.labelHeight + 10
            let gap: Int32 = 8
            let buttonWidth = min(150, (inner - gap) / 2)
            var bx = m + (contentWidth - (2 * buttonWidth + gap)) / 2
            for button in [openFileButton!, pasteCodeButton!] {
                put(button, x: bx, y: zy, width: buttonWidth, height: Self.controlHeight)
                bx += buttonWidth + gap
            }
            y += zoneHeight + 12
        }
        if mode == .receive, !(texts[receiveMessageLabel] ?? "").isEmpty {
            let messageHeight = labelHeight(receiveMessageLabel, width: contentWidth)
            put(receiveMessageLabel, x: m, y: y, width: contentWidth, height: messageHeight)
            y += messageHeight + 12
        }
        contentHeight = y + 8
        updateCritterTimer(on: critterRect != nil)

        let placed = Set(items.map { $0.hwnd })
        for control in viewportControls where !placed.contains(control) { ShowWindow(control, SW_HIDE) }
        placements = items
        updateScrollInfo()
        applyPlacements()
    }

    private func updateCritterTimer(on: Bool) {
        guard on != critterTimerOn else { return }
        critterTimerOn = on
        if on {
            SetTimer(hwnd, Self.critterTimerID, Self.critterInterval, nil)
        } else {
            KillTimer(hwnd, Self.critterTimerID)
        }
    }

    private func pin(_ control: HWND, x: Int32, y: Int32, width: Int32, height: Int32) {
        SetWindowPos(control, nil, x, y, width, height, UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE) | UINT(SWP_SHOWWINDOW))
    }

    // -- scrolling ----------------------------------------------------------

    private func updateScrollInfo() {
        scrollY = min(max(0, scrollY), max(0, contentHeight - viewportHeight))
        var info = SCROLLINFO()
        info.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        info.fMask = UINT(SIF_RANGE | SIF_PAGE | SIF_POS)
        info.nMin = 0
        info.nMax = contentHeight - 1
        info.nPage = UINT(viewportHeight)
        info.nPos = scrollY
        SetScrollInfo(viewport, Int32(SB_VERT), &info, true)
    }

    // One DeferWindowPos batch moves every control, then the viewport is
    // redrawn in one go (the cards are painted, not controls).
    private func applyPlacements() {
        var batch = BeginDeferWindowPos(Int32(placements.count))
        for item in placements {
            batch = DeferWindowPos(
                batch, item.hwnd, nil, item.x, item.y - scrollY, item.width, item.height,
                UINT(SWP_NOZORDER) | UINT(SWP_NOACTIVATE) | UINT(SWP_SHOWWINDOW))
        }
        EndDeferWindowPos(batch)
        RedrawWindow(viewport, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ERASE) | UINT(RDW_ALLCHILDREN) | UINT(RDW_UPDATENOW))
    }

    private func scroll(to target: Int32) {
        let clamped = min(max(0, target), max(0, contentHeight - viewportHeight))
        guard clamped != scrollY else { return }
        scrollY = clamped
        SetScrollPos(viewport, Int32(SB_VERT), clamped, true)
        applyPlacements()
    }

    fileprivate func handleVScroll(wParam: WPARAM) {
        let request = Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) & 0xFFFF)
        let target: Int32
        switch request {
        case SB_LINEUP: target = scrollY - Self.scrollLine
        case SB_LINEDOWN: target = scrollY + Self.scrollLine
        case SB_PAGEUP: target = scrollY - viewportHeight
        case SB_PAGEDOWN: target = scrollY + viewportHeight
        case SB_TOP: target = 0
        case SB_BOTTOM: target = contentHeight
        case SB_THUMBTRACK, SB_THUMBPOSITION:
            var info = SCROLLINFO()
            info.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
            info.fMask = UINT(SIF_TRACKPOS)
            GetScrollInfo(viewport, Int32(SB_VERT), &info)
            target = info.nTrackPos
        default:
            return
        }
        scroll(to: target)
    }

    // WM_MOUSEWHEEL goes to the focused control and DefWindowProc bubbles it
    // up to here; the high word of wParam is a signed multiple of 120.
    private func handleMouseWheel(wParam: WPARAM) {
        let highWord = UInt16(truncatingIfNeeded: UInt32(truncatingIfNeeded: wParam) >> 16)
        let notches = Double(Int16(bitPattern: highWord)) / 120.0
        scroll(to: scrollY + Int32((-notches * 60).rounded()))
    }

    // -- painting -----------------------------------------------------------

    private func offset(_ rect: RECT) -> RECT {
        RECT(left: rect.left, top: rect.top - scrollY, right: rect.right, bottom: rect.bottom - scrollY)
    }

    // Selects a 1 px pen + the stock hollow or a solid white brush, draws a
    // rounded rect, restores.
    private func strokeRoundRect(_ hdc: HDC, _ rect: RECT, penStyle: Int32, penHex: String, fillWhite: Bool) {
        guard let pen = CreatePen(penStyle, 1, WindowsTheme.colorref(hex: penHex)) else { return }
        let brush = fillWhite ? CreateSolidBrush(COLORREF(0x00FF_FFFF)) : nil
        let previousPen = SelectObject(hdc, HGDIOBJ(OpaquePointer(pen)))
        let previousBrush = SelectObject(hdc, brush.map { HGDIOBJ(OpaquePointer($0)) } ?? GetStockObject(NULL_BRUSH))
        let previousBackground = SetBkMode(hdc, TRANSPARENT)
        RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, 20, 20)
        SetBkMode(hdc, previousBackground)
        SelectObject(hdc, previousBrush)
        SelectObject(hdc, previousPen)
        DeleteObject(HGDIOBJ(OpaquePointer(pen)))
        if let brush { DeleteObject(HGDIOBJ(OpaquePointer(brush))) }
    }

    fileprivate func paintViewport() {
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(viewport, &ps) else { return }
        defer { EndPaint(viewport, &ps) }

        if let card = cardRect.map(offset) {
            strokeRoundRect(hdc, card, penStyle: PS_SOLID, penHex: darkMode ? Self.borderDarkHex : Self.borderLightHex, fillWhite: true)
            if let qr = qrBitmap, sendCode != nil {
                let x = card.left + ((card.right - card.left) - qr.size.cx) / 2
                let y = card.top + ((card.bottom - card.top) - qr.size.cy) / 2
                BitBlt(hdc, x, y, qr.size.cx, qr.size.cy, qr.hdc, 0, 0, DWORD(SRCCOPY))
            } else if sendTooBig {
                // The card is white in both themes, so the text is too-dark gray.
                var textRect = RECT(left: card.left + 20, top: card.top + 20, right: card.right - 20, bottom: card.bottom - 20)
                let font = GetStockObject(DEFAULT_GUI_FONT)
                let previousFont = SelectObject(hdc, font)
                SetBkMode(hdc, TRANSPARENT)
                SetTextColor(hdc, WindowsTheme.colorref(hex: "#444444"))
                let wide = Array(L.t("transfer.tooBig.message").utf16) + [0]
                _ = wide.withUnsafeBufferPointer {
                    DrawTextW(hdc, $0.baseAddress, -1, &textRect, UINT(DT_CENTER) | UINT(DT_VCENTER) | UINT(DT_WORDBREAK) | UINT(DT_NOPREFIX))
                }
                SelectObject(hdc, previousFont)
            }
        }
        if let zone = zoneRect.map(offset) {
            strokeRoundRect(hdc, zone, penStyle: PS_DASH, penHex: darkMode ? Self.dashDarkHex : Self.dashLightHex, fillWhite: false)
            if let critter = critterRect.map(offset), critterFrames.indices.contains(critterFrame), let alphaBlend = Self.alphaBlendProc {
                let frame = critterFrames[critterFrame]
                let blend = BLENDFUNCTION(BlendOp: BYTE(AC_SRC_OVER), BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: BYTE(AC_SRC_ALPHA))
                _ = alphaBlend(hdc, critter.left, critter.top, frame.size.cx, frame.size.cy, frame.hdc, 0, 0, frame.size.cx, frame.size.cy, blend)
            }
        }
        if let card = previewRect.map(offset) {
            strokeRoundRect(hdc, card, penStyle: PS_SOLID, penHex: darkMode ? Self.borderDarkHex : Self.borderLightHex, fillWhite: false)
        }
    }

    // The thin line over the pinned bottom bar.
    private func paintMain() {
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        guard barTop < client.bottom, let pen = CreatePen(PS_SOLID, 1, WindowsTheme.colorref(hex: darkMode ? Self.separatorDarkHex : Self.separatorLightHex)) else { return }
        let previous = SelectObject(hdc, HGDIOBJ(OpaquePointer(pen)))
        MoveToEx(hdc, 0, barTop, nil)
        LineTo(hdc, client.right, barTop)
        SelectObject(hdc, previous)
        DeleteObject(HGDIOBJ(OpaquePointer(pen)))
    }

    // -- mode ---------------------------------------------------------------

    private func setMode(_ newMode: Mode) {
        mode = newMode
        // Send re-reads the settings and log each time it's shown, so an
        // import (or a Settings change) since the window opened is in its code.
        if newMode == .send {
            snapshotSettings = settingsStore.get()
            snapshotSessions = sessionLogger.allSessionsSync()
            refreshSend()
        }
        SendMessageW(sendRadio, UINT(BM_SETCHECK), WPARAM(newMode == .send ? BST_CHECKED : BST_UNCHECKED), 0)
        SendMessageW(receiveRadio, UINT(BM_SETCHECK), WPARAM(newMode == .receive ? BST_CHECKED : BST_UNCHECKED), 0)
        scrollY = 0
        layout()
        InvalidateRect(hwnd, nil, true)
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

        sendData = nil
        sendCode = nil
        sendTooBig = false
        disposeQR()
        setText(weightLabel, "")
        setText(sendMessageLabel, "")

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
        layout()
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
        setText(copyButton, "✓ " + L.t("transfer.copied"))
        SetTimer(hwnd, Self.copiedTimerID, 2000, nil)
    }

    private func saveImage() {
        guard let code = sendCode,
              let path = promptPath(save: true, defaultName: "Pomoppi Transfer.png", filters: [("PNG (.png)", "*.png")], defExt: "png")
        else { return }
        writeSaved(TransferPNG.encode(code, scale: 8), to: path)
    }

    // The file holds the text code (UTF-8), not the raw bytes; reading a
    // .pomoppi still accepts both.
    private func saveFile() {
        guard let data = sendData else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "transfer-\(formatter.string(from: Date())).\(TransferCodec.fileExtension)"
        guard let path = promptPath(save: true, defaultName: name, filters: [("Pomoppi (.\(TransferCodec.fileExtension))", "*.\(TransferCodec.fileExtension)")], defExt: TransferCodec.fileExtension)
        else { return }
        writeSaved(Data(TransferCodec.textCode(data).utf8), to: path)
    }

    private func writeSaved(_ data: Data, to path: String) {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            setText(sendMessageLabel, L.t("diary.export.failed"))
            layout()
        }
    }

    // GetSaveFileNameW / GetOpenFileNameW with one filter pair, the same
    // OPENFILENAMEW shape as SettingsWindow's Diary export prompts. Returns
    // the path with the default extension appended if the user typed none.
    private func promptPath(save: Bool, defaultName: String, filters: [(label: String, pattern: String)], defExt: String) -> String? {
        var pathBuffer = [UInt16](repeating: 0, count: 1024)
        for (index, unit) in Array(defaultName.utf16).enumerated() where save {
            pathBuffer[index] = unit
        }
        let filter = Array((filters.map { "\($0.label)\0\($0.pattern)\0" }.joined() + "\0").utf16)
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
        layout()
        InvalidateRect(receiveMessageLabel, nil, true)
    }

    private func fail(_ key: String) {
        showReceiveMessage(L.t(key) + "\n" + L.t("transfer.error.nothingChanged"), isError: true)
    }

    // Picking any source starts clean: no old error, no old preview.
    private func beginReceive() {
        preview = nil
        showReceiveMessage("", isError: false)
    }

    // One button for both: a QR image goes to the image reader, anything
    // else (a .pomoppi file) is read as a code.
    private func openFile() {
        let supported = (Self.imageExtensions.sorted() + [TransferCodec.fileExtension]).map { "*.\($0)" }.joined(separator: ";")
        let filters = [("Images, Pomoppi (.\(TransferCodec.fileExtension))", supported), ("All files", "*.*")]
        guard let path = promptPath(save: false, defaultName: "", filters: filters, defExt: TransferCodec.fileExtension) else { return }
        if Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) {
            receiveImage(at: path)
        } else {
            receiveFile(at: path)
        }
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
        // Plain text, no spinner: the read blocks this thread, so it has to
        // be on screen before the decode starts.
        showReceiveMessage(L.t("transfer.reading"), isError: false)
        RedrawWindow(hwnd, nil, nil, UINT(RDW_INVALIDATE) | UINT(RDW_ALLCHILDREN) | UINT(RDW_UPDATENOW))
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
        preview = Preview(payload: payload, newPomodoros: newPomodoros, differingSettings: differing)
        updateImportEnabled()
        showReceiveMessage("", isError: false)
    }

    private func updateImportEnabled() {
        guard let preview else { return }
        let settings = preview.payload.settings != nil && isChecked(applySettingsBox)
        let log = preview.payload.sessions != nil && preview.newPomodoros > 0 && isChecked(applyLogBox)
        setEnabled(importButton, settings || log)
    }

    private func cancelPreview() {
        preview = nil
        layout()
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
        showReceiveMessage(lines.map { "✓ " + $0 }.joined(separator: "\n"), isError: false)
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
            if UINT_PTR(wParam) == Self.critterTimerID {
                critterFrame = (critterFrame + 1) % max(1, critterFrames.count)
                if var rect = critterRect.map(offset) { InvalidateRect(viewport, &rect, true) }
            } else if UINT_PTR(wParam) == Self.copiedTimerID {
                KillTimer(hwnd, Self.copiedTimerID)
                setText(copyButton, L.t("transfer.copyCode"))
            }
            return 0
        case WM_GETMINMAXINFO:
            // Sent during CreateWindowExW too, before `current` is set; the
            // proc's guard sends that one to DefWindowProcW, which is fine.
            guard let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: UInt(bitPattern: Int(lParam))) else {
                return DefWindowProcW(hwnd, message, wParam, lParam)
            }
            var minRect = RECT(left: 0, top: 0, right: Self.minClientWidth, bottom: Self.minClientHeight)
            AdjustWindowRectEx(&minRect, Self.windowStyle, false, 0)
            info.pointee.ptMinTrackSize = POINT(x: minRect.right - minRect.left, y: minRect.bottom - minRect.top)
            return 0
        case WM_SIZE:
            layout()
            InvalidateRect(hwnd, nil, true)
            return 0
        case WM_MOUSEWHEEL:
            handleMouseWheel(wParam: wParam)
            return 0
        case WM_PAINT:
            paintMain()
            return 0
        case WM_ERASEBKGND:
            return handleEraseBackground(wParam: wParam)
        case WM_NOTIFY:
            if darkMode, let result = WindowsTheme.disabledButtonCustomDraw(lParam: lParam) { return result }
            return 0
        case WM_CTLCOLORSTATIC, WM_CTLCOLORBTN, WM_CTLCOLOREDIT:
            return handleCtlColor(message: message, wParam: wParam, lParam: lParam)
        case WM_CLOSE:
            close()
            return 0
        case WM_DESTROY:
            KillTimer(hwnd, Self.copiedTimerID)
            KillTimer(hwnd, Self.critterTimerID)
            disposeCritter()
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
