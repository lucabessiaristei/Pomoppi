import AVFoundation
import PomoppiCore
import PomoppiSprites

// Plays the chime sound described in SPEC.md §4's "Chime" contract: the
// focus-end sound when a focus phase just ended, the break-end sound when a
// break just ended, built on demand from GeneratedSounds' raw PCM bytes via
// WAVFile and played with AVAudioPlayer(data:). Owned by AppDelegate, same
// lifetime as SessionLogger — main-thread-only, no different from any other
// cache/singleton in this app (see CLAUDE.md's swiftLanguageMode invariant).
final class ChimePlayer {
    // Keyed by pack id + which sound, so building the WAV image (a plain
    // header prepend, cheap, but no reason to redo it on every play) only
    // happens once per pack per process.
    private var wavCache: [String: Data] = [:]
    // AVAudioPlayer stops as soon as nothing retains it — this is that one
    // strong reference, replaced (not appended to) on every call, so only
    // the most recent chime ever plays.
    private var currentPlayer: AVAudioPlayer?

    func play(chime id: String, focusEnd: Bool) {
        guard let player = makePlayer(chime: id, focusEnd: focusEnd) else { return }
        currentPlayer = player
        player.prepareToPlay()
        player.play()
    }

    private func makePlayer(chime id: String, focusEnd: Bool) -> AVAudioPlayer? {
        guard let data = wavData(chime: id, focusEnd: focusEnd) else { return nil }
        return try? AVAudioPlayer(data: data)
    }

    private func wavData(chime id: String, focusEnd: Bool) -> Data? {
        let key = "\(id)/\(focusEnd ? "focusEnd" : "breakEnd")"
        if let cached = wavCache[key] { return cached }
        guard let pack = GeneratedSounds.chimes[id] else { return nil }
        let pcm = focusEnd ? pack.focusEnd : pack.breakEnd
        let data = Data(WAVFile.data(
            pcm: pcm, sampleRate: GeneratedSounds.sampleRate,
            bitsPerSample: GeneratedSounds.bitsPerSample, channels: GeneratedSounds.channels))
        wavCache[key] = data
        return data
    }
}
