import AVFoundation
import SwiftUI
import WatchKit

/// Records on the watch, sends the recording to the iPhone and waits for the text.
/// Recording stops on a tap (or Double Tap), after a pause following speech, or at 60 s.
@MainActor
final class WatchDictation: ObservableObject {
    static let shared = WatchDictation()

    enum Phase: Equatable {
        case idle
        case recording
        /// Sending the recording, then waiting for the iPhone's text.
        case working
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    /// The microphone level, 0...1, for the button's ring.
    @Published private(set) var level: Double = 0
    /// Recent texts, newest first, so a text is not lost when the app closes.
    @Published private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: "history") ?? []

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// The recording waiting for its text, kept for a retry.
    private var pendingID: String?
    private var lastRecording: Data?
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("watch-recording.m4a")

    private init() {
        PhoneLink.shared.onResult = { [weak self] id, text, error in
            self?.received(id: id, text: text, error: error)
        }
        PhoneLink.shared.start()
    }

    /// The main button: start, stop, or start again after a result.
    func toggle() {
        switch phase {
        case .recording: stop()
        case .working: break
        default: Task { await start() }
        }
    }

    func startFromComplication() {
        guard phase != .recording, phase != .working else { return }
        Task { await start() }
    }

    /// The last recording did not get its text and can be sent again.
    var canRetry: Bool { lastRecording != nil }

    func retry() {
        guard let audio = lastRecording else { return }
        send(audio)
    }

    func reset() {
        phase = .idle
    }

    // MARK: - Recording

    private func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("دسترسی به میکروفون داده نشده است. از تنظیمات ساعت فعالش کنید.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            // Compressed so a minute of speech is about 180 KB over Bluetooth.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
            ]
            try? FileManager.default.removeItem(at: recordingURL)
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                phase = .failed("شروع ضبط ناموفق بود.")
                return
            }
            self.recorder = recorder
            phase = .recording
            WKInterfaceDevice.current().play(.start)
            watchForSilence()
        } catch {
            phase = .failed("خطا در ضبط: \(error.localizedDescription)")
        }
    }

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
                let power = recorder.averagePower(forChannel: 0)
                self.level = max(0, min(1, Double(power + 50) / 50))
                if power > -40 {
                    heardSpeech = true
                    silence = 0
                } else {
                    silence += 0.1
                }
                let elapsed = Date().timeIntervalSince(started)
                if (heardSpeech && silence >= 2) || (!heardSpeech && silence >= 8) || elapsed >= 60 {
                    self.stop()
                    return
                }
            }
        }
    }

    private func stop() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        WKInterfaceDevice.current().play(.stop)
        guard let audio = try? Data(contentsOf: recordingURL), audio.count > 1_000 else {
            phase = .failed("صدایی ضبط نشد.")
            return
        }
        lastRecording = audio
        send(audio)
    }

    // MARK: - iPhone

    private func send(_ audio: Data) {
        let id = UUID().uuidString
        pendingID = id
        phase = .working
        Task {
            do {
                try await PhoneLink.shared.send(audio, id: id)
            } catch {
                guard pendingID == id else { return }
                pendingID = nil
                phase = .failed(error.localizedDescription)
                return
            }
            // The iPhone has about 30 s in the background; a minute of speech takes a few seconds.
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                guard !Task.isCancelled, let self, self.pendingID == id else { return }
                self.pendingID = nil
                self.phase = .failed("آیفون جواب نداد. اپ کیلس را روی گوشی یک بار باز کنید و دوباره بفرستید.")
            }
        }
    }

    private func received(id: String, text: String?, error: String?) {
        // A late text for an earlier recording still goes into the history.
        if let text, !text.isEmpty { remember(text) }
        guard id == pendingID else { return }
        pendingID = nil
        timeoutTask?.cancel()
        if let text, !text.isEmpty {
            phase = .done(text)
            lastRecording = nil
            WKInterfaceDevice.current().play(.success)
        } else {
            phase = .failed(error ?? "متنی برنگشت.")
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func remember(_ text: String) {
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }
        UserDefaults.standard.set(history, forKey: "history")
    }
}
