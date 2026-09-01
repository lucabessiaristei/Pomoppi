// lib/timer.js — wall-clock pomodoro state machine (SPEC.md §5).
// No Electron, no timers of its own: the host drives it by calling tick() on
// whatever cadence it likes (main.js calls it every 250ms). Timing is stored
// as an epoch-ms `endsAt` rather than accumulated ticks, so it stays correct
// across sleep/wake — a tick() call after a long clock jump completes the
// phase in one step instead of drifting.
'use strict';

const { EventEmitter } = require('events');

const BREAK_PHASES = new Set(['shortBreak', 'longBreak']);

class Timer extends EventEmitter {
  constructor({ settingsGetter, now = Date.now } = {}) {
    super();
    this.getSettings = settingsGetter;
    this.now = now;

    this.phase = 'idle';
    this.running = false;
    this.ringing = false;
    this.endsAt = null;         // epoch ms while running; null while paused/idle
    this.remainingMs = 0;       // authoritative while not running
    this.totalMs = 0;           // duration locked in when the phase began
    this.cycleIndex = 0;
    this.completedToday = 0;
    this.completedTodayKey = null; // local calendar-day key completedToday is stamped with
    this.task = '';
    this.phaseStartedAt = null; // epoch ms the current phase first started running
    this.ringStartedAt = null;
  }

  // -- public API mirroring window.pomoppi (see SPEC.md §6) ---------------------

  start() {
    const nowTs = this.now();
    if (this.ringing) this._silenceRing(false);
    if (this.phase === 'idle') this._setupPhase('focus');
    if (this.running || this.remainingMs <= 0) return this.getState();
    this._beginRunning(nowTs);
    this.emit('change', this.getState());
    return this.getState();
  }

  pause() {
    const nowTs = this.now();
    if (this.ringing) this._silenceRing(false);
    if (!this.running) return this.getState();
    this.remainingMs = Math.max(0, this.endsAt - nowTs);
    this.endsAt = null;
    this.running = false;
    this.emit('change', this.getState());
    return this.getState();
  }

  reset() {
    const nowTs = this.now();
    if (this.ringing) this._silenceRing(false);
    if (this.phase !== 'idle' && this.phaseStartedAt != null) {
      const remaining = this._computeRemainingMs(nowTs);
      const actualMs = Math.max(0, this.totalMs - remaining);
      this._emitPhaseComplete({
        phase: this.phase,
        startedAt: this.phaseStartedAt,
        endedAt: nowTs,
        plannedMs: this.totalMs,
        actualMs,
        task: this.task,
        completed: false,
      });
    }
    this.phase = 'idle';
    this.running = false;
    this.endsAt = null;
    this.remainingMs = 0;
    this.totalMs = 0;
    this.phaseStartedAt = null;
    this.emit('change', this.getState());
    return this.getState();
  }

  // Ends the current phase early and moves straight on to the next one, either
  // direction: a break jumps into the focus session, a focus session is cut
  // short and hands over to the break. Idle is the only phase with nothing to
  // skip.
  //
  // The abandoned phase is always reported with `completed: false` and the time
  // actually spent, which is what makes lib/obsidian.js log it as a partial (an
  // ❌ line carrying `actualMs`, not the planned length, and excluded from the
  // day's focus total) whenever `logAborted` is on.
  //
  // A cut-short focus does NOT advance the cycle or the day's count: a long
  // break is earned by finishing sessions, not by skipping through them. So the
  // break that follows is always a short one, and `cycleIndex` stays put for
  // the next session to claim.
  //
  // Either direction bypasses autoStartFocus/autoStartBreaks — the user
  // explicitly asked to move on now.
  skip() {
    if (this.phase === 'idle') return this.getState();
    const nowTs = this.now();
    if (this.ringing) this._silenceRing(false);

    const skippedPhase = this.phase;
    const remaining = this._computeRemainingMs(nowTs);
    const actualMs = Math.max(0, this.totalMs - remaining);
    this._emitPhaseComplete({
      phase: skippedPhase,
      startedAt: this.phaseStartedAt != null ? this.phaseStartedAt : nowTs,
      endedAt: nowTs,
      plannedMs: this.totalMs,
      actualMs,
      task: this.task,
      completed: false,
    });

    if (BREAK_PHASES.has(skippedPhase)) {
      this._setupPhase('focus');
    } else {
      // The task belonged to the session just abandoned; it went out with the
      // phaseComplete above, same as when a focus session runs to the end.
      this.task = '';
      this._setupPhase('shortBreak');
    }
    this._beginRunning(nowTs);
    this.emit('change', this.getState());
    return this.getState();
  }

  dismissRing() {
    if (this.ringing) this._silenceRing(true);
    return this.getState();
  }

