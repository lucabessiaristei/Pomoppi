// GlobalShortcutManager.swift — Windows counterpart to
// PomoppiApp/GlobalShortcutManager.swift's Carbon-based registrar, using
// RegisterHotKey/WM_HOTKEY instead. Unlike Carbon hotkeys (process-wide, no
// owning window), Win32 hotkeys are tied to a specific HWND — this one is
// constructed with WidgetWindow's, and WM_HOTKEY is routed to
// handleHotKey(id:) from WidgetWindow.handleMessage's switch (see that
// file's wiring), same "own object, not a WidgetWindow extension" shape as
// TrayController.
import PomoppiCore
import WinSDK

final class GlobalShortcutManager {
    private let hwnd: HWND
    private var idsByAction: [String: Int32] = [:]
    private var handlers: [Int32: () -> Void] = [:]
    private var nextHotKeyID: Int32 = 1

    init(hwnd: HWND) {
        self.hwnd = hwnd
    }

    // Registers `accelerator` (already-normalized "Alt+Shift+P" syntax, see
    // PomoppiCore.Shortcuts.normalize) to call `handler` when pressed.
    // Returns false if the OS refused the combo — already claimed by
    // another app, or an accelerator this parser doesn't recognize — same
    // contract as macOS's GlobalShortcutManager.register: a failed
    // RegisterHotKey already means "leave this one unbound," no extra
    // collision pre-checking needed.
    @discardableResult
    func register(id: String, accelerator: String, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard let (vk, modifiers) = Self.parse(accelerator) else { return false }

        let hotKeyID = nextHotKeyID
        nextHotKeyID += 1

        guard RegisterHotKey(hwnd, hotKeyID, modifiers, vk) else { return false }

        idsByAction[id] = hotKeyID
        handlers[hotKeyID] = handler
        return true
    }

    func unregister(id: String) {
        guard let hotKeyID = idsByAction.removeValue(forKey: id) else { return }
        UnregisterHotKey(hwnd, hotKeyID)
        handlers.removeValue(forKey: hotKeyID)
    }

    func unregisterAll() {
        for id in Array(idsByAction.keys) { unregister(id: id) }
    }

    // Called from WidgetWindow.handleMessage's WM_HOTKEY case — wParam
    // carries the numeric id RegisterHotKey was called with.
    func handleHotKey(id: WPARAM) {
        handlers[Int32(truncatingIfNeeded: id)]?()
    }

    // -- accelerator string -> (vkCode, modifierMask) -------------------------

    // Virtual-key codes for every key Shortcuts.canonicalKey can produce.
    // Letters/digits use their raw ASCII value directly rather than named
    // VK_A...VK_Z/VK_0...VK_9 constants — those aren't guaranteed to be
    // defined as importable symbols in every SDK header, and the raw ASCII
    // value is numerically identical to the Virtual-Key code either way.
    private static let keyCodes: [String: UInt32] = {
        var out: [String: UInt32] = [:]
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            out[String(c)] = UInt32(c.asciiValue!)
        }
        out["`"] = UInt32(VK_OEM_3)
        out["~"] = UInt32(VK_OEM_3)
        out["-"] = UInt32(VK_OEM_MINUS)
        out["_"] = UInt32(VK_OEM_MINUS)
        out["="] = UInt32(VK_OEM_PLUS)
        out["+"] = UInt32(VK_OEM_PLUS)
        out["Plus"] = UInt32(VK_OEM_PLUS)
        out["["] = UInt32(VK_OEM_4)
        out["{"] = UInt32(VK_OEM_4)
        out["]"] = UInt32(VK_OEM_6)
        out["}"] = UInt32(VK_OEM_6)
        out["\\"] = UInt32(VK_OEM_5)
        out["|"] = UInt32(VK_OEM_5)
        out[";"] = UInt32(VK_OEM_1)
        out[":"] = UInt32(VK_OEM_1)
        out["'"] = UInt32(VK_OEM_7)
        out["\""] = UInt32(VK_OEM_7)
        out[","] = UInt32(VK_OEM_COMMA)
        out["<"] = UInt32(VK_OEM_COMMA)
        out["."] = UInt32(VK_OEM_PERIOD)
        out[">"] = UInt32(VK_OEM_PERIOD)
        out["/"] = UInt32(VK_OEM_2)
        out["?"] = UInt32(VK_OEM_2)

