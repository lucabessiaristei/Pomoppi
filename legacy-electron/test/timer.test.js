'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Timer = require('../lib/timer');

// Local noon, far from any midnight boundary — built via the local Date
// constructor (not a raw epoch offset) so it's safe regardless of the host's
// timezone. Tests that specifically exercise the midnight rollover construct
// their own clock explicitly instead of using this default.
function defaultClockStart() {
  return new Date(2024, 0, 15, 12, 0, 0, 0).getTime();
}

function makeClock(start = defaultClockStart()) {
  let t = start;
  return {
    now: () => t,
    advance(ms) { t += ms; return t; },
  };
}

function makeSettings(overrides) {
  return Object.assign({
    focusMinutes: 25,
    shortBreakMinutes: 5,
    longBreakMinutes: 15,
    longBreakEvery: 4,
    autoStartBreaks: true,
    autoStartFocus: false,
    ringSeconds: 10,
  }, overrides);
}

function makeTimer(overrides, clock) {
  clock = clock || makeClock();
  const settings = makeSettings(overrides);
  const timer = new Timer({ settingsGetter: () => settings, now: clock.now });
  return { timer, clock, settings };
}

test('idle initial state previews the focus length rather than reading 00:00', () => {
  const { timer } = makeTimer();
  const s = timer.getState();
  assert.equal(s.phase, 'idle');
  assert.equal(s.running, false);
  assert.equal(s.ringing, false);
  assert.equal(s.remainingMs, 25 * 60000);
  assert.equal(s.totalMs, 25 * 60000);
  assert.equal(s.cycleIndex, 0);
  assert.equal(s.completedToday, 0);
  assert.equal(s.task, '');
});

test('the idle preview follows focusMinutes, so the widget clock tracks edits', () => {
  const { timer, settings } = makeTimer();
  settings.focusMinutes = 40;
  assert.equal(timer.getState().remainingMs, 40 * 60000);
  settings.focusMinutes = 1;
  assert.equal(timer.getState().remainingMs, 60000);
});

test('starting picks up the length the idle preview was showing', () => {
  const { timer, settings } = makeTimer();
  settings.focusMinutes = 40;
  const idle = timer.getState();
  const started = timer.start();
  assert.equal(started.phase, 'focus');
  assert.equal(started.remainingMs, idle.remainingMs);
  assert.equal(started.totalMs, idle.totalMs);
});

test('start begins a focus phase at full duration', () => {
  const { timer } = makeTimer();
  const s = timer.start();
  assert.equal(s.phase, 'focus');
  assert.equal(s.running, true);
  assert.equal(s.totalMs, 25 * 60000);
  assert.equal(s.remainingMs, 25 * 60000);
});

test('starting twice while already running is a no-op', () => {
  const { timer, clock } = makeTimer();
  timer.start();
  clock.advance(1000);
  const before = timer.tick();
  const after = timer.start();
  assert.deepEqual(after, before);
});

test('tick reduces remainingMs based on wall-clock elapsed time', () => {
  const { timer, clock } = makeTimer();
  timer.start();
  clock.advance(5000);
  const s = timer.tick();
  assert.equal(s.remainingMs, 25 * 60000 - 5000);
});

test('pause freezes remainingMs and resume continues correctly across a clock jump', () => {
  const { timer, clock } = makeTimer();
  timer.start();
  clock.advance(10_000);
  timer.tick();
  const paused = timer.pause();
  assert.equal(paused.running, false);
  const remainingAtPause = paused.remainingMs;

  // simulate the machine sleeping for an hour while paused
  clock.advance(60 * 60 * 1000);
  const stillPaused = timer.tick();
  assert.equal(stillPaused.running, false);
  assert.equal(stillPaused.remainingMs, remainingAtPause);

  const resumed = timer.start();
  assert.equal(resumed.running, true);
  assert.equal(resumed.remainingMs, remainingAtPause);

  clock.advance(1000);
  const s = timer.tick();
  assert.equal(s.remainingMs, remainingAtPause - 1000);
});

test('phase completes exactly at endsAt and emits phaseComplete', () => {
  const { timer, clock } = makeTimer({ autoStartBreaks: true });
  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  timer.start();
  clock.advance(25 * 60000);
  const s = timer.tick();

  assert.equal(events.length, 1);
  assert.equal(events[0].phase, 'focus');
  assert.equal(events[0].completed, true);
  assert.equal(events[0].plannedMs, 25 * 60000);
  assert.equal(events[0].actualMs, 25 * 60000);

  assert.equal(s.phase, 'shortBreak');
  assert.equal(s.ringing, true);
  assert.equal(s.running, true); // autoStartBreaks
  assert.equal(s.cycleIndex, 1);
  assert.equal(s.completedToday, 1);
});

