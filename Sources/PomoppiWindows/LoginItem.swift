import Foundation
import WinSDK

// "Open Pomoppi when I log in" (SPEC.md §7) — Windows counterpart to
// PomoppiApp/LoginItem.swift's SMAppService-based registrar. Windows has no
// equivalent framework, so this reimplements the same intent directly via
// the registry: HKCU\Software\Microsoft\Windows\CurrentVersion\Run, value
// name "Pomoppi", value data the current running executable's full path —
// the standard, no-COM way apps register themselves to start at login (a
// Startup-folder .lnk would need IShellLink instead, more machinery for the
// same result). Unlike macOS's SMAppService (only meaningful from an
// installed, bundle-identified .app), a raw .exe path is a perfectly valid,
// launchable registry value regardless of where it's run from — no
// unbundled-dev-binary no-op case needed here.
enum LoginItem {
    private static let subKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    private static let valueName = "Pomoppi"

    enum LoginItemError: Error {
        case registryOperationFailed(String, LSTATUS)
    }

    static func apply(enabled: Bool) -> Result<Void, Error> {
        var key: HKEY?
        let openStatus = subKey.withCString(encodedAs: UTF16.self) { subKeyPtr in
            RegOpenKeyExW(HKEY_CURRENT_USER, subKeyPtr, 0, DWORD(KEY_SET_VALUE), &key)
        }
        guard openStatus == ERROR_SUCCESS, let key else {
            return .failure(LoginItemError.registryOperationFailed("RegOpenKeyExW", openStatus))
        }
        defer { RegCloseKey(key) }

        if enabled {
            let exePath = currentExecutablePath()
            // +1 for the trailing NUL: RegSetValueExW's REG_SZ contract
            // wants it included in cbData, same as any other WCHAR string
            // buffer handed to a Win32 API by pointer + length.
            let wide: [WCHAR] = Array(exePath.utf16) + [0]
            let status = valueName.withCString(encodedAs: UTF16.self) { valueNamePtr in
                wide.withUnsafeBufferPointer { buf -> LSTATUS in
                    buf.baseAddress!.withMemoryRebound(to: BYTE.self, capacity: buf.count * 2) { bytes in
                        RegSetValueExW(key, valueNamePtr, 0, DWORD(REG_SZ), bytes, DWORD(buf.count * 2))
                    }
                }
            }
            guard status == ERROR_SUCCESS else {
                return .failure(LoginItemError.registryOperationFailed("RegSetValueExW", status))
            }
        } else {
            let status = valueName.withCString(encodedAs: UTF16.self) { valueNamePtr in
                RegDeleteValueW(key, valueNamePtr)
            }
            // Fine if the value doesn't already exist — not an error.
            guard status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND else {
                return .failure(LoginItemError.registryOperationFailed("RegDeleteValueW", status))
            }
        }
        return .success(())
    }

    private static func currentExecutablePath() -> String {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
    }
}
