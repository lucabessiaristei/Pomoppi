#!/usr/bin/env node
// Synthesizes the four chime packs described in SPEC.md §4 ("Chime"):
//   - classic: three square-wave OscillatorNode blips, an Electron-era Web
//     Audio design — kept byte-for-byte from the original
//     synthesize-classic-chime.js this file replaces.
//   - chord: two stacked major-triad square-wave chords (polyphonic,
//     chiptune-style — several voices sounding together).
//   - jingle: a fast square-wave arpeggio over a sustained bass voice,
//     ending on a held chord (also polyphonic/chiptune).
//   - soft: the same three notes as classic, but sine tones — gentler and
//     quieter, the one non-beeping pack for users who want something
//     softer.
// Each preset writes Sounds/import/chimes/<id>/{focus-end,break-end}.wav
// (16-bit mono 44100Hz, same as before).
//
//   node Sounds/tools/synthesize-chimes.js
//
// Re-run any time; it always overwrites every pack from scratch.
'use strict';

const fs = require('fs');
const path = require('path');

const { encodeWav, SAMPLE_RATE } = require('./wav');

const IMPORT_DIR = path.join(__dirname, '..', 'import', 'chimes');

function writePack(id, focusSamples, breakSamples) {
  const outDir = path.join(IMPORT_DIR, id);
  fs.mkdirSync(outDir, { recursive: true });
  for (const [filename, samples] of [['focus-end.wav', focusSamples], ['break-end.wav', breakSamples]]) {
    const wav = encodeWav(samples);
    const dest = path.join(outDir, filename);
    fs.writeFileSync(dest, wav);
    const ms = (samples.length / SAMPLE_RATE * 1000).toFixed(0);
    console.log(`wrote ${path.relative(path.join(__dirname, '..', '..'), dest)} (${wav.length} bytes, ${ms}ms)`);
  }
}

// A square wave: +amplitude while sin(2*pi*freq*t) is positive,
// -amplitude otherwise (not a sine — that's the whole point of every
// preset below being "polyphonic" in the chiptune sense rather than a
// synth pad). Shared by classic, chord and jingle.
function square(freq, t) {
  return Math.sin(2 * Math.PI * freq * t) >= 0 ? 1 : -1;
}

// A linear attack/decay envelope over a span of `lengthSamples`, ramping
// 0->1 over the first `rampSamples` and 1->0 over the last `rampSamples` —
// the click-avoidance shape every preset below uses at both ends of every
// voice, not just the tail the way classic's original fadeOut-only shape
// did (a sine/square starting or stopping mid-cycle otherwise pops).
function linearEnvelope(s, lengthSamples, rampSamples) {
  const attack = s < rampSamples ? s / rampSamples : 1;
  const decay = s < lengthSamples - rampSamples ? 1 : (lengthSamples - s) / rampSamples;
  return Math.min(attack, decay);
}

function clampToInt16(mixed) {
  const samples = new Int16Array(mixed.length);
  for (let s = 0; s < mixed.length; s++) {
    const clamped = Math.max(-1, Math.min(1, mixed[s]));
    samples[s] = Math.round(clamped * 32767);
  }
  return samples;
}

// -- classic: three square-wave blips, GAP_MS apart, each ramped to
// silence over its last RAMP_MS. Unchanged from synthesize-classic-chime.js
// (fade-out only, no fade-in — the original design predates linearEnvelope
// above, and this preset is explicitly kept byte-for-byte).

const CLASSIC_NOTES = [880, 1174, 1568]; // ascending: focus-end. break-end reuses these, reversed.
const CLASSIC_TONE_MS = 90;
const CLASSIC_GAP_MS = 60; // each tone starts TONE_MS + GAP_MS after the previous one
const CLASSIC_RAMP_MS = 8; // linear fade to 0 at the tail of each tone, avoids a click
const CLASSIC_GAIN = 0.06;