        out["Space"] = UInt32(VK_SPACE)
        out["Return"] = UInt32(VK_RETURN)
        out["Enter"] = UInt32(VK_RETURN)
        out["Tab"] = UInt32(VK_TAB)
        out["Backspace"] = UInt32(VK_BACK)
        out["Delete"] = UInt32(VK_DELETE)
        out["Insert"] = UInt32(VK_INSERT)
        out["Escape"] = UInt32(VK_ESCAPE)
        out["Up"] = UInt32(VK_UP)
        out["Down"] = UInt32(VK_DOWN)
        out["Left"] = UInt32(VK_LEFT)
        out["Right"] = UInt32(VK_RIGHT)
        out["Home"] = UInt32(VK_HOME)
        out["End"] = UInt32(VK_END)
        out["PageUp"] = UInt32(VK_PRIOR)
        out["PageDown"] = UInt32(VK_NEXT)
        out["PrintScreen"] = UInt32(VK_SNAPSHOT)

        let fKeys: [Int32] = [
            VK_F1, VK_F2, VK_F3, VK_F4, VK_F5, VK_F6, VK_F7, VK_F8, VK_F9, VK_F10,
            VK_F11, VK_F12, VK_F13, VK_F14, VK_F15, VK_F16, VK_F17, VK_F18, VK_F19, VK_F20,
            VK_F21, VK_F22, VK_F23, VK_F24,
        ]
        for (i, vk) in fKeys.enumerated() { out["F\(i + 1)"] = UInt32(vk) }

        let numpadDigits: [Int32] = [
            VK_NUMPAD0, VK_NUMPAD1, VK_NUMPAD2, VK_NUMPAD3, VK_NUMPAD4,
            VK_NUMPAD5, VK_NUMPAD6, VK_NUMPAD7, VK_NUMPAD8, VK_NUMPAD9,
        ]
        for (i, vk) in numpadDigits.enumerated() { out["num\(i)"] = UInt32(vk) }
        out["numdec"] = UInt32(VK_DECIMAL)
        out["numadd"] = UInt32(VK_ADD)
        out["numsub"] = UInt32(VK_SUBTRACT)
        out["nummult"] = UInt32(VK_MULTIPLY)
        out["numdiv"] = UInt32(VK_DIVIDE)
        return out
    }()

    static func parse(_ accelerator: String) -> (vkCode: UInt32, modifiers: UINT)? {
        var parts = accelerator.split(separator: "+").map(String.init)
        guard let keyPart = parts.popLast(), let vk = keyCodes[keyPart] else { return nil }

        var modifiers: UINT = 0
        for part in parts {
            switch part {
            // No separate Command key on Windows — Command/CommandOrControl
            // both collapse onto MOD_CONTROL, same as plain Control. A real
            // collision source for a hypothetical custom binding that
            // distinguishes them, but Shortcuts.actions' defaults never use
            // Command/Control at all (only Alt+Shift), so this only matters
            // for hand-edited/future-custom bindings.
            case "Command", "CommandOrControl", "Control": modifiers |= UINT(MOD_CONTROL)
            case "Alt": modifiers |= UINT(MOD_ALT)
            case "Shift": modifiers |= UINT(MOD_SHIFT)
            default: break
            }
        }
        guard modifiers != 0 else { return nil }
        // MOD_NOREPEAT: prevents WM_HOTKEY from firing repeatedly while the
        // key is held. No macOS-side equivalent to mirror — Carbon hotkeys
        // don't repeat-fire in the first place — this is a Windows-specific
        // addition needed for equivalent behavior.
        return (vk, modifiers | UINT(MOD_NOREPEAT))
    }
}
