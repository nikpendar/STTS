import AVFoundation
import Foundation
import SwiftUI

/// Reads Persian text aloud, offline: PersianPhonemizer writes each sentence as IPA, the Mana
/// Piper voice turns it into audio on a background queue, and the sentences play one after
/// another while the next is made. The voice files are in the app (Models/Voice, from setup.sh).
final class PersianSpeech: ObservableObject {
    static let shared = PersianSpeech()
    static let stressKey = "voiceStress"
    static let speedKey = "voiceSpeed"

    @Published private(set) var isSpeaking = false
    @Published private(set) var error: String?

    /// The folder with the voice files, nil in a build without them.
    static var directory: URL? {
        Bundle.main.url(forResource: "Models", withExtension: nil)
            .map { $0.appendingPathComponent("Voice") }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("mana.onnx").path) ? $0 : nil }
    }

    private let queue = DispatchQueue(label: "ir.nikpendar.PersianSTT.voice", qos: .userInitiated)
    // Used on `queue` only.
    private var phonemizer: PersianPhonemizer?
    private var voice: PiperVoice?
    // Raised by stop() and every new text; the queue drops the sentences of an older one.
    private let lock = NSLock()
    private var currentRun = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var ownsAudioSession = false

    private init() {
        engine.attach(player)
    }

    func speak(_ text: String) {
        stop()
        let run = nextRun()
        let stress = PersianPhonemizer.Stress(rawValue: UserDefaults.standard.string(forKey: Self.stressKey) ?? "") ?? .rules
        let speed = Float(UserDefaults.standard.object(forKey: Self.speedKey) as? Double ?? 1)
        isSpeaking = true
        error = nil
        queue.async { [self] in
            do {
                try loadIfNeeded()
                guard let phonemizer, let voice else { return }
                let sentences = try phonemizer.sentences(text, stress: stress)
                if sentences.isEmpty { DispatchQueue.main.async { self.finish(run) } }
                for (i, sentence) in sentences.enumerated() {
                    guard isCurrent(run) else { return }
                    let samples = try voice.synthesize(sentence, speed: speed)
                    let last = i == sentences.count - 1
                    DispatchQueue.main.async { self.play(samples, rate: voice.sampleRate, run: run, last: last) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.finish(run)
                }
            }
        }
    }

    func stop() {
        _ = nextRun()
        player.stop()
        if engine.isRunning { engine.stop() }
        releaseAudioSession()
        isSpeaking = false
    }

    // MARK: - Private

    private func loadIfNeeded() throws {
        guard voice == nil else { return }
        guard let directory = Self.directory else {
            throw OnnxModel.Failure(message: "صدای فارسی در این نسخه‌ی برنامه نیست.")
        }
        phonemizer = try PersianPhonemizer(directory: directory)
        voice = try PiperVoice(directory: directory)
    }

    private func nextRun() -> Int {
        lock.lock()
        defer { lock.unlock() }
        currentRun += 1
        return currentRun
    }

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return run == currentRun
    }

    private func play(_ samples: [Float], rate: Double, run: Int, last: Bool) {
        guard isCurrent(run), !samples.isEmpty else {
            if last { finish(run) }
            return
        }
        do {
            if !engine.isRunning {
                try claimAudioSession()
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                if self.format != format {
                    engine.disconnectNodeOutput(player)
                    engine.connect(player, to: engine.mainMixerNode, format: format)
                    self.format = format
                }
                try engine.start()
            }
            guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard last else { return }
                DispatchQueue.main.async { self?.finish(run) }
            }
            if !player.isPlaying { player.play() }
        } catch {
            self.error = error.localizedDescription
            finish(run)
        }
    }

    private func finish(_ run: Int) {
        guard isCurrent(run) else { return }
        player.stop()
        if engine.isRunning { engine.stop() }
        releaseAudioSession()
        isSpeaking = false
    }

    /// Playback without touching a running keyboard session, which already plays and records.
    private func claimAudioSession() throws {
        // Called on the main queue only.
        guard !MainActor.assumeIsolated({ KeyboardSession.shared.isActive }) else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        ownsAudioSession = true
    }

    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Type or paste Persian text and hear it, with the speed and where the stress falls.
struct ReadAloudPage: View {
    @ObservedObject private var speech = PersianSpeech.shared
    @AppStorage("voiceText") private var text = "سلام! این صدای فارسی برنامه است و بدون اینترنت کار می‌کند."
    @AppStorage(PersianSpeech.speedKey) private var speed = 1.0
    @AppStorage(PersianSpeech.stressKey) private var stress = PersianPhonemizer.Stress.rules.rawValue
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .focused($editing)
                    .environment(\.layoutDirection, .rightToLeft)
                Button {
                    editing = false
                    if speech.isSpeaking { speech.stop() } else { speech.speak(text) }
                } label: {
                    Label(speech.isSpeaking ? "توقف" : "خواندن", systemImage: speech.isSpeaking ? "stop.fill" : "play.fill")
                }
                .disabled(PersianSpeech.directory == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                if PersianSpeech.directory == nil {
                    Text("صدای فارسی در این نسخه‌ی برنامه نیست.").font(.app(.footnote))
                } else if let error = speech.error {
                    Text(error).font(.app(.footnote)).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("سرعت") {
                    Slider(value: $speed, in: 0.7...1.5, step: 0.1)
                }
                Picker("تکیه", selection: $stress) {
                    Text("قاعده‌ی فارسی").tag(PersianPhonemizer.Stress.rules.rawValue)
                    Text("هجای آخر").tag(PersianPhonemizer.Stress.final.rawValue)
                    Text("بدون تکیه").tag(PersianPhonemizer.Stress.none.rawValue)
                }
            } footer: {
                Text("صدای Mana و آوانگار Homo-GE2PE، هر دو از Mahta Fetrat با مجوز MIT؛ داده‌ی صدا: Mana-TTS.")
                    .font(.app(.footnote))
            }
        }
        .navigationTitle("خواندن متن")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .font(.app(.body))
        .onDisappear { speech.stop() }
    }
}
