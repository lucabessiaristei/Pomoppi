// Imports chime WAV packs from import/chimes/*/ for refresh-sounds.js to
// embed into Sources/PomoppiSprites/Sounds.generated.swift.
//
//   node Sounds/tools/import-chimes.js
//   node Sounds/tools/import-chimes.js <dir>
//
// Each subdirectory of Sounds/import/chimes/ is one chime "pack" id (the
// directory name, e.g. "classic"). A valid pack has both focus-end.wav and
// break-end.wav inside it; any subdirectory missing either file is skipped,
// with a warning, not a hard failure — a pack still being recorded can sit
// there unfinished without blocking the ones that are.
//
// Every WAV must be 16-bit mono PCM at 44100Hz — a fixed project-wide
// format constraint (see GeneratedSounds.sampleRate/bitsPerSample/channels
// in the generated file), not something auto-converted or silently
// accepted on a mismatch: a pack recorded at the wrong rate/depth fails
// loudly instead of shipping subtly wrong audio.
//
// Re-import after adding, editing, or removing a chime pack under
// Sounds/import/chimes/ — added/removed packs propagate on their own,
// nothing to register by hand (see refresh-sounds.js, which also syncs
// PomoppiCore/Settings.swift's chimeIDs from this same roster).

'use strict';

const fs = require('fs');
const path = require('path');

const { decodeWav, SAMPLE_RATE, BITS_PER_SAMPLE, CHANNELS } = require('./wav');

const DEFAULT_DIR = path.join(__dirname, '..', 'import', 'chimes');
const FILES = { focusEnd: 'focus-end.wav', breakEnd: 'break-end.wav' };

// Plain alphabetical would put "chord" ahead of "classic" — keep classic
// as the picker's first/default option when present, the rest alphabetical.
function orderChimeIDs(ids) {
  const rest = ids.filter((id) => id !== 'classic').sort();
  return ids.includes('classic') ? ['classic', ...rest] : rest;
}

function importChimes({ dir = DEFAULT_DIR } = {}) {
  if (!fs.existsSync(dir)) {
    console.error('no chime import dir: ' + dir);
    process.exit(1);
  }

  const packDirs = fs.readdirSync(dir)
    .filter((f) => fs.statSync(path.join(dir, f)).isDirectory())
    .sort();

  const chimes = {};
  for (const id of packDirs) {
    const packDir = path.join(dir, id);
    const missing = Object.values(FILES).filter((f) => !fs.existsSync(path.join(packDir, f)));
    if (missing.length) {
      console.log(`${id.padEnd(12)} skipped — missing ${missing.join(', ')}`);
      continue;
    }

    const pack = {};
    for (const [key, filename] of Object.entries(FILES)) {
      const file = path.join(packDir, filename);
      const wav = decodeWav(fs.readFileSync(file));
      if (wav.audioFormat !== 1 || wav.channels !== CHANNELS || wav.sampleRate !== SAMPLE_RATE || wav.bitsPerSample !== BITS_PER_SAMPLE) {
        console.error(
          `${path.relative(path.join(__dirname, '..', '..'), file)}: expected ${BITS_PER_SAMPLE}-bit mono PCM at ` +
          `${SAMPLE_RATE}Hz, got format=${wav.audioFormat} channels=${wav.channels} rate=${wav.sampleRate} bits=${wav.bitsPerSample}`
        );
        process.exit(1);
      }
      pack[key] = wav.data;
    }
    chimes[id] = pack;
    console.log(`${id.padEnd(12)} ${pack.focusEnd.length + pack.breakEnd.length} sample bytes`);
  }

  const chimeIDs = orderChimeIDs(Object.keys(chimes));
  if (chimeIDs.length === 0) {
    console.error(`no complete chime pack (needs ${Object.values(FILES).join(' + ')}) in ${dir}`);
    process.exit(1);
  }

  return { chimeIDs, chimes };
}

module.exports = { importChimes, DEFAULT_DIR };

if (require.main === module) {
  importChimes({ dir: process.argv[2] || DEFAULT_DIR });
}
