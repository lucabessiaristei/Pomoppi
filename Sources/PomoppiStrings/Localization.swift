// Localization.swift — the runtime side of the string catalog
// (LOCALIZATION_PLAN.md). Foundation only: the shell passes the OS language
// in, so nothing here has a platform seam.
//
//   L.t("general.reset.button")
//   L.t("updates.downloading", received, total)   // "{0} of {1}"
//
// A key missing from the current language renders English; a key missing
// from English too renders the key itself, so a typo shows up on screen
// instead of as an empty control.
import Foundation

public enum L {
    public static let sourceLanguage = "en"

    // Every language the catalog carries, English first.
    public static var languageIDs: [String] { GeneratedStrings.languageIDs }

    // The language strings resolve against right now.
    public private(set) static var current = sourceLanguage

    private static var systemLanguage = sourceLanguage

    // `preferred` is the OS's ordered list (macOS `Locale.preferredLanguages`,
    // Windows `GetUserDefaultLocaleName`): BCP 47 tags like "it-IT" or
    // "zh-Hans-CN". The first one whose primary subtag the catalog carries
    // wins; none means English.
    public static func configure(systemLanguages preferred: [String]) {
        systemLanguage = preferred.lazy.compactMap(match).first ?? sourceLanguage
    }

    // `setting` is PomoppiSettings.language: "system" or a language id.
    public static func apply(setting: String) {
        current = languageIDs.contains(setting) ? setting : systemLanguage
    }

    // The language the "System" choice resolves to, for labelling it.
    public static var resolvedSystemLanguage: String { systemLanguage }

    // A language's name in its own language ("Italiano"), for the picker.
    public static func displayName(of id: String) -> String {
        GeneratedStrings.tables[id]?["language.name"] ?? id
    }

    public static func t(_ key: String) -> String {
        GeneratedStrings.tables[current]?[key]
            ?? GeneratedStrings.tables[sourceLanguage]?[key]
            ?? key
    }

    // For names that come from data rather than code (backgrounds, frame
    // styles, chimes): an id added by `node refresh-art` / `refresh-sounds`
    // shows `fallback` until the catalog gets a key for it.
    public static func t(_ key: String, fallback: String) -> String {
        GeneratedStrings.tables[current]?[key]
            ?? GeneratedStrings.tables[sourceLanguage]?[key]
            ?? fallback
    }

    // {0}, {1}, ... replaced positionally, so a translation can reorder them.
    public static func t(_ key: String, _ args: CustomStringConvertible...) -> String {
        var result = t(key)
        for (index, arg) in args.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: arg.description)
        }
        return result
    }

    static func match(_ tag: String) -> String? {
        let primary = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return languageIDs.contains(primary) ? primary : nil
    }
}
