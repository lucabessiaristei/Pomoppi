// Settings.swift — port of lib/settings.js (SPEC.md §7): load/validate/persist
// settings.json. Reads and writes the SAME file the Electron app uses
// (~/Library/Application Support/Pomoppi/settings.json), so an existing
// user's choices carry over. Named `PomoppiSettings`, not `Settings`, to
// avoid colliding with SwiftUI's `Settings` scene once the settings window
// exists.
//
// Unlike lib/settings.js's `validate(raw)` (a free function over a loosely
// typed object), clamping here happens in two places that share the same
// logic: `init(from:)` (loading raw JSON off disk) and `clamped()` (re-run
// after any in-memory mutation) — both funnel through `clampInPlace()`.
import Foundation

public struct PomoppiSettings: Codable, Equatable {
    public var focusMinutes: Double
    public var shortBreakMinutes: Double
    public var longBreakMinutes: Double
    public var longBreakEvery: Int
    public var autoStartBreaks: Bool
    public var autoStartFocus: Bool

    // Session history (SPEC.md §8, redesigned 2026-09-19): every completed
    // or aborted phase is appended to a single local JSON file
    // (`SessionLogger`, next to settings.json) whenever this is on — no
    // vault/folder/heading to configure anymore, and no per-phase-kind
    // toggle (logBreaks/logAborted are gone; the log is meant to be a
    // complete internal record, with filtering left to whatever reads it
    // later — see project-obsidian-logging-redesign).
    public var loggingEnabled: Bool

    // The Diary tab (SPEC.md §8b): reads sessions.json and either bundles
    // it into a `.zip` (Export) or syncs it into `diaryFolderPath` (a
    // plain folder — Pomoppi doesn't need to know it's "an Obsidian
    // vault", just somewhere to drop date-named .md files). No cursor
    // field anymore (2026-09-20 redesign) — sync is idempotent on each
    // day file's own content, so there's nothing left to track here.
    public var diaryFolderPath: String

    public var friend: String
    public var frameStyle: String
    public var background: String
    public var inkColor: String
    public var paperColor: String

    // The settings window's own chrome (SPEC.md §7): "auto" follows the OS
    // light/dark setting (today's behavior, still the default), "light"/
    // "dark" force it. Governs the settings window only — the widget's
    // ink/paper theme is a separate, manual choice, and the tray icon tint
    // is untouched either way.
    public var colorScheme: String
    public var alwaysOnTop: Bool
    public var raiseOnEnd: Bool
    public var reverseTrayClick: Bool
    public var scale: Int
    public var opacity: Double
    public var launchAtLogin: Bool
    public var startHidden: Bool

    public var soundEnabled: Bool
    public var ringSeconds: Double
    public var askForTaskName: Bool

    public var shortcuts: [String: String]

    // Mirrors renderer/friends.js's FRIEND_ART keys, renderer/sprites.js's
    // FRAME_STYLES, and renderer/background.js's BACKGROUND_IDS. Kept as
    // plain constants here (not sourced from PomoppiSprites) so this file has
    // no dependency on generated art data — only Phase 1's default friend
    // (namidappi) and background (scacchi) actually have Swift sprite data
    // yet, but settings validation shouldn't silently reset a choice just
    // because that asset hasn't been ported to Swift as art — the renderer
    // is the one that falls back for missing art, not settings validation.
    public static let friendIDs = ["namidappi", "onanippi", "gemuppin", "jankuppin", "utsupon"]
    public static let frameStyles = ["ziggy", "scallopy", "splotchy", "wavey"]
    public static let backgroundIDs = ["grid", "luna"]
    public static let chimeIDs = ["classic"]
    public static let colorSchemeIDs = ["auto", "light", "dark"]

