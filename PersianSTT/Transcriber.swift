import AVFoundation
import CoreML
import Foundation
import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "model")

/// The speech model, Shenava Koochik: a streaming Core ML model that writes text while the user
/// speaks (`ShenavaStream`). It runs on its own serial queue, off the main actor; every call is
/// one block on that queue, so a recording fed in pieces and a whole file never interleave.
final class SpeechEngine: @unchecked Sendable {
    /// The Neural Engine, or the CPU alone where Core ML could not run the model there.
    private(set) var computeUnits: MLComputeUnits
    private let queue = DispatchQueue(label: "ir.nikpendar.PersianSTT.speech", qos: .userInitiated)
    /// Replaced (on `queue`) by a CPU-only stream when a prediction fails.
    private var stream: ShenavaStream
    private let model: URL
    private let resources: URL

    private init(stream: ShenavaStream, units: MLComputeUnits, model: URL, resources: URL) {
        self.stream = stream
        computeUnits = units
        self.model = model
        self.resources = resources
    }

    /// Loads a compiled model (.mlmodelc). The first prediction prepares it for the hardware,
    /// so it runs here once on a second of silence rather than at the start of the first dictation.
    /// No GPU: the keyboard dictates with the app in the background, where iOS refuses GPU work
    /// and every prediction then failed, so no text came while the user spoke.
    static func load(model: URL, resources: URL) async throws -> SpeechEngine {
        try await Task.detached(priority: .userInitiated) {
            var lastError: Error?
            for units in [MLComputeUnits.cpuAndNeuralEngine, .cpuOnly] {
                do {
                    let stream = try ShenavaStream(model: model, resources: resources, computeUnits: units)
                    try stream.accept([Float](repeating: 0, count: 16_000))
                    try stream.finish()
                    stream.reset()
                    return SpeechEngine(stream: stream, units: units, model: model, resources: resources)
                } catch {
                    log.error("model failed with compute units \(units.rawValue): \(error.localizedDescription, privacy: .public)")
                    lastError = error
                }
            }
            throw lastError ?? ShenavaError.missing(model.lastPathComponent)
        }.value
    }

    private func run<T>(_ work: @escaping (ShenavaStream) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work(self.stream) })
            }
        }
    }

    /// After a failed prediction: the same model on the CPU alone, with a new dictation started.
    /// Returns false when it is already on the CPU or cannot be rebuilt.
    func fallBackToCPU() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.computeUnits != .cpuOnly,
                      let stream = try? ShenavaStream(model: self.model, resources: self.resources, computeUnits: .cpuOnly)
                else { return continuation.resume(returning: false) }
                log.error("speech model moved to the CPU after a failed prediction")
                self.stream = stream
                self.computeUnits = .cpuOnly
                continuation.resume(returning: true)
            }
        }
    }

    /// Starts a new dictation.
    func begin() async {
        _ = try? await run { $0.reset() }
    }

    /// Feeds the next piece of the recording; returns the text so far when it changed.
    func feed(_ samples: [Float]) async throws -> String? {
        try await run { stream in
            try stream.accept(samples) ? stream.text : nil
        }
    }

    /// Ends the dictation with the last piece of the recording: the end is padded and decoded.
    /// Returns the whole text.
    func finish(_ samples: [Float] = []) async throws -> String {
        try await run { stream in
            try stream.accept(samples)
            try stream.finish()
            return stream.text
        }
    }

    /// A whole recording at once (the dictation shortcut). It would replace a dictation in
    /// progress, which does not happen: the shortcut records with the app in front, the
    /// keyboard with the app in the background.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await run { stream in
            stream.reset()
            try stream.accept(samples)
            try stream.finish()
            return stream.text
        }
    }

    /// Seconds of model time per second of audio so far, for the keyboard's processing ring.
    var secondsPerAudioSecond: Double {
        get async {
            (try? await run { stream in
                stream.steps > 20 ? stream.computeSeconds / (Double(stream.steps) * 0.08) : 0.5
            }) ?? 0.5
        }
    }
}

/// Owns the speech model: loads the personal, imported or bundled model (in that order), and
/// records and transcribes the dictation shortcut, whose text goes to the clipboard. The
/// keyboard session streams its recordings into `engine`.
@MainActor
final class Transcriber: ObservableObject {
    /// Shared by the keyboard session, the settings page and the dictation shortcut (DictateIntent).
    static let shared = Transcriber()

    /// The model's state, or the last shortcut dictation's result, for the settings page.
    @Published var status = "در حال بارگذاری مدل…"
    /// The dictation shortcut is recording.
    @Published var isRecording = false
    @Published var isBusy = true
    @Published var modelName = ""
    /// A model is loaded. Builds without a bundled model need one imported (`ModelImporter`).
    @Published private(set) var hasModel = false

    private(set) var engine: SpeechEngine?
    private var loadTask: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var quickDictationPending = false
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording.wav")

    /// The model's sidecars, in the app's Models folder: tokens.json, preprocessor.json,
    /// mel_filters_slaney_80x257.json and manifest.json. A fine-tuned model keeps them.
    static var resources: URL? {
        Bundle.main.url(forResource: "Models", withExtension: nil)
    }

