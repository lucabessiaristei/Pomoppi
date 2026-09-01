import Carbon.HIToolbox
import Foundation

// System-wide hotkeys, ported from main.js's registerGlobalShortcuts()/
// globalShortcut usage — Electron's globalShortcut is itself a thin wrapper
// over exactly this Carbon API (RegisterEventHotKey/InstallEventHandler),
// which remains the only way to claim an exclusive, system-wide key combo
// on macOS without extra entitlements or Accessibility permission.
//
// One process-wide event handler dispatches to per-action closures via each
// hotkey's numeric id (Carbon hotkeys don't carry a name, just an
// EventHotKeyID), looked up through `userData` rather than a capture —
// InstallEventHandler's callback must be a context-free C function pointer.
public final class GlobalShortcutManager {
    public static let shared = GlobalShortcutManager()

    private var refs: [String: EventHotKeyRef] = [:]
    private var idsByAction: [String: UInt32] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        installEventHandler()
    }

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handlers[hotKeyID.id]?()
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &eventHandlerRef)
    }

    // Registers `accelerator` (already-normalized "Alt+Shift+P" syntax, see
    // PomoppiCore.Shortcuts.normalize) to call `handler` when pressed.
    // Returns false if the OS refused the combo — already claimed by
    // another app, or an accelerator this parser doesn't recognize.
    @discardableResult
    public func register(id: String, accelerator: String, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard let (keyCode, modifiers) = Self.parse(accelerator) else { return false }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextHotKeyID)
        let thisHotKeyID = nextHotKeyID
        nextHotKeyID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }

        refs[id] = ref
        idsByAction[id] = thisHotKeyID
        handlers[thisHotKeyID] = handler
        return true
    }

    public func unregister(id: String) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        if let hotKeyID = idsByAction.removeValue(forKey: id) {
            handlers.removeValue(forKey: hotKeyID)
        }
    }

    public func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    // -- accelerator string -> (keyCode, modifierMask) -----------------------

    // 4-char signature identifying our hotkeys among any other app's, packed
    // the way OSType historically encodes a FourCharCode.
    private static let signature: OSType = {
        var result: UInt32 = 0
        for byte in "PMPI".utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }()

    // US ANSI virtual keycodes (Carbon's kVK_* constants) for every key
    // Shortcuts.canonicalKey can produce.
    private static let keyCodes: [String: UInt32] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07,
        "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10,
        "T": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "O": 0x1F, "U": 0x20,
        "[": 0x21, "I": 0x22, "P": 0x23, "L": 0x25, "J": 0x26, "'": 0x27, "K": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "N": 0x2D, "M": 0x2E, ".": 0x2F, "`": 0x32,
        "Space": 0x31, "Return": 0x24, "Enter": 0x24, "Tab": 0x30, "Backspace": 0x33,
        "Escape": 0x35, "Delete": 0x75, "Home": 0x73, "End": 0x77, "PageUp": 0x74, "PageDown": 0x79,
        "Left": 0x7B, "Right": 0x7C, "Down": 0x7D, "Up": 0x7E,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61, "F7": 0x62,
        "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
    ]

    static func parse(_ accelerator: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var parts = accelerator.split(separator: "+").map(String.init)
        guard let keyPart = parts.popLast(), let keyCode = keyCodes[keyPart] else { return nil }

        var modifiers: UInt32 = 0
        for part in parts {
            switch part {
            case "Command", "CommandOrControl": modifiers |= UInt32(cmdKey)
            case "Control": modifiers |= UInt32(controlKey)
            case "Alt": modifiers |= UInt32(optionKey)
            case "Shift": modifiers |= UInt32(shiftKey)
            default: break
            }
        }
        guard modifiers != 0 else { return nil }
        return (keyCode, modifiers)
    }
}
