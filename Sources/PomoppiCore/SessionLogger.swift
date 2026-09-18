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
}

// The whole file's shape: one growing array, not one file per day — chosen
// deliberately over the old daily-note-per-day model. Simple to read/query/
// back up; re-reading and rewriting the whole array on every append is
// accepted as a someday problem if session history ever grows large enough
// for it to matter, not solved for now.
private struct SessionLogFile: Codable {
    var sessions: [SessionLogEntry]
}

public actor SessionLogger {
    private let getSettings: () -> PomoppiSettings
    // nonisolated: fileSizeBytes() below reads this off-actor. Immutable
    // after init, so sharing it across isolation domains is safe.
    private nonisolated let fileURL: URL

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

        let calendar = Calendar.current
        let comps = calendar.dateComponents([.day, .month, .year], from: event.startedAt)
        let minutes = max(0, Int(((event.completed ? event.plannedMs : event.actualMs) / 60000).rounded()))
        let entry = SessionLogEntry(
            phase: event.phase.rawValue, task: event.task,
            day: comps.day ?? 0, month: comps.month ?? 0, year: comps.year ?? 0,
            startTime: event.startedAt, endTime: event.endedAt,
            durationMinutes: minutes, completed: event.completed)

        var file = readFile() ?? SessionLogFile(sessions: [])
        file.sessions.append(entry)
        return writeFile(file)
    }

    // The settings window's "Erase cached sessions" button (with its own
    // confirmation dialog — this actor doesn't confirm anything, it just
    // does what it's told).
    @discardableResult
    public func eraseAll() async -> Bool {
        writeFile(SessionLogFile(sessions: []))
    }

    // The settings window's "current cache weight" display. Deliberately
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
    // fileSizeBytes() above is nonisolated — Windows' Log tab button needs
    // a same-thread answer with no async hop (see that method's comment).
    // Bypasses the actor's own write-serialization guarantee, an accepted
    // simplification: this is a rare, user-initiated action a MessageBoxW
    // confirmation already precedes (blocking the message loop for as
    // long as the user is deciding), so racing it against the timer's own
    // async append is vanishingly unlikely, and low-stakes either way —
    // worst case is one session's entry surviving an erase that just
    // missed it, not corruption.
    public nonisolated func eraseAllSync() {
        try? "{\"sessions\":[]}".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readFile() -> SessionLogFile? {
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
