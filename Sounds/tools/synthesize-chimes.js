#!/usr/bin/env node
// Synthesizes the three chime packs described in SPEC.md §4 ("Chime"):
//   - classic: three square-wave OscillatorNode blips, an Electron-era Web
//     Audio design — kept byte-for-byte from the original
//     synthesize-classic-chime.js this file replaces.
//   - soft: the same three notes, but sine tones — gentler and quieter.
//   - bell: two struck-bell tones per pack (a decaying fundamental plus one
//     faster-decaying inharmonic partial), rather than three blips.
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

// -- classic: three square-wave blips, GAP_MS apart, each ramped to
// silence over its last RAMP_MS. A square wave: +amplitude while
// sin(2*pi*freq*t) is positive, -amplitude otherwise (not a sine — that's
// the whole point of the original "square-wave OscillatorNode" design).
// Unchanged from synthesize-classic-chime.js.

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
      const square = Math.sin(2 * Math.PI * freq * t) >= 0 ? 1 : -1;
      const fadeOut = s < toneSamples - rampSamples ? 1 : (toneSamples - s) / rampSamples;
      samples[start + s] = Math.round(square * CLASSIC_GAIN * fadeOut * 32767);
    }
  });
  return samples;
}

// -- soft: the same three notes as sine tones — a short linear attack (to
// avoid a click on the way in, the same reason classic ramps out) then a
// longer linear fade-out, quieter than classic since a sine at the same
// gain reads much louder than a square.

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

// -- bell: two struck-bell tones (E6 then G6, break-end reversed), each a
// sine fundamental with an exponential decay plus one faster-decaying
// inharmonic partial — no attack ramp, since a strike's attack is
// instantaneous by nature, unlike soft's bowed-feeling ramp-in. The second
// strike starts before the first has fully decayed (overlapping slightly);
// both envelopes are summed sample-by-sample and clamped to 16-bit range
// at the end, since the overlap can otherwise push the combined peak past
// what a single struck tone would reach on its own.

const BELL_NOTES = [1318.51, 1567.98]; // E6 then G6, struck order: focus-end. break-end reuses these, reversed.
const BELL_NOTE_OFFSET_MS = 180; // the second strike starts this long after the first
const BELL_TOTAL_MS = 560; // stays under the ~600ms budget even with both tails included
const BELL_FUND_TAU_MS = 250;
const BELL_PARTIAL_RATIO = 2.4;
const BELL_PARTIAL_AMP = 0.4; // relative to the fundamental's own envelope
const BELL_PARTIAL_TAU_MS = 100; // decays faster than the fundamental
const BELL_PEAK = 0.3;

function synthesizeBell(notes) {
  const totalSamples = Math.round(SAMPLE_RATE * BELL_TOTAL_MS / 1000);
  const offsetSamples = Math.round(SAMPLE_RATE * BELL_NOTE_OFFSET_MS / 1000);
  const mixed = new Float64Array(totalSamples);

  notes.forEach((freq, i) => {
    const start = i * offsetSamples;
    for (let s = start; s < totalSamples; s++) {
      const t = (s - start) / SAMPLE_RATE;
      const fundEnvelope = BELL_PEAK * Math.exp(-t / (BELL_FUND_TAU_MS / 1000));
      const partialEnvelope = BELL_PEAK * BELL_PARTIAL_AMP * Math.exp(-t / (BELL_PARTIAL_TAU_MS / 1000));
      const fund = Math.sin(2 * Math.PI * freq * t) * fundEnvelope;
      const partial = Math.sin(2 * Math.PI * freq * BELL_PARTIAL_RATIO * t) * partialEnvelope;
      mixed[s] += fund + partial;
    }
  });

  const samples = new Int16Array(totalSamples);
  for (let s = 0; s < totalSamples; s++) {
    const clamped = Math.max(-1, Math.min(1, mixed[s]));
    samples[s] = Math.round(clamped * 32767);
  }
  return samples;
}

function synthesizeChimes() {
  writePack('classic', synthesizeClassic(CLASSIC_NOTES), synthesizeClassic([...CLASSIC_NOTES].reverse()));
  writePack('soft', synthesizeSoft(SOFT_NOTES), synthesizeSoft([...SOFT_NOTES].reverse()));
  writePack('bell', synthesizeBell(BELL_NOTES), synthesizeBell([...BELL_NOTES].reverse()));
}

module.exports = { synthesizeChimes, IMPORT_DIR };

if (require.main === module) {
  synthesizeChimes();
}