    public static let defaults = PomoppiSettings(
        focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakEvery: 4,
        autoStartBreaks: true, autoStartFocus: false,
        // No vault to configure anymore, so there's nothing to misconfigure —
        // unlike the old Obsidian-only default (false, "a fresh install has
        // no vault configured yet"), this is safe to default on.
        loggingEnabled: true,
        friend: friendIDs[0], frameStyle: "scallopy", background: backgroundIDs[0],
        // "LCD Green" theme preset (SettingsView.swift/SettingsWindow.swift's
        // themePresets) — the default on a fresh install on both platforms.
        inkColor: "#276231", paperColor: "#80B391",
        alwaysOnTop: true, raiseOnEnd: true, scale: 2, opacity: 1.0,
        launchAtLogin: false, startHidden: false,
        soundEnabled: true, ringSeconds: 10, askForTaskName: true,
        shortcuts: Shortcuts.defaults, reverseTrayClick: false)

    public init(
        focusMinutes: Double, shortBreakMinutes: Double, longBreakMinutes: Double, longBreakEvery: Int,
        autoStartBreaks: Bool, autoStartFocus: Bool,
        loggingEnabled: Bool,
        friend: String, frameStyle: String, background: String,
        inkColor: String, paperColor: String,
        alwaysOnTop: Bool, raiseOnEnd: Bool, scale: Int, opacity: Double,
        launchAtLogin: Bool, startHidden: Bool,
        soundEnabled: Bool, ringSeconds: Double, askForTaskName: Bool,
        shortcuts: [String: String], reverseTrayClick: Bool = false,
        diaryFolderPath: String = "",
        colorScheme: String = "auto"
    ) {
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.longBreakEvery = longBreakEvery
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
        self.loggingEnabled = loggingEnabled
        self.diaryFolderPath = diaryFolderPath
        self.friend = friend
        self.frameStyle = frameStyle
        self.background = background
        self.inkColor = inkColor
        self.paperColor = paperColor
        self.colorScheme = colorScheme
        self.alwaysOnTop = alwaysOnTop
        self.raiseOnEnd = raiseOnEnd
        self.reverseTrayClick = reverseTrayClick
        self.scale = scale
        self.opacity = opacity
        self.launchAtLogin = launchAtLogin
        self.startHidden = startHidden
        self.soundEnabled = soundEnabled
        self.ringSeconds = ringSeconds
        self.askForTaskName = askForTaskName
        self.shortcuts = shortcuts
        clampInPlace()
    }

    enum CodingKeys: String, CodingKey {
        case focusMinutes, shortBreakMinutes, longBreakMinutes, longBreakEvery
        case autoStartBreaks, autoStartFocus
        case loggingEnabled, diaryFolderPath
        case friend, frameStyle, background, inkColor, paperColor, colorScheme
        case alwaysOnTop, raiseOnEnd, reverseTrayClick, scale, opacity, launchAtLogin, startHidden
        case soundEnabled, ringSeconds, askForTaskName, shortcuts
    }

    // A separate keyed container for the legacy `mascot` key (SPEC.md §7):
    // kept out of CodingKeys above so that enum maps 1:1 to stored properties
    // and Encodable synthesis (encode(to:)) still works alongside the custom
    // Decodable init(from:) below.
    private enum LegacyCodingKeys: String, CodingKey {
        case mascot
    }

    // Drops unknown keys (Codable does this for free), fills in missing ones
    // from defaults, clamps out-of-range values rather than rejecting them.
    // `try?` around every field collapses "key missing" and "key present but
    // the wrong type" to the same outcome: fall back to the default, never
    // throw the whole decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomoppiSettings.defaults

        focusMinutes = (try? c.decodeIfPresent(Double.self, forKey: .focusMinutes)) ?? d.focusMinutes
        shortBreakMinutes = (try? c.decodeIfPresent(Double.self, forKey: .shortBreakMinutes)) ?? d.shortBreakMinutes
        longBreakMinutes = (try? c.decodeIfPresent(Double.self, forKey: .longBreakMinutes)) ?? d.longBreakMinutes
        longBreakEvery = (try? c.decodeIfPresent(Int.self, forKey: .longBreakEvery)) ?? d.longBreakEvery
        autoStartBreaks = (try? c.decodeIfPresent(Bool.self, forKey: .autoStartBreaks)) ?? d.autoStartBreaks
        autoStartFocus = (try? c.decodeIfPresent(Bool.self, forKey: .autoStartFocus)) ?? d.autoStartFocus

        loggingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .loggingEnabled)) ?? d.loggingEnabled
        diaryFolderPath = (try? c.decodeIfPresent(String.self, forKey: .diaryFolderPath)) ?? d.diaryFolderPath

        // `friend` was called `mascot` until the rename; read the old key only
        // if the new one is absent, same as lib/settings.js. (`try?` on an
        // already-Optional-returning expression flattens rather than
        // double-wrapping, so this is a plain String?.)
        if let decodedFriend = try? c.decodeIfPresent(String.self, forKey: .friend) {
            friend = decodedFriend
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  let legacyFriend = try? legacy.decodeIfPresent(String.self, forKey: .mascot) {
            friend = legacyFriend
        } else {
            friend = d.friend
        }
        frameStyle = (try? c.decodeIfPresent(String.self, forKey: .frameStyle)) ?? d.frameStyle
        background = (try? c.decodeIfPresent(String.self, forKey: .background)) ?? d.background
        inkColor = (try? c.decodeIfPresent(String.self, forKey: .inkColor)) ?? d.inkColor
        paperColor = (try? c.decodeIfPresent(String.self, forKey: .paperColor)) ?? d.paperColor
        colorScheme = (try? c.decodeIfPresent(String.self, forKey: .colorScheme)) ?? d.colorScheme
        alwaysOnTop = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)) ?? d.alwaysOnTop
        raiseOnEnd = (try? c.decodeIfPresent(Bool.self, forKey: .raiseOnEnd)) ?? d.raiseOnEnd
        reverseTrayClick = (try? c.decodeIfPresent(Bool.self, forKey: .reverseTrayClick)) ?? d.reverseTrayClick
        scale = (try? c.decodeIfPresent(Int.self, forKey: .scale)) ?? d.scale
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? d.opacity
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        startHidden = (try? c.decodeIfPresent(Bool.self, forKey: .startHidden)) ?? d.startHidden

        soundEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .soundEnabled)) ?? d.soundEnabled
        ringSeconds = (try? c.decodeIfPresent(Double.self, forKey: .ringSeconds)) ?? d.ringSeconds
        askForTaskName = (try? c.decodeIfPresent(Bool.self, forKey: .askForTaskName)) ?? d.askForTaskName

        let decodedShortcuts = (try? c.decodeIfPresent([String: String].self, forKey: .shortcuts)) ?? nil
        var shortcuts = Shortcuts.defaults
        for (key, value) in decodedShortcuts ?? [:] { shortcuts[key] = value }
        self.shortcuts = shortcuts

        clampInPlace()
    }

    // Re-run after any in-memory mutation, mirroring lib/settings.js's set()
    // calling validate(merged) on every write.
    public func clamped() -> PomoppiSettings {
        var copy = self
        copy.clampInPlace()
        return copy
    }

    private mutating func clampInPlace() {
        focusMinutes = Self.clamp(focusMinutes, 1, 180)
        shortBreakMinutes = Self.clamp(shortBreakMinutes, 1, 180)
        longBreakMinutes = Self.clamp(longBreakMinutes, 1, 180)
        longBreakEvery = Int(Self.clamp(Double(longBreakEvery), 2, 10).rounded())
        ringSeconds = Self.clamp(ringSeconds, 0, 60)
        opacity = Self.clamp(opacity, 0.3, 1.0)

        scale = [1, 2, 3, 4].contains(scale) ? scale : PomoppiSettings.defaults.scale
        friend = PomoppiSettings.friendIDs.contains(friend) ? friend : PomoppiSettings.defaults.friend
        frameStyle = PomoppiSettings.frameStyles.contains(frameStyle) ? frameStyle : PomoppiSettings.defaults.frameStyle
        background = PomoppiSettings.backgroundIDs.contains(background) ? background : PomoppiSettings.defaults.background
        colorScheme = PomoppiSettings.colorSchemeIDs.contains(colorScheme) ? colorScheme : PomoppiSettings.defaults.colorScheme

        inkColor = Self.normalizeColor(inkColor) ?? PomoppiSettings.defaults.inkColor
        paperColor = Self.normalizeColor(paperColor) ?? PomoppiSettings.defaults.paperColor
        // Two identical colours would render an entirely blank widget.
        if inkColor == paperColor {
            inkColor = PomoppiSettings.defaults.inkColor
            paperColor = PomoppiSettings.defaults.paperColor
        }

        // Normalizes every binding and clears whichever loses a conflict —
        // same re-validate-on-every-write contract as everything else here.
        shortcuts = Shortcuts.validate(shortcuts)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        Swift.min(upper, Swift.max(lower, value))
    }

    // Accepts '#rgb' and '#rrggbb', with or without the '#', in either case,
    // and normalises to upper-case '#RRGGBB'.
    private static func normalizeColor(_ raw: String) -> String? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 3 {
            return "#" + hex.map { "\($0)\($0)" }.joined().uppercased()
        }
        if hex.count == 6 {
            return "#" + hex.uppercased()
        }
        return nil
    }
}

