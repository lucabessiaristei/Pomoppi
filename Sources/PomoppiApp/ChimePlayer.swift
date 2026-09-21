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
    // Keyed by pack id + which sound, one AVAudioPlayer built and
    // prepareToPlay()'d once per pack per process, then reused for every
    // later play — a fresh AVAudioPlayer(data:) per call used to work once
    // and then silently degrade (only the first note of a multi-note chime
    // played back on repeat plays), the same class of bug the Windows
    // ChimePlayer's PlaySoundW(SND_MEMORY) had for a different reason; a
    // persistent, replayable player sidesteps it on both platforms.
    private var players: [String: AVAudioPlayer] = [:]

    func play(chime id: String, focusEnd: Bool) {
        guard let player = player(chime: id, focusEnd: focusEnd) else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    private func player(chime id: String, focusEnd: Bool) -> AVAudioPlayer? {
        let key = "\(id)/\(focusEnd ? "focusEnd" : "breakEnd")"
        if let cached = players[key] { return cached }
        guard let data = wavData(chime: id, focusEnd: focusEnd), let player = try? AVAudioPlayer(data: data) else { return nil }
        player.prepareToPlay()
        players[key] = player
        return player
    }

    private func wavData(chime id: String, focusEnd: Bool) -> Data? {
        guard let pack = GeneratedSounds.chimes[id] else { return nil }
        let pcm = focusEnd ? pack.focusEnd : pack.breakEnd
        return Data(WAVFile.data(
            pcm: pcm, sampleRate: GeneratedSounds.sampleRate,
            bitsPerSample: GeneratedSounds.bitsPerSample, channels: GeneratedSounds.channels))
    }
}
