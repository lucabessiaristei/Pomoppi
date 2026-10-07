// TransferCodec+Log.swift — the log block of the transfer payload (SPEC.md
// §16): consecutive entries of one pomodoro are grouped, string-ish values go
// through tables, and everything SessionLogger derives when it writes an
// entry (day/month/year, minutes, end time, focus number, ...) is predicted
// instead of stored. Where an entry breaks a prediction an exceptions
// bitmask says which values follow explicitly, so the round trip is
// lossless for any entry, including absent optionals.
import Foundation

extension TransferCodec {
    // Planned seconds a phase starts out "same as last" against.
    static let initialPlanned: [Int] = [1500, 300, 900, 0]
    static let phaseNames = ["focus", "shortBreak", "longBreak"]

    // Exception bits (permanent, add-only), payloads follow in bit order.
    enum Exc {
        static let date = 0            // year, month, day (3 ints)
        static let minutes = 1         // durationMinutes (int)
        static let durationSecondsNil = 2
        static let length = 3          // completed entry whose length isn't its planned: seconds (int)
        static let plannedNil = 4
        static let pausedFlip = 5      // pausedSeconds present/absent differs from the pomodoro's
        static let end = 6             // endTime minus predicted end (int)
        static let focusNumber = 7     // optional code
        static let task = 8            // title ref
        static let friend = 9          // friend ref
        static let timeZone = 10       // tz ref
        static let appVersion = 11     // app version ref
        static let focusCount = 12     // optional code
        static let count = 13
    }

    // MARK: Shared prediction helpers

    final class CalendarCache {
        private var cache: [String: Calendar] = [:]

