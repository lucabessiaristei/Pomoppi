// TransferCodec+Settings.swift — the settings block of the transfer payload
// (SPEC.md §16). Everything is stored as a difference from
// PomoppiSettings.defaults, in protobuf-style fields (key = field number << 3
// | wire type; 0 varint, 1 three fixed bytes, 2 length-delimited) so a newer
// sender's unknown fields are skipped, not fatal. The field numbers, bool
// bit positions and registries below are PERMANENT and add-only: never
// renumber, reorder or reuse one.
import Foundation

extension TransferCodec {
    // Machine-local, never transferred: diaryFolderPath, launchAtLogin,
    // startHidden, alwaysOnTop.

    // Bool bit positions in field 5 (bit set = differs from the default).
    static let boolFields: [WritableKeyPath<PomoppiSettings, Bool>] = [
        \.autoStartBreaks, \.autoStartFocus, \.loggingEnabled, \.raiseOnEnd,
        \.reverseTrayClick, \.checkForUpdates, \.soundEnabled, \.askForTaskName,
    ]

    // Frozen registries (copies of today's ids; the live lists can reorder).
    static let friendRegistry = ["namidappi", "onanippi", "gemuppin", "jankuppin", "utsupon"]
    static let frameRegistry = ["ziggy", "scallopy", "splotchy", "wavey"]
    static let backgroundRegistry = ["grid", "luna", "tatami"]
    static let chimeRegistry = ["classic", "chord", "jingle", "soft"]
    static let languageRegistry = ["en", "de", "es", "fr", "it"]   // "system" is the default, never sent
    static let colorSchemeRegistry = ["auto", "light", "dark"]
    static let actionRegistry = ["toggleWidget", "startPause", "skip", "reset", "toggleOnTop", "openSettings"]

    // Enum fields: index at `field` (varint), unknown id as a string at
    // `field + 1` (length-delimited).
    static let enumFields: [(field: UInt64, registry: [String], path: WritableKeyPath<PomoppiSettings, String>)] = [
        (6, friendRegistry, \.friend),
        (8, frameRegistry, \.frameStyle),
        (10, backgroundRegistry, \.background),
        (12, chimeRegistry, \.chime),
        (14, languageRegistry, \.language),
        (16, colorSchemeRegistry, \.colorScheme),
    ]

    // Shortcut modifier bits; 32 = a raw accelerator string follows instead.
    static let modifierBits = ["Command", "CommandOrControl", "Control", "Alt", "Shift"]
    static let rawShortcutBit: UInt64 = 32

    // Key table, index + 1 is the reference (0 = string follows).
    static let keyRegistry: [String] = {
        var keys = (65...90).map { String(UnicodeScalar($0)!) }           // A-Z
        keys += (0...9).map(String.init)                                   // 0-9
        keys += ["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
                 "~", "_", "+", "{", "}", "|", ":", "\"", "<", ">", "?"]
        keys += ["Space", "Tab", "Backspace", "Delete", "Insert", "Return", "Enter",
                 "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
                 "Escape", "Plus", "PrintScreen"]
        keys += (1...24).map { "F\($0)" }
        keys += ["numdec", "numadd", "numsub", "nummult", "numdiv"]
        keys += (0...9).map { "num\($0)" }
        return keys
    }()

    // MARK: Normalization (wire precision)

    static func whole(_ x: Double) throws -> UInt64 {
        guard x.isFinite, x >= 0, x < 1e15 else { throw TransferError.selfCheckFailed }
        return UInt64(x.rounded())
    }

    static func unsigned(_ x: Int) throws -> UInt64 {
        guard x >= 0 else { throw TransferError.selfCheckFailed }
        return UInt64(x)
    }

    // What the receiver gets back: minutes at whole seconds, opacity at whole
    // percent, ringSeconds at tenths; machine-local fields at their defaults.
    static func normalizedForTransfer(_ s: PomoppiSettings) throws -> PomoppiSettings {
        var out = s
        let d = PomoppiSettings.defaults
        out.focusMinutes = Double(try whole(s.focusMinutes * 60)) / 60
        out.shortBreakMinutes = Double(try whole(s.shortBreakMinutes * 60)) / 60
        out.longBreakMinutes = Double(try whole(s.longBreakMinutes * 60)) / 60
        out.opacity = Double(try whole(s.opacity * 100)) / 100
        out.ringSeconds = Double(try whole(s.ringSeconds * 10)) / 10
        out.diaryFolderPath = d.diaryFolderPath
        out.launchAtLogin = d.launchAtLogin
        out.startHidden = d.startHidden
        out.alwaysOnTop = d.alwaysOnTop
        return out
    }

