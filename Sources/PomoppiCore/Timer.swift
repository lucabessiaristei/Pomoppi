// Timer.swift — wall-clock pomodoro state machine.
// Port of lib/timer.js (SPEC.md §5): timing is stored as an absolute `endsAt`
// rather than accumulated ticks, so it stays correct across sleep/wake — a
// tick() call after a long clock jump completes the phase in one step
// instead of drifting. Named `PomodoroTimer`, not `Timer`, to avoid colliding
// with Foundation.Timer.
import Foundation

public enum Phase: String, Equatable {
    case idle, focus, shortBreak, longBreak
}

public struct TimerState: Equatable {
    public let phase: Phase
    public let running: Bool
    public let ringing: Bool
    public let remainingMs: Double
    public let totalMs: Double
    public let cycleIndex: Int
    public let completedToday: Int
    public let task: String
}

public struct PhaseCompleteEvent {
    public let phase: Phase
    public let startedAt: Date
    public let endedAt: Date
    public let plannedMs: Double
    public let actualMs: Double
    public let task: String
    public let completed: Bool
    // The first focus's start in this phase's pomodoro (SPEC.md §5); the log
    // groups by it. nil only for a phase outside any pomodoro.
    public let pomodoroStartedAt: Date?
    // Which focus of the pomodoro this is, 1-based; a break carries the
    // number of the focus it follows. focusCount is the pomodoro's planned
    // number of focus sessions (longBreakEvery) at the time. 0 when unknown.
    public let focusNumber: Int
    public let focusCount: Int
    // Time spent paused inside this phase, not counted in actualMs.
    public let pausedMs: Double

    public init(
        phase: Phase, startedAt: Date, endedAt: Date, plannedMs: Double, actualMs: Double,
        task: String, completed: Bool, pomodoroStartedAt: Date? = nil,
        focusNumber: Int = 0, focusCount: Int = 0, pausedMs: Double = 0
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedMs = plannedMs
        self.actualMs = actualMs
        self.task = task
        self.completed = completed
        self.pomodoroStartedAt = pomodoroStartedAt
        self.focusNumber = focusNumber
        self.focusCount = focusCount
        self.pausedMs = pausedMs
    }
}

// The slice of settings the timer needs, decoupled from the full Settings
// model so this file (and its tests) don't depend on PomoppiCore's disk I/O.
public struct TimerSettingsSnapshot {
    public var focusMinutes: Double
    public var shortBreakMinutes: Double
    public var longBreakMinutes: Double
    public var longBreakEvery: Int
    public var autoStartBreaks: Bool
    public var autoStartFocus: Bool
    public var ringSeconds: Double

    public init(
        focusMinutes: Double,
        shortBreakMinutes: Double,
        longBreakMinutes: Double,
        longBreakEvery: Int,
        autoStartBreaks: Bool,
        autoStartFocus: Bool,
        ringSeconds: Double
    ) {
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.longBreakEvery = longBreakEvery
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
        self.ringSeconds = ringSeconds
    }
}

private let breakPhases: Set<Phase> = [.shortBreak, .longBreak]

public final class PomodoroTimer {
    public var onChange: ((TimerState) -> Void)?
    public var onTick: ((TimerState) -> Void)?
    public var onPhaseComplete: ((PhaseCompleteEvent) -> Void)?
    // reset() threw a pomodoro away: the shell erases its log entries
    // (SessionLogger.discardPomodoro). Carries that pomodoro's start.
    public var onPomodoroDiscarded: ((Date) -> Void)?

    private let getSettings: () -> TimerSettingsSnapshot
    private let now: () -> Date

    private var phase: Phase = .idle
    private var running = false
    private var ringing = false
    private var endsAt: Date?          // set while running; nil while paused/idle
    private var remainingMs: Double = 0 // authoritative while not running
    private var totalMs: Double = 0     // duration locked in when the phase began
    private var cycleIndex = 0             // focus sessions done this pomodoro
    private var completedToday = 0
    private var completedThisPomodoro = 0  // handed back by reset()
    private var pomodoroStartedAt: Date?   // nil = no pomodoro under way
    private var pausedMs: Double = 0       // paused time in the current phase
    private var pausedAt: Date?
    private var completedTodayKey: String?
    private var task: String = ""
    private var phaseStartedAt: Date?
    private var ringStartedAt: Date?
    // Set by completePhase() instead of switching `phase` right away, so the
    // ring/shake animation plays out entirely over the phase that just
    // finished — flipping `phase` (and therefore isBreak/the Zzz animation)
    // immediately would overlap the two. Applied by advancePendingPhase()
    // whichever way the ring ends: naturally timing out, or the user
    // interacting (start/pause/reset/skip all silence an active ring first).
    private var pendingPhase: Phase?
    private var pendingAutoStart = false

    public init(settingsGetter: @escaping () -> TimerSettingsSnapshot, now: @escaping () -> Date = Date.init) {
        self.getSettings = settingsGetter
        self.now = now
    }

