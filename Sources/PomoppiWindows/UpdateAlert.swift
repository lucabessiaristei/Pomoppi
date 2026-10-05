// UpdateAlert.swift — the launch-time "update available" alert (SPEC.md §15),
// the Windows counterpart to the NSAlert AppDelegate.offerLaunchUpdate shows.
// TaskDialogIndirect rather than MessageBoxW because the buttons carry their
// own labels (Update / Later, or Open release page / Later), which
// MessageBoxW can't do; needs the Common Controls v6 manifest, which
// Pomoppi.exe.manifest already declares. Blocks the message loop until
// dismissed, same as every MessageBoxW in this port.
import WinSDK

enum UpdateAlert {
    enum Choice {
        case primary
        case secondary
    }

    private static let primaryID: Int32 = 1001
    private static let secondaryID: Int32 = 1002

    static func run(title: String, message: String?, primary: String, secondary: String) -> Choice {
        func wide(_ s: String) -> UnsafeMutablePointer<UInt16> {
            let units = Array(s.utf16) + [0]
            let p = UnsafeMutablePointer<UInt16>.allocate(capacity: units.count)
            p.initialize(from: units, count: units.count)
            return p
        }
        let windowTitle = wide("Pomoppi")
        let mainInstruction = wide(title)
        let content = message.map(wide)
        let primaryText = wide(primary)
        let secondaryText = wide(secondary)
        defer {
            for p in [windowTitle, mainInstruction, primaryText, secondaryText] { p.deallocate() }
            content?.deallocate()
        }

        var buttons = [
            TASKDIALOG_BUTTON(nButtonID: primaryID, pszButtonText: UnsafePointer(primaryText)),
            TASKDIALOG_BUTTON(nButtonID: secondaryID, pszButtonText: UnsafePointer(secondaryText)),
        ]
        var selected: Int32 = 0
        let result: HRESULT = buttons.withUnsafeMutableBufferPointer { buttonsPtr in
            var config = TASKDIALOGCONFIG()
            config.cbSize = UINT(MemoryLayout<TASKDIALOGCONFIG>.size)
            // Esc / the title-bar close map to IDCANCEL, i.e. "Later".
            config.dwFlags = TASKDIALOG_FLAGS(TDF_ALLOW_DIALOG_CANCELLATION.rawValue)
            config.pszWindowTitle = UnsafePointer(windowTitle)
            // MAKEINTRESOURCEW(TD_INFORMATION_ICON), which Swift doesn't import.
            config.pszMainIcon = UnsafePointer(bitPattern: 0xFFFD)
            config.pszMainInstruction = UnsafePointer(mainInstruction)
            config.pszContent = content.map { UnsafePointer($0) }
            config.cButtons = UINT(buttonsPtr.count)
            config.pButtons = UnsafePointer(buttonsPtr.baseAddress)
            config.nDefaultButton = primaryID
            return TaskDialogIndirect(&config, &selected, nil, nil)
        }
        return result == S_OK && selected == primaryID ? .primary : .secondary
    }
}