test('a break that does not auto-start sits paused, still ringing', () => {
  const { timer, clock } = makeTimer({ autoStartBreaks: false });
  timer.start();
  clock.advance(25 * 60000);
  const s = timer.tick();
  assert.equal(s.phase, 'shortBreak');
  assert.equal(s.ringing, true);
  assert.equal(s.running, false);
  assert.equal(s.remainingMs, 5 * 60000);
});

test('sleep/wake: a large forward clock jump completes the phase in one tick', () => {
  const { timer, clock } = makeTimer();
  timer.start();
  clock.advance(2 * 60 * 60 * 1000); // machine slept for 2 hours
  const s = timer.tick();
  assert.equal(s.phase, 'shortBreak');
  assert.equal(s.remainingMs <= 5 * 60000, true);
});

test('ringing clears automatically after ringSeconds', () => {
  const { timer, clock } = makeTimer({ ringSeconds: 10 });
  timer.start();
  clock.advance(25 * 60000);
  timer.tick();
  assert.equal(timer.getState().ringing, true);
  clock.advance(11_000);
  const s = timer.tick();
  assert.equal(s.ringing, false);
});

test('dismissRing silences the ring immediately, ahead of the timeout', () => {
  const { timer, clock } = makeTimer({ ringSeconds: 10 });
  timer.start();
  clock.advance(25 * 60000);
  timer.tick();
  assert.equal(timer.getState().ringing, true);
  const s = timer.dismissRing();
  assert.equal(s.ringing, false);
});

test('pressing start while ringing both silences the ring and starts the next phase', () => {
  const { timer, clock } = makeTimer({ autoStartBreaks: false });
  timer.start();
  clock.advance(25 * 60000);
  timer.tick();
  assert.equal(timer.getState().ringing, true);
  assert.equal(timer.getState().running, false);
  const s = timer.start();
  assert.equal(s.ringing, false);
  assert.equal(s.running, true);
  assert.equal(s.phase, 'shortBreak');
});

test('long-break cadence: triggers after longBreakEvery focus sessions and resets cycleIndex', () => {
  const { timer, clock } = makeTimer({
    longBreakEvery: 2,
    autoStartBreaks: true,
    autoStartFocus: true,
  });

  timer.start(); // focus #1
  clock.advance(25 * 60000);
  timer.tick(); // -> shortBreak
  let s = timer.getState();
  assert.equal(s.phase, 'shortBreak');
  assert.equal(s.cycleIndex, 1);

  clock.advance(5 * 60000);
  timer.tick(); // -> focus #2 (auto-started)
  s = timer.getState();
  assert.equal(s.phase, 'focus');
  assert.equal(s.running, true);

  clock.advance(25 * 60000);
  timer.tick(); // -> longBreak, cycleIndex resets
  s = timer.getState();
  assert.equal(s.phase, 'longBreak');
  assert.equal(s.cycleIndex, 0);
  assert.equal(s.completedToday, 2);
});

test('skip during a break aborts it and force-starts the next focus session', () => {
  const { timer, clock } = makeTimer({ autoStartBreaks: true, autoStartFocus: false });
  timer.start();
  clock.advance(25 * 60000);
  timer.tick(); // -> shortBreak, auto-started and running
  clock.advance(60000); // sit in the break a while before skipping

  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  const s = timer.skip();

  assert.equal(events.length, 1);
  assert.equal(events[0].phase, 'shortBreak');
  assert.equal(events[0].completed, false);
  assert.equal(events[0].actualMs, 60000);

  assert.equal(s.phase, 'focus');
  assert.equal(s.running, true); // forced, regardless of autoStartFocus
});

test('skipping a break that never auto-started counts zero elapsed time', () => {
  const { timer, clock } = makeTimer({ autoStartBreaks: false });
  timer.start();
  clock.advance(25 * 60000);
  timer.tick(); // -> shortBreak, sits paused since autoStartBreaks is off
  clock.advance(60000); // wall-clock time passing while paused must not count

  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  timer.skip();
  assert.equal(events[0].actualMs, 0);
});

test('skip during a focus session cuts it short and hands over to the break', () => {
  const { timer, clock } = makeTimer({ autoStartBreaks: false });
  timer.start();
  clock.advance(7 * 60000); // 7 of the 25 minutes spent

  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  const s = timer.skip();

  assert.equal(events.length, 1);
  assert.equal(events[0].phase, 'focus');
  assert.equal(events[0].completed, false);      // -> logged as a partial
  assert.equal(events[0].actualMs, 7 * 60000);   // what was spent, not planned
  assert.equal(events[0].plannedMs, 25 * 60000);

  assert.equal(s.phase, 'shortBreak');
  assert.equal(s.running, true); // forced, regardless of autoStartBreaks
});