    // MARK: Apply / preview

    // The sent settings with this machine's four machine-local ones kept,
    // through the same validation Settings uses on load.
    public static func applying(_ sent: PomoppiSettings, to local: PomoppiSettings) -> PomoppiSettings {
        var out = sent
        out.diaryFolderPath = local.diaryFolderPath
        out.launchAtLogin = local.launchAtLogin
        out.startHidden = local.startHidden
        out.alwaysOnTop = local.alwaysOnTop
        return out.clamped()
    }

    // How many transferable settings applying `sent` would change (each
    // shortcut counts as one).
    public static func differingSettingsCount(_ sent: PomoppiSettings, _ local: PomoppiSettings) -> Int {
        let a = applying(sent, to: local)
        let b = local
        var n = 0
        for (x, y) in [
            (a.focusMinutes, b.focusMinutes), (a.shortBreakMinutes, b.shortBreakMinutes),
            (a.longBreakMinutes, b.longBreakMinutes), (a.opacity, b.opacity), (a.ringSeconds, b.ringSeconds),
        ] where x != y { n += 1 }
        if a.longBreakEvery != b.longBreakEvery { n += 1 }
        if a.scale != b.scale { n += 1 }
        for path in boolFields where a[keyPath: path] != b[keyPath: path] { n += 1 }
        for e in enumFields where a[keyPath: e.path] != b[keyPath: e.path] { n += 1 }
        if a.inkColor != b.inkColor { n += 1 }
        if a.paperColor != b.paperColor { n += 1 }
        for id in Set(a.shortcuts.keys).union(b.shortcuts.keys) where a.shortcuts[id] != b.shortcuts[id] { n += 1 }
        return n
    }

    // MARK: Encode

    static func encodeSettings(_ s: PomoppiSettings) throws -> [UInt8] {
        let d = PomoppiSettings.defaults
        var w = ByteWriter()

        func put(_ field: UInt64, _ value: UInt64, _ def: UInt64) {
            guard value != def else { return }
            w.key(field, 0)
            w.varint(value)
        }
        put(1, try whole(s.focusMinutes * 60), try whole(d.focusMinutes * 60))
        put(2, try whole(s.shortBreakMinutes * 60), try whole(d.shortBreakMinutes * 60))
        put(3, try whole(s.longBreakMinutes * 60), try whole(d.longBreakMinutes * 60))
        put(4, try unsigned(s.longBreakEvery), try unsigned(d.longBreakEvery))

        var mask: UInt64 = 0
        for (bit, path) in boolFields.enumerated() where s[keyPath: path] != d[keyPath: path] {
            mask |= 1 << UInt64(bit)
        }
        put(5, mask, 0)

        for e in enumFields where s[keyPath: e.path] != d[keyPath: e.path] {
            let value = s[keyPath: e.path]
            if let index = e.registry.firstIndex(of: value) {
                w.key(e.field, 0)
                w.varint(UInt64(index))
            } else {
                w.key(e.field + 1, 2)
                w.string(value)
            }
        }

        func putColor(_ field: UInt64, _ hex: String, _ def: String) throws {
            guard hex != def else { return }
            w.key(field, 1)
            w.bytes(try rgb(hex))
        }
        try putColor(18, s.inkColor, d.inkColor)
        try putColor(19, s.paperColor, d.paperColor)

        put(20, try unsigned(s.scale), try unsigned(d.scale))
        put(21, try whole(s.opacity * 100), try whole(d.opacity * 100))
        put(22, try whole(s.ringSeconds * 10), try whole(d.ringSeconds * 10))

        let shortcutIDs = s.shortcuts.keys.filter { s.shortcuts[$0] != Shortcuts.defaults[$0] }
        if !shortcutIDs.isEmpty {
            let ordered = shortcutIDs.sorted { a, b in
                let ia = actionRegistry.firstIndex(of: a) ?? Int.max
                let ib = actionRegistry.firstIndex(of: b) ?? Int.max
                return ia != ib ? ia < ib : a < b
            }
            var sw = ByteWriter()
            for id in ordered { encodeShortcut(id: id, accelerator: s.shortcuts[id] ?? "", into: &sw) }
            w.key(23, 2)
            w.varint(UInt64(sw.out.count))
            w.bytes(sw.out)
        }
        return w.out
    }

