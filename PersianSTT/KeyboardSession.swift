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
        server.clear()
        isCapturing = true
        resetIdleTimer()
        DictationBridge.post(DictationBridge.recording)
        log.info("recording started, live text \(Self.liveTranscription)")
        if Self.liveTranscription { startLiveTranscription() }
        if let testAudio { feedTestAudio(testAudio) }
    }

    /// Appends the test file to the recording in real time, 0.1 s at a time, then silence, as
    /// a microphone in a quiet room would.
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

    /// Live mode: text of the pieces already committed, and how many samples they cover.
    private var committedText = ""
    private var committedCount = 0
    /// Text of a full pass over all of the uncommitted audio, run when the speaker paused. If
    /// only silence follows it when the recording stops, it is the final text and the final
    /// pass is skipped.
    private var candidate: (start: Int, end: Int, text: String)?
    /// The live pass in progress: stopping waits for a full pass and drops a preview.
    private var livePass: LivePass?
    /// Stops the live pass in progress, and the final pass.
    private var liveAbort = AbortFlag()
    private var finalAbort = AbortFlag()

    private struct LivePass {
        enum Kind {
            /// Quick provisional text of the uncommitted audio.
            case preview
            /// The uncommitted audio up to a pause, transcribed in full and kept.
            case commit
            /// All of the uncommitted audio once the speaker paused, transcribed in full.
            case candidate
        }
        let kind: Kind
        let start: Int
        let end: Int
        let started: Date
        let estimate: Double
    }

    /// While recording, transcribes the uncommitted part of the recording whenever enough new
    /// audio has arrived. Once that part is 10 s long, everything up to a pause is committed,
    /// so a pass never covers more than 20 s and the final pass only the last piece. Passes over
    /// the whole recording got slower as it grew and fell behind on long dictations. When the
    /// speaker pauses, the uncommitted part gets a full pass, which is usually the final text.
    private func startLiveTranscription() {
        let rate = Int(AudioLoader.sampleRate)
        committedText = ""
        committedCount = 0
        candidate = nil
        liveAbort.set()
        liveAbort = AbortFlag()
        let abort = liveAbort
        liveTask = Task { [weak self] in
            log.info("live loop started")
            defer { log.info("live loop ended") }
            var passedCount = 0
            while let self, self.isCapturing, !abort.isSet {
                let count = self.collector.count
                let levels = self.collector.levels()
                let speech = Self.speech(levels, from: self.committedCount)
                let kind: LivePass.Kind
                let piece: [Float]
                if let speech, speech.paused, count - self.committedCount >= rate,
                   !(self.candidate.map { $0.start == self.committedCount && $0.end >= speech.end } ?? false) {
                    kind = .candidate
                    piece = self.collector.snapshot(from: self.committedCount)
                } else if speech?.paused == false, count - self.committedCount >= rate, count - passedCount >= rate * 3 / 2 {
                    let tail = self.collector.snapshot(from: self.committedCount)
                    let cut = tail.count >= rate * 10 ? Self.pause(in: tail) : nil
                    kind = cut == nil ? .preview : .commit
                    piece = cut.map { Array(tail[..<$0]) } ?? tail
                } else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                passedCount = count
                let start = self.committedCount
                let estimate = Transcriber.shared.estimatedSeconds(sampleCount: piece.count, preview: kind == .preview)
                self.livePass = LivePass(kind: kind, start: start, end: start + piece.count, started: Date(), estimate: estimate)
                self.publishLive(estimate)
                log.info("live pass (\(String(describing: kind), privacy: .public)) starting at \(Double(count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s, estimate \(estimate, format: .fixed(precision: 1)) s")
                let started = Date()
                let text: String
                do {
                    text = try await Transcriber.shared.transcribe(samples: piece, abort: abort, preview: kind == .preview) { [weak self] remaining in
                        if self?.isCapturing == true { self?.publishLive(remaining) }
                    }
                } catch {
                    self.livePass = nil
                    log.info("live pass failed after \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s: \(error.localizedDescription, privacy: .public)")
                    // Empty text: nothing changes but the keyboard's live ring.
                    if self.isCapturing { self.publishPartial("") }
                    continue
                }
                self.livePass = nil
                log.info("live pass: \(Double(piece.count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s, \(String(describing: kind), privacy: .public), \(text.count) chars")
                // A full pass is kept even if the recording stopped meanwhile; the final pass uses it.
                guard !abort.isSet else { break }
                switch kind {
                case .commit:
                    self.committedText = Self.join(self.committedText, text)
                    self.committedCount = start + piece.count
                    self.candidate = nil
                case .candidate where piece.count >= rate * 10:
                    self.committedText = Self.join(self.committedText, text)
                    self.committedCount = start + piece.count
                    self.candidate = nil
                case .candidate:
                    self.candidate = (start, start + piece.count, text)
                case .preview:
                    break
                }
                guard self.isCapturing else { break }
                let shown = kind == .preview || kind == .candidate && self.candidate != nil
                    ? Self.join(self.committedText, text) : self.committedText
                self.publishPartial(shown)
            }
        }
    }

    /// Provisional text for the keyboard; empty text leaves the typed text as it is.
    private func publishPartial(_ text: String) {
        server.publish(DictationBridge.partialPrefix + text)
        DictationBridge.post(DictationBridge.partial)
    }

    private func publishLive(_ seconds: Double) {
        server.publish(DictationBridge.livePrefix + String(format: "%.1f", seconds))
        DictationBridge.post(DictationBridge.progress)
    }

    private func publishEstimate(_ seconds: Double) {
        server.publish(DictationBridge.estimatePrefix + String(format: "%.1f", seconds))
        DictationBridge.post(DictationBridge.progress)
    }

    /// Recording levels are kept per 0.1 s frame (`SampleCollector.levels`).
    private static let frame = Int(AudioLoader.sampleRate) / 10

    /// Below this level a frame counts as silence: 15% of the recording's speech level, taken as
    /// the 90th percentile of its frame levels.
    private static func quietLevel(_ levels: [Float]) -> Float {
        guard !levels.isEmpty else { return 0 }
        let sorted = levels.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.9)] * 0.15
    }

    /// Where speech in the recording from sample `start` on ends (in samples), and whether at
    /// least 0.6 s of silence follows it; nil without speech.
    private static func speech(_ levels: [Float], from start: Int) -> (end: Int, paused: Bool)? {
        let quiet = quietLevel(levels)
        let first = min(levels.count, start / frame)
        guard levels[first...].contains(where: { $0 >= 3 * quiet }),
              let last = levels[first...].lastIndex(where: { $0 >= quiet }) else { return nil }
        return ((last + 1) * frame, levels.count - 1 - last >= 6)
    }

    /// Whether the recording from sample `start` on is all silence.
    private static func isSilent(_ levels: [Float], from start: Int) -> Bool {
        let quiet = quietLevel(levels)
        let first = min(levels.count, (start + frame - 1) / frame)
        return levels[first...].allSatisfy { $0 < quiet }
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

    /// Waits for the live loop to end. A preview in progress is stopped (its encoder still runs
    /// to the end, as whisper.cpp only checks between steps); a full pass is left to finish,
    /// since its text is kept.
    private func stopLiveTranscription() async {
        if livePass?.kind == .preview { liveAbort.set() }
        guard let task = liveTask else { return }
        liveTask = nil
        await task.value
    }

    /// The first estimate for the processing ring, before the live loop has ended.
    private func estimateAfterStop(samples: Int, levels: [Float]) -> Double {
        var wait = 0.0
        var restStart = committedCount
        if let pass = livePass {
            let elapsed = Date().timeIntervalSince(pass.started)
            switch pass.kind {
            case .preview:
                wait = max(0, Transcriber.shared.estimatedEncodeSeconds(sampleCount: pass.end - pass.start) - elapsed)
            case .commit:
                wait = max(0, pass.estimate - elapsed)
                restStart = pass.end
            case .candidate:
                wait = max(0, pass.estimate - elapsed)
                if Self.isSilent(levels, from: pass.end) { return wait }
                if pass.end - pass.start >= Int(AudioLoader.sampleRate) * 10 { restStart = pass.end }
            }
        } else if let candidate, candidate.start == committedCount, Self.isSilent(levels, from: candidate.end) {
            return 0
        }
        if committedCount > 0, Self.isSilent(levels, from: restStart) { return wait }
        return wait + Transcriber.shared.estimatedSeconds(sampleCount: max(0, samples - restStart))
    }

    private func finishCapture() {
        guard isActive, isCapturing else { return }
        isCapturing = false
        testFeed?.cancel()
        let levels = collector.levels()
        let samples = collector.end()
        resetIdleTimer()
        dictationID += 1
        let id = dictationID
        let live = liveTask != nil
        finalAbort = AbortFlag()
        let abort = finalAbort
        if samples.count <= 30 * Int(AudioLoader.sampleRate) { SpeedTest.save(samples) }
        if live { publishEstimate(estimateAfterStop(samples: samples.count, levels: levels)) }
        Task {
            await stopLiveTranscription()
            guard id == dictationID else { return }
            // With live text, only the piece after the last committed one is left to transcribe.
            let restStart = live ? min(committedCount, samples.count) : 0
            do {
                var text = live ? committedText : ""
                if live, let candidate, candidate.start == committedCount, Self.isSilent(levels, from: candidate.end) {
                    text = Self.join(text, candidate.text)
                    log.info("final pass: not needed, the pass from the pause is final")
                } else if live, committedCount > 0, Self.isSilent(levels, from: restStart) {
                    log.info("final pass: not needed, only silence after the committed text")
                } else if samples.count - restStart > Int(AudioLoader.sampleRate / 2) {
                    let rest = Array(samples[restStart...])
                    let estimate = Transcriber.shared.estimatedSeconds(sampleCount: rest.count)
                    publishEstimate(estimate)
                    let started = Date()
                    let piece = try await Transcriber.shared.transcribe(samples: rest, abort: abort) { [weak self] remaining in
                        if id == self?.dictationID { self?.publishEstimate(remaining) }
                    }
                    text = Self.join(text, piece)
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

/// Collects converted samples from the audio thread while a recording is in progress, and the
/// level (RMS) of each 0.1 s of it, by which pauses are found.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var frameLevels: [Float] = []
    private var frameSum: Float = 0
    private var frameCount = 0
    private var capturing = false
    private static let frame = Int(AudioLoader.sampleRate) / 10

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        frameLevels.removeAll(keepingCapacity: true)
        frameSum = 0
        frameCount = 0
        capturing = true
        lock.unlock()
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
            let buffer = UnsafeBufferPointer(start: pointer, count: count)
            samples.append(contentsOf: buffer)
            for sample in buffer {
                frameSum += sample * sample
                frameCount += 1
                if frameCount == Self.frame {
                    frameLevels.append((frameSum / Float(Self.frame)).squareRoot())
                    frameSum = 0
                    frameCount = 0
                }
            }
        }
        lock.unlock()
    }
}