    // -- public API mirroring lib/timer.js -----------------------------

    @discardableResult
    public func start() -> TimerState {
        let nowTs = now()
        if ringing { silenceRing(emitChange: false, nowTs) }
        if phase == .idle { setupPhase(.focus) }
        if running || remainingMs <= 0 { return getState() }
        if pomodoroStartedAt == nil { pomodoroStartedAt = nowTs }
        if let pausedAt {
            pausedMs += max(0, nowTs.timeIntervalSince(pausedAt) * 1000)
            self.pausedAt = nil
        }
        beginRunning(nowTs)
        onChange?(getState())
        return getState()
    }

    @discardableResult
    public func pause() -> TimerState {
        let nowTs = now()
        if ringing { silenceRing(emitChange: false, nowTs) }
        guard running else { return getState() }
        remainingMs = max(0, computeRemainingMs(nowTs))
        endsAt = nil
        running = false
        pausedAt = nowTs
        onChange?(getState())
        return getState()
    }

    // Throws the current pomodoro away (SPEC.md §5): nothing is logged, and
    // onPomodoroDiscarded tells the shell to erase what already was. A no-op
    // from idle with no pomodoro under way.
    @discardableResult
    public func reset() -> TimerState {
        let nowTs = now()
        if ringing { silenceRing(emitChange: false, nowTs) }
        guard phase != .idle || pomodoroStartedAt != nil else { return getState() }
        if let startedAt = pomodoroStartedAt {
            rolloverIfNeeded(nowTs)
            completedToday = max(0, completedToday - completedThisPomodoro)
            onPomodoroDiscarded?(startedAt)
        }
        endPomodoro()
        onChange?(getState())
        return getState()
    }

    // Ends the current phase and moves on (SPEC.md §5), bypassing
    // autoStartFocus/autoStartBreaks. A skipped focus fills its dot like a
    // finished one but is logged as stopped early with its real length;
    // skipping the long break ends the pomodoro.
    @discardableResult
    public func skip() -> TimerState {
        let nowTs = now()
        if ringing { silenceRing(emitChange: false, nowTs) }
        guard phase != .idle else { return getState() }

        let skippedPhase = phase
        let remaining = computeRemainingMs(nowTs)
        let actualMs = max(0, totalMs - remaining)
        emitPhaseComplete(event(startedAt: phaseStartedAt ?? nowTs, endedAt: nowTs, actualMs: actualMs, completed: false))

        switch skippedPhase {
        case .focus:
            // Under a minute nothing worth counting happened (SPEC.md §8b).
            finishFocus(nowTs, countsForToday: actualMs >= 60_000)
            setupPhase(cycleIndex >= getSettings().longBreakEvery ? .longBreak : .shortBreak)
        case .shortBreak:
            setupPhase(.focus)
        case .longBreak, .idle:
            endPomodoro()
            onChange?(getState())
            return getState()
        }
        beginRunning(nowTs)
        onChange?(getState())
        return getState()
    }

    @discardableResult
    public func dismissRing() -> TimerState {
        if ringing { silenceRing(emitChange: true, now()) }
        return getState()
    }

    @discardableResult
    public func setTask(_ newTask: String) -> TimerState {
        task = newTask
        onChange?(getState())
        return getState()
    }

    public func getTask() -> String { task }

    // Call on whatever cadence the host wants. Detects phase completion and
    // ring timeout, then always fires onTick.
    @discardableResult
    public func tick() -> TimerState {
        let nowTs = now()
        if ringing, let ringStartedAt {
            let ringMs = max(0, getSettings().ringSeconds) * 1000
            if nowTs.timeIntervalSince(ringStartedAt) * 1000 >= ringMs {
                silenceRing(emitChange: false, nowTs)
            }
        }
        if running, let endsAt, nowTs >= endsAt {
            completePhase(nowTs)
        }
        let state = getState()
        onTick?(state)
        return state
    }

    // While idle there is no phase counting down, but the widget still has a
    // clock to fill: report the focus length that pressing start would use,
    // derived on read rather than stored, so changing focusMinutes while idle
    // moves the preview with no extra plumbing.
    public func getState() -> TimerState {
        rolloverIfNeeded(now())
        let idle = phase == .idle
        let stateTotalMs = idle ? durationMs(for: .focus) : totalMs
        let stateRemainingMs = idle ? stateTotalMs : max(0, computeRemainingMs(now()))
        return TimerState(
            phase: phase, running: running, ringing: ringing,
            remainingMs: stateRemainingMs, totalMs: stateTotalMs,
            cycleIndex: cycleIndex, completedToday: completedToday, task: task)
    }

    // -- internals -------------------------------------------------------

