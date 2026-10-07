// FeedbackSystem.swift — the Windows-only facts the Feedback section needs:
// the version line's OS/architecture text and whether an email app is
// registered for mailto:. The text builders live in PomoppiCore/Feedback.swift.
import Foundation
import PomoppiCore
import WinSDK

enum FeedbackSystem {
    static func versionLine() -> FeedbackVersionLine {
        FeedbackVersionLine(version: pomoppiVersion, system: systemName(), architecture: architectureName())
    }

    // "Windows 11 24H2". RtlGetVersion rather than GetVersionEx, which
    // reports a fake version to an app without a compatibility manifest.
    // Build 22000+ is Windows 11 (its major version still reads 10).
    private static func systemName() -> String {
        typealias RtlGetVersionProc = @convention(c) (UnsafeMutablePointer<OSVERSIONINFOW>) -> Int32
        var name = "Windows"
        let ntdll: [UInt16] = Array("ntdll.dll".utf16) + [0]
        if let module = ntdll.withUnsafeBufferPointer({ LoadLibraryW($0.baseAddress) }),
           let proc = GetProcAddress(module, "RtlGetVersion") {
            var info = OSVERSIONINFOW()
            info.dwOSVersionInfoSize = DWORD(MemoryLayout<OSVERSIONINFOW>.size)
            if unsafeBitCast(proc, to: RtlGetVersionProc.self)(&info) == 0 {
                name = info.dwBuildNumber >= 22000 ? "Windows 11" : "Windows 10"
            }
        }
        if let display = registryString(subKey: "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", value: "DisplayVersion"), !display.isEmpty {
            name += " " + display
        }
        return name
    }

    private static func registryString(subKey: String, value: String) -> String? {
        var size: DWORD = 0
        let wideKey = Array(subKey.utf16) + [0]
        let wideValue = Array(value.utf16) + [0]
        let flags = DWORD(RRF_RT_REG_SZ)
        guard RegGetValueW(HKEY_LOCAL_MACHINE, wideKey, wideValue, flags, nil, nil, &size) == ERROR_SUCCESS, size > 0 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
        guard RegGetValueW(HKEY_LOCAL_MACHINE, wideKey, wideValue, flags, nil, &buffer, &size) == ERROR_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }

    // The machine's own CPU from IsWow64Process2's nativeMachine, plus the
    // architecture this build runs as (compile time). An x64 process
    // emulated on ARM64 reports processMachine UNKNOWN, so that output
    // isn't used.
    private static func architectureName() -> String {
        var process: USHORT = 0
        var native: USHORT = 0
        let native64 = IsWow64Process2(GetCurrentProcess(), &process, &native)
        let machine: String
        switch native {
        case 0xAA64: machine = "ARM64"
        case 0x8664: machine = "x64"
        case 0x014C: machine = "x86"
        default: machine = ""
        }
        #if arch(arm64)
        let running = "ARM64"
        #elseif arch(x86_64)
        let running = "x64"
        #else
        let running = "x86"
        #endif
        guard native64, !machine.isEmpty else { return running }
        return machine == running ? machine : "\(machine), running as \(running)"
    }

    // True when mailto: has a real handler. AssocQueryStringW with
    // ASSOCF_IS_PROTOCOL fails (0x80070483) when nothing is registered;
    // Windows 11 can also answer with its "pick an app" shim (OpenWith.exe /
    // OpenAs_RunDLL / the Store), which opens a dead-end dialog, so those
    // count as none. shlwapi isn't in the default link set, hence the
    // LoadLibraryW dance (same as SetWindowTheme in SettingsWindow).
    static func hasMailHandler() -> Bool {
        typealias AssocQueryStringProc = @convention(c) (DWORD, Int32, LPCWSTR?, LPCWSTR?, LPWSTR?, UnsafeMutablePointer<DWORD>) -> HRESULT
        let module: [UInt16] = Array("shlwapi.dll".utf16) + [0]
        guard let lib = module.withUnsafeBufferPointer({ LoadLibraryW($0.baseAddress) }),
              let proc = GetProcAddress(lib, "AssocQueryStringW") else { return true }
        let query = unsafeBitCast(proc, to: AssocQueryStringProc.self)
        let scheme = Array("mailto".utf16) + [0]
        let verb = Array("open".utf16) + [0]
        var buffer = [UInt16](repeating: 0, count: 2048)
        var count = DWORD(buffer.count)
        // ASSOCF_IS_PROTOCOL = 0x1000, ASSOCSTR_COMMAND = 1
        let hr = query(0x1000, 1, scheme, verb, &buffer, &count)
        guard hr >= 0 else { return false }
        let command = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self).lowercased()
        if command.isEmpty { return false }
        for shim in ["openwith.exe", "openas_rundll", "ms-windows-store", "wsreset"] where command.contains(shim) {
            return false
        }
        return true
    }
}
