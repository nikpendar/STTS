import AVFoundation
import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "dictation")

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
    private lazy var corrections = CorrectionServer { [weak self] correction in
        MainActor.assumeIsolated { self?.received(correction) }
    }
    /// Recent dictations by id, kept so a correction the keyboard reports later can be paired
    /// with its recording.
    private var recent: [(id: String, samples: [Float], text: String)] = []
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

    /// CI only: launch argument `-testAudio <path>` plays this file into recordings instead of
    /// the microphone, so the simulator can test dictation end to end.
    private let testAudio = UserDefaults.standard.string(forKey: "testAudio")
    private var testFeed: Task<Void, Never>?

    func start() {
        guard !isActive else {
            resetIdleTimer()
            return
        }
        // Loads the model now if nothing has yet, so the first live pass does not wait for it.
        _ = Transcriber.shared
        Task {
            await PersonalModel.shared.upload()
            await PersonalModel.shared.check(automatic: true)
        }
        if testAudio != nil {
            server.start()
            corrections.start()
            isActive = true
            DictationBridge.post(DictationBridge.alive)
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
            corrections.start()
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
        liveAbort.set()
        finalAbort.set()
        liveTask = nil
        idleTimer?.invalidate()
        idleTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        _ = collector.end()
        isCapturing = false
        server.stop()
        corrections.stop()
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
        log.info("recording started, live text \(Self.liveTranscription)")
        if Self.liveTranscription { startLiveTranscription(id: dictationID) }
        if let testAudio { feedTestAudio(testAudio) }
    }

    /// Appends the test file to the recording in real time, 0.1 s at a time.
    private func feedTestAudio(_ path: String) {
        guard let samples = try? AudioLoader.loadSamples(url: URL(fileURLWithPath: path)) else {
            log.error("cannot read test audio \(path, privacy: .public)")
            return
        }
        let chunk = Int(AudioLoader.sampleRate) / 10
        let collector = self.collector
        testFeed?.cancel()
        testFeed = Task.detached {
            var start = 0
            while start < samples.count, !Task.isCancelled {
                let end = min(start + chunk, samples.count)
                samples[start..<end].withUnsafeBufferPointer { collector.append($0.baseAddress!, count: $0.count) }
                start = end
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Live mode: text of the pieces already committed, and how many samples they cover.
    private var committedText = ""
    private var committedCount = 0
    /// Stops the live pass in progress, and the final pass.
    private var liveAbort = AbortFlag()
    private var finalAbort = AbortFlag()

    /// While recording, transcribes the uncommitted part of the recording whenever enough new
    /// audio has arrived. Once that part is 10 s long, everything up to a pause is committed,
    /// so a pass never covers more than 20 s and the final pass only the last piece. Passes over
    /// the whole recording got slower as it grew and fell behind on long dictations.
    private func startLiveTranscription(id: Int) {
        let rate = Int(AudioLoader.sampleRate)
        committedText = ""
        committedCount = 0
        liveAbort = AbortFlag()
        let abort = liveAbort
        liveTask = Task { [weak self] in
            log.info("live loop started")
            defer { log.info("live loop ended") }
            var passedCount = 0
            while let self, self.isCapturing, self.dictationID == id, !abort.isSet {
                let count = self.collector.count
                guard count - self.committedCount >= rate, count - passedCount >= rate * 3 / 2 else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                passedCount = count
                log.info("live pass starting at \(Double(count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s")
                let tail = self.collector.snapshot(from: self.committedCount)
                let cut = tail.count >= rate * 10 ? Self.pause(in: tail) : nil
                let piece = cut.map { Array(tail[..<$0]) } ?? tail
                let started = Date()
                let text: String
                do {
                    text = try await Transcriber.shared.transcribe(samples: piece, abort: abort, preview: cut == nil)
                } catch {
                    log.info("live pass failed after \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                guard self.isCapturing, self.dictationID == id else { continue }
                log.info("live pass: \(Double(piece.count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s, cut \(cut ?? -1), \(text.count) chars")
                if let cut {
                    self.committedText = Self.join(self.committedText, text)
                    self.committedCount += cut
                }
                let shown = cut == nil ? Self.join(self.committedText, text) : self.committedText
                guard !shown.isEmpty else { continue }
                self.server.publish(DictationBridge.partialPrefix + shown)
                DictationBridge.post(DictationBridge.partial)
            }
        }
    }

    /// Where to split a piece of at least 10 s: the latest pause after 6 s (0.3 s quieter than a
    /// third of the average level), else, once the piece reaches 20 s, its quietest point after 10 s.
    private static func pause(in samples: [Float]) -> Int? {
        let frame = Int(AudioLoader.sampleRate) / 10
        let levels = stride(from: 0, to: samples.count - frame + 1, by: frame).map { start in
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            return (sum / Float(frame)).squareRoot()
        }
        guard levels.count > 64 else { return nil }
        let quiet = levels.reduce(0, +) / Float(levels.count) / 3
        for i in stride(from: levels.count - 3, through: 61, by: -1)
        where levels[i - 1] < quiet && levels[i] < quiet && levels[i + 1] < quiet {
            return i * frame + frame / 2
        }
        guard levels.count >= 200 else { return nil }
        let quietest = (100..<200).min { levels[$0] < levels[$1] } ?? 150
        return quietest * frame + frame / 2
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    /// Stops a live pass in progress and waits for it, so the final pass gets the model.
    private func stopLiveTranscription() async {
        liveAbort.set()
        guard let task = liveTask else { return }
        liveTask = nil
        await task.value
    }

    private func finishCapture() {
        guard isActive, isCapturing else { return }
        isCapturing = false
        testFeed?.cancel()
        let samples = collector.end()
        resetIdleTimer()
        dictationID += 1
        let id = dictationID
        let live = liveTask != nil
        finalAbort = AbortFlag()
        let abort = finalAbort
        Task {
            await stopLiveTranscription()
            guard id == dictationID else { return }
            // With live text, only the piece after the last committed one is left to transcribe.
            let prefix = live ? committedText : ""
            let rest = live ? Array(samples[min(committedCount, samples.count)...]) : samples
            do {
                var text = prefix
                if rest.count > Int(AudioLoader.sampleRate / 2) {
                    let estimate = Transcriber.shared.estimatedSeconds(sampleCount: rest.count)
                    server.publish(DictationBridge.estimatePrefix + String(format: "%.1f", estimate))
                    DictationBridge.post(DictationBridge.progress)
                    let started = Date()
                    text = Self.join(prefix, try await Transcriber.shared.transcribe(samples: rest, abort: abort))
                    log.info("final pass: \(Double(rest.count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s, estimate \(estimate, format: .fixed(precision: 1)) s")
                }
                guard id == dictationID else { return }
                guard !text.isEmpty else {
                    DictationBridge.post(DictationBridge.failed)
                    return
                }
                let dictation = UUID().uuidString
                // Training uses recordings of up to 30 s (`PersonalModel.add`).
                if samples.count <= 30 * Int(AudioLoader.sampleRate) {
                    recent.append((dictation, samples, text))
                    if recent.count > 8 { recent.removeFirst() }
                }
                server.publish(DictationBridge.finalPrefix + dictation + "\n" + text)
                DictationBridge.post(DictationBridge.done)
            } catch {
                if id == dictationID { DictationBridge.post(DictationBridge.failed) }
            }
        }
    }

    private func received(_ correction: Correction) {
        guard let dictation = recent.first(where: { $0.id == correction.id }) else { return }
        log.info("correction for \(correction.id, privacy: .public)")
        PersonalModel.shared.add(id: correction.id, samples: dictation.samples,
                                 original: dictation.text, corrected: correction.corrected)
    }

    private func cancelDictation() {
        dictationID += 1
        liveAbort.set()
        finalAbort.set()
        liveTask = nil
        if isCapturing {
            isCapturing = false
            _ = collector.end()
        }
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

    /// A copy of the recording from sample `start` on, for a live pass.
    func snapshot(from start: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples[min(start, samples.count)...])
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