    /// A compiled model inside the app, only in builds that bundle it.
    static var bundledModel: URL? {
        Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: "Models")?.first
    }

    private init() {
        loadTask = Task { await loadModel() }
    }

    /// Switches to a newly downloaded personal model (or back to the imported one).
    func reloadModel() {
        guard !isRecording else { return }
        engine = nil
        hasModel = false
        isBusy = true
        status = "در حال بارگذاری مدل…"
        loadTask = Task { await loadModel() }
    }

    /// Loads a model imported while no model was loaded.
    func loadNewModelIfNeeded() {
        guard !hasModel, !isBusy, ModelImporter.installedModel != nil else { return }
        reloadModel()
    }

    /// The loaded model, after waiting for one still loading; nil if there is none.
    func readyEngine() async -> SpeechEngine? {
        if engine == nil { await loadTask?.value }
        return engine
    }

    private func loadModel() async {
        // A personal model trained on the user's corrections comes first, then the one
        // imported from Files, then one inside the app (only in builds that bundle it).
        guard let url = PersonalModel.shared.modelFile ?? ModelImporter.installedModel ?? Self.bundledModel else {
            status = "مدل گفتار نصب نیست."
            modelName = ""
            isBusy = false
            return
        }
        guard let resources = Self.resources else {
            status = "فایل‌های همراه مدل در اپ نیست."
            isBusy = false
            return
        }
        modelName = url.deletingPathExtension().lastPathComponent
        do {
            let engine = try await SpeechEngine.load(model: url, resources: resources)
            self.engine = engine
            hasModel = true
            log.info("loaded \(url.lastPathComponent, privacy: .public), compute units \(engine.computeUnits.rawValue)")
            if !isRecording {
                status = engine.computeUnits == .cpuOnly ? "آماده (CPU)" : "آماده"
            }
        } catch {
            log.error("cannot load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // A personal model that does not load is dropped for the imported one.
            if url == PersonalModel.shared.modelFile {
                PersonalModel.shared.useBaseModel()
                return
            }
            status = url == ModelImporter.installedModel
                ? "فایل مدل باز نشد؛ ممکن است ناقص کپی شده باشد. دوباره وارد کنید."
                : error.localizedDescription
        }
        if !isRecording {
            isBusy = false
        }
    }

    // MARK: - Dictation shortcut

    /// Called by DictateIntent. Recording can only start once the app is in the foreground,
    /// so the request is kept until `appDidBecomeActive()` if needed.
    func requestQuickDictation() {
        quickDictationPending = true
        if UIApplication.shared.applicationState == .active {
            appDidBecomeActive()
        }
    }

    func appDidBecomeActive() {
        guard quickDictationPending, !isRecording else { return }
        quickDictationPending = false
        Task { await startRecording() }
    }

    /// Records until a pause after speech (`watchForSilence`), then transcribes.
    private func startRecording() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "دسترسی به میکروفون داده نشده است. از تنظیمات آیفون فعالش کنید."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // voiceChat mode turns on Apple's voice processing (noise suppression) for the recorder.
            if KeyboardSession.noiseSuppression {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            } else {
                try session.setCategory(.record, mode: .default)
            }
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
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                status = "شروع ضبط ناموفق بود."
                return
            }
            self.recorder = recorder
            isRecording = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            status = "در حال گوش دادن… بعد از مکث خودکار تمام می‌شود."
            watchForSilence()
        } catch {
            status = "خطا در ضبط: \(error.localizedDescription)"
        }
    }

    /// Stops the dictation after speech followed by a pause, or when nothing is said.
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
                if recorder.averagePower(forChannel: 0) > -40 {
                    heardSpeech = true
                    silence = 0
                } else {
                    silence += 0.1
                }
                let elapsed = Date().timeIntervalSince(started)
                if (heardSpeech && silence >= 1.8) || (!heardSpeech && silence >= 8) || elapsed >= 60 {
                    self.stopAndTranscribe()
                    return
                }
            }
        }
    }

    private func stopAndTranscribe() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        if !KeyboardSession.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        transcribe(url: recordingURL)
    }

    /// Transcribes, then copies the text to the clipboard so it can be pasted into any app. The
    /// shortcut has no keyboard, so spoken punctuation and numbers are applied here.
    private func transcribe(url: URL) {
        isBusy = true
        Task {
            if engine == nil { status = "در حال بارگذاری مدل…" }
            guard let engine = await readyEngine() else {
                isBusy = false
                return
            }
            status = "در حال تبدیل به متن…"
            do {
                let start = Date()
                let samples = try await Task.detached { try AudioLoader.loadSamples(url: url) }.value
                let raw = try await engine.transcribe(samples)
                let text = VoiceCommands.process(raw, punctuation: true, commands: false).text
                let audioSeconds = Double(samples.count) / AudioLoader.sampleRate
                let elapsed = Date().timeIntervalSince(start)
                var summary = String(format: "%.1f ثانیه صدا در %.1f ثانیه تبدیل شد", audioSeconds, elapsed)
                if !text.isEmpty {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    summary += " و در کلیپ‌بورد کپی شد"
                }
                status = summary
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}
