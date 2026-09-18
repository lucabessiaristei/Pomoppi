// tools/wav.js — minimal WAV (RIFF/PCM) encoder + decoder shared by the
// chime synthesizer and importer. No dependencies: unlike PNG, WAV has no
// compression, just a RIFF header, a `fmt ` chunk, and a `data` chunk of
// raw samples (see Art/tools/read-png.js for the PNG equivalent).
'use strict';

const SAMPLE_RATE = 44100;
const BITS_PER_SAMPLE = 16;
const CHANNELS = 1;

// samples: array-like of signed 16-bit PCM samples, mono. Returns a Buffer
// ready to write to disk as-is.
function encodeWav(samples) {
  const dataSize = samples.length * 2;
  const buf = Buffer.alloc(44 + dataSize);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16); // fmt chunk size (16 = PCM, no extension)
  buf.writeUInt16LE(1, 20); // audioFormat: 1 = PCM
  buf.writeUInt16LE(CHANNELS, 22);
  buf.writeUInt32LE(SAMPLE_RATE, 24);
  buf.writeUInt32LE(SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8), 28); // byte rate
  buf.writeUInt16LE(CHANNELS * (BITS_PER_SAMPLE / 8), 32); // block align
  buf.writeUInt16LE(BITS_PER_SAMPLE, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataSize, 40);
  for (let i = 0; i < samples.length; i++) buf.writeInt16LE(samples[i], 44 + i * 2);
  return buf;
}

// Walks the RIFF chunk list (order not assumed, same chunk-walk style as
// read-png.js) far enough to find `fmt ` and `data`, and returns the format
// fields the caller needs to validate plus the raw sample bytes. Doesn't
// touch any chunk beyond those two — a WAV can carry others (e.g. `LIST`)
// that nothing here needs.
function decodeWav(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('not a wav file');
  }
  let pos = 12, fmt = null, data = null;
  while (pos + 8 <= buf.length) {
    const id = buf.toString('ascii', pos, pos + 4);
    const size = buf.readUInt32LE(pos + 4);
    const body = buf.subarray(pos + 8, pos + 8 + size);
    if (id === 'fmt ') fmt = body;
    else if (id === 'data') data = body;
    pos += 8 + size + (size % 2); // chunks are word-aligned; odd sizes pad 1 byte
  }
  if (!fmt || !data) throw new Error('missing fmt or data chunk');
  return {
    audioFormat: fmt.readUInt16LE(0),
    channels: fmt.readUInt16LE(2),
    sampleRate: fmt.readUInt32LE(4),
    bitsPerSample: fmt.readUInt16LE(14),
    data,
  };
}

module.exports = { encodeWav, decodeWav, SAMPLE_RATE, BITS_PER_SAMPLE, CHANNELS };
