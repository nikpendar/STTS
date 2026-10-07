import AVFoundation
import Foundation

@MainActor
final class Transcriber: ObservableObject {
    @Published var text = ""
    @Published var status = "در حال بارگذاری مدل…"
    @Published var isRecording = false
    @Published var isBusy = true
    @Published var modelName = ""

    private var whisper: WhisperContext?
    private var usesCoreML = false
    private var recorder: AVAudioRecorder?
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")

    init() {
        Task { await loadModel() }
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
            status = usesCoreML ? "آماده (Neural Engine)" : "آماده"
        } catch {
            status = error.localizedDescription
        }
        isBusy = false
    }

    func toggleRecording() async {
        if isRecording {
            stopAndTranscribe()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "دسترسی به میکروفون داده نشده است. از تنظیمات آیفون فعالش کنید."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
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
            guard recorder.record() else {
                status = "شروع ضبط ناموفق بود."
                return
            }
            self.recorder = recorder
            isRecording = true
            status = "در حال ضبط… برای پایان دوباره بزنید."
        } catch {
            status = "خطا در ضبط: \(error.localizedDescription)"
        }
    }

    private func stopAndTranscribe() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
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

    private func transcribe(url: URL) {
        guard let whisper else {
            status = "مدل بارگذاری نشده است."
            return
        }
        isBusy = true
        status = "در حال تبدیل به متن…"
        Task {
            do {
                let start = Date()
                let samples = try await Task.detached { try AudioLoader.loadSamples(url: url) }.value
                let result = try await whisper.transcribe(samples: samples, shortenAudioContext: !usesCoreML)
                text = result.trimmingCharacters(in: .whitespacesAndNewlines)
                let audioSeconds = Double(samples.count) / AudioLoader.sampleRate
                let elapsed = Date().timeIntervalSince(start)
                status = String(format: "%.1f ثانیه صدا در %.1f ثانیه تبدیل شد", audioSeconds, elapsed)
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}