        func ymd(_ seconds: Int64, _ timeZone: String?) -> (year: Int, month: Int, day: Int) {
            let key = timeZone ?? ""
            let cal: Calendar
            if let cached = cache[key] {
                cal = cached
            } else {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)!
                cache[key] = c
                cal = c
            }
            let comps = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(seconds)))
            return (comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        }
    }

    static func predictedMinutes(_ seconds: Int) -> Int {
        max(0, Int((Double(seconds) / 60).rounded()))
    }

    static func predictedFocusNumber(previous: Int?, phase: String) -> Int {
        max(1, (previous ?? 0) + (phase == "focus" ? 1 : 0))
    }

    // Magnitudes well inside what the varints and Date arithmetic can carry.
    static func small(_ v: Int64) -> Bool { v > -(1 << 40) && v < 1 << 40 }

    static func optCode(_ v: Int?) throws -> UInt64 {
        guard let v else { return 0 }
        guard small(Int64(v)) else { throw TransferError.selfCheckFailed }
        return UInt64(bitPattern: Int64(v << 1) ^ Int64(v >> 63)) + 1
    }

    static func optValue(_ code: UInt64) -> Int? {
        guard code != 0 else { return nil }
        let v = code - 1
        return Int(Int64(bitPattern: v >> 1 ^ (0 &- (v & 1))))
    }

    static func wholeSeconds(_ d: Date) throws -> Int64 {
        let t = d.timeIntervalSince1970
        guard t.isFinite, abs(t) < 1e12, t == t.rounded(.down) else { throw TransferError.selfCheckFailed }
        return Int64(t)
    }

    // Values by use count (most first), ties by first appearance.
    static func tableOrder(_ values: [String]) -> [String] {
        var count: [String: Int] = [:]
        var first: [String: Int] = [:]
        for (i, v) in values.enumerated() {
            count[v, default: 0] += 1
            if first[v] == nil { first[v] = i }
        }
        return count.keys.sorted { a, b in
            count[a]! != count[b]! ? count[a]! > count[b]! : first[a]! < first[b]!
        }
    }

    // MARK: Encode

    private struct Group {
        var entries: [SessionLogEntry]
        var hasStart: Bool
        var start: Int64
    }

    static func encodeLog(_ sessions: [SessionLogEntry]) throws -> [UInt8] {
        // Consecutive entries with the same pomodoro key form one pomodoro.
        var groups: [Group] = []
        var currentKey: Int64?
        for e in sessions {
            let key = e.pomodoroStart.map(pomodoroKey)
            if !groups.isEmpty, key == currentKey {
                groups[groups.count - 1].entries.append(e)
            } else {
                let start = try e.pomodoroStart.map(wholeSeconds) ?? wholeSeconds(e.startTime)
                groups.append(Group(entries: [e], hasStart: e.pomodoroStart != nil, start: start))
                currentKey = key
            }
        }

        let titles = tableOrder(sessions.map(\.task).filter { !$0.isEmpty })
        let zones = tableOrder(sessions.compactMap(\.timeZone))
        let versions = tableOrder(sessions.compactMap(\.appVersion))
        let extraFriends = tableOrder(sessions.compactMap(\.friend).filter { !friendRegistry.contains($0) })

        var w = ByteWriter()
        for table in [titles, zones, versions, extraFriends] {
            w.varint(UInt64(table.count))
            for s in table { w.string(s) }
        }

        func tableRef(_ v: String?, _ table: [String]) -> UInt64 {
            guard let v, let i = table.firstIndex(of: v) else { return 0 }
            return UInt64(i + 1)
        }
        func titleRef(_ v: String) -> UInt64 { v.isEmpty ? 0 : tableRef(v, titles) }
        func friendRef(_ v: String?) -> UInt64 {
            guard let v else { return 0 }
            if let i = friendRegistry.firstIndex(of: v) { return UInt64(i + 1) }
            return UInt64(friendRegistry.count) + tableRef(v, extraFriends)
        }

        let calendars = CalendarCache()
        w.varint(UInt64(groups.count))
        var prevStart: Int64 = 0
        var prevFriend: UInt64 = 0, prevFocusCount: Int? = nil, prevZone: UInt64 = 0, prevVersion: UInt64 = 0
        var lastPlanned = initialPlanned

        for g in groups {
            let first = g.entries[0]
            let pomFriend = friendRef(first.friend)
            let pomZone = tableRef(first.timeZone, zones)
            let pomVersion = tableRef(first.appVersion, versions)
            let pomTitle = titleRef(first.task)
            let pomFocusCount = first.focusCount
            let noPaused = first.pausedSeconds == nil

            var flags: UInt64 = 0
            if !g.hasStart { flags |= 1 << 0 }
            if pomFriend == prevFriend { flags |= 1 << 1 }
            if pomFocusCount == prevFocusCount { flags |= 1 << 2 }
            if pomZone == prevZone { flags |= 1 << 3 }
            if pomVersion == prevVersion { flags |= 1 << 4 }
            if noPaused { flags |= 1 << 5 }

            w.int(g.start - prevStart)
            w.varint(flags)
            w.varint(pomTitle)
            if flags & 1 << 1 == 0 { w.varint(pomFriend) }
            if flags & 1 << 2 == 0 { w.varint(try optCode(pomFocusCount)) }
            if flags & 1 << 3 == 0 { w.varint(pomZone) }
            if flags & 1 << 4 == 0 { w.varint(pomVersion) }
            w.varint(UInt64(g.entries.count))
            prevStart = g.start
            prevFriend = pomFriend; prevFocusCount = pomFocusCount; prevZone = pomZone; prevVersion = pomVersion

            var prevEnd = g.start
            var prevFocusNumber: Int? = nil
            for e in g.entries {
                let startS = try wholeSeconds(e.startTime)
                let endS = try wholeSeconds(e.endTime)
                let phaseCode = phaseNames.firstIndex(of: e.phase) ?? 3
                let seconds = e.seconds
                let planned = e.plannedSeconds
                let paused = e.pausedSeconds
                guard small(Int64(seconds)), small(Int64(planned ?? 0)), small(Int64(paused ?? 0))
                else { throw TransferError.selfCheckFailed }

                var exc: UInt64 = 0
                var payload = ByteWriter()
                func flag(_ bit: Int) { exc |= 1 << UInt64(bit) }

                let ymd = calendars.ymd(startS, e.timeZone)
                if (ymd.year, ymd.month, ymd.day) != (e.year, e.month, e.day) {
                    flag(Exc.date)
                    payload.int(e.year); payload.int(e.month); payload.int(e.day)
                }
                if e.durationMinutes != predictedMinutes(seconds) {
                    flag(Exc.minutes)
                    payload.int(e.durationMinutes)
                }
                if e.durationSeconds == nil { flag(Exc.durationSecondsNil) }
                if e.completed && seconds != (planned ?? 0) {
                    flag(Exc.length)
                    payload.int(seconds)
                }
                if planned == nil { flag(Exc.plannedNil) }
                let pausedPresent = paused != nil
                if pausedPresent == noPaused { flag(Exc.pausedFlip) }
                let predictedEnd = startS + Int64(seconds) + Int64(paused ?? 0)
                if endS != predictedEnd {
                    flag(Exc.end)
                    payload.int(endS - predictedEnd)
                }
                let predictedNumber = predictedFocusNumber(previous: prevFocusNumber, phase: e.phase)
                if e.focusNumber != predictedNumber {
                    flag(Exc.focusNumber)
                    payload.varint(try optCode(e.focusNumber))
                }
                if titleRef(e.task) != pomTitle { flag(Exc.task); payload.varint(titleRef(e.task)) }
                if friendRef(e.friend) != pomFriend { flag(Exc.friend); payload.varint(friendRef(e.friend)) }
                if tableRef(e.timeZone, zones) != pomZone { flag(Exc.timeZone); payload.varint(tableRef(e.timeZone, zones)) }
                if tableRef(e.appVersion, versions) != pomVersion {
                    flag(Exc.appVersion)
                    payload.varint(tableRef(e.appVersion, versions))
                }
                if e.focusCount != pomFocusCount {
                    flag(Exc.focusCount)
                    payload.varint(try optCode(e.focusCount))
                }

                let slot = phaseCode
                let contiguous = startS == prevEnd
                let samePlanned = planned != nil && planned == lastPlanned[slot]
                var b: UInt64 = UInt64(phaseCode)
                if e.completed { b |= 1 << 2 }
                if contiguous { b |= 1 << 3 }
                if samePlanned { b |= 1 << 4 }
                if paused == 0 { b |= 1 << 5 }
                if exc == 0 { b |= 1 << 6 }
                w.varint(b)
                if phaseCode == 3 { w.string(e.phase) }
                if exc != 0 { w.varint(exc) }
                if !contiguous { w.int(startS - prevEnd) }
                if let planned, !samePlanned { w.int(planned) }
                if let paused, paused != 0 { w.int(paused) }
                if !e.completed { w.int(seconds) }
                w.bytes(payload.out)

                if let planned { lastPlanned[slot] = planned }
                prevEnd = endS
                prevFocusNumber = e.focusNumber
            }
        }
        return w.out
    }

    // MARK: Decode

    static func decodeLog(_ block: [UInt8]) throws -> [SessionLogEntry] {
        var r = ByteReader(block)
        var tables: [[String]] = []
        for _ in 0..<4 {
            var t: [String] = []
            for _ in 0..<(try r.count()) { t.append(try r.string()) }
            tables.append(t)
        }
        let titles = tables[0], zones = tables[1], versions = tables[2], extraFriends = tables[3]

        func lookup(_ ref: UInt64, _ table: [String]) throws -> String? {
            guard ref != 0 else { return nil }
            guard ref <= UInt64(table.count) else { throw TransferError.malformed }
            return table[Int(ref) - 1]
        }
        func friendName(_ ref: UInt64) throws -> String? {
            guard ref != 0 else { return nil }
            if ref <= UInt64(friendRegistry.count) { return friendRegistry[Int(ref) - 1] }
            return try lookup(ref - UInt64(friendRegistry.count), extraFriends)
        }

        let calendars = CalendarCache()
        var out: [SessionLogEntry] = []
        let groupCount = try r.count(perItem: 4)
        var prevStart: Int64 = 0
        var prevFriend: UInt64 = 0, prevFocusCount: Int? = nil, prevZone: UInt64 = 0, prevVersion: UInt64 = 0
        var lastPlanned = initialPlanned

        for _ in 0..<groupCount {
            let start = prevStart &+ Int64(try r.int())
            let flags = try r.varint()
            guard flags < 1 << 6 else { throw TransferError.malformed }
            let hasStart = flags & 1 == 0
            let noPaused = flags & 1 << 5 != 0
            let pomTitle = try r.varint()
            let pomFriend = flags & 1 << 1 != 0 ? prevFriend : try r.varint()
            let pomFocusCount = flags & 1 << 2 != 0 ? prevFocusCount : optValue(try r.varint())
            let pomZone = flags & 1 << 3 != 0 ? prevZone : try r.varint()
            let pomVersion = flags & 1 << 4 != 0 ? prevVersion : try r.varint()
            let entryCount = try r.count()
            prevStart = start
            prevFriend = pomFriend; prevFocusCount = pomFocusCount; prevZone = pomZone; prevVersion = pomVersion

            var prevEnd = start
            var prevFocusNumber: Int? = nil
            for _ in 0..<entryCount {
                let b = try r.varint()
                guard b < 1 << 7 else { throw TransferError.malformed }
                let phaseCode = Int(b & 3)
                let completed = b & 1 << 2 != 0
                let phase = phaseCode == 3 ? try r.string() : phaseNames[phaseCode]
                let exc = b & 1 << 6 != 0 ? 0 : try r.varint()
                guard exc < 1 << UInt64(Exc.count) else { throw TransferError.malformed }
                func has(_ bit: Int) -> Bool { exc & 1 << UInt64(bit) != 0 }

                let startS = b & 1 << 3 != 0 ? prevEnd : prevEnd &+ Int64(try r.int())
                var planned: Int? = nil
                if !has(Exc.plannedNil) {
                    planned = b & 1 << 4 != 0 ? lastPlanned[phaseCode] : try r.int()
                }
                let pausedPresent = !noPaused != has(Exc.pausedFlip)
                var paused: Int? = nil
                if pausedPresent { paused = b & 1 << 5 != 0 ? 0 : try r.int() }
                var seconds = completed ? (planned ?? 0) : try r.int()

                var ymd: (year: Int, month: Int, day: Int)? = nil
                var minutes: Int? = nil
                if has(Exc.date) { ymd = (try r.int(), try r.int(), try r.int()) }
                if has(Exc.minutes) { minutes = try r.int() }
                if has(Exc.length) { seconds = try r.int() }
                var endDelta: Int64 = 0
                if has(Exc.end) { endDelta = Int64(try r.int()) }
                let predictedNumber = predictedFocusNumber(previous: prevFocusNumber, phase: phase)
                let focusNumber = has(Exc.focusNumber) ? optValue(try r.varint()) : predictedNumber
                let titleRef = has(Exc.task) ? try r.varint() : pomTitle
                let friendRef = has(Exc.friend) ? try r.varint() : pomFriend
                let zoneRef = has(Exc.timeZone) ? try r.varint() : pomZone
                let versionRef = has(Exc.appVersion) ? try r.varint() : pomVersion
                let focusCount = has(Exc.focusCount) ? optValue(try r.varint()) : pomFocusCount

                let endS = startS &+ Int64(seconds) &+ Int64(paused ?? 0) &+ endDelta
                guard small(startS), small(endS), small(Int64(seconds)) else { throw TransferError.malformed }
                let zone = try lookup(zoneRef, zones)
                let date = ymd ?? calendars.ymd(startS, zone)
                out.append(SessionLogEntry(
                    phase: phase, task: try lookup(titleRef, titles) ?? "",
                    day: date.day, month: date.month, year: date.year,
                    startTime: Date(timeIntervalSince1970: Double(startS)),
                    endTime: Date(timeIntervalSince1970: Double(endS)),
                    durationMinutes: minutes ?? predictedMinutes(seconds), completed: completed,
                    durationSeconds: has(Exc.durationSecondsNil) ? nil : seconds,
                    pomodoroStart: hasStart ? Date(timeIntervalSince1970: Double(start)) : nil,
                    plannedSeconds: planned, pausedSeconds: paused,
                    focusNumber: focusNumber, focusCount: focusCount,
                    timeZone: zone, appVersion: try lookup(versionRef, versions),
                    friend: try friendName(friendRef)))

                if let planned { lastPlanned[phaseCode] = planned }
                prevEnd = endS
                prevFocusNumber = focusNumber
            }
        }
        guard r.atEnd else { throw TransferError.malformed }
        return out
    }
}
