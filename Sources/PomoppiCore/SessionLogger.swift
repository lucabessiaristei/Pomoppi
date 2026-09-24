// SessionLogger.swift — replaces ObsidianLogger.swift (SPEC.md §8,
// redesigned 2026-09-19). Writes a single local JSON file recording every
// completed or aborted phase, on both platforms, with no vault/folder to
// configure — the previous design wrote directly to an Obsidian daily note;
// this one is the platform-agnostic internal record that a later "export to
// Obsidian/Apple Notes/OneNote/.md/.odt" feature (not built yet — see
// project-obsidian-logging-redesign) would read from instead of writing to
// a specific editor's format itself.
//
// An actor rather than a promise chain, same reasoning ObsidianLogger had:
// actors already serialize calls to their own methods one at a time, which
// is exactly the guarantee needed so two sessions completing close together
// can never interleave a read-modify-write of the same file.
import Foundation

// One entry per completed-or-aborted phase. day/month/year are stored
// alongside the full ISO8601 startTime/endTime (not derived from them by
// whatever reads this file later) because they were asked for explicitly,
// and because trivial day/month/year filtering shouldn't require every
// consumer to parse a timestamp first.
public struct SessionLogEntry: Codable, Equatable {
    public let phase: String
    public let task: String
    public let day: Int
    public let month: Int
    public let year: Int
    public let startTime: Date
    public let endTime: Date
    public let durationMinutes: Int
    public let completed: Bool
    // Added in 0.4.0 (log version 2, SPEC.md §8), absent from older entries.
    // Fields are only ever added, never renamed or removed, so a future
    // version can always read this one.
    public let durationSeconds: Int?   // the length that counted (planned if completed, else actual)
    public let plannedSeconds: Int?
    public let pausedSeconds: Int?     // paused inside the phase, not in durationSeconds
    public let pomodoroStart: Date?    // identifies the pomodoro
    public let focusNumber: Int?       // 1-based; a break carries the focus it follows
    public let focusCount: Int?        // focus sessions planned for the pomodoro then
    public let timeZone: String?       // what day/month/year were computed in
    public let appVersion: String?     // the Pomoppi that wrote the entry

    public init(
        phase: String, task: String, day: Int, month: Int, year: Int,
        startTime: Date, endTime: Date, durationMinutes: Int, completed: Bool,
        durationSeconds: Int? = nil, pomodoroStart: Date? = nil,
        plannedSeconds: Int? = nil, pausedSeconds: Int? = nil,
        focusNumber: Int? = nil, focusCount: Int? = nil,
        timeZone: String? = nil, appVersion: String? = nil
    ) {
        self.phase = phase
        self.task = task
        self.day = day
        self.month = month
        self.year = year
        self.startTime = startTime
        self.endTime = endTime
        self.durationMinutes = durationMinutes
        self.completed = completed
        self.durationSeconds = durationSeconds
        self.pomodoroStart = pomodoroStart
        self.plannedSeconds = plannedSeconds
        self.pausedSeconds = pausedSeconds
        self.focusNumber = focusNumber
        self.focusCount = focusCount
        self.timeZone = timeZone
        self.appVersion = appVersion
    }

    // Older entries only have whole minutes.
    public var seconds: Int { durationSeconds ?? durationMinutes * 60 }

    // A focus worth a line in the diary: completed, or stopped early after
    // at least a minute (SPEC.md §8b). A pomodoro with none is empty.
    public var isRealFocus: Bool {
        phase == "focus" && (completed || seconds >= 60)
    }
}

// ISO8601 in sessions.json keeps whole seconds only, so pomodoros are
// matched on that rather than on Date equality.
func pomodoroKey(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970.rounded(.down))
}

