// WAVFile.swift — a minimal, dependency-free WAV (RIFF/PCM) header writer,
// the Swift-side counterpart to Sounds/tools/wav.js's encodeWav. Chime
// playback (ChimePlayer, both platforms) needs a real WAV image to hand to
// AVAudioPlayer/PlaySoundW; GeneratedSounds only stores raw PCM sample
// bytes, so this just prepends the 44-byte canonical header — no
// compression, no extra chunks, mirroring the JS encoder byte for byte.
import Foundation

public enum WAVFile {
    public static func data(pcm: [UInt8], sampleRate: Int, bitsPerSample: Int, channels: Int) -> [UInt8] {
        let dataSize = UInt32(pcm.count)
        let byteRate = UInt32(sampleRate * channels * (bitsPerSample / 8))
        let blockAlign = UInt16(channels * (bitsPerSample / 8))

        var header: [UInt8] = []
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendUInt32(36 + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendUInt32(16) // fmt chunk size (16 = PCM, no extension)
        header.appendUInt16(1) // audioFormat: 1 = PCM
        header.appendUInt16(UInt16(channels))
        header.appendUInt32(UInt32(sampleRate))
        header.appendUInt32(byteRate)
        header.appendUInt16(blockAlign)
        header.appendUInt16(UInt16(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.appendUInt32(dataSize)
        return header + pcm
    }
}

private extension Array where Element == UInt8 {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
