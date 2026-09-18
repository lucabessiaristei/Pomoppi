#!/usr/bin/env node
// Synthesizes the "classic" chime pack described in SPEC.md §4 ("Chime (no
// audio files)"): an Electron-era Web Audio design — three square-wave
// OscillatorNode blips — that was never actually carried into either native
// rewrite. This writes real WAV files so there's something for
// import-chimes.js to embed, rather than leaving the chime feature with no
// placeholder audio at all.
//
//   node Sounds/tools/synthesize-classic-chime.js
//
// Re-run any time; it always overwrites
// Sounds/import/chimes/classic/{focus-end,break-end}.wav from scratch.
'use strict';

const fs = require('fs');
const path = require('path');

const { encodeWav, SAMPLE_RATE } = require('./wav');

const TONE_MS = 90;
const GAP_MS = 60; // each tone starts TONE_MS + GAP_MS after the previous one
const RAMP_MS = 8; // linear fade to 0 at the tail of each tone, avoids a click
const GAIN = 0.06;
const NOTES = [880, 1174, 1568]; // ascending: focus-end. break-end reuses these, reversed.

const OUT_DIR = path.join(__dirname, '..', 'import', 'chimes', 'classic');

// Three square-wave tones, GAP_MS apart, each ramped to silence over its
// last RAMP_MS — see SPEC.md §4. A square wave: +amplitude while
// sin(2*pi*freq*t) is positive, -amplitude otherwise (not a sine — that's
// the whole point of the original "square-wave OscillatorNode" design).
function synthesizeChime(notes) {
  const toneSamples = Math.round(SAMPLE_RATE * TONE_MS / 1000);
  const gapSamples = Math.round(SAMPLE_RATE * GAP_MS / 1000);
  const rampSamples = Math.round(SAMPLE_RATE * RAMP_MS / 1000);
  const stepSamples = toneSamples + gapSamples;
  const totalSamples = stepSamples * (notes.length - 1) + toneSamples;
  const samples = new Int16Array(totalSamples);

  notes.forEach((freq, i) => {
    const start = i * stepSamples;
    for (let s = 0; s < toneSamples; s++) {
      const t = s / SAMPLE_RATE;
      const square = Math.sin(2 * Math.PI * freq * t) >= 0 ? 1 : -1;
      const fadeOut = s < toneSamples - rampSamples ? 1 : (toneSamples - s) / rampSamples;
      samples[start + s] = Math.round(square * GAIN * fadeOut * 32767);
    }
  });
  return samples;
}

function writeChime(filename, notes) {
  const samples = synthesizeChime(notes);
  const wav = encodeWav(samples);
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const dest = path.join(OUT_DIR, filename);
  fs.writeFileSync(dest, wav);
  const ms = (samples.length / SAMPLE_RATE * 1000).toFixed(0);
  console.log(`wrote ${path.relative(path.join(__dirname, '..', '..'), dest)} (${wav.length} bytes, ${ms}ms)`);
}

function synthesizeClassicChime() {
  writeChime('focus-end.wav', NOTES);
  writeChime('break-end.wav', [...NOTES].reverse());
}

module.exports = { synthesizeClassicChime, OUT_DIR };

if (require.main === module) {
  synthesizeClassicChime();
}
