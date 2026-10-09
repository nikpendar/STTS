import AVFoundation
import Foundation
import UIKit

@MainActor
final class Transcriber: ObservableObject {
    /// Shared so the dictation shortcut (DictateIntent) can drive the same instance as the UI.
    static let shared = Transcriber()

    @Published var text = ""
    @Published var status = "در حال بارگذاری مدل…"
    @Published var isRecording = false
    @Published var isBusy = true
    @Published var modelName = ""
    /// Recording that stops by itself after a pause, started from the dictation shortcut.
    @Published var isQuickDictation = false

    private var whisper: WhisperContext?
    private var usesCoreML = false
    /// Smallest encoder window (frames, 50 per second) for short recordings; 0 means always 30 s.
    /// Stock OpenAI models (ggml-base, ggml-large-v3-turbo, ...) tolerate 384. Fine-tuned models
    /// (ggml-whisper-...) repeat and hallucinate below about 20 s: the Persian medium model went
    /// from 11.3% to 20.6% WER on FLEURS at 384 and 12.7% at 750, but kept its accuracy at 1000
    /// (FLEURS 11.0%, Common Voice 20.2%) while transcribing about 30% faster.
    private var minimumAudioContext = 0
    private var loadTask: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var quickDictationPending = false
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")

    private init() {
        loadTask = Task { await loadModel() }
    }

    /// The first ggml-*.bin found in the bundled Models folder is used.
    private static func findModel() -> URL? {
        Bundle.main.urls(forResourcesWithExtension: "bin", subdirectory: "Models")?
            .filter { $0.lastPathComponent.hasPrefix("ggml-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// whisper.cpp loads ggml-<name>-encoder.mlmodelc (next to the .bin) to run the encoder on the Neural Engine.
    private static func hasCoreMLEncoder(for model: URL) -> Bool {
        var name = model.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"-q\d_[\dk]$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        let encoder = model.deletingLastPathComponent().appendingPathComponent("\(name)-encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    private func loadModel() async {
        guard let url = Self.findModel() else {
            status = "مدلی در پوشه‌ی Models پیدا نشد. ابتدا setup.sh را اجرا کنید."
            isBusy = false
            return
        }
        modelName = url.lastPathComponent
        if Self.hasCoreMLEncoder(for: url) {
            status = "در حال بارگذاری مدل… اجرای اول Neural Engine ممکن است چند دقیقه طول بکشد."
        }
        do {
            let path = url.path
            whisper = try await Task.detached { try WhisperContext(path: path) }.value
            usesCoreML = Self.hasCoreMLEncoder(for: url)
            let stock = ["tiny", "base", "small", "medium", "large"].contains { url.lastPathComponent.hasPrefix("ggml-\($0)") }
            minimumAudioContext = usesCoreML ? 0 : (stock ? 384 : 1000)
            if !isRecording {
                status = usesCoreML ? "آماده (Neural Engine)" : "آماده"
            }
        } catch {
            status = error.localizedDescription
        }
        if !isRecording {
            isBusy = false
        }
    }

    // MARK: - Dictation shortcut

    /// Called by DictateIntent. Recording can only start once the app is in the foreground,
    /// so the request is kept until `appDidBecomeActive()` if needed.
    func requestQuickDictation() {
        quickDictationPending = true
        if UIApplication.shared.applicationState == .active {
            appDidBecomeActive()
        }
    }

    func appDidBecomeActive() {
        guard quickDictationPending, !isRecording else { return }
        quickDictationPending = false
        Task { await startRecording(quick: true) }
    }

    // MARK: - Recording

    func toggleRecording() async {
        if isRecording {
            stopAndTranscribe()
        } else {
            await startRecording(quick: false)
        }
    }

    private func startRecording(quick: Bool) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "دسترسی به میکروفون داده نشده است. از تنظیمات آیفون فعالش کنید."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // voiceChat mode turns on Apple's voice processing (noise suppression) for the recorder.
            if KeyboardSession.noiseSuppression {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            } else {
                try session.setCategory(.record, mode: .default)
            }
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: AudioLoader.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.isMeteringEnabled = quick
            guard recorder.record() else {
                status = "شروع ضبط ناموفق بود."
                return
            }
            self.recorder = recorder
            isRecording = true
            isQuickDictation = quick
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if quick {
                status = "در حال گوش دادن… بعد از مکث خودکار تمام می‌شود."
                watchForSilence()
            } else {
                status = "در حال ضبط… برای پایان دوباره بزنید."
            }
        } catch {
            status = "خطا در ضبط: \(error.localizedDescription)"
        }
    }

    /// Stops a quick dictation after speech followed by a pause, or when nothing is said.
    private func watchForSilence() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            let started = Date()
            var heardSpeech = false
            var silence: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                if recorder.averagePower(forChannel: 0) > -40 {
                    heardSpeech = true
                    silence = 0
                } else {
                    silence += 0.1
                }
                let elapsed = Date().timeIntervalSince(started)
                if (heardSpeech && silence >= 1.8) || (!heardSpeech && silence >= 8) || elapsed >= 60 {
                    self.stopAndTranscribe()
                    return
                }
            }
        }
    }

    private func stopAndTranscribe() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        isQuickDictation = false
        if !KeyboardSession.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        transcribe(url: recordingURL)
    }

    func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                transcribe(url: copy)
            } catch {
                status = "خواندن فایل ناموفق بود: \(error.localizedDescription)"
            }
        case .failure(let error):
            status = error.localizedDescription
        }
    }

    /// Stops the transcription in progress; it then throws `WhisperError.cancelled`.
    func cancelTranscription() {
        whisper?.abort.set()
    }

    /// Used by the keyboard session, which records its own audio. The result goes only to the
    /// keyboard, not to the app's text box.
    func transcribe(samples: [Float]) async throws -> String {
        if whisper == nil {
            await loadTask?.value
        }
        guard let whisper else { throw WhisperError.cannotLoadModel }
        let result = try await whisper.transcribe(samples: samples, minimumAudioContext: minimumAudioContext)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcribes, then copies the text to the clipboard so it can be pasted into any app.
    private func transcribe(url: URL) {
        isBusy = true
        Task {
            if whisper == nil {
                status = "در حال بارگذاری مدل…"
                await loadTask?.value
            }
            guard let whisper else {
                isBusy = false
                return
            }
            status = "در حال تبدیل به متن…"
            do {
                let start = Date()
                let samples = try await Task.detached { try AudioLoader.loadSamples(url: url) }.value
                let result = try await whisper.transcribe(samples: samples, minimumAudioContext: minimumAudioContext)
                text = result.trimmingCharacters(in: .whitespacesAndNewlines)
                let audioSeconds = Double(samples.count) / AudioLoader.sampleRate
                let elapsed = Date().timeIntervalSince(start)
                var summary = String(format: "%.1f ثانیه صدا در %.1f ثانیه تبدیل شد", audioSeconds, elapsed)
                if !text.isEmpty {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    summary += " و در کلیپ‌بورد کپی شد"
                }
                status = summary
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}
