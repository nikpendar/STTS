import AVFoundation
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "notes")

/// Turns a long stream of audio into the pieces of a note (`SpeechSegmenter`): the model hears
/// the audio as it comes (live text), and each piece is decoded to its end at the pause that
/// closes it, so the stream's text never grows without end and each piece keeps its own time.
/// Only one stream uses the model at a time: the keyboard's dictation, a note's recording or
/// a transcribed file (`NoteRecorder`, `FileTranscriber` keep out of each other's way).
@MainActor
final class NoteTranscription {
    struct Piece {
        let start: Double
        let end: Double
        let words: String
    }

    private let engine: SpeechEngine
    private var segmenter = SpeechSegmenter()
    /// The current piece's audio (at most 30 s and the part of a push past it).
    private var buffer: [Float] = []
    /// Samples of `buffer` the model has had, and the ones the segmenter has seen.
    private var fed = 0
    private var scanned = 0
    /// Where `buffer` starts in the whole stream, in samples.
    private var bufferStart = 0
    private var failures = 0

    var onPartial: (String) -> Void = { _ in }
    var onPiece: (Piece) -> Void = { _ in }

    init(engine: SpeechEngine) {
        self.engine = engine
    }

    /// Seconds of audio taken so far.
    var seconds: Double { Double(bufferStart + buffer.count) / AudioStream.sampleRate }

    func start() async {
        await engine.begin()
    }

    /// The next audio of the stream.
    func push(_ samples: [Float]) async throws {
        buffer += samples
        let frame = SpeechSegmenter.frameSamples
        while scanned + frame <= buffer.count {
            let level = SpeechSegmenter.level(buffer[scanned..<(scanned + frame)])
            scanned += frame
            if case .cut(let speech) = segmenter.add(level: level) {
                try await close(at: scanned, speech: speech)
            }
        }
        guard fed < buffer.count else { return }
        let piece = Array(buffer[fed...])
        do {
            if let text = try await engine.feed(piece) { onPartial(DictationBridge.removingPauseMarks(text)) }
            fed = buffer.count
        } catch {
            // As the keyboard does: once more on the CPU, the piece again from its start.
            log.error("note stream failed: \(error.localizedDescription, privacy: .public)")
            failures += 1
            guard failures <= 2 else { throw error }
            if await !engine.fallBackToCPU() { await engine.begin() }
            fed = 0
        }
    }

    /// Ends the current piece (a pause by the user, or the end).
    func flush() async throws {
        let speech = segmenter.end()
        try await close(at: buffer.count, speech: speech)
    }

    /// The model was used by someone else (the keyboard): the current piece starts again.
    func restartPiece() async {
        await engine.begin()
        fed = 0
    }

    private func close(at end: Int, speech: Bool) async throws {
        let start = bufferStart
        if speech {
            let raw = try await engine.finish(Array(buffer[min(fed, end)..<end]))
            let words = DictationBridge.removingPauseMarks(raw).trimmingCharacters(in: .whitespaces)
            if !words.isEmpty {
                onPiece(Piece(start: Double(start) / AudioStream.sampleRate,
                              end: Double(start + end) / AudioStream.sampleRate, words: words))
            }
        }
        buffer.removeFirst(end)
        bufferStart += end
        scanned = max(0, scanned - end)
        fed = 0
        await engine.begin()
        onPartial("")
    }
}

/// Writes 16 kHz mono samples to an AAC (.m4a) file on its own queue. The file is complete
/// once the writer is closed (`close`), when AVAudioFile writes its index.
final class AudioWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ir.nikpendar.PersianSTT.notes.writer", qos: .utility)
    private var file: AVAudioFile?

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioStream.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: AudioStream.format,
                                                          frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            do { try file.write(from: buffer) } catch {
                log.error("cannot write note audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Finishes the file; waits for the writes before it.
    func close() {
        queue.sync { file = nil }
    }

    /// The samples of `url` from `start` to `end` seconds (a note piece, for training).
    static func samples(_ url: URL, from start: Double, to end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = min(file.length, AVAudioFramePosition(start * rate))
        let count = AVAudioFrameCount(min(AVAudioFramePosition(max(0, end - start) * rate), file.length - file.framePosition))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        try file.read(into: buffer, frameCount: count)
        let resampler = try AudioStream.Resampler(from: file.processingFormat)
        return try resampler.convert(buffer) + resampler.convert(nil, last: true)
    }
}

/// Collects the microphone's samples (converted to 16 kHz) from the audio thread.
private final class MicCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var dropping = false

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return dropping }
        set { lock.lock(); dropping = newValue; samples.removeAll(); lock.unlock() }
    }

    func append(_ pointer: UnsafePointer<Float>, count: Int) {
        lock.lock()
        if !dropping { samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count)) }
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: true)
        return out
    }
}

