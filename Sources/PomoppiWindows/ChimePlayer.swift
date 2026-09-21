// ChimePlayer.swift — Windows counterpart to AppDelegate's ChimePlayer.swift
// (macOS): plays the chime described in SPEC.md §4's "Chime" contract.
//
// This used to be PlaySoundW(SND_MEMORY | SND_ASYNC | SND_NODEFAULT) over a
// never-freed WAV image, and that reproducibly played the whole chime on
// the first click but only its first note on every later one (the VM's
// audio device; PlaySound tears the previous playback down internally
// before starting the next, and whatever that does there clipped the new
// sound). waveOut is the API PlaySound itself is built on — driving it
// directly makes the reset/prepare/write sequence explicit and ours, and
// let the fix be verified by timing WOM_DONE against waveOutWrite: three
// consecutive clicks, ~380ms each for a ~390ms sound.
import PomoppiCore
import PomoppiSprites
import WinSDK

// WOM_DONE is the only message this cares about, and the documented
// restriction on waveOut callbacks (no waveOut* calls from inside one,
// except a couple of read-only queries) leaves nothing useful to do with
// it here anyway: waveOutReset at the top of the next play() already
// handles a buffer whether it's still playing or already finished, so
// there's no state this needs to hand back to play(). A real, if inert,
// callback is still required — CALLBACK_FUNCTION needs a valid function
// pointer, not nil.
private let pomoppiChimeCallback: @convention(c) (
    HWAVEOUT?, UINT, DWORD_PTR, DWORD_PTR, DWORD_PTR
) -> Void = { _, _, _, _, _ in }

final class ChimePlayer {
    // Opened once, on the first play, and kept open for the process's
    // life — a tiny app sharing the mixer with everything else, same
    // "main-thread-only, process-lifetime cache" shape as
    // GlobalShortcutManager.shared (see CLAUDE.md's swiftLanguageMode
    // invariant).
    private var device: HWAVEOUT?

    // Keyed by pack id + which sound: each pack+sound's raw PCM bytes,
    // copied into its own never-freed allocation the first time it's
    // played. WAVEHDR.lpData must stay valid for as long as waveOut might
    // still be reading from it — same reasoning the old PlaySoundW buffer
    // cache used, just raw PCM now instead of a full WAV image (waveOut
    // wants samples, not a RIFF header).
    private var pcmBuffers: [String: UnsafeMutablePointer<UInt8>] = [:]

    // One reused WAVEHDR — only one sound plays at a time, so there's
    // never a need for more than one outstanding header. Heap-allocated
    // once rather than a stored `WAVEHDR` passed as `&header`: the driver
    // keeps writing to this address (WHDR_DONE) long after waveOutWrite
    // returns, and Swift only promises a stable address for an explicit
    // allocation — an inout on a stored property is allowed to be a
    // copy-in/copy-out temporary.
    private let header = UnsafeMutablePointer<WAVEHDR>.allocate(capacity: 1)

    func play(chime id: String, focusEnd: Bool) {
        guard let pack = GeneratedSounds.chimes[id] else { return }
        let pcm = focusEnd ? pack.focusEnd : pack.breakEnd
        guard !pcm.isEmpty, let buffer = pcmBuffer(chime: id, focusEnd: focusEnd, pcm: pcm) else { return }
        guard let device = openDeviceIfNeeded() else { return }

        // Whatever the previous play's header is doing — still playing, or
        // done but never unprepared — waveOutReset hands it back
        // immediately (WHDR_DONE), so this is safe to call unconditionally
        // every time, first play included (an unprepared header just fails
        // the unprepare call harmlessly).
        _ = waveOutReset(device)
        _ = waveOutUnprepareHeader(device, header, UInt32(MemoryLayout<WAVEHDR>.size))

        header.pointee = WAVEHDR()
        header.pointee.lpData = UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: CHAR.self)
        header.pointee.dwBufferLength = DWORD(pcm.count)
        header.pointee.dwFlags = 0

        guard waveOutPrepareHeader(device, header, UInt32(MemoryLayout<WAVEHDR>.size)) == MMSYSERR_NOERROR else { return }
        _ = waveOutWrite(device, header, UInt32(MemoryLayout<WAVEHDR>.size))
    }

    private func openDeviceIfNeeded() -> HWAVEOUT? {
        if let device { return device }

        var format = WAVEFORMATEX()
        format.wFormatTag = WORD(WAVE_FORMAT_PCM)
        format.nChannels = WORD(GeneratedSounds.channels)
        format.nSamplesPerSec = DWORD(GeneratedSounds.sampleRate)
        format.wBitsPerSample = WORD(GeneratedSounds.bitsPerSample)
        format.nBlockAlign = WORD(GeneratedSounds.channels * GeneratedSounds.bitsPerSample / 8)
        format.nAvgBytesPerSec = DWORD(GeneratedSounds.sampleRate * GeneratedSounds.channels * GeneratedSounds.bitsPerSample / 8)
        format.cbSize = 0

        var opened: HWAVEOUT?
        let callback = unsafeBitCast(pomoppiChimeCallback, to: DWORD_PTR.self)
        // WAVE_MAPPER is #define'd as ((UINT)-1) in mmeapi.h, but this SDK's
        // ClangImporter fails to type-check that cast on its own (a negative
        // literal into an unsigned type) however it's used here, wrapped or
        // bare -- confirmed directly against the SDK. UInt32.max is the same
        // bit pattern (0xFFFFFFFF) without going through the macro.
        let result = waveOutOpen(&opened, UInt32.max, &format, callback, 0, DWORD(CALLBACK_FUNCTION))
        guard result == MMSYSERR_NOERROR else { return nil }
        device = opened
        return opened
    }

    private func pcmBuffer(chime id: String, focusEnd: Bool, pcm: [UInt8]) -> UnsafeMutablePointer<UInt8>? {
        let key = "\(id)/\(focusEnd ? "focusEnd" : "breakEnd")"
        if let cached = pcmBuffers[key] { return cached }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pcm.count)
        buffer.initialize(from: pcm, count: pcm.count)
        pcmBuffers[key] = buffer
        return buffer
    }
}
