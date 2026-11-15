import Foundation

/// Cuts a long recording into pieces at the speaker's pauses, by the level of each 0.1 s, so a
/// note's dictation is a list of short pieces: each one is decoded to its end (the last words
/// come out right), can be played again on its own, and, at 30 s or less, can go to training
/// when the user corrects its text. Foundation only, so Tests/Notes checks it on a Mac.
struct SpeechSegmenter {
    static let frameSamples = 1_600          // 0.1 s at 16 kHz
    /// A pause this long after speech ends a piece (1.2 s).
    var pauseFrames = 12
    /// A piece is at least this long (2 s) before a pause ends it.
    var minimumFrames = 20
    /// From this length (25 s) a short pause (0.3 s) ends a piece too.
    var longFrames = 250
    /// A piece never grows past this (30 s, what training takes).
    var maximumFrames = 300
    /// A piece with no speech at all is dropped after this long (5 s), to keep nothing in memory.
    var silentFrames = 50

    enum Decision: Equatable {
        case keep
        /// End the piece here; `speech` is false for a piece with no speech in it.
        case cut(speech: Bool)
    }

    private(set) var frames = 0
    private(set) var speechFrames = 0
    private var quietRun = 0
    private var noise: Float = 0.0003
    private var recent: [Float] = []

    /// The level (RMS) of the next 0.1 s; returns whether the piece ends after it.
    mutating func add(level: Float) -> Decision {
        frames += 1
        // The room's noise: the quietest 0.3 s of the last 15 s (median of three, so a click
        // does not count). People pause well within 15 s, so speech is never taken for noise;
        // it rises at most 5% a frame, so a recording that starts with speech is not taken for
        // a loud room (it was: the first pause of a voice message was missed).
        recent.append(level)
        if recent.count > 150 { recent.removeFirst() }
        if recent.count >= 3 {
            var quietest = Float.infinity
            for i in 1..<(recent.count - 1) {
                let a = recent[i - 1], b = recent[i], c = recent[i + 1]
                quietest = min(quietest, max(min(a, b), min(max(a, b), c)))
            }
            noise = max(0.0003, min(quietest, noise * 1.05))
        }
        let quiet = max(3 * noise, 0.0015)
        let loud = max(2 * quiet, 0.004)
        if level >= loud { speechFrames += 1 }
        quietRun = level < quiet ? quietRun + 1 : 0

        let hasSpeech = speechFrames >= 3
        if !hasSpeech {
            return frames >= silentFrames ? cut(false) : .keep
        }
        if frames >= maximumFrames { return cut(true) }
        if frames >= longFrames, quietRun >= 3 { return cut(true) }
        if frames >= minimumFrames, quietRun >= pauseFrames { return cut(true) }
        return .keep
    }

    /// The piece's end, from outside (the user paused or stopped): whether it had speech.
    mutating func end() -> Bool {
        let speech = speechFrames >= 3
        reset()
        return speech
    }

    private mutating func cut(_ speech: Bool) -> Decision {
        reset()
        return .cut(speech: speech)
    }

    private mutating func reset() {
        frames = 0
        speechFrames = 0
        quietRun = 0
    }

    /// RMS of `samples`.
    static func level(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        return (sum / Float(samples.count)).squareRoot()
    }
}