/// Long dictation into a note, in the app: the microphone stays open as long as the user
/// wants (with the screen locked too: the app has background audio), with pause and resume.
/// The audio is kept with the note; text goes in piece by piece at the pauses.
@MainActor
final class NoteRecorder: ObservableObject {
    static let shared = NoteRecorder()

    @Published private(set) var noteID: UUID?
    @Published private(set) var isPaused = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published var message: String?

    /// Live text of the piece being spoken, and each finished piece; set by the open editor.
    /// Without an editor, pieces go to the end of the note.
    var onPartial: (String) -> Void = { _ in }
    var onPiece: ((NoteSegment) -> Void)?

    private let audio = AVAudioEngine()
    private let collector = MicCollector()
    private var writer: AudioWriter?
    private var audioFile = ""
    private var loop: Task<Void, Never>?
    private var pauseRequested = false
    private var stopRequested = false
    private var interruption: NSObjectProtocol?

    var isRecording: Bool { noteID != nil }
    func isRecording(_ id: UUID) -> Bool { noteID == id }

    /// Starts recording into note `id`; false (with `message`) when it cannot.
    func start(note id: UUID) async -> Bool {
        guard noteID == nil else { return false }
        message = nil
        if FileTranscriber.shared.job != nil {
            message = L("یک فایل صوتی در حال تبدیل است. بعد از پایان آن دوباره امتحان کنید.", "An audio file is being transcribed. Try again when it is done.")
            return false
        }
        let keyboard = KeyboardSession.shared
        if keyboard.isCapturing {
            message = L("کیبورد آواک در حال ضبط است.", "The Avak keyboard is recording.")
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = L("دسترسی به میکروفون داده نشده است. از تنظیمات آیفون، آواک، میکروفون را روشن کنید.", "Microphone access is off. Turn it on in iPhone Settings, Avak, Microphone.")
            return false
        }
        guard let engine = await Transcriber.shared.readyEngine() else {
            message = L("مدل گفتار نصب نیست.", "The speech model is not installed.")
            return false
        }
        // The keyboard's session holds the microphone; the user is in the app, so it can go.
        if keyboard.isActive { keyboard.stop() }
        PersianSpeech.shared.stop()

        let store = NotesStore.shared
        audioFile = store.newAudioFile(for: id)
        do {
            writer = try AudioWriter(url: store.audioURL(id, audioFile))
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let input = audio.inputNode
            try input.setVoiceProcessingEnabled(KeyboardSession.noiseSuppression)
            let inFormat = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inFormat, to: AudioStream.format) else {
                throw AudioLoaderError.unsupportedFormat
            }
            let collector = self.collector
            collector.paused = false
            _ = collector.take()
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * AudioStream.sampleRate / inFormat.sampleRate) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: AudioStream.format, frameCapacity: capacity) else { return }
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
                if let channel = out.floatChannelData?[0] { collector.append(channel, count: Int(out.frameLength)) }
            }
            audio.prepare()
            try audio.start()
        } catch {
            log.error("note recording failed to start: \(error.localizedDescription, privacy: .public)")
            message = L("ضبط شروع نشد: \(error.localizedDescription)", "Recording did not start: \(error.localizedDescription)")
            teardown()
            store.update(id, touch: false) { $0.audioFiles.removeAll { $0 == self.audioFile } }
            return false
        }

        noteID = id
        isPaused = false
        seconds = 0
        pauseRequested = false
        stopRequested = false
        UIApplication.shared.isIdleTimerDisabled = true
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                              object: nil, queue: .main) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        }

        let transcription = NoteTranscription(engine: engine)
        let file = audioFile
        let writer = writer
        transcription.onPartial = { [weak self] text in self?.onPartial(text) }
        transcription.onPiece = { [weak self] piece in
            let writerText = NoteTextWriter().write(piece.words)
            let segment = NoteSegment(audio: file, start: piece.start, end: piece.end, raw: piece.words, text: writerText)
            store.update(id, touch: false) { $0.segments.append(segment) }
            if let handler = self?.onPiece {
                handler(segment)
            } else {
                store.update(id) { $0.body = NotesStore.appending(segment.text, to: $0.body) }
            }
        }
        log.info("note recording started")
        loop = Task { [weak self] in
            await transcription.start()
            var flushed = false
            while let self {
                let samples = self.collector.take()
                if !samples.isEmpty {
                    writer?.write(samples)
                    self.level = SpeechSegmenter.level(samples[...])
                    do { try await transcription.push(samples) } catch {
                        self.message = L("تبدیل گفتار ناموفق بود.", "Speech recognition failed.")
                        self.stopRequested = true
                    }
                    self.seconds = transcription.seconds
                }
                if self.pauseRequested || self.stopRequested, !flushed {
                    try? await transcription.flush()
                    flushed = true
                }
                if !self.pauseRequested { flushed = false }
                if self.stopRequested { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.finishStop()
        }
        return true
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        level = 0
        // Audio already taken goes through before the piece is closed.
        pauseRequested = true
        collector.paused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        collector.paused = false
        pauseRequested = false
        isPaused = false
    }

    /// Stops; the last piece is decoded and goes into the note.
    func stop() {
        guard isRecording else { return }
        stopRequested = true
        // The microphone is free at once (the keyboard's session may be taking it); the audio
        // already taken still goes through before the loop ends.
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
    }

    private func finishStop() {
        let id = noteID
        teardown()
        log.info("note recording stopped after \(Int(self.seconds)) s, memory \(Int(MemoryFootprint.megabytes.now)) MB")
        // A recording with nothing heard keeps no audio.
        if let id, let note = NotesStore.shared.note(id), !note.segments.contains(where: { $0.audio == audioFile }) {
            try? FileManager.default.removeItem(at: NotesStore.shared.audioURL(id, audioFile))
            NotesStore.shared.update(id, touch: false) { $0.audioFiles.removeAll { $0 == self.audioFile } }
        }
        noteID = nil
        isPaused = false
        level = 0
    }

    private func teardown() {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        writer?.close()
        writer = nil
        loop = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if !KeyboardSession.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Transcribes an audio file into a note: a voice message shared from Telegram or WhatsApp
/// (Ogg Opus), or any file AVFoundation opens. The file is read and decoded a piece at a time,
/// so length is no limit; the audio is kept with the note at 16 kHz for listening again.
/// It waits while the keyboard's voice typing is on, which needs the same model.
@MainActor
final class FileTranscriber: ObservableObject {
    static let shared = FileTranscriber()

    struct Job: Equatable {
        let noteID: UUID
        let name: String
        var progress: Double
        var waiting = false
    }

    @Published private(set) var job: Job?
    @Published var message: String?
    private var task: Task<Void, Never>?

    /// Audio types the app opens from the share sheet and the file picker.
    static let ogg = "org.xiph.ogg-audio"
    static let opus = "org.xiph.opus"

    /// Starts transcribing `url` into a new note (or `noteID`); returns the note, nil if busy.
    @discardableResult
    func transcribe(_ url: URL, into noteID: UUID? = nil) -> UUID? {
        message = nil
        guard job == nil, !NoteRecorder.shared.isRecording else {
            message = L("تبدیل دیگری در جریان است. بعد از پایان آن دوباره امتحان کنید.", "Another transcription is running. Try again when it is done.")
            return nil
        }
        // A copy of our own: a shared file can go away, and a picked one needs its access scope.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            message = L("فایل باز نشد: \(error.localizedDescription)", "The file did not open: \(error.localizedDescription)")
            return nil
        }
        // Files shared to the app land in Documents/Inbox; the copy is ours now.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }

        let store = NotesStore.shared
        let id = noteID ?? store.create().id
        let name = url.lastPathComponent
        store.update(id) { $0.source = $0.source ?? name }
        job = Job(noteID: id, name: name, progress: 0)
        task = Task { [weak self] in
            await self?.run(copy, into: id)
            try? FileManager.default.removeItem(at: copy)
        }
        return id
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ url: URL, into id: UUID) async {
        let store = NotesStore.shared
        let started = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            job = nil
        }
        let reader: AudioStreamReader
        do {
            reader = try AudioStream.open(url)
        } catch {
            log.error("cannot open audio file: \(error.localizedDescription, privacy: .public)")
            message = L("این فایل صوتی باز نشد. قالب‌های پشتیبانی‌شده: ویس تلگرام و واتس‌اپ (ogg، opus)، m4a، mp3، wav و aac.", "This audio file did not open. Supported: Telegram and WhatsApp voice messages (ogg, opus), m4a, mp3, wav and aac.")
            return
        }
        guard let engine = await waitForModel() else { return }
        let file = store.newAudioFile(for: id)
        let writer: AudioWriter
        do { writer = try AudioWriter(url: store.audioURL(id, file)) } catch {
            message = error.localizedDescription
            return
        }
        let transcription = NoteTranscription(engine: engine)
        let textWriter = NoteTextWriter()
        transcription.onPiece = { piece in
            let text = textWriter.write(piece.words)
            let segment = NoteSegment(audio: file, start: piece.start, end: piece.end, raw: piece.words, text: text)
            store.update(id) { note in
                note.segments.append(segment)
                note.body = NotesStore.appending(text, to: note.body)
            }
        }
        await transcription.start()
        let duration = reader.duration
        var failed = false
        while !Task.isCancelled {
            // The keyboard's voice typing has the model: wait, then start the piece again.
            if KeyboardSession.shared.isActive {
                job?.waiting = true
                while KeyboardSession.shared.isActive, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                job?.waiting = false
                await transcription.restartPiece()
            }
            let samples: [Float]
            do { samples = try reader.read(seconds: 2) } catch {
                log.error("audio file read failed: \(error.localizedDescription, privacy: .public)")
                failed = true
                break
            }
            if samples.isEmpty { break }
            writer.write(samples)
            do { try await transcription.push(samples) } catch {
                failed = true
                break
            }
            if duration > 0 { job?.progress = min(1, transcription.seconds / duration) }
        }
        try? await transcription.flush()
        writer.close()
        let seconds = transcription.seconds
        log.info("file transcribed: \(Int(seconds)) s of audio in \(Int(Date().timeIntervalSince(started))) s, memory \(Int(MemoryFootprint.megabytes.now)) MB (peak \(Int(MemoryFootprint.megabytes.peak)) MB)")
        if failed {
            message = L("تبدیل فایل نیمه‌کاره ماند.", "The transcription stopped partway.")
        } else if Task.isCancelled {
            message = L("تبدیل لغو شد؛ متن تا همین‌جا در یادداشت هست.", "Cancelled; the text so far is in the note.")
        } else if store.note(id)?.segments.isEmpty ?? true {
            message = L("در این فایل گفتاری پیدا نشد.", "No speech was found in this file.")
        }
        if UIApplication.shared.applicationState != .active, !failed, !Task.isCancelled {
            let content = UNMutableNotificationContent()
            content.title = L("تبدیل فایل صوتی تمام شد", "Audio file transcribed")
            content.body = store.note(id)?.title ?? ""
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "note-\(id)", content: content, trigger: nil))
        }
    }

    private func waitForModel() async -> SpeechEngine? {
        guard let engine = await Transcriber.shared.readyEngine() else {
            message = L("مدل گفتار نصب نیست.", "The speech model is not installed.")
            return nil
        }
        return engine
    }
}