    private static func rgb(_ hex: String) throws -> [UInt8] {
        let chars = Array(hex.utf8)
        guard chars.count == 7, chars[0] == UInt8(ascii: "#"), hex == hex.uppercased(),
              let v = UInt32(hex.dropFirst(), radix: 16) else { throw TransferError.selfCheckFailed }
        return [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    // action ref (0 = string follows, else index + 1), modifier mask (0 =
    // unbound; bit 5 = raw accelerator string follows), key ref.
    private static func encodeShortcut(id: String, accelerator: String, into w: inout ByteWriter) {
        if let i = actionRegistry.firstIndex(of: id) {
            w.varint(UInt64(i + 1))
        } else {
            w.varint(0)
            w.string(id)
        }
        guard !accelerator.isEmpty else {
            w.varint(0)
            return
        }
        let parts = accelerator.components(separatedBy: "+")
        let key = parts.last ?? ""
        let mods = parts.dropLast()
        var mask: UInt64 = 0
        for (bit, name) in modifierBits.enumerated() where mods.contains(name) { mask |= 1 << UInt64(bit) }
        let rebuilt = (modifierBits.filter { mods.contains($0) } + [key]).joined(separator: "+")
        guard mask != 0, rebuilt == accelerator, mods.count == mask.nonzeroBitCount else {
            w.varint(rawShortcutBit)
            w.string(accelerator)
            return
        }
        w.varint(mask)
        if let k = keyRegistry.firstIndex(of: key) {
            w.varint(UInt64(k + 1))
        } else {
            w.varint(0)
            w.string(key)
        }
    }

    // MARK: Decode

    static func decodeSettings(_ block: [UInt8]) throws -> PomoppiSettings {
        var s = PomoppiSettings.defaults
        var r = ByteReader(block)
        while !r.atEnd {
            let key = try r.varint()
            let field = key >> 3
            let wire = key & 7
            func expect(_ w: UInt64) throws { guard wire == w else { throw TransferError.malformed } }

            switch field {
            case 1, 2, 3, 4, 5, 20, 21, 22:
                try expect(0)
                let v = try r.varint()
                switch field {
                case 1: s.focusMinutes = Double(v) / 60
                case 2: s.shortBreakMinutes = Double(v) / 60
                case 3: s.longBreakMinutes = Double(v) / 60
                case 4: s.longBreakEvery = Int(clamping: v)
                case 5:
                    for (bit, path) in boolFields.enumerated() where v & (1 << UInt64(bit)) != 0 {
                        s[keyPath: path].toggle()
                    }
                case 20: s.scale = Int(clamping: v)
                case 21: s.opacity = Double(v) / 100
                default: s.ringSeconds = Double(v) / 10
                }
            case 18, 19:
                try expect(1)
                let b = try r.take(3)
                let hex = String(format: "#%02X%02X%02X", b[0], b[1], b[2])
                if field == 18 { s.inkColor = hex } else { s.paperColor = hex }
            case 23:
                try expect(2)
                try decodeShortcuts(try r.block(), into: &s)
            default:
                if let e = enumFields.first(where: { $0.field == field || $0.field + 1 == field }) {
                    if field == e.field {
                        try expect(0)
                        // An index this version's registry doesn't have yet is ignored.
                        let i = try r.varint()
                        if i < UInt64(e.registry.count) { s[keyPath: e.path] = e.registry[Int(i)] }
                    } else {
                        try expect(2)
                        s[keyPath: e.path] = try r.string()
                    }
                } else {
                    // Unknown field from a newer sender: skip by wire type.
                    switch wire {
                    case 0: _ = try r.varint()
                    case 1: _ = try r.take(3)
                    case 2: _ = try r.block()
                    default: throw TransferError.malformed
                    }
                }
            }
        }
        return s
    }

    private static func decodeShortcuts(_ block: [UInt8], into s: inout PomoppiSettings) throws {
        var r = ByteReader(block)
        while !r.atEnd {
            let ref = try r.varint()
            let id: String
            if ref == 0 {
                id = try r.string()
            } else if ref <= UInt64(actionRegistry.count) {
                id = actionRegistry[Int(ref) - 1]
            } else {
                throw TransferError.malformed
            }
            let mask = try r.varint()
            if mask == 0 {
                s.shortcuts[id] = ""
            } else if mask & rawShortcutBit != 0 {
                s.shortcuts[id] = try r.string()
            } else {
                guard mask < 1 << UInt64(modifierBits.count) else { throw TransferError.malformed }
                let mods = modifierBits.enumerated().filter { mask & (1 << UInt64($0.offset)) != 0 }.map(\.element)
                let k = try r.varint()
                let key: String
                if k == 0 {
                    key = try r.string()
                } else if k <= UInt64(keyRegistry.count) {
                    key = keyRegistry[Int(k) - 1]
                } else {
                    throw TransferError.malformed
                }
                s.shortcuts[id] = (mods + [key]).joined(separator: "+")
            }
        }
    }
}
