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

    /// Seconds of silence after speech that end the recording by themselves; 0 never does.
    static let autoStopKey = "autoStopSeconds"
    static let defaultAutoStop = 2.0
    static var autoStopSeconds: Double {
        UserDefaults.standard.object(forKey: autoStopKey) as? Double ?? defaultAutoStop
    }
    /// A recording in which nobody speaks for this long is dropped without transcribing it.
    static let noSpeechSeconds = 8.0

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
    /// Feeds the recording to the model while it comes in (`startStreaming`).
    private var streamTask: Task<Void, Never>?
    /// Samples of the current recording the model has been given.
    private var fedCount = 0
    /// The stream failed during the recording, so the final text comes from the whole recording.
    private var streamFailed = false
    /// Watches the recording: the level for the keyboard's orb, and the end of speech.
    private var monitorTask: Task<Void, Never>?
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
            MainActor.assumeIsolated { self?.startCapture(held: false) }
        }
        observer.observe(DictationBridge.startHeld) { [weak self] in
            MainActor.assumeIsolated { self?.startCapture(held: true) }
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
    /// The test file plays into the first recording only; later ones get silence, to test a
    /// recording in which nobody speaks.
    private var testRecordings = 0

    func start() {
        guard !isActive else {
            resetIdleTimer()
            return
        }
        // Loads the model now if nothing has yet, so the first dictation does not wait for it.
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
        dictationID += 1
        streamTask = nil
        monitorTask?.cancel()
        monitorTask = nil
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

    /// `held`: the keyboard's space bar is held; the keyboard ends the recording, not a silence.
    private func startCapture(held: Bool) {
        guard isActive else { return }
        Self.ambientNoise = collector.begin()
        server.clear()
        isCapturing = true
        dictationID += 1
        resetIdleTimer()
        DictationBridge.post(DictationBridge.recording)
        log.info("recording started, \(held ? "held" : "auto stop \(Self.autoStopSeconds) s", privacy: .public)")
        startStreaming(id: dictationID)
        startMonitor(held: held)
        if let testAudio { feedTestAudio(testAudio) }
    }

    /// Every 0.05 s while recording: sends the level of the latest 0.1 s of audio to the
    /// keyboard (as one of `DictationBridge.levels` notifications, only when it changes), so the
    /// orb keeps up with the voice; twice a second it drops a recording in which nobody has
    /// spoken for `noSpeechSeconds`, and ends one after `autoStopSeconds` of silence following speech.
    /// The longest a held (or locked) recording runs.
    static let heldLimitSeconds = 300.0

    private func startMonitor(held: Bool) {
        monitorTask?.cancel()
        let autoStop = Self.autoStopSeconds
        monitorTask = Task { [weak self] in
            var lastStep = -1
            var checked = 0
            while !Task.isCancelled, let self, self.isCapturing {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, self.isCapturing else { break }
                let level = self.collector.recentLevel(Int(AudioLoader.sampleRate) / 10)
                let db = 20 * log10(max(level, 1e-6))
                let step = min(DictationBridge.levels - 1, max(0, Int((db + 55) / 2)))
                if step != lastStep {
                    lastStep = step
                    DictationBridge.post(DictationBridge.level(step))
                }
                // Speech decisions twice a second are enough, and none while the space bar is held,
                // except a limit on its length, should the keyboard never say it was let go.
                let levels = self.collector.levels()
                if held {
                    if Double(levels.count) / 10 >= Self.heldLimitSeconds {
                        log.info("held recording reached \(Self.heldLimitSeconds, format: .fixed(precision: 0)) s; stopped")
                        DictationBridge.post(DictationBridge.stopped)
                        self.finishCapture()
                        break
                    }
                    continue
                }
                guard levels.count - checked >= 5 else { continue }
                checked = levels.count
                let seconds = Double(levels.count) / 10
                guard let speech = Self.speechFrames(levels, from: 0) else {
                    if seconds >= Self.noSpeechSeconds {
                        log.info("no speech in \(seconds, format: .fixed(precision: 1)) s; recording dropped")
                        self.dropRecording()
                        break
                    }
                    continue
                }
                let silence = Double(levels.count - 1 - speech.upperBound) / 10
                if autoStop > 0, silence >= autoStop {
                    log.info("auto stop after \(silence, format: .fixed(precision: 1)) s of silence")
                    DictationBridge.post(DictationBridge.stopped)
                    self.finishCapture()
                    break
                }
            }
        }
    }

    /// Ends a recording without transcribing it, because nobody spoke.
    private func dropRecording() {
        cancelDictation()
        testFeed?.cancel()
        DictationBridge.post(DictationBridge.idle)
    }

    /// Appends the test file to the recording in real time, 0.1 s at a time, then silence, as
    /// a microphone in a quiet room would.
    private func feedTestAudio(_ path: String) {
        testRecordings += 1
        var samples: [Float] = []
        if testRecordings == 1 {
            guard let file = try? AudioLoader.loadSamples(url: URL(fileURLWithPath: path)) else {
                log.error("cannot read test audio \(path, privacy: .public)")
                return
            }
            samples = file
        }
        let chunk = Int(AudioLoader.sampleRate) / 10
        let collector = self.collector
        testFeed?.cancel()
        testFeed = Task.detached {
            var start = 0
            let silence = [Float](repeating: 0, count: chunk)
            while !Task.isCancelled {
                if start < samples.count {
                    let end = min(start + chunk, samples.count)
                    samples[start..<end].withUnsafeBufferPointer { collector.append($0.baseAddress!, count: $0.count) }
                    start = end
                } else {
                    silence.withUnsafeBufferPointer { collector.append($0.baseAddress!, count: $0.count) }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Gives the model each new 0.1 s of the recording as it comes in. The model writes text as
    /// the user speaks, so when the recording stops only the last fraction of a second is left,
    /// and the keyboard shows the text so far.
    private func startStreaming(id: Int) {
        fedCount = 0
        streamFailed = false
        streamTask = Task { [weak self] in
            guard let engine = await Transcriber.shared.readyEngine() else {
                log.error("no model for the dictation")
                return
            }
            await engine.begin()
            var latest = ""
            var shown = ""
            var shownAt = Date.distantPast
            while let self, self.isCapturing, id == self.dictationID {
                let piece = self.collector.snapshot(from: self.fedCount)
                if !piece.isEmpty {
                    self.fedCount += piece.count
                    do {
                        if let text = try await engine.feed(piece) { latest = text }
                    } catch {
                        log.error("stream failed: \(error.localizedDescription, privacy: .public)")
                        self.streamFailed = true
                        return
                    }
                }
                // A new word can come every 80 ms; the keyboard gets the text at most 4 times a second.
                if latest != shown, Date().timeIntervalSince(shownAt) >= 0.25, id == self.dictationID, self.isCapturing {
                    shown = latest
                    shownAt = Date()
                    self.publishPartial(latest)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Provisional text for the keyboard.
    private func publishPartial(_ text: String) {
        server.publish(DictationBridge.partialPrefix + text)
        DictationBridge.post(DictationBridge.partial)
    }

    private func publishEstimate(_ seconds: Double) {
        server.publish(DictationBridge.estimatePrefix + String(format: "%.1f", seconds))
        DictationBridge.post(DictationBridge.progress)
    }

    /// Level of the room just before the current recording, if the microphone was on.
    private static var ambientNoise: Float?

    /// Speech detection on the levels of 0.1 s frames. Speech lasts as long as frames stay above
    /// `quiet`: 15% of the recording's speech level (90th percentile), but at least three times
    /// the noise floor. It needs 0.3 s of frames twice as loud, and above a fixed floor (-48 dB)
    /// that silence stays under. Without the floors, the loudest tenth of a silent recording
    /// counted as speech and was transcribed.
    /// The noise floor is the quieter of the room before the recording (`SampleCollector`) and
    /// the quietest 0.3 s of the recording: a percentile of the recording alone is speech when
    /// someone talks without a pause, and then no speech was found at all.
    private struct Thresholds {
        let loud: Float
        let quiet: Float

        init(_ levels: [Float], ambient: Float?) {
            guard !levels.isEmpty else {
                loud = .infinity
                quiet = .infinity
                return
            }
            let sorted = levels.sorted()
            var quietest = sorted[0]
            if levels.count >= 3 {
                quietest = (1..<(levels.count - 1)).lazy.map { i -> Float in
                    let a = levels[i - 1], b = levels[i], c = levels[i + 1]
                    return max(min(a, b), min(max(a, b), c))
                }.min() ?? quietest
            }
            let noise = max(min(quietest, ambient ?? .infinity), 0.0003)
            let quiet = max(0.15 * sorted[Int(Double(sorted.count - 1) * 0.9)], 3 * noise, 0.0015)
            self.quiet = quiet
            loud = max(2 * quiet, 0.004)
        }
    }

    /// The frames in `first..<last` (to the end by default) that hold speech, from the first to
    /// the last frame above `quiet` (single-frame clicks ignored); nil if they have less than
    /// 0.3 s of loud audio.
    private static func speechFrames(_ levels: [Float], from first: Int, to last: Int? = nil) -> ClosedRange<Int>? {
        let last = min(last ?? levels.count, levels.count)
        let first = min(max(0, first), last)
        guard last - first >= 3 else { return nil }
        let t = Thresholds(levels, ambient: ambientNoise)
        guard levels[first..<last].lazy.filter({ $0 >= t.loud }).count >= 3 else { return nil }
        // Median of three neighbours, so a lone click or crackle does not extend the speech.
        func smoothed(_ i: Int) -> Float {
            let a = levels[max(first, i - 1)], b = levels[i], c = levels[min(last - 1, i + 1)]
            return max(min(a, b), min(max(a, b), c))
        }
        guard let start = (first..<last).first(where: { smoothed($0) >= t.quiet }),
              let end = (first..<last).last(where: { smoothed($0) >= t.quiet }) else { return nil }
        return start...end
    }

    /// Ends the recording: the model gets the audio it has not had yet and finishes the text.
    private func finishCapture() {
        guard isActive, isCapturing else { return }
        isCapturing = false
        testFeed?.cancel()
        let levels = collector.levels()
        let samples = collector.end()
        resetIdleTimer()
        let id = dictationID
        let feeding = streamTask
        streamTask = nil
        Task {
            // The feeder stops at its next turn; the samples it took are then counted in `fedCount`.
            await feeding?.value
            guard id == dictationID else { return }
            guard let engine = await Transcriber.shared.readyEngine() else {
                DictationBridge.post(DictationBridge.failed)
                return
            }
            let rest = streamFailed ? samples : Array(samples[min(fedCount, samples.count)...])
            let speed = await engine.secondsPerAudioSecond
            publishEstimate(0.2 + speed * Double(rest.count) / AudioLoader.sampleRate)
            let started = Date()
            do {
                let raw = streamFailed ? try await engine.transcribe(samples) : try await engine.finish(rest)
                guard id == dictationID else { return }
                log.info("final text: \(Double(rest.count) / AudioLoader.sampleRate, format: .fixed(precision: 2)) s of audio left, done in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
                let text = raw.trimmingCharacters(in: .whitespaces)
                guard !DictationBridge.removingPauseMarks(text).isEmpty else {
                    if Self.speechFrames(levels, from: 0) == nil {
                        log.info("final text: no speech")
                        DictationBridge.post(DictationBridge.idle)
                    } else {
                        DictationBridge.post(DictationBridge.failed)
                    }
                    return
                }
                let dictation = UUID().uuidString
                // Training uses recordings of up to 30 s (`PersonalModel.add`).
                if samples.count <= 30 * Int(AudioLoader.sampleRate) {
                    recent.append((dictation, samples, DictationBridge.removingPauseMarks(text)))
                    if recent.count > 8 { recent.removeFirst() }
                }
                server.publish(DictationBridge.finalPrefix + dictation + "\n" + text)
                DictationBridge.post(DictationBridge.done)
            } catch {
                guard id == dictationID else { return }
                log.error("final text failed: \(error.localizedDescription, privacy: .public)")
                DictationBridge.post(DictationBridge.failed)
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
        monitorTask?.cancel()
        monitorTask = nil
        dictationID += 1
        streamTask = nil
        if isCapturing {
            isCapturing = false
            _ = collector.end()
        }
    }
}

/// Collects converted samples from the audio thread while a recording is in progress, and the
/// level (RMS) of each 0.1 s of it, by which speech and silence are found. Between recordings it keeps the
/// levels of the last 3 s, the room's noise.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var frameLevels: [Float] = []
    private var ambient: [Float] = []
    private var frameSum: Float = 0
    private var frameCount = 0
    private var capturing = false
    private static let frame = Int(AudioLoader.sampleRate) / 10

    /// Starts a recording; returns the room's level before it (the 30th percentile of the last
    /// 3 s), or nil if the microphone was not on long enough.
    func begin() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        let sorted = ambient.sorted()
        samples.removeAll(keepingCapacity: true)
        frameLevels.removeAll(keepingCapacity: true)
        ambient.removeAll(keepingCapacity: true)
        frameSum = 0
        frameCount = 0
        capturing = true
        return sorted.count >= 10 ? sorted[sorted.count * 3 / 10] : nil
    }

    /// Levels of the complete 0.1 s frames so far.
    func levels() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return frameLevels
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// Level of the last `count` samples of the recording.
    func recentLevel(_ count: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        let n = min(count, samples.count)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for sample in samples[(samples.count - n)...] { sum += sample * sample }
        return (sum / Float(n)).squareRoot()
    }

    /// A copy of the recording from sample `start` on, for the model.
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
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        if capturing { samples.append(contentsOf: buffer) }
        for sample in buffer {
            frameSum += sample * sample
            frameCount += 1
            if frameCount == Self.frame {
                let level = (frameSum / Float(Self.frame)).squareRoot()
                if capturing {
                    frameLevels.append(level)
                } else {
                    ambient.append(level)
                    if ambient.count > 30 { ambient.removeFirst() }
                }
                frameSum = 0
                frameCount = 0
            }
        }
        lock.unlock()
    }
}