function synthesizeClassic(notes) {
  const toneSamples = Math.round(SAMPLE_RATE * CLASSIC_TONE_MS / 1000);
  const gapSamples = Math.round(SAMPLE_RATE * CLASSIC_GAP_MS / 1000);
  const rampSamples = Math.round(SAMPLE_RATE * CLASSIC_RAMP_MS / 1000);
  const stepSamples = toneSamples + gapSamples;
  const totalSamples = stepSamples * (notes.length - 1) + toneSamples;
  const samples = new Int16Array(totalSamples);

  notes.forEach((freq, i) => {
    const start = i * stepSamples;
    for (let s = 0; s < toneSamples; s++) {
      const t = s / SAMPLE_RATE;
      const fadeOut = s < toneSamples - rampSamples ? 1 : (toneSamples - s) / rampSamples;
      samples[start + s] = Math.round(square(freq, t) * CLASSIC_GAIN * fadeOut * 32767);
    }
  });
  return samples;
}

// -- chord: two stacked major-triad square-wave chords, CHORD_GAP_MS
// apart. Each voice in a chord gets its own linear attack/decay envelope
// (declicks both the chord's entrance and its release), and the three
// voices' waveforms are summed before clamping to 16-bit range — three
// voices at CHORD_GAIN each sum to about the same peak as classic's single
// 0.06 square.

const CHORD_C6 = [1046.5, 1318.5, 1568.0]; // C6 major
const CHORD_G6 = [1568.0, 1975.5, 2349.3]; // G6 major
const CHORD_TONE_MS = 170;
const CHORD_GAP_MS = 40;
const CHORD_RAMP_MS = 9;
const CHORD_GAIN = 0.035;

function synthesizeChord(chords) {
  const toneSamples = Math.round(SAMPLE_RATE * CHORD_TONE_MS / 1000);
  const gapSamples = Math.round(SAMPLE_RATE * CHORD_GAP_MS / 1000);
  const rampSamples = Math.round(SAMPLE_RATE * CHORD_RAMP_MS / 1000);
  const stepSamples = toneSamples + gapSamples;
  const totalSamples = stepSamples * (chords.length - 1) + toneSamples;
  const mixed = new Float64Array(totalSamples);

  chords.forEach((freqs, i) => {
    const start = i * stepSamples;
    for (let s = 0; s < toneSamples; s++) {
      const t = s / SAMPLE_RATE;
      const envelope = linearEnvelope(s, toneSamples, rampSamples);
      for (const freq of freqs) {
        mixed[start + s] += square(freq, t) * CHORD_GAIN * envelope;
      }
    }
  });
  return clampToInt16(mixed);
}

// -- jingle: a fast square-wave arpeggio, back-to-back (no gap between
// notes — each gets its own short attack/decay so adjacent notes don't
// click into each other), over a sustained bass voice held for the whole
// duration (one attack/decay envelope, not per-note), ending on a held
// chord (three voices, also one shared envelope). All three layers —
// bass, melody, chord — are summed before clamping, same as chord's own
// multi-voice mix.

const JINGLE_ARPEGGIO_UP = [523.25, 659.25, 783.99, 1046.5, 1318.51, 1567.98]; // C5 E5 G5 C6 E6 G6
const JINGLE_CHORD_UP = [1046.5, 1318.51, 1567.98]; // C6 E6 G6, the arpeggio's top three notes held
const JINGLE_CHORD_DOWN = [523.25, 659.25, 783.99]; // C5 E5 G5, one octave lower
const JINGLE_BASS_FREQ = 261.63; // C4
const JINGLE_NOTE_MS = 55;
const JINGLE_CHORD_MS = 180;
const JINGLE_RAMP_MS = 8;
const JINGLE_MELODY_GAIN = 0.05;
const JINGLE_CHORD_GAIN = 0.03;
const JINGLE_BASS_GAIN = 0.03;

