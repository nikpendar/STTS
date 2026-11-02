import AVFoundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "speech")

/// A Persian text-to-speech engine. The offline Persian voice plugs in here when it is
/// chosen; until then `SystemVoice` uses a Persian voice from iOS if the phone has one.
protocol PersianVoice: AnyObject {
    /// False when the engine cannot speak Persian on this phone.
    var isAvailable: Bool { get }
    /// Starts speaking; `finished` is called on the main queue when this text has been spoken
    /// or was cut off. Texts given while one is playing are queued.
    func speak(_ text: String, finished: @escaping () -> Void)
}

enum SpeakerError: Error, CustomLocalizedStringResourceConvertible {
    case noPersianVoice
    case emptyText

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noPersianVoice: "صدای فارسی هنوز در کیلس نیست."
        case .emptyText: "متنی برای خواندن نیست."
        }
    }
}

/// Reads text aloud for `ReadAloudIntent`, also while the app is in the background.
@MainActor
final class Speaker {
    static let shared = Speaker()

    private let voice: PersianVoice = SystemVoice()
    /// Texts started and not yet finished; the audio session is released when it reaches 0.
    private var playing = 0

    var isAvailable: Bool { voice.isAvailable }

    func speak(_ text: String) throws {
        let text = Self.prepare(text)
        guard !text.isEmpty else { throw SpeakerError.emptyText }
        guard voice.isAvailable else { throw SpeakerError.noPersianVoice }
        // A running keyboard session already holds a play-and-record session; changing it would
        // stop the microphone, and speech plays through it as it is.
        if playing == 0, !KeyboardSession.shared.isActive {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
            } catch {
                log.error("audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
        playing += 1
        log.info("speaking \(text.count) characters")
        voice.speak(text) { [weak self] in
            MainActor.assumeIsolated { self?.finished() }
        }
    }

    private func finished() {
        playing = max(0, playing - 1)
        guard playing == 0, !KeyboardSession.shared.isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Links are replaced by a word so they are not read out letter by letter.
    static func prepare(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: " لینک ",
                                             options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Speaks with a Persian voice from iOS (Settings > Accessibility > Spoken Content > Voices)
/// if one is installed. A stopgap until the offline engine is added.
final class SystemVoice: NSObject, PersianVoice, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var callbacks: [ObjectIdentifier: () -> Void] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private var persianVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("fa") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    var isAvailable: Bool { persianVoice != nil }

    func speak(_ text: String, finished: @escaping () -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = persianVoice
        callbacks[ObjectIdentifier(utterance)] = finished
        synthesizer.speak(utterance)
    }

    private func done(_ utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            self.callbacks.removeValue(forKey: key)?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        done(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        done(utterance)
    }
}
