import AVFoundation
import CoreML
import SwiftUI

enum ComputeChoice: String, CaseIterable, Identifiable {
    case neuralEngine, cpu, gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neuralEngine: return "Neural Engine"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }

    var units: MLComputeUnits {
        switch self {
        case .neuralEngine: return .all
        case .cpu: return .cpuOnly
        case .gpu: return .cpuAndGPU
        }
    }
}

/// Snapshot of the stream after a step, handed to the UI.
struct StreamUpdate: Sendable {
    var text: String
    var stepMs: Double
    var averageStepMs: Double
    var lagSeconds: Double
    var audioMsPerStep: Int
}

/// Owns the ShenavaStream and the serial queue it runs on. All stream access happens on `queue`.
final class StreamWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shenava.stream", qos: .userInitiated)
    private var stream: ShenavaStream?
    private let lock = NSLock()
    private var pendingSamples = 0

    func load(_ kind: ShenavaModel, units: MLComputeUnits,
              done: @escaping @Sendable (Result<Double, Error>) -> Void) {
        queue.async {
            self.stream = nil
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let s = try ShenavaStream(model: kind, computeUnits: units)
                // Warm-up: the first prediction compiles the model for the chosen hardware.
                try s.accept([Float](repeating: 0, count: 16_000))
                s.reset()
                self.stream = s
                done(.success(CFAbsoluteTimeGetCurrent() - start))
            } catch {
                done(.failure(error))
            }
        }
    }

    func begin() {
        lock.lock(); pendingSamples = 0; lock.unlock()
        queue.async { self.stream?.reset() }
    }

    /// Called on the audio thread.
    func feed(_ samples: [Float], update: @escaping @Sendable (StreamUpdate) -> Void) {
        lock.lock(); pendingSamples += samples.count; lock.unlock()
        queue.async {
            guard let stream = self.stream else { return }
            let changed = (try? stream.accept(samples)) ?? false
            self.lock.lock(); self.pendingSamples -= samples.count; let pending = self.pendingSamples; self.lock.unlock()
            if changed || stream.steps % 6 == 0 {
                update(self.snapshot(stream, pending: pending))
            }
        }
    }

    func end(done: @escaping @Sendable (StreamUpdate) -> Void) {
        queue.async {
            guard let stream = self.stream else { return }
            try? stream.finish()
            done(self.snapshot(stream, pending: 0))
        }
    }

    private func snapshot(_ stream: ShenavaStream, pending: Int) -> StreamUpdate {
        StreamUpdate(text: stream.text.trimmingCharacters(in: .whitespaces),
                     stepMs: stream.lastStepMs,
                     averageStepMs: stream.steps > 0 ? stream.computeSeconds * 1000 / Double(stream.steps) : 0,
                     lagSeconds: Double(pending) / 16_000,
                     audioMsPerStep: stream.audioMsPerStep)
    }
}

/// Microphone -> 16 kHz mono -> StreamWorker, with live text and timing for the UI.
@MainActor
final class Recognizer: ObservableObject {
    @Published var model: ShenavaModel = .koochik { didSet { if model != oldValue { load() } } }
    @Published var compute: ComputeChoice = .neuralEngine { didSet { if compute != oldValue { load() } } }
    @Published private(set) var isLoading = false
    @Published private(set) var isRecording = false
    @Published private(set) var finished = ""      // earlier utterances
    @Published private(set) var live = ""          // current utterance
    @Published private(set) var status = ""
    @Published private(set) var stepMs: Double = 0
    @Published private(set) var averageStepMs: Double = 0
    @Published private(set) var lagSeconds: Double = 0
    @Published private(set) var audioMsPerStep = 80

    var text: String { [finished, live].filter { !$0.isEmpty }.joined(separator: "\n") }

    private let worker = StreamWorker()
    private let engine = AVAudioEngine()
    private var loadGeneration = 0

    init() { load() }

    func load() {
        guard !isRecording else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        status = "بارگذاری مدل…"
        worker.load(model, units: compute.units) { result in
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.isLoading = false
                switch result {
                case .success(let seconds): self.status = String(format: "مدل آماده است (بارگذاری %.1f ثانیه)", seconds)
                case .failure(let error): self.status = "خطا: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func clear() {
        finished = ""
        live = ""
    }

    private func start() {
        guard !isLoading else { return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { self.startEngine() } else { self.status = "دسترسی میکروفون داده نشده است." }
            }
        }
    }

    private func apply(_ u: StreamUpdate) {
        live = u.text
        stepMs = u.stepMs
        averageStepMs = u.averageStepMs
        lagSeconds = u.lagSeconds
        audioMsPerStep = u.audioMsPerStep
    }

    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                status = "قالب صدای میکروفون پشتیبانی نمی‌شود."
                return
            }
            worker.begin()
            stepMs = 0
            averageStepMs = 0
            lagSeconds = 0
            live = ""
            let worker = self.worker
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / inFormat.sampleRate) + 64
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
                guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
                worker.feed(samples) { update in
                    DispatchQueue.main.async {
                        guard let self, self.isRecording else { return }
                        self.apply(update)
                    }
                }
            }
            engine.prepare()
            try engine.start()
            UIApplication.shared.isIdleTimerDisabled = true
            isRecording = true
            status = "در حال گوش دادن…"
        } catch {
            status = "شروع میکروفون ناموفق بود: \(error.localizedDescription)"
        }
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        status = "پایان…"
        worker.end { update in
            DispatchQueue.main.async {
                self.apply(update)
                if !update.text.isEmpty {
                    self.finished = [self.finished, update.text].filter { !$0.isEmpty }.joined(separator: "\n")
                }
                self.live = ""
                self.lagSeconds = 0
                self.status = String(format: "میانگین هر گام: %.0f ms برای %d ms صدا", update.averageStepMs,
                                     update.audioMsPerStep)
            }
        }
    }
}
