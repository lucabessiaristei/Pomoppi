// Shortcuts.swift — port of renderer/shortcuts.js: the global-shortcut
// action table, accelerator string normalization, and conflict validation.
// Pure string logic, no AppKit/Carbon — the actual OS-level hotkey
// registration lives in PomoppiApp, which turns a normalized string like
// "Alt+Shift+P" into a real key code + modifier mask.
import Foundation

public struct ShortcutAction {
    public let id: String
    public let label: String
    public let hint: String
    public let defaultAccelerator: String
}

public enum Shortcuts {
    // Display order doubles as tie-break order in validate() below:
    // whichever action comes first here keeps a contested accelerator.
    public static let actions: [ShortcutAction] = [
        ShortcutAction(id: "toggleWidget", label: "Show / hide the widget", hint: "Brings Pomoppi to the front, or tucks it away.", defaultAccelerator: "Alt+Shift+P"),
        ShortcutAction(id: "startPause", label: "Start / pause", hint: "Same as the widget's play button.", defaultAccelerator: "Alt+Shift+Space"),
        ShortcutAction(id: "skip", label: "Skip phase", hint: "Ends the current phase early. No-op while idle.", defaultAccelerator: "Alt+Shift+K"),
        ShortcutAction(id: "reset", label: "Reset phase", hint: "Puts the current phase back to full. No-op while idle.", defaultAccelerator: "Alt+Shift+R"),
        ShortcutAction(id: "toggleOnTop", label: "Keep on top", hint: "Toggles whether the widget floats above other windows.", defaultAccelerator: "Alt+Shift+T"),
        ShortcutAction(id: "snapshot", label: "Save SVG snapshot", hint: "Writes the widget exactly as drawn to the Desktop.", defaultAccelerator: "Alt+Shift+S"),
        ShortcutAction(id: "openSettings", label: "Open settings", hint: "", defaultAccelerator: "Alt+Shift+,"),
    ]

    public static let actionIDs: [String] = actions.map(\.id)

    private static let modifierAliases: [String: String] = [
        "command": "Command", "cmd": "Command", "super": "Command", "meta": "Command",
        "control": "Control", "ctrl": "Control",
        "alt": "Alt", "option": "Alt", "opt": "Alt",
        "shift": "Shift",
        "commandorcontrol": "CommandOrControl", "cmdorctrl": "CommandOrControl",
    ]

    private static let modifierOrder = ["Command", "CommandOrControl", "Control", "Alt", "Shift"]

    private static let punctuationKeys: Set<Character> = [
        "`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
        "~", "_", "+", "{", "}", "|", ":", "\"", "<", ">", "?",
    ]

    private static let namedKeyLookup: [String: String] = {
        var named = [
            "Space", "Tab", "Backspace", "Delete", "Insert", "Return", "Enter",
            "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
            "Escape", "Plus", "PrintScreen",
        ]
        for i in 1...24 { named.append("F\(i)") }
        named.append(contentsOf: ["numdec", "numadd", "numsub", "nummult", "numdiv"])
        for i in 0...9 { named.append("num\(i)") }
        var lookup: [String: String] = [:]
        for key in named { lookup[key.lowercased()] = key }
        return lookup
    }()

    private static func canonicalKey(_ key: String) -> String {
        if key.count == 1, let c = key.first, c.isASCII, (c.isLetter || c.isNumber) {
            return key.uppercased()
        }
        if key.count == 1, let c = key.first, punctuationKeys.contains(c) {
            return key
        }
        return namedKeyLookup[key.lowercased()] ?? ""
    }

    // Parses whatever a capture UI or an old settings.json hands in and
    // returns the canonical accelerator syntax, or "" if the input can't be
    // one. "" is a valid result, not an error — it means deliberately
    // unbound.
    public static func normalize(_ accel: String?) -> String {
        guard let accel else { return "" }
        let trimmed = accel.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }

        let body: String
        if trimmed.count > 1, trimmed.hasSuffix("+") {
            body = String(trimmed.dropLast()) + "Plus"
        } else {
            body = trimmed
        }

        var mods = Set<String>()
        var key = ""
        var extraKey = false
        for rawPart in body.split(separator: "+", omittingEmptySubsequences: false) {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            if let alias = modifierAliases[part.lowercased()] {
                mods.insert(alias)
            } else if key.isEmpty {
                key = part
            } else {
                extraKey = true
            }
        }
        guard !extraKey, !key.isEmpty, !mods.isEmpty else { return "" }

        let resolvedKey = canonicalKey(key)
        guard !resolvedKey.isEmpty else { return "" }

        let out = modifierOrder.filter { mods.contains($0) } + [resolvedKey]
        return out.joined(separator: "+")
    }

    public static let defaults: [String: String] = {
        var out: [String: String] = [:]
        for action in actions { out[action.id] = normalize(action.defaultAccelerator) }
        return out
    }()

    // Fills in every id, clamping rather than rejecting: an id missing from
    // raw falls back to its default, one present but unbindable stays
    // unbound, and unknown ids are dropped. Two actions can't share one
    // global accelerator — walks actionIDs in table order so the earlier
    // action keeps a contested combo.
    public static func validate(_ raw: [String: String]) -> [String: String] {
        var out = defaults
        for id in actionIDs {
            if let value = raw[id] {
                out[id] = normalize(value)
            }
        }

        var claimed = Set<String>()
        for id in actionIDs {
            guard let accel = out[id], !accel.isEmpty else { continue }
            if claimed.contains(accel) {
                out[id] = ""
            } else {
                claimed.insert(accel)
            }
        }
        return out
    }

    private static let modifierGlyphs: [String: String] = [
        "Control": "⌃", "Alt": "⌥", "Shift": "⇧", "Command": "⌘", "CommandOrControl": "⌘",
    ]
    private static let keyGlyphs: [String: String] = [
        "Space": "Space", "Return": "↩", "Enter": "↩", "Escape": "⎋",
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→",
    ]

    // Human string for macOS, e.g. "Alt+Shift+P" -> "⌥⇧P". Purely cosmetic.
    public static func display(_ accel: String) -> String {
        guard !accel.isEmpty else { return "Not set" }
        let parts = accel.split(separator: "+").map(String.init)
        guard let key = parts.last else { return "Not set" }
        let mods = Set(parts.dropLast())

        var out = ""
        for m in ["Control", "Alt", "Shift", "Command", "CommandOrControl"] {
            if mods.contains(m) { out += modifierGlyphs[m] ?? "" }
        }
        return out + (keyGlyphs[key] ?? key)
    }
}
