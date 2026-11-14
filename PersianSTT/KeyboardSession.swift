import AVFoundation
import UIKit
import UserNotifications
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
    /// Watches the recording: the level for the keyboard's voice wave, and the end of speech.
    private var monitorTask: Task<Void, Never>?
    private(set) var isCapturing = false
    /// Identifies the current dictation, so a cancelled one cannot report a late result.
    private var dictationID = 0

    /// The keyboard went off screen during a locked recording at this time (nil otherwise):
    /// the recording goes on only if the screen locked, and its text waits for the keyboard to
    /// come back to the same text field (Rooz, 2026-11-14).
    private var awaySince: Date?
    /// The screen locked while the keyboard was away (protected data went away: needs a passcode).
    private var screenLocked = false
    /// The screen was unlocked again at this time, the keyboard still away.
    private var unlockedAt: Date?
    /// The recording ended while the keyboard was away; its final text waits for it.
    private var awayFinished = false
    private var awayTimer: Timer?
    /// When the live text last changed, for ending a recording after a silence while locked.
    private var lastPartialAt = Date()
    private var lastPartialText = ""
    /// iOS locks protected data about 10 s after the screen locks; without it by then, another
    /// app was opened and the recording is cancelled.
    static let lockWaitSeconds = 20.0
    /// After unlocking, the keyboard has this long to come back to the recording.
    static let rejoinWaitSeconds = 30.0
    private static let recordingNotice = "avak.recording"

    private init() {
        observer.observe(DictationBridge.away) { [weak self] in
            MainActor.assumeIsolated { self?.keyboardLeft() }
        }
        observer.observe(DictationBridge.rejoin) { [weak self] in
            MainActor.assumeIsolated { self?.keyboardReturned() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenDidLock() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenDidUnlock() }
        }
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
        observer.observe(DictationBridge.pause) { [weak self] in
            MainActor.assumeIsolated { self?.setPaused(true) }
        }
        observer.observe(DictationBridge.resume) { [weak self] in
            MainActor.assumeIsolated { self?.setPaused(false) }
        }
        observer.observe(DictationBridge.cancel) { [weak self] in
            MainActor.assumeIsolated { self?.cancelDictation() }
        }
        // A call or Siri pauses the engine; it is restarted when the interruption ends.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch raw.flatMap(AVAudioSession.InterruptionType.init) {
            case .began:
                // iOS took the microphone: the recording pauses (what was said stays) until the
                // keyboard resumes it.
                MainActor.assumeIsolated { self?.interrupted() }
            case .ended:
                MainActor.assumeIsolated { self?.resume() }
            default:
                break
            }
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
    private let testAudio = TestHooks.string("testAudio")
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
        // A recording that goes on while the screen is locked says so on the lock screen.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
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
            message = "روشن کردن تایپ صوتی ناموفق بود: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        endAway()
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
            message = "تایپ صوتی خاموش شد."
            DictationBridge.post(DictationBridge.ended)
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
        endAway()
        lastPartialText = ""
        isCapturing = true
        pausedSince = nil
        dictationID += 1
        resetIdleTimer()
        DictationBridge.post(DictationBridge.recording)
        log.info("recording started\(held ? ", held" : "", privacy: .public)")
        startStreaming(id: dictationID)
        startMonitor(held: held)
        if let testAudio { feedTestAudio(testAudio) }
    }

    /// The keyboard paused or resumed a locked recording: while paused, no audio is kept, so
    /// the model hears nothing of it and the held limit does not run.
    private func setPaused(_ paused: Bool) {
        guard isCapturing else { return }
        collector.paused = paused
        pausedSince = paused ? Date() : nil
        log.info("recording \(paused ? "paused" : "resumed", privacy: .public)")
    }

    /// When the recording was paused; a recording left paused this long is ended and
    /// transcribed, so a keyboard that went away does not keep it (and its audio) for ever.
    private var pausedSince: Date?
    static let pauseLimitSeconds = 300.0

    private func interrupted() {
        guard isCapturing, pausedSince == nil else { return }
        log.info("microphone taken by iOS")
        setPaused(true)
        DictationBridge.post(DictationBridge.interrupted)
    }

    /// Every 0.05 s while recording: sends the level of the latest 0.1 s of audio to the
    /// keyboard (as one of `DictationBridge.levels` notifications, only when it changes), so the
    /// wave keeps up with the voice; twice a second it drops a recording in which nobody has
    /// spoken for `noSpeechSeconds`. Silence never ends a recording: the keyboard does.
    /// The longest a held (or locked) recording runs.
    static let heldLimitSeconds = 300.0

    private func startMonitor(held: Bool) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var lastStep = -1
            var checked = 0
            while !Task.isCancelled, let self, self.isCapturing {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, self.isCapturing else { break }
                let level = self.collector.paused ? 0 : self.collector.recentLevel(Int(AudioLoader.sampleRate) / 10)
                let db = 20 * log10(max(level, 1e-6))
                let step = min(DictationBridge.levels - 1, max(0, Int((db + 55) / 2)))
                if step != lastStep {
                    lastStep = step
                    DictationBridge.post(DictationBridge.level(step))
                }
                // Speech decisions twice a second are enough, and none while the space bar is held,
                // except a limit on its length, should the keyboard never say it was let go.
                let levels = self.collector.levels()
                if let since = self.pausedSince, Date().timeIntervalSince(since) >= Self.pauseLimitSeconds {
                    log.info("recording paused for \(Self.pauseLimitSeconds, format: .fixed(precision: 0)) s; stopped")
                    DictationBridge.post(DictationBridge.stopped)
                    self.finishCapture()
                    break
                }
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
                if Self.speechFrames(levels, from: 0) == nil, seconds >= Self.noSpeechSeconds {
                    log.info("no speech in \(seconds, format: .fixed(precision: 1)) s; recording dropped")
                    self.dropRecording()
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
            var failures = 0
            // For the device log: whether live text reached the keyboard is the question when it does not show.
            var published = 0
            var fed = 0
            let started = Date()
            while let self, self.isCapturing, id == self.dictationID {
                let piece = self.collector.snapshot(from: self.fedCount)
                if !piece.isEmpty {
                    self.fedCount += piece.count
                    fed += 1
                    do {
                        if let text = try await engine.feed(piece) { latest = text }
                    } catch {
                        log.error("stream failed: \(error.localizedDescription, privacy: .public)")
                        // Once more from the start on the CPU, or (already there) on a fresh stream:
                        // a recording without live text was the failure users saw.
                        failures += 1
                        guard failures <= 2 else {
                            self.streamFailed = true
                            return
                        }
                        if await !engine.fallBackToCPU() { await engine.begin() }
                        guard id == self.dictationID else { return }
                        self.fedCount = 0
                        latest = ""
                        continue
                    }
                }
                // A new word can come every 80 ms; the keyboard gets the text at most 4 times a second.
                if latest != shown, Date().timeIntervalSince(shownAt) >= 0.25, id == self.dictationID, self.isCapturing {
                    shown = latest
                    shownAt = Date()
                    self.publishPartial(latest)
                    published += 1
                    if published == 1 {
                        log.info("live text: first after \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s, \(latest.count) characters")
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            log.info("live text: \(published) updates from \(fed) pieces in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s, last \(latest.count) characters, compute units \(engine.computeUnits.rawValue)")
        }
    }

    /// Provisional text for the keyboard.
    private func publishPartial(_ text: String) {
        if text != lastPartialText {
            lastPartialText = text
            lastPartialAt = Date()
        }
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
        pausedSince = nil
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
                guard id == dictationID else { return }
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
        DictionarySuggestions.learn(original: correction.original, corrected: correction.corrected)
        guard let dictation = recent.first(where: { $0.id == correction.id }) else { return }
        log.info("correction for \(correction.id, privacy: .public)")
        PersonalModel.shared.add(id: correction.id, samples: dictation.samples,
                                 original: dictation.text, corrected: correction.corrected)
    }

    // MARK: - Locked screen

    private func keyboardLeft() {
        guard isCapturing else { return }
        awaySince = Date()
        screenLocked = !UIApplication.shared.isProtectedDataAvailable
        unlockedAt = nil
        awayFinished = false
        lastPartialAt = Date()
        log.info("keyboard left a locked recording\(self.screenLocked ? ", screen locked" : "", privacy: .public)")
        if screenLocked { showRecordingNotice() }
        awayTimer?.invalidate()
        awayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAway() }
        }
    }

    private func screenDidLock() {
        guard awaySince != nil, !screenLocked else { return }
        screenLocked = true
        log.info("screen locked during a recording; it goes on")
        showRecordingNotice(finished: awayFinished)
    }

    private func screenDidUnlock() {
        guard awaySince != nil, screenLocked else { return }
        unlockedAt = Date()
    }

    /// Once a second while the keyboard is away: cancels the recording if the screen did not
    /// lock or the keyboard does not come back after unlocking, and ends it after a silence.
    private func checkAway() {
        guard let since = awaySince else {
            endAway()
            return
        }
        let now = Date()
        guard screenLocked else {
            if now.timeIntervalSince(since) > Self.lockWaitSeconds {
                log.info("keyboard left without a screen lock; recording cancelled")
                cancelAway()
            }
            return
        }
        if let unlocked = unlockedAt, now.timeIntervalSince(unlocked) > Self.rejoinWaitSeconds {
            log.info("keyboard not back after unlocking; recording cancelled")
            cancelAway()
            return
        }
        if isCapturing, now.timeIntervalSince(lastPartialAt) > KeyboardOptions.load().lockedSilenceSeconds {
            log.info("silence while the screen is locked; recording stopped")
            finishCapture()
        }
        if !isCapturing, !awayFinished {
            // Ended by the silence above or by the length limit: the text waits for the keyboard.
            awayFinished = true
            showRecordingNotice(finished: true)
        }
    }

    /// The keyboard is back: it learns whether to go on with the recording or take its text.
    private func keyboardReturned() {
        guard awaySince != nil else { return }
        let finished = awayFinished || !isCapturing
        endAway()
        log.info("keyboard back to a recording that \(finished ? "ended" : "goes on", privacy: .public)")
        DictationBridge.post(finished ? DictationBridge.rejoinDone : DictationBridge.rejoinRecording)
    }

    private func cancelAway() {
        cancelDictation()
        server.clear()
        endAway()
    }

    private func endAway() {
        awaySince = nil
        awayTimer?.invalidate()
        awayTimer = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.recordingNotice])
        center.removePendingNotificationRequests(withIdentifiers: [Self.recordingNotice])
    }

    private func showRecordingNotice(finished: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = finished ? "ضبط آواک تمام شد" : "آواک در حال ضبط است"
        content.body = finished
            ? "قفل گوشی را باز کنید تا متن در همان برنامه نوشته شود."
            : "به صحبت ادامه دهید. بعد از باز کردن قفل، متن در همان برنامه نوشته می‌شود."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.recordingNotice, content: content, trigger: nil))
    }

    private func cancelDictation() {
        monitorTask?.cancel()
        monitorTask = nil
        dictationID += 1
        streamTask = nil
        pausedSince = nil
        if isCapturing {
            isCapturing = false
            let dropped = collector.end()
            log.info("recording cancelled, \(dropped.count / Int(AudioLoader.sampleRate)) s dropped")
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
    private var isPaused = false
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
        isPaused = false
        return sorted.count >= 10 ? sorted[sorted.count * 3 / 10] : nil
    }

    /// While a recording is paused, its audio is dropped (and is not taken for room noise either).
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isPaused }
        set {
            lock.lock()
            isPaused = newValue
            frameSum = 0
            frameCount = 0
            lock.unlock()
        }
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
        isPaused = false
        let result = samples
        samples = []
        return result
    }

    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.lock()
        if capturing && isPaused {
            lock.unlock()
            return
        }
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