// The whole file's shape: one growing array, not one file per day — chosen
// deliberately over the old daily-note-per-day model. Simple to read/query/
// back up; re-reading and rewriting the whole array on every append is
// accepted as a someday problem if session history ever grows large enough
// for it to matter, not solved for now.
// `version` is absent from logs written before 0.4.0 and is 2 from then on.
// It gates the one-time cleanup in migrateLegacyLog(): once a file carries
// it, nothing in it is ever dropped automatically again.
private struct SessionLogFile: Codable {
    static let currentVersion = 2
    var version: Int?
    var sessions: [SessionLogEntry]

    static var empty: SessionLogFile { SessionLogFile(version: currentVersion, sessions: []) }
}

public actor SessionLogger {
    private let getSettings: () -> PomoppiSettings
    // nonisolated: fileSizeBytes() below reads this off-actor. Immutable
    // after init, so sharing it across isolation domains is safe.
    private nonisolated let fileURL: URL
    // Pomodoros reset() threw away this run: an append for one of them that
    // arrives after discardPomodoro (both are async) is dropped too.
    private var discarded: Set<Int64> = []

    public init(getSettings: @escaping () -> PomoppiSettings, storageDir: URL) {
        self.getSettings = getSettings
        self.fileURL = storageDir.appendingPathComponent("sessions.json")
    }

    // Every completed-or-aborted phase gets logged unconditionally when
    // loggingEnabled is on — no logBreaks/logAborted-style filtering
    // anymore. This is meant to be a complete internal record; deciding
    // what to show is a job for whatever reads it later, not for the
    // logger itself.
    @discardableResult
    public func logSession(_ event: PhaseCompleteEvent) async -> Bool {
        guard getSettings().loggingEnabled else { return false }
        if let start = event.pomodoroStartedAt, discarded.contains(pomodoroKey(start)) { return false }

        let calendar = Calendar.current
        let comps = calendar.dateComponents([.day, .month, .year], from: event.startedAt)
        let lengthMs = event.completed ? event.plannedMs : event.actualMs
        let minutes = max(0, Int((lengthMs / 60000).rounded()))
        let entry = SessionLogEntry(
            phase: event.phase.rawValue, task: event.task,
            day: comps.day ?? 0, month: comps.month ?? 0, year: comps.year ?? 0,
            startTime: event.startedAt, endTime: event.endedAt,
            durationMinutes: minutes, completed: event.completed,
            durationSeconds: max(0, Int((lengthMs / 1000).rounded())),
            pomodoroStart: event.pomodoroStartedAt,
            plannedSeconds: max(0, Int((event.plannedMs / 1000).rounded())),
            pausedSeconds: max(0, Int((event.pausedMs / 1000).rounded())),
            focusNumber: event.focusNumber > 0 ? event.focusNumber : nil,
            focusCount: event.focusCount > 0 ? event.focusCount : nil,
            timeZone: calendar.timeZone.identifier,
            appVersion: pomoppiVersion)

        var file = readFile() ?? .empty
        file.sessions.append(entry)
        return writeFile(file)
    }

    // One-time cleanup for logs written before 0.4.0 (SPEC.md §8): their
    // entries have no pomodoroStart and can't be placed in a pomodoro, so
    // they're deleted, and the file is stamped with the current version.
    // Only a file with no version is ever touched: from 0.4.0 on this never
    // removes anything. Called at launch on both platforms. Returns how
    // many entries were removed.
    @discardableResult
    public func migrateLegacyLog() async -> Int {
        guard var file = readFile(), file.version == nil else { return 0 }
        let before = file.sessions.count
        file.sessions.removeAll { $0.pomodoroStart == nil }
        file.version = SessionLogFile.currentVersion
        return writeFile(file) ? before - file.sessions.count : 0
    }

    // Launch-time tidy-up (SPEC.md §8): removes every pomodoro that has no
    // real focus at all (each focus skipped under a minute), breaks
    // included. Only called at launch, when no pomodoro can be in progress.
    // The one automatic removal the versioned log allows. Returns how many
    // entries were removed.
    @discardableResult
    public func pruneEmptyPomodoros() async -> Int {
        guard var file = readFile() else { return 0 }
        var real: Set<Int64> = []
        for entry in file.sessions where entry.isRealFocus {
            if let start = entry.pomodoroStart { real.insert(pomodoroKey(start)) }
        }
        let before = file.sessions.count
        file.sessions.removeAll { entry in
            guard let start = entry.pomodoroStart else { return false }
            return !real.contains(pomodoroKey(start))
        }
        guard file.sessions.count != before else { return 0 }
        return writeFile(file) ? before - file.sessions.count : 0
    }

    // reset() threw this pomodoro away (SPEC.md §5, §8): remove its entries
    // and ignore any of its appends still in flight.
    @discardableResult
    public func discardPomodoro(startedAt: Date) async -> Bool {
        let key = pomodoroKey(startedAt)
        discarded.insert(key)
        guard var file = readFile() else { return true }
        let before = file.sessions.count
        file.sessions.removeAll { $0.pomodoroStart.map(pomodoroKey) == key }
        return file.sessions.count == before || writeFile(file)
    }

    // The settings window's "Erase History" button (with its own
    // confirmation dialog — this actor doesn't confirm anything, it just
    // does what it's told).
    @discardableResult
    public func eraseAll() async -> Bool {
        writeFile(.empty)
    }

    // The settings window's "History size" display. Deliberately
    // `nonisolated` and synchronous, not routed through the actor: it's a
    // plain read-only filesystem stat with no shared mutable state to
    // protect, and every UI caller on both platforms needs a same-thread,
    // no-async-hop answer — Windows' whole settings window is
    // synchronous/main-thread-only by design (see CLAUDE.md's
    // swiftLanguageMode(.v5) invariant), and routing this through an
    // actor risks the continuation resuming on a different thread than
    // the one that owns the Win32 controls being updated. Worst case on a
    // read racing an in-flight write: a byte count that's stale by one
    // session's worth of JSON, cosmetically irrelevant for a size display.
    public nonisolated func fileSizeBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return 0 }
        return (attributes[.size] as? Int64) ?? 0
    }

    // A plain, synchronous, non-actor-isolated erase for the same reason
    // fileSizeBytes() above is nonisolated — Windows' Diary tab Erase
    // button needs a same-thread answer with no async hop (see that
    // method's comment).
    // Bypasses the actor's own write-serialization guarantee, an accepted
    // simplification: this is a rare, user-initiated action a MessageBoxW
    // confirmation already precedes (blocking the message loop for as
    // long as the user is deciding), so racing it against the timer's own
    // async append is vanishingly unlikely, and low-stakes either way —
    // worst case is one session's entry surviving an erase that just
    // missed it, not corruption.
    public nonisolated func eraseAllSync() {
        try? "{\"sessions\":[],\"version\":\(SessionLogFile.currentVersion)}".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // The Diary tab's "Sessions recorded" count and the Export/Sync actions
    // themselves all just need a snapshot of what's there right now, then
    // go write somewhere else entirely (a user-chosen export file, or an
    // Obsidian day-note) — none of that needs to serialize against
    // `logSession`'s own writes to *this* file, only avoid reading a
    // half-written one, which an atomic write already guarantees (a
    // reader always sees either the old or the new content, never a torn
    // mix). `nonisolated`/synchronous for the same same-thread-on-Windows
    // reason as `fileSizeBytes()`/`eraseAllSync()` above.
    public nonisolated func allSessionsSync() -> [SessionLogEntry] {
        readFile()?.sessions ?? []
    }

    private nonisolated func readFile() -> SessionLogFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionLogFile.self, from: data)
    }

    // Same atomic tmp-then-rename dance as SettingsStore.persistData, and
    // the same Windows fallback ObsidianLogger already needed:
    // FileManager.replaceItemAt isn't implemented in swift-corelibs-
    // foundation on Windows.
    private func writeFile(_ file: SessionLogFile) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                #if os(Windows)
                try FileManager.default.removeItem(at: fileURL)
                try FileManager.default.moveItem(at: tmp, to: fileURL)
                #else
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
                #endif
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }
}