function synthesizeJingle(arpeggio, chordNotes) {
  const noteSamples = Math.round(SAMPLE_RATE * JINGLE_NOTE_MS / 1000);
  const chordSamples = Math.round(SAMPLE_RATE * JINGLE_CHORD_MS / 1000);
  const rampSamples = Math.round(SAMPLE_RATE * JINGLE_RAMP_MS / 1000);
  const arpeggioSamples = noteSamples * arpeggio.length;
  const totalSamples = arpeggioSamples + chordSamples;
  const mixed = new Float64Array(totalSamples);

  // bass: sustained under the whole thing, one attack/decay envelope
  for (let s = 0; s < totalSamples; s++) {
    const t = s / SAMPLE_RATE;
    const envelope = linearEnvelope(s, totalSamples, rampSamples);
    mixed[s] += square(JINGLE_BASS_FREQ, t) * JINGLE_BASS_GAIN * envelope;
  }

  // melody: the arpeggio, each note its own tone (phase restarts per note,
  // same as classic's per-tone t)
  arpeggio.forEach((freq, i) => {
    const start = i * noteSamples;
    for (let s = 0; s < noteSamples; s++) {
      const t = s / SAMPLE_RATE;
      const envelope = linearEnvelope(s, noteSamples, rampSamples);
      mixed[start + s] += square(freq, t) * JINGLE_MELODY_GAIN * envelope;
    }
  });

  // the held chord after the arpeggio, three voices sustained together
  for (let s = 0; s < chordSamples; s++) {
    const t = s / SAMPLE_RATE;
    const envelope = linearEnvelope(s, chordSamples, rampSamples);
    for (const freq of chordNotes) {
      mixed[arpeggioSamples + s] += square(freq, t) * JINGLE_CHORD_GAIN * envelope;
    }
  }

  return clampToInt16(mixed);
}

// -- soft: the same three notes as sine tones — a short linear attack (to
// avoid a click on the way in, the same reason classic ramps out) then a
// longer linear fade-out, quieter than classic since a sine at the same
// gain reads much louder than a square. The one non-beeping pack, for
// users who want something softer than the chiptune packs above.

const SOFT_NOTES = CLASSIC_NOTES;
const SOFT_TONE_MS = 140;
const SOFT_GAP_MS = 40;
const SOFT_ATTACK_MS = 10;
const SOFT_FADE_MS = 60;
const SOFT_PEAK = 0.15;

function synthesizeSoft(notes) {
  const toneSamples = Math.round(SAMPLE_RATE * SOFT_TONE_MS / 1000);
  const gapSamples = Math.round(SAMPLE_RATE * SOFT_GAP_MS / 1000);
  const attackSamples = Math.round(SAMPLE_RATE * SOFT_ATTACK_MS / 1000);
  const fadeSamples = Math.round(SAMPLE_RATE * SOFT_FADE_MS / 1000);
  const stepSamples = toneSamples + gapSamples;
  const totalSamples = stepSamples * (notes.length - 1) + toneSamples;
  const samples = new Int16Array(totalSamples);

  notes.forEach((freq, i) => {
    const start = i * stepSamples;
    for (let s = 0; s < toneSamples; s++) {
      const t = s / SAMPLE_RATE;
      const sine = Math.sin(2 * Math.PI * freq * t);
      const attack = s < attackSamples ? s / attackSamples : 1;
      const fadeOut = s < toneSamples - fadeSamples ? 1 : (toneSamples - s) / fadeSamples;
      samples[start + s] = Math.round(sine * SOFT_PEAK * attack * fadeOut * 32767);
    }
  });
  return samples;
}

function synthesizeChimes() {
  writePack('classic', synthesizeClassic(CLASSIC_NOTES), synthesizeClassic([...CLASSIC_NOTES].reverse()));
  writePack('chord', synthesizeChord([CHORD_C6, CHORD_G6]), synthesizeChord([CHORD_G6, CHORD_C6]));
  writePack('jingle',
    synthesizeJingle(JINGLE_ARPEGGIO_UP, JINGLE_CHORD_UP),
    synthesizeJingle([...JINGLE_ARPEGGIO_UP].reverse(), JINGLE_CHORD_DOWN));
  writePack('soft', synthesizeSoft(SOFT_NOTES), synthesizeSoft([...SOFT_NOTES].reverse()));
}

module.exports = { synthesizeChimes, IMPORT_DIR };

if (require.main === module) {
  synthesizeChimes();
}
