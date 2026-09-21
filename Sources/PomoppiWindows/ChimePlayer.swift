// ChimePlayer.swift — Windows counterpart to AppDelegate's ChimePlayer.swift
// (macOS): plays the chime described in SPEC.md §4's "Chime" contract via
// PlaySoundW(SND_MEMORY), the Win32 equivalent of AVAudioPlayer(data:).
import PomoppiCore
import PomoppiSprites
import WinSDK

final class ChimePlayer {
    // PlaySoundW(SND_MEMORY) needs its buffer to stay valid for as long as
    // playback might still be running — SND_ASYNC returns immediately, so a
    // scoped withUnsafeBufferPointer buffer (freed the moment this function
    // returns) would corrupt whatever's still mid-playback. Each
    // pack+sound's WAV image is copied into its own never-freed allocation
    // instead, the first time it's played, and kept alive for the rest of
    // the process's life — same "main-thread-only, process-lifetime cache"
    // shape as GlobalShortcutManager.shared (see CLAUDE.md's
    // swiftLanguageMode invariant).
    private var buffers: [String: UnsafeMutablePointer<UInt8>] = [:]

    func play(chime id: String, focusEnd: Bool) {
        guard let buffer = wavBuffer(chime: id, focusEnd: focusEnd) else { return }
        // PlaySoundW's first parameter is declared LPCWSTR, but with
        // SND_MEMORY set it's reinterpreted as a pointer to the raw sound
        // data instead — a classic Win32 API quirk, not a string at all.
        let sound = UnsafeRawPointer(buffer).assumingMemoryBound(to: UInt16.self)
        _ = PlaySoundW(sound, nil, DWORD(SND_MEMORY | SND_ASYNC | SND_NODEFAULT))
    }

    private func wavBuffer(chime id: String, focusEnd: Bool) -> UnsafeMutablePointer<UInt8>? {
        let key = "\(id)/\(focusEnd ? "focusEnd" : "breakEnd")"
        if let cached = buffers[key] { return cached }
        guard let pack = GeneratedSounds.chimes[id] else { return nil }
        let pcm = focusEnd ? pack.focusEnd : pack.breakEnd
        let wav = WAVFile.data(
            pcm: pcm, sampleRate: GeneratedSounds.sampleRate,
            bitsPerSample: GeneratedSounds.bitsPerSample, channels: GeneratedSounds.channels)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: wav.count)
        buffer.initialize(from: wav, count: wav.count)
        buffers[key] = buffer
        return buffer
    }
}