  setTask(task) {
    this.task = typeof task === 'string' ? task : '';
    this.emit('change', this.getState());
    return this.getState();
  }

  getTask() {
    return this.task;
  }

  // Call on whatever cadence the host wants (main.js: every 250ms). Detects
  // phase completion and ring timeout, then always emits 'tick'.
  tick() {
    const nowTs = this.now();
    if (this.ringing) {
      const ringMs = Math.max(0, Number(this.getSettings().ringSeconds) || 0) * 1000;
      if (nowTs - this.ringStartedAt >= ringMs) this._silenceRing(false);
    }
    if (this.running && this.endsAt != null && nowTs >= this.endsAt) {
      this._completePhase(nowTs);
    }
    const state = this.getState();
    this.emit('tick', state);
    return state;
  }

  // While idle there is no phase counting down, but the widget still has a
  // clock to fill: report the focus length that pressing start would use, so a
  // timer that has never run reads 25:00 instead of 00:00. Derived on read
  // rather than stored, so changing focusMinutes while idle moves the preview
  // with no extra plumbing, and start() locks in the same number.
  getState() {
    this._rolloverIfNeeded(this.now());
    const idle = this.phase === 'idle';
    const totalMs = idle ? this._durationMsFor('focus') : this.totalMs;
    return {
      phase: this.phase,
      running: this.running,
      ringing: this.ringing,
      remainingMs: idle ? totalMs : Math.max(0, this._computeRemainingMs(this.now())),
      totalMs,
      cycleIndex: this.cycleIndex,
      completedToday: this.completedToday,
      task: this.task,
    };
  }

  // -- internals ---------------------------------------------------------

  // completedToday is stamped with the local calendar day it belongs to; a
  // widget left running overnight rolls it back to 0 rather than carrying
  // yesterday's total into today.
  _dateKey(nowTs) {
    const d = new Date(nowTs);
    return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
  }

  _rolloverIfNeeded(nowTs) {
    const key = this._dateKey(nowTs);
    if (this.completedTodayKey !== null && this.completedTodayKey !== key) {
      this.completedToday = 0;
    }
    this.completedTodayKey = key;
  }

  _computeRemainingMs(nowTs) {
    if (this.running && this.endsAt != null) return Math.max(0, this.endsAt - nowTs);
    return Math.max(0, this.remainingMs);
  }

  _durationMsFor(phase) {
    const s = this.getSettings();
    if (phase === 'focus') return s.focusMinutes * 60000;
    if (phase === 'shortBreak') return s.shortBreakMinutes * 60000;
    if (phase === 'longBreak') return s.longBreakMinutes * 60000;
    return 0;
  }

  _setupPhase(phase) {
    this.phase = phase;
    this.totalMs = this._durationMsFor(phase);
    this.remainingMs = this.totalMs;
    this.endsAt = null;
    this.running = false;
    this.phaseStartedAt = null;
  }

  _beginRunning(nowTs) {
    if (this.phaseStartedAt == null) this.phaseStartedAt = nowTs;
    this.endsAt = nowTs + this.remainingMs;
    this.running = true;
  }

  _silenceRing(emitChange) {
    this.ringing = false;
    this.ringStartedAt = null;
    if (emitChange) this.emit('change', this.getState());
  }

  _emitPhaseComplete(payload) {
    this.emit('phaseComplete', payload);
  }

  _completePhase(nowTs) {
    const finishedPhase = this.phase;
    const startedAt = this.phaseStartedAt != null ? this.phaseStartedAt : nowTs;
    const plannedMs = this.totalMs;
    const task = this.task;

    this.running = false;
    this.endsAt = null;
    this.remainingMs = 0;

    this._emitPhaseComplete({
      phase: finishedPhase,
      startedAt,
      endedAt: nowTs,
      plannedMs,
      actualMs: plannedMs, // ran to completion, so actual == planned
      task,
      completed: true,
    });

    const settings = this.getSettings();
    let nextPhase;
    if (finishedPhase === 'focus') {
      this._rolloverIfNeeded(nowTs);
      this.completedToday += 1;
      this.cycleIndex += 1;
      if (this.cycleIndex >= settings.longBreakEvery) {
        nextPhase = 'longBreak';
        this.cycleIndex = 0;
      } else {
        nextPhase = 'shortBreak';
      }
      this.task = '';
    } else {
      nextPhase = 'focus';
    }

    this._setupPhase(nextPhase);
    this.ringing = true;
    this.ringStartedAt = nowTs;

    const autoStart = nextPhase === 'focus' ? settings.autoStartFocus : settings.autoStartBreaks;
    if (autoStart) this._beginRunning(nowTs);

    this.emit('change', this.getState());
  }
}

module.exports = Timer;