// Load/validate/persist settings.json, mirroring lib/settings.js's Settings
// class. Takes the storage directory as an argument (rather than reaching
// into FileManager.applicationSupport itself) so tests can point it at a
// temp dir.
public final class SettingsStore {
    public private(set) var current: PomoppiSettings
    private let filePath: URL
    private let storageDir: URL

    // Fires after every persisted change, regardless of who made it (the
    // widget's own direct interactions, or a settings window). Most
    // settings only affect what gets drawn, and whatever renders the widget
    // already re-reads `get()` every frame — this callback exists only for
    // the few window-level properties (opacity, scale-driven size,
    // always-on-top) that something owns applying once rather than
    // continuously, and needs to know when to re-apply them. A single
    // closure, not a list of observers: only one thing (the widget window)
    // needs this today.
    public var onChange: ((PomoppiSettings) -> Void)?

    public init(storageDir: URL) {
        self.storageDir = storageDir
        self.filePath = storageDir.appendingPathComponent("settings.json")
        self.current = PomoppiSettings.defaults
        self.current = load()
    }

    public func get() -> PomoppiSettings { current }

    // Type-safe alternative to lib/settings.js's `set(patch)`: callers mutate
    // whichever fields they own (e.g. the widget's focus-minutes stepper),
    // then the whole struct is re-clamped and persisted — same "always
    // re-validate on write" contract as the JS version's shallow merge.
    @discardableResult
    public func update(_ mutate: (inout PomoppiSettings) -> Void) -> PomoppiSettings {
        var next = current
        mutate(&next)
        current = next.clamped()
        persist()
        onChange?(current)
        return current
    }

    @discardableResult
    public func reset() -> PomoppiSettings {
        current = PomoppiSettings.defaults
        persist()
        onChange?(current)
        return current
    }

    private func load() -> PomoppiSettings {
        guard let data = try? Data(contentsOf: filePath) else {
            let defaults = PomoppiSettings.defaults
            persistData(defaults)
            return defaults
        }
        guard let decoded = try? JSONDecoder().decode(PomoppiSettings.self, from: data) else {
            // Corrupt file: preserve it for inspection and start fresh.
            try? FileManager.default.removeItem(at: filePath.appendingPathExtension("bak"))
            try? FileManager.default.moveItem(at: filePath, to: filePath.appendingPathExtension("bak"))
            let defaults = PomoppiSettings.defaults
            persistData(defaults)
            return defaults
        }
        persistData(decoded)
        return decoded
    }

    private func persist() {
        persistData(current)
    }

    private func persistData(_ settings: PomoppiSettings) {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            let tmp = filePath.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: filePath.path) {
                #if os(Windows)
                try FileManager.default.removeItem(at: filePath)
                try FileManager.default.moveItem(at: tmp, to: filePath)
                #else
                _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmp)
                #endif
            } else {
                try FileManager.default.moveItem(at: tmp, to: filePath)
            }
        } catch {
            // Best effort — in-memory settings stay usable even if persisting fails.
        }
    }
}
