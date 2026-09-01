// ObsidianLogger.swift — port of lib/obsidian.js (SPEC.md §8): appends
// pomodoro sessions to an Obsidian daily note. An actor rather than a
// promise chain: actors already serialize calls to their own methods one at
// a time, which is exactly the guarantee the JS version builds by hand with
// a chained Promise so two sessions can never interleave a write.
import Foundation

public struct ObsidianLogResult {
    public let ok: Bool
    public let path: String?
    public let error: String?
    public let skipped: Bool

    public init(ok: Bool, path: String? = nil, error: String? = nil, skipped: Bool = false) {
        self.ok = ok
        self.path = path
        self.error = error
        self.skipped = skipped
    }
}

public actor ObsidianLogger {
    private let getSettings: () -> PomoppiSettings

    public init(getSettings: @escaping () -> PomoppiSettings) {
        self.getSettings = getSettings
    }

    // Decides whether this phaseComplete event should be logged, then
    // appends it. Never throws.
    @discardableResult
    public func logSession(_ entry: PhaseCompleteEvent) async -> ObsidianLogResult {
        let settings = getSettings()
        guard settings.loggingEnabled else { return ObsidianLogResult(ok: true, skipped: true) }

        let isFocus = entry.phase == .focus
        let shouldLog = entry.completed ? (isFocus || settings.logBreaks) : settings.logAborted
        guard shouldLog else { return ObsidianLogResult(ok: true, skipped: true) }

        return await appendEntry(entry, settings: settings)
    }

    // A dry check: confirms the vault/folder is reachable and writable
    // without adding a log entry.
    public func test() async -> ObsidianLogResult {
        let settings = getSettings()
        let filePath = Self.dailyNotePath(vaultPath: settings.vaultPath, folder: settings.dailyNoteFolder, format: settings.dailyNoteFormat, date: Date())
        let dir = (filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: dir) else {
                return ObsidianLogResult(ok: false, error: "\(dir) is not writable")
            }
            return ObsidianLogResult(ok: true, path: filePath)
        } catch {
            return ObsidianLogResult(ok: false, error: error.localizedDescription)
        }
    }

    private func appendEntry(_ entry: PhaseCompleteEvent, settings: PomoppiSettings) async -> ObsidianLogResult {
        let date = entry.endedAt
        let filePath = Self.dailyNotePath(vaultPath: settings.vaultPath, folder: settings.dailyNoteFolder, format: settings.dailyNoteFormat, date: date)
        let dir = (filePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var content = ""
            if let data = FileManager.default.contents(atPath: filePath), let existing = String(data: data, encoding: .utf8) {
                content = existing
            }
            let nextContent = Self.insertEntry(content: content, entry: entry, heading: settings.logHeading)
            let tmpPath = filePath + ".tmp"
            try nextContent.write(toFile: tmpPath, atomically: false, encoding: .utf8)
            if FileManager.default.fileExists(atPath: filePath) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: filePath), withItemAt: URL(fileURLWithPath: tmpPath))
            } else {
                try FileManager.default.moveItem(atPath: tmpPath, toPath: filePath)
            }
            return ObsidianLogResult(ok: true, path: filePath)
        } catch {
            return ObsidianLogResult(ok: false, error: error.localizedDescription)
        }
    }

    // -- pure string transforms, ported from lib/obsidian.js -----------------

    static func dailyNotePath(vaultPath: String, folder: String, format: String, date: Date) -> String {
        let formatted = formatDate(date, format: format)
        var components = [vaultPath]
        if !folder.isEmpty { components.append(folder) }
        components.append(formatted + ".md")
        return components.joined(separator: "/")
    }

    private static func formatDate(_ date: Date, format: String) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", c.year ?? 0)
        let month = String(format: "%02d", c.month ?? 0)
        let day = String(format: "%02d", c.day ?? 0)
        return format
            .replacingOccurrences(of: "YYYY", with: year)
            .replacingOccurrences(of: "MM", with: month)
            .replacingOccurrences(of: "DD", with: day)
    }

    private static func pad2(_ n: Int) -> String { String(format: "%02d", n) }

    private static func formatClock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return "\(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
    }

    private static func minutesFrom(_ ms: Double) -> Int {
        max(0, Int((ms / 60000).rounded()))
    }

    static func buildEntryLine(_ entry: PhaseCompleteEvent) -> String {
        let isFocus = entry.phase == .focus
        let minutes = minutesFrom(entry.completed ? entry.plannedMs : entry.actualMs)
        let start = formatClock(entry.startedAt)
        let end = formatClock(entry.endedAt)
        let durationLabel = isFocus ? "\(minutes)m" : "\(minutes)m break"
        let taskPart = (isFocus && !entry.task.isEmpty) ? " — \(entry.task)" : ""
        let mark = !entry.completed ? "❌" : (isFocus ? "✅" : "")
        let markPart = mark.isEmpty ? "" : " \(mark)"
        return "- \(start)–\(end) (\(durationLabel))\(taskPart)\(markPart)"
    }

    private static func isSectionHeading(_ line: String) -> Bool {
        line.hasPrefix("## ")
    }

    private static func findSection(_ lines: [String], heading: String) -> (headingIndex: Int, endIndex: Int)? {
        guard let headingIndex = lines.firstIndex(of: heading) else { return nil }
        var endIndex = lines.count
        for i in (headingIndex + 1)..<lines.count {
            if isSectionHeading(lines[i]) { endIndex = i; break }
        }
        return (headingIndex, endIndex)
    }

    private static func buildTotalLine(_ lines: [String], start: Int, end: Int) -> String {
        var totalMinutes = 0
        var count = 0
        for i in start..<end {
            let line = lines[i]
            if line.hasPrefix("- "), line.hasSuffix("✅") {
                if let range = line.range(of: #"\((\d+)m\)"#, options: .regularExpression) {
                    let digits = String(line[range]).filter(\.isNumber)
                    totalMinutes += Int(digits) ?? 0
                }
                count += 1
            }
        }
        return "**Total focus: \(totalMinutes)m across \(count) pomodoros**"
    }

    // Pure string transform — split out so it's trivial to unit test.
    static func insertEntry(content: String, entry: PhaseCompleteEvent, heading: String) -> String {
        let hadTrailingNewline = content.isEmpty || content.hasSuffix("\n")
        var lines = content.isEmpty ? [] : content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if hadTrailingNewline, let last = lines.last, last.isEmpty { lines.removeLast() }

        var section = findSection(lines, heading: heading)
        if section == nil {
            if !lines.isEmpty { lines.append("") }
            lines.append(heading)
            section = (lines.count - 1, lines.count)
        }
        guard let (headingIndex, endIndex) = section else { return content }

        var lastDashIndex = -1
        var totalLineIndex = -1
        for i in (headingIndex + 1)..<endIndex {
            if lines[i].hasPrefix("- ") { lastDashIndex = i }
            else if lines[i].hasPrefix("**Total focus:") { totalLineIndex = i }
        }

        let newLine = buildEntryLine(entry)
        let insertAt = lastDashIndex != -1 ? lastDashIndex + 1 : (totalLineIndex != -1 ? totalLineIndex : endIndex)
        lines.insert(newLine, at: insertAt)

        let newEndIndex = endIndex + 1
        let newLastDashIndex = insertAt

        var newTotalLineIndex = -1
        for i in (headingIndex + 1)..<newEndIndex {
            if lines[i].hasPrefix("**Total focus:") { newTotalLineIndex = i; break }
        }

        let totalLine = buildTotalLine(lines, start: headingIndex + 1, end: newEndIndex)
        if newTotalLineIndex != -1 {
            lines[newTotalLineIndex] = totalLine
        } else {
            lines.insert(contentsOf: ["", totalLine], at: newLastDashIndex + 1)
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
