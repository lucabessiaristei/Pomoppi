// WindowsTheme.swift — "is Pomoppi's own chrome dark right now", plus the
// two hex constants that answer feeds into a paint. Extracted out of
// SettingsWindow.swift so TaskPromptDialog.swift can use the same
// detection and colors instead of a light-mode-only popup out of a
// dark-themed app. Both files are Windows-side, so this needs no
// Mac-side equivalent and doesn't violate the no-shared-abstraction
// invariant (CLAUDE.md) — it's one file sharing with another file on the
// same platform, not a cross-platform extraction.
import WinSDK

enum WindowsTheme {
    // Every classic 3D system color (COLOR_BTNFACE, COLOR_BTNSHADOW, ...)
    // does NOT shift with the OS light/dark setting for a plain,
    // non-manifested Win32 window — confirmed live — so this pair of
    // hardcoded overrides is what every dark-aware owner-drawn surface
    // actually needs.
    static let darkBackgroundHex = "#202020"
    static let darkTextHex = "#F0F0F0"

    // colorScheme is PomoppiSettings.colorScheme ("auto"/"light"/"dark") —
    // callers pass settingsStore.get().colorScheme rather than this type
    // depending on PomoppiCore itself. "auto" defers to
    // systemPrefersDarkTheme() below; "light"/"dark" override it outright,
    // regardless of what the OS is doing.
    static func resolveDarkMode(colorScheme: String) -> Bool {
        switch colorScheme {
        case "light": return false
        case "dark": return true
        default: return systemPrefersDarkTheme()
        }
    }

    // Same registry key TrayController.systemPrefersLightTaskbar() reads,
    // but a different value in it: AppsUseLightTheme governs app chrome
    // (settings window, task prompt), SystemUsesLightTheme governs the
    // taskbar/tray — TrayController already owns that one for its own
    // tray-icon tinting. Defaults to light (not dark) if the key/value is
    // missing, the same "clamp rather than fail" stance that one takes on a
    // missing value.
    static func systemPrefersDarkTheme() -> Bool {
        var value: DWORD = 0
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".withCString(encodedAs: UTF16.self) { subKey in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { valueName in
                RegGetValueW(HKEY_CURRENT_USER, subKey, valueName, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        guard status == ERROR_SUCCESS else { return false }
        return value == 0
    }

    // hex "#RRGGBB" -> COLORREF, this file's own copy of SettingsWindow's
    // private colorref(hex:)/rgbComponents(hex:) pair, just for the two
    // constants above — SettingsWindow keeps its own for its many other
    // hex colors (theme swatches, the scroll rail, ...), unrelated to dark
    // mode.
    static func colorref(hex: String) -> COLORREF {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return COLORREF(0) }
        let r = DWORD((value >> 16) & 0xFF)
        let g = DWORD((value >> 8) & 0xFF)
        let b = DWORD(value & 0xFF)
        return COLORREF(r | (g << 8) | (b << 16))
    }

    // Reused for both a WM_ERASEBKGND page fill and a WM_CTLCOLORSTATIC/
    // WM_CTLCOLORBTN/WM_CTLCOLOREDIT returned brush (same color either way)
    // — created once and kept for the process's lifetime rather than the
    // usual create-then-delete pattern for a paint-local GDI object, since a
    // brush handed back from a CTLCOLOR handler has to stay valid for
    // Windows to actually paint with it after that call returns. Shared
    // across every dark-aware window in the process — a brush is a GDI
    // object, not window-owned state, so SettingsWindow and TaskPromptDialog
    // painting with the same handle is fine.
    static let darkBackgroundBrush: HBRUSH? = CreateSolidBrush(colorref(hex: darkBackgroundHex))

    // A "DarkMode_Explorer" push button keeps its light text when disabled,
    // so it looks enabled. Both windows' WM_NOTIFY handlers pass an
    // NM_CUSTOMDRAW from a button here: a disabled one gets its text color
    // set to a dim gray before the themed draw (CDRF_NEWFONT); anything else
    // returns nil and falls through to the caller's own handling.
    static let disabledButtonTextHex = "#6A6A6A"

    static func disabledButtonCustomDraw(lParam: LPARAM) -> LRESULT? {
        guard let draw = UnsafeMutablePointer<NMCUSTOMDRAW>(bitPattern: UInt(bitPattern: Int(lParam))),
              draw.pointee.hdr.code == UINT(NM_CUSTOMDRAW),
              draw.pointee.dwDrawStage == DWORD(CDDS_PREPAINT),
              !IsWindowEnabled(draw.pointee.hdr.hwndFrom),
              let hdc = draw.pointee.hdc else { return nil }
        var className = [UInt16](repeating: 0, count: 8)
        GetClassNameW(draw.pointee.hdr.hwndFrom, &className, Int32(className.count))
        guard String(decoding: className.prefix { $0 != 0 }, as: UTF16.self) == "Button" else { return nil }
        SetTextColor(hdc, colorref(hex: disabledButtonTextHex))
        return LRESULT(CDRF_NEWFONT)
    }
}
