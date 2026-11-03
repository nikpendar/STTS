import ActivityKit
import AVFoundation
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "background")

/// A dictation with the app in the background, also with the iPhone locked: started by Siri,
/// the Control Center or lock screen button or the home screen widget (`KeylessDictationIntent`).
/// The words show as they are spoken in a Live Activity (`DictationActivityAttributes`), whose
/// buttons pause and end it; a pause after speech ends it too. The text goes to the history
/// (`DictationHistory`) and, where iOS allows it, to the clipboard; otherwise a notification
/// copies it when tapped.
@MainActor
final class BackgroundDictation {
    static let shared = BackgroundDictation()

    private(set) var isRunning = false
    private var isPaused = false
    private var ending = false
    private var cancelled = false
    private var pausedAt: Date?
    private var started = Date()
    private var levels: [Double] = []
    private var liveText = ""
    private var activity: Activity<DictationActivityAttributes>?
    private let audio = AVAudioEngine()
    private let collector = LiveSamples()

    /// Seconds of silence after speech that end the dictation.
    private static let endSilence: TimeInterval = 2.5
    private static let maxSeconds: TimeInterval = 120
    private static let pauseLimit: TimeInterval = 300

    private init() {}

    /// Records until the end button, a pause after speech or the time limit, then returns the
    /// written text ("" when nothing was said). Running it while a dictation records ends that one.
    func run() async -> String {
        if isRunning {
            end()
            return ""
        }
        guard !KeyboardSession.shared.isCapturing else {
            log.info("background dictation refused: the keyboard is dictating")
            return ""
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            log.error("background dictation: no microphone permission")
            return ""
        }
        isRunning = true
        isPaused = false
        ending = false
        cancelled = false
        pausedAt = nil
        levels = []
        liveText = ""
        started = Date()
        defer { isRunning = false }
        let launchedAt = UIApplication.shared.applicationState
        log.info("background dictation started, app state \(launchedAt.rawValue), protected data \(UIApplication.shared.isProtectedDataAvailable)")

        // AudioRecordingIntent: the Live Activity must be up before the recording starts.
        startActivity()
        do {
            try startAudio()
        } catch {
            log.error("background dictation: recording failed: \(error.localizedDescription, privacy: .public)")
            await endActivity(phase: .failed, text: "ضبط شروع نشد.", note: "")
            return ""
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let speech = await Transcriber.shared.readyEngine()
        await speech?.begin()
        var fed = 0
        var heardSpeech = false
        var silence: TimeInterval = 0
        var shownAt = Date.distantPast
        while !ending {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if isPaused {
                if let pausedAt, Date().timeIntervalSince(pausedAt) > Self.pauseLimit { break }
                continue
            }
            let level = collector.takeLevel()
            levels.append(min(1, level * 12))
            if levels.count > 16 { levels.removeFirst(levels.count - 16) }
            if level > 0.012 {
                heardSpeech = true
                silence = 0
            } else {
                silence += 0.1
            }
            let piece = collector.snapshot(from: fed)
            if !piece.isEmpty, let speech {
                fed += piece.count
                if let text = try? await speech.feed(piece) { liveText = text }
            }
            if (heardSpeech && silence >= Self.endSilence) || (!heardSpeech && silence >= 8)
                || Double(collector.count) / AudioLoader.sampleRate >= Self.maxSeconds { break }
            if Date().timeIntervalSince(shownAt) >= 0.5 {
                shownAt = Date()
                updateActivity(phase: .listening)
            }
        }
        stopAudio()
        if cancelled {
            await endActivity(phase: .failed, text: "", note: "", immediately: true)
            return ""
        }
        updateActivity(phase: .transcribing)

        let samples = collector.end()
        let seconds = Double(samples.count) / AudioLoader.sampleRate
        guard let speech, heardSpeech else {
            await endActivity(phase: .failed, text: speech == nil ? "مدل گفتار نصب نیست." : "صدایی شنیده نشد.", note: "")
            return ""
        }
        var raw = ""
        do {
            raw = try await speech.finish(Array(samples[min(fed, samples.count)...]))
        } catch {
            log.error("background dictation: stream failed, whole recording: \(error.localizedDescription, privacy: .public)")
            raw = (try? await speech.transcribe(samples)) ?? ""
        }
        let text = Self.written(raw)
        guard !text.isEmpty else {
            await endActivity(phase: .failed, text: "صدایی شنیده نشد.", note: "")
            return ""
        }

        // The clipboard takes the text only from an app on screen; changeCount tells whether it did.
        let before = UIPasteboard.general.changeCount
        UIPasteboard.general.string = text
        let copied = UIPasteboard.general.changeCount != before
        log.info("background dictation: \(seconds, format: .fixed(precision: 1)) s, clipboard \(copied ? "written" : "refused", privacy: .public), app state \(UIApplication.shared.applicationState.rawValue)")
        DictationHistory.add(text, copied: copied)
        AppUsage.recordDictation(words: text.split(whereSeparator: \.isWhitespace).count, seconds: seconds)
        if !copied { Self.notify(text) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await endActivity(phase: .done, text: text, note: copied ? "کپی شد" : "ذخیره شد؛ برای کپی، اعلان را لمس کنید")
        return text
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        collector.paused = isPaused
        if isPaused {
            pausedAt = Date()
        } else if let pausedAt {
            started = started.addingTimeInterval(Date().timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
        updateActivity(phase: isPaused ? .paused : .listening)
    }

    /// Stops the recording and writes the text.
    func end() {
        guard isRunning else { return }
        ending = true
    }

    /// Stops without writing anything: the keyboard starts a dictation of its own.
    func cancel() {
        guard isRunning else { return }
        cancelled = true
        ending = true
    }

    /// As for the keyboard and the watch: punctuation, then numbers, ZWNJ and the personal dictionary.
    static func written(_ raw: String) -> String {
        let text = DictationBridge.removingPauseMarks(raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        let options = KeyboardOptions.load()
        let dictionary = PersonalDictionary.saved
        let punctuated = options.autoPunctuation
            ? AutoPunctuation.shared.punctuate(text, quiet: dictionary.symbolWords)
            : text
        return VoiceCommands.process(punctuated, punctuation: false, commands: false,
                                     zwnj: options.autoZWNJ, dictionary: dictionary).text
    }

    // MARK: - Recording

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        if !KeyboardSession.shared.isActive {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        }
        collector.begin()
        let input = audio.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioLoader.sampleRate,
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
        audio.prepare()
        try audio.start()
    }

    private func stopAudio() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        if !KeyboardSession.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Live Activity

    private func state(_ phase: DictationActivityAttributes.ContentState.Phase, text: String? = nil, note: String = "")
        -> DictationActivityAttributes.ContentState {
        DictationActivityAttributes.ContentState(phase: phase, text: text ?? liveText, levels: levels,
                                                 started: started, note: note)
    }

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("Live Activities are off for the app")
            return
        }
        do {
            activity = try Activity.request(attributes: DictationActivityAttributes(),
                                            content: ActivityContent(state: state(.listening), staleDate: nil))
        } catch {
            log.error("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateActivity(phase: DictationActivityAttributes.ContentState.Phase) {
        guard let activity else { return }
        let content = ActivityContent(state: state(phase), staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endActivity(phase: DictationActivityAttributes.ContentState.Phase, text: String, note: String,
                             immediately: Bool = false) async {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: state(phase, text: text, note: note), staleDate: nil)
        // The text stays on the lock screen a while, to read before unlocking.
        await activity.end(content, dismissalPolicy: immediately ? .immediate : .after(Date().addingTimeInterval(120)))
    }

    // MARK: - Notification

    static let notificationTextKey = "dictationText"

    /// Asked once, with the app on screen: the notification is how a text from the locked
    /// iPhone reaches the clipboard.
    static func askForNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private static func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "متن دیکته آماده است"
        content.subtitle = "برای کپی لمس کنید"
        content.body = text
        content.userInfo = [notificationTextKey: text]
        let request = UNNotificationRequest(identifier: "dictation-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The recording of a background dictation, filled on the audio thread.
final class LiveSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var squares: Float = 0
    private var squaredCount = 0
    private var _paused = false

    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    var count: Int { lock.withLock { samples.count } }

    func begin() {
        lock.withLock {
            samples = []
            samples.reserveCapacity(16_000 * 30)
            squares = 0
            squaredCount = 0
            _paused = false
        }
    }

    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.withLock {
            guard !_paused else { return }
            let buffer = UnsafeBufferPointer(start: pointer, count: count)
            samples.append(contentsOf: buffer)
            for sample in buffer { squares += sample * sample }
            squaredCount += count
        }
    }

    /// The loudness (RMS) since the last call.
    func takeLevel() -> Double {
        lock.withLock {
            defer {
                squares = 0
                squaredCount = 0
            }
            return squaredCount > 0 ? Double((squares / Float(squaredCount)).squareRoot()) : 0
        }
    }

    func snapshot(from start: Int) -> [Float] {
        lock.withLock { start < samples.count ? Array(samples[start...]) : [] }
    }

    func end() -> [Float] {
        lock.withLock {
            defer { samples = [] }
            return samples
        }
    }
}

/// The texts of the dictations started without the app on screen, newest first, to copy later.
enum DictationHistory {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        let date: Date
        let text: String
        let copied: Bool
    }

    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("dictation-history.json")
    }

    static func all() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func add(_ text: String, copied: Bool) {
        let entries = [Entry(date: Date(), text: text, copied: copied)] + all().prefix(49)
        save(entries)
    }

    static func save(_ entries: [Entry]) {
        // Readable while the iPhone is locked (after the first unlock), where it is written.
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: file)
    }
}