    // completedToday is stamped with the local calendar day it belongs to; a
    // widget left running overnight rolls it back to 0 rather than carrying
    // yesterday's total into today.
    private func dateKey(_ nowTs: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: nowTs)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    private func rolloverIfNeeded(_ nowTs: Date) {
        let key = dateKey(nowTs)
        if let currentKey = completedTodayKey, currentKey != key {
            completedToday = 0
        }
        completedTodayKey = key
    }

    private func computeRemainingMs(_ nowTs: Date) -> Double {
        if running, let endsAt {
            return max(0, endsAt.timeIntervalSince(nowTs) * 1000)
        }
        return max(0, remainingMs)
    }

    private func durationMs(for phase: Phase) -> Double {
        let s = getSettings()
        switch phase {
        case .focus: return s.focusMinutes * 60000
        case .shortBreak: return s.shortBreakMinutes * 60000
        case .longBreak: return s.longBreakMinutes * 60000
        case .idle: return 0
        }
    }

    private func setupPhase(_ newPhase: Phase) {
        phase = newPhase
        totalMs = durationMs(for: newPhase)
        remainingMs = totalMs
        endsAt = nil
        running = false
        phaseStartedAt = nil
        pausedMs = 0
        pausedAt = nil
    }

    // The current phase as a phaseComplete event.
    private func event(startedAt: Date, endedAt: Date, actualMs: Double, completed: Bool) -> PhaseCompleteEvent {
        let stillPaused = pausedAt.map { max(0, endedAt.timeIntervalSince($0) * 1000) } ?? 0
        return PhaseCompleteEvent(
            phase: phase, startedAt: startedAt, endedAt: endedAt,
            plannedMs: totalMs, actualMs: actualMs, task: task, completed: completed,
            pomodoroStartedAt: pomodoroStartedAt,
            focusNumber: phase == .focus ? cycleIndex + 1 : cycleIndex,
            focusCount: getSettings().longBreakEvery,
            pausedMs: pausedMs + stillPaused)
    }

    private func finishFocus(_ nowTs: Date, countsForToday: Bool) {
        cycleIndex += 1
        if countsForToday {
            rolloverIfNeeded(nowTs)
            completedToday += 1
            completedThisPomodoro += 1
        }
    }

    // Back to idle with nothing under way: dots emptied, title cleared.
    private func endPomodoro() {
        setupPhase(.idle)
        cycleIndex = 0
        completedThisPomodoro = 0
        pomodoroStartedAt = nil
        task = ""
        pendingPhase = nil
        pendingAutoStart = false
    }

    private func beginRunning(_ nowTs: Date) {
        if phaseStartedAt == nil { phaseStartedAt = nowTs }
        endsAt = nowTs.addingTimeInterval(remainingMs / 1000)
        running = true
    }

    private func silenceRing(emitChange: Bool, _ nowTs: Date) {
        ringing = false
        ringStartedAt = nil
        advancePendingPhase(nowTs)
        if emitChange { onChange?(getState()) }
    }

    // Applies whatever completePhase() deferred, if anything — a no-op once
    // the ring has already been resolved once. Runs on every path that stops
    // a ring: it timing out on its own, or any user interaction cutting it
    // short.
    private func advancePendingPhase(_ nowTs: Date) {
        guard let next = pendingPhase else { return }
        pendingPhase = nil
        if next == .idle {
            endPomodoro()
            return
        }
        setupPhase(next)
        if pendingAutoStart { beginRunning(nowTs) }
        pendingAutoStart = false
    }

    private func emitPhaseComplete(_ event: PhaseCompleteEvent) {
        onPhaseComplete?(event)
    }

    private func completePhase(_ nowTs: Date) {
        let finishedPhase = phase
        let startedAt = phaseStartedAt ?? nowTs

        running = false
        endsAt = nil
        remainingMs = 0

        emitPhaseComplete(event(startedAt: startedAt, endedAt: nowTs, actualMs: totalMs, completed: true))

        let settings = getSettings()
        let nextPhase: Phase
        switch finishedPhase {
        case .focus:
            finishFocus(nowTs, countsForToday: true)
            nextPhase = cycleIndex >= settings.longBreakEvery ? .longBreak : .shortBreak
        case .longBreak:
            // The pomodoro is over as of now, so a reset during the ring
            // can't discard it; the dots stay full until the ring ends.
            nextPhase = .idle
            pomodoroStartedAt = nil
            completedThisPomodoro = 0
        case .shortBreak, .idle:
            nextPhase = .focus
        }

        // `phase` deliberately stays `finishedPhase` for now — setupPhase(),
        // and any auto-start, are deferred to advancePendingPhase() so the
        // break/Zzz animation (which keys off `phase`) never starts until
        // the ring/shake animation for the phase that just ended has fully
        // played out and been silenced. Logging above already happened
        // immediately: only the *visual* transition is held back.
        pendingPhase = nextPhase
        pendingAutoStart = nextPhase == .idle ? false
            : nextPhase == .focus ? settings.autoStartFocus : settings.autoStartBreaks
        ringing = true
        ringStartedAt = nowTs

        onChange?(getState())
    }
}
