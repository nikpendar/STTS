import AVFoundation
import UIKit

/// Keeps the microphone open while the app is in the background so the dictation keyboard
/// can record and get transcripts without leaving the text field. Keyboard extensions
/// cannot use the microphone themselves, and the model is too large for one.
@MainActor
final class KeyboardSession: ObservableObject {
    static let shared = KeyboardSession()
    /// Minutes without dictation before the session closes; 0 keeps it open until stopped.
    static let idleMinutesKey = "keyboardSessionMinutes"
    static let defaultIdleMinutes = 30
    static var idleMinutes: Int {
        UserDefaults.standard.object(forKey: idleMinutesKey) as? Int ?? defaultIdleMinutes
    }
    /// Apple's voice processing on the microphone: noise suppression and echo cancellation.
    /// It also lets the user pick Voice Isolation in the system microphone-mode menu.
    static let noiseSuppressionKey = "noiseSuppression"
    static var noiseSuppression: Bool {
        UserDefaults.standard.object(forKey: noiseSuppressionKey) as? Bool ?? true
    }

    /// Transcribes while the user is still speaking, so the keyboard shows text as it comes.
    /// Costs extra CPU: the recording so far is re-transcribed every time a pass finishes.
    static let liveTranscriptionKey = "liveTranscription"
    static var liveTranscription: Bool {
        UserDefaults.standard.object(forKey: liveTranscriptionKey) as? Bool ?? true
    }

    @Published private(set) var isActive = false
    @Published private(set) var message = ""

    private let engine = AVAudioEngine()
    private let observer = DarwinObserver()
    private let collector = SampleCollector()
    private let server = TranscriptServer()
    private var idleTimer: Timer?
    private var liveTask: Task<Void, Never>?
    private var isCapturing = false
    /// Identifies the current dictation, so a cancelled one cannot report a late result.
    private var dictationID = 0

    private init() {
        observer.observe(DictationBridge.ping) { [weak self] in
            MainActor.assumeIsolated {
                if self?.isActive == true { DictationBridge.post(DictationBridge.alive) }
            }
        }
        observer.observe(DictationBridge.start) { [weak self] in
            MainActor.assumeIsolated { self?.startCapture() }
        }
        observer.observe(DictationBridge.stop) { [weak self] in
            MainActor.assumeIsolated { self?.finishCapture() }
        }
        observer.observe(DictationBridge.cancel) { [weak self] in
            MainActor.assumeIsolated { self?.cancelDictation() }
        }
        // A call or Siri pauses the engine; it is restarted when the interruption ends.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            MainActor.assumeIsolated { self?.resume() }
        }
    }

    private func resume() {
        guard isActive, !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            stop()
        }
    }

    /// Restarts a running session so a changed noise-suppression setting takes effect.
    func noiseSuppressionChanged() {
        guard isActive else { return }
        stop()
        start()
    }

    /// Applies a changed session length to a running session.
    func idleMinutesChanged() {
        if isActive { resetIdleTimer() }
    }

    func start() {
        guard !isActive else {
            resetIdleTimer()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(Self.noiseSuppression)
            if Self.noiseSuppression {
                // Voice processing ducks other audio by default; keep music and videos at their volume.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            let inFormat = input.outputFormat(forBus: 0)
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: AudioLoader.sampleRate,
                                                channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw AudioLoaderError.unsupportedFormat
            }
            let collector = self.collector
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / inFormat.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
                var consumed = false
                _ = converter.convert(to: out, error: nil) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return buffer
                }
                if let channel = out.floatChannelData?[0] {
                    collector.append(channel, count: Int(out.frameLength))
                }
            }
            engine.prepare()
            try engine.start()
            server.start()
            isActive = true
            message = "کیبورد آماده است. به اپ قبلی برگردید."
            resetIdleTimer()
            DictationBridge.post(DictationBridge.alive)
        } catch {
            message = "شروع جلسه ناموفق بود: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        liveTask?.cancel()
        liveTask = nil
        idleTimer?.invalidate()
        idleTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = collector.end()
        isCapturing = false
        server.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if isActive {
            message = "جلسه‌ی کیبورد تمام شد."
        }
        isActive = false
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        let minutes = Self.idleMinutes
        guard minutes > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    private func startCapture() {
        guard isActive else { return }
        collector.begin()
        isCapturing = true
        resetIdleTimer()
        DictationBridge.post(DictationBridge.recording)
        if Self.liveTranscription { startLiveTranscription(id: dictationID) }
    }

    /// While recording, transcribes the audio so far whenever enough new speech has arrived.
    private func startLiveTranscription(id: Int) {
        let minimumNew = Int(AudioLoader.sampleRate * 1.5)
        liveTask = Task { [weak self] in
            var transcribedCount = 0
            while let self, self.isCapturing, self.dictationID == id, !Task.isCancelled {
                let count = self.collector.count
                guard count >= Int(AudioLoader.sampleRate), count - transcribedCount >= minimumNew else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                transcribedCount = count
                guard let text = try? await Transcriber.shared.transcribe(samples: self.collector.snapshot()),
                      self.isCapturing, self.dictationID == id, !text.isEmpty else { continue }
                self.server.publish(DictationBridge.partialPrefix + text)
                DictationBridge.post(DictationBridge.partial)
            }
        }
    }

    /// Stops a live pass in progress and waits for it, so the final pass gets the model.
    private func stopLiveTranscription() async {
        guard let task = liveTask else { return }
        liveTask = nil
        task.cancel()
        Transcriber.shared.cancelTranscription()
        await task.value
    }

    private func finishCapture() {
        guard isActive, isCapturing else { return }
        isCapturing = false
        let samples = collector.end()
        resetIdleTimer()
        dictationID += 1
        let id = dictationID
        guard samples.count > Int(AudioLoader.sampleRate / 2) else {
            Task { await stopLiveTranscription() }
            DictationBridge.post(DictationBridge.failed)
            return
        }
        Task {
            await stopLiveTranscription()
            guard id == dictationID else { return }
            do {
                let text = try await Transcriber.shared.transcribe(samples: samples)
                guard id == dictationID else { return }
                guard !text.isEmpty else {
                    DictationBridge.post(DictationBridge.failed)
                    return
                }
                server.publish(DictationBridge.finalPrefix + text)
                DictationBridge.post(DictationBridge.done)
            } catch {
                if id == dictationID { DictationBridge.post(DictationBridge.failed) }
            }
        }
    }

    private func cancelDictation() {
        dictationID += 1
        liveTask?.cancel()
        liveTask = nil
        if isCapturing {
            isCapturing = false
            _ = collector.end()
        }
        Transcriber.shared.cancelTranscription()
    }
}

/// Collects converted samples from the audio thread while a recording is in progress.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// A copy of the recording so far, for a live pass.
    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func end() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        capturing = false
        let result = samples
        samples = []
        return result
    }

    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.lock()
        if capturing {
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        }
        lock.unlock()
    }
}