test('a cut-short focus claims neither the cycle slot nor the day count', () => {
  const { timer, clock } = makeTimer({ longBreakEvery: 2 });
  timer.start();
  clock.advance(25 * 60000);
  timer.tick();          // first focus completed -> cycleIndex 1
  assert.equal(timer.getState().cycleIndex, 1);
  const completed = timer.getState().completedToday;

  timer.skip();          // out of the break, into focus #2
  clock.advance(60000);
  const s = timer.skip(); // abandon focus #2 after a minute

  // longBreakEvery is 2, so a *completed* second session would have earned the
  // long break. A skipped one earns a short break and leaves the slot open.
  assert.equal(s.phase, 'shortBreak');
  assert.equal(s.cycleIndex, 1);
  assert.equal(s.completedToday, completed);
});

test('the abandoned task rides out on the phaseComplete and is then cleared', () => {
  const { timer, clock } = makeTimer();
  timer.setTask('write the spec');
  timer.start();
  clock.advance(60000);

  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  timer.skip();

  assert.equal(events[0].task, 'write the spec');
  assert.equal(timer.getTask(), '');
});

test('skip is a no-op while idle - there is no phase to skip', () => {
  const { timer } = makeTimer();
  const before = timer.getState();
  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  const after = timer.skip();
  assert.deepEqual(after, before);
  assert.equal(events.length, 0);
});

test('reset aborts the current running phase and returns to idle', () => {
  const { timer, clock } = makeTimer();
  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  timer.start();
  clock.advance(60000);
  timer.tick();
  const s = timer.reset();

  assert.equal(s.phase, 'idle');
  assert.equal(s.running, false);
  // Back to idle means back to the preview, not a zeroed clock.
  assert.equal(s.remainingMs, 25 * 60000);
  assert.equal(s.totalMs, 25 * 60000);

  assert.equal(events.length, 1);
  assert.equal(events[0].completed, false);
  assert.equal(events[0].actualMs, 60000);
  assert.equal(events[0].plannedMs, 25 * 60000);
});

test('reset from idle is a harmless no-op', () => {
  const { timer } = makeTimer();
  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  const s = timer.reset();
  assert.equal(s.phase, 'idle');
  assert.equal(events.length, 0);
});

test('reset while paused still reports the elapsed time, not a full session', () => {
  const { timer, clock } = makeTimer();
  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  timer.start();
  clock.advance(60000);
  timer.tick();
  timer.pause();
  clock.advance(999999); // time passing while paused must not count
  const s = timer.reset();
  assert.equal(s.phase, 'idle');
  assert.equal(events.length, 1);
  assert.equal(events[0].actualMs, 60000);
});

test('task is captured on the completed focus phaseComplete event, then cleared', () => {
  const { timer, clock } = makeTimer();
  timer.setTask('write spec');
  assert.equal(timer.getTask(), 'write spec');
  timer.start();
  assert.equal(timer.getState().task, 'write spec');

  const events = [];
  timer.on('phaseComplete', (e) => events.push(e));
  clock.advance(25 * 60000);
  timer.tick();

  assert.equal(events[0].task, 'write spec');
  assert.equal(timer.getState().task, '');
});

test('completedToday resets to 0 after local midnight even if nothing completes right then', () => {
  const clock = makeClock(new Date(2024, 0, 15, 20, 0, 0, 0).getTime());
  const { timer } = makeTimer({ autoStartBreaks: true }, clock);
  timer.start();
  clock.advance(25 * 60000);
  timer.tick();
  assert.equal(timer.getState().completedToday, 1);

  // Jump well past local midnight with no further ticks or completions —
  // merely reading state should still trigger the rollover.
  clock.advance(6 * 60 * 60 * 1000);
  assert.equal(timer.getState().completedToday, 0);
});

test('a stale completedToday from "yesterday" never leaks into "today"; fresh completions start from 0', () => {
  const clock = makeClock(new Date(2024, 0, 15, 22, 0, 0, 0).getTime());
  const { timer } = makeTimer({ autoStartBreaks: false, autoStartFocus: false }, clock);

  // Two focus sessions completed the evening before midnight.
  timer.start();
  clock.advance(25 * 60000);
  timer.tick(); // -> shortBreak, paused
  timer.skip(); // abort the break, force-start focus #2
  clock.advance(25 * 60000);
  timer.tick();
  assert.equal(timer.getState().completedToday, 2);

  // Cross into the next local day without completing anything new.
  clock.advance(3 * 60 * 60 * 1000);
  assert.equal(timer.getState().completedToday, 0);

  // A session completed after the rollover counts fresh, not 3.
  timer.skip(); // currently sitting in a break; jump straight to a fresh focus
  clock.advance(25 * 60000);
  timer.tick();
  assert.equal(timer.getState().completedToday, 1);
});
