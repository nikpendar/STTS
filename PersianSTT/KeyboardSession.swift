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
    private var liveTask: Task<Void, Never>?
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
    /// The test file plays into the first recording only; later ones get silence, to test a
    /// recording in which nobody speaks.
    private var testRecordings = 0

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

    private func startCapture() {
        guard isActive else { return }
        Self.ambientNoise = collector.begin()
        server.clear()
        isCapturing = true
        resetIdleTimer()
        DictationBridge.post(DictationBridge.recording)
        log.info("recording started, live text \(Self.liveTranscription), auto stop \(Self.autoStopSeconds) s")
        if Self.liveTranscription { startLiveTranscription() }
        startMonitor()
        if let testAudio { feedTestAudio(testAudio) }
    }

    /// Every 0.1 s while recording: sends the level of the latest audio to the keyboard (as one
    /// of `DictationBridge.levels` notifications, only when it changes), drops a recording in
    /// which nobody has spoken for `noSpeechSeconds`, and ends one after `autoStopSeconds` of
    /// silence following speech.
    private func startMonitor() {
        monitorTask?.cancel()
        let autoStop = Self.autoStopSeconds
        monitorTask = Task { [weak self] in
            var lastStep = -1
            var checked = 0
            while !Task.isCancelled, let self, self.isCapturing {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, self.isCapturing else { break }
                let levels = self.collector.levels()
                guard let latest = levels.last else { continue }
                // Two frames, so a short syllable still moves the orb.
                let level = max(latest, levels.count > 1 ? levels[levels.count - 2] : 0)
                let db = 20 * log10(max(level, 1e-6))
                let step = min(DictationBridge.levels - 1, max(0, Int((db + 55) / 4)))
                if step != lastStep {
                    lastStep = step
                    DictationBridge.post(DictationBridge.level(step))
                }
                // Speech decisions twice a second are enough.
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
                // Only the speech in the piece is transcribed; the piece still counts as done.
                let audio = Self.trimmed(levels, start, start + piece.count)
                    .map { Array(piece[($0.lowerBound - start)..<($0.upperBound - start)]) } ?? []
                let estimate = Transcriber.shared.estimatedSeconds(sampleCount: audio.count, preview: kind == .preview)
                self.livePass = LivePass(kind: kind, start: start, end: start + piece.count, started: Date(), estimate: estimate)
                if !audio.isEmpty { self.publishLive(estimate) }
                log.info("live pass (\(String(describing: kind), privacy: .public)) starting at \(Double(count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s, \(Double(audio.count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s of speech, estimate \(estimate, format: .fixed(precision: 1)) s")
                let started = Date()
                var text = ""
                do {
                    if !audio.isEmpty {
                        text = try await Transcriber.shared.transcribe(samples: audio, abort: abort, preview: kind == .preview) { [weak self] remaining in
                            if self?.isCapturing == true { self?.publishLive(remaining) }
                        }
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

    /// Where speech in the recording from sample `start` on ends (in samples), and whether at
    /// least 0.6 s of silence follows it; nil without speech.
    private static func speech(_ levels: [Float], from start: Int) -> (end: Int, paused: Bool)? {
        guard let frames = speechFrames(levels, from: start / frame) else { return nil }
        return ((frames.upperBound + 1) * frame, levels.count - 1 - frames.upperBound >= 6)
    }

    /// Whether the recording from sample `start` on has no speech.
    private static func isSilent(_ levels: [Float], from start: Int) -> Bool {
        speechFrames(levels, from: (start + frame - 1) / frame) == nil
    }

    /// The part of samples `start..<end` that holds speech, with 0.3 s before it and 0.5 s after
    /// it, so the model is not fed silence; nil if there is no speech.
    private static func trimmed(_ levels: [Float], _ start: Int, _ end: Int) -> Range<Int>? {
        let endFrame = (end + frame - 1) / frame
        guard end > start, let frames = speechFrames(levels, from: start / frame, to: endFrame) else { return nil }
        let from = max(start, (frames.lowerBound - 3) * frame)
        // Speech up to the last complete frame: the audio after it may be the start of a word.
        let to = frames.upperBound + 1 >= levels.count ? end : min(end, (frames.upperBound + 1 + 5) * frame)
        return from < to ? from..<to : nil
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
        guard let rest = Self.trimmed(levels, restStart, samples) else { return wait }
        return wait + Transcriber.shared.estimatedSeconds(sampleCount: rest.count)
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
                } else if let speech = Self.trimmed(levels, restStart, samples.count) {
                    let rest = Array(samples[speech])
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
                    if Self.speechFrames(levels, from: 0) == nil {
                        log.info("final pass: no speech")
                        DictationBridge.post(DictationBridge.idle)
                    } else {
                        DictationBridge.post(DictationBridge.failed)
                    }
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
        monitorTask?.cancel()
        monitorTask = nil
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
/// level (RMS) of each 0.1 s of it, by which pauses are found. Between recordings it keeps the
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