extension NotesStore {
    /// `text` after `body`, with a space between them (or nothing when the body is empty or
    /// ends in a line break).
    static func appending(_ text: String, to body: String) -> String {
        guard let last = body.last else { return text }
        return body + (last.isWhitespace ? "" : " ") + text
    }

    /// The user corrected a dictated piece: the note's text follows, the personal dictionary
    /// learns the words, and with «یادگیری از اصلاح‌ها» on the piece's audio and both texts go
    /// to training (pieces of 30 s or less, as from the keyboard).
    func correct(_ segment: NoteSegment, in id: UUID, to corrected: String) {
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != segment.text else { return }
        update(id) { note in
            if let range = note.body.range(of: segment.text) {
                note.body.replaceSubrange(range, with: corrected)
            }
            if let i = note.segments.firstIndex(where: { $0.id == segment.id }) {
                note.segments[i].text = corrected
                note.segments[i].corrected = true
            }
        }
        DictionarySuggestions.learn(original: segment.text, corrected: corrected)
        guard segment.duration <= 30 else { return }
        let url = audioURL(id, segment.audio)
        Task.detached(priority: .utility) {
            guard let samples = try? AudioWriter.samples(url, from: segment.start, to: segment.end), !samples.isEmpty else { return }
            await MainActor.run {
                PersonalModel.shared.add(id: segment.id.uuidString, samples: samples, original: segment.raw, corrected: corrected)
            }
        }
    }
}