/// Words the user keeps replacing in dictations, offered in the app as personal dictionary
/// entries once seen `minimum` times. Kept whether or not corrections are uploaded.
enum DictionarySuggestions {
    struct Suggestion: Identifiable, Equatable {
        let heard: String
        let written: String
        let count: Int
        var id: String { heard + "\t" + written }
    }

    static let minimum = 2
    private static let countsKey = "dictionarySuggestions"
    private static let dismissedKey = "dictionaryDismissed"

    private static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: countsKey) }
    }

    static func learn(original: String, corrected: String) {
        let found = PersonalDictionary.replacements(original: original, corrected: corrected)
        guard !found.isEmpty else { return }
        var counts = counts
        for pair in found { counts[pair.heard + "\t" + pair.written, default: 0] += 1 }
        // Pairs seen once go first when the list grows.
        if counts.count > 300 {
            for (key, _) in counts.sorted(by: { $0.value < $1.value }).prefix(counts.count - 300) { counts[key] = nil }
        }
        self.counts = counts
    }

    /// Suggestions not yet in `dictionary` nor dismissed, the most frequent first.
    static func list(excluding dictionary: PersonalDictionary) -> [Suggestion] {
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        let known = Set(dictionary.entries.map { PersonalDictionary.key($0.heard) })
        return counts.compactMap { key, count -> Suggestion? in
            let parts = key.components(separatedBy: "\t")
            guard count >= minimum, parts.count == 2, !dismissed.contains(key),
                  !known.contains(PersonalDictionary.key(parts[0])) else { return nil }
            return Suggestion(heard: parts[0], written: parts[1], count: count)
        }
        .sorted { ($0.count, $1.heard) > ($1.count, $0.heard) }
    }

    static func dismiss(_ suggestion: Suggestion) {
        var dismissed = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        dismissed.append(suggestion.id)
        UserDefaults.standard.set(Array(dismissed.suffix(300)), forKey: dismissedKey)
    }
}
