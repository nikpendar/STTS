import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "speed")

/// Finds the fastest whisper.cpp settings on this phone: flash attention on or off, and the
/// number of threads. Neither changes what the model computes, only how, and which is faster
/// depends on the phone's mix of performance and efficiency cores, so it is measured: the last
/// keyboard recording is transcribed with each setting, and the fastest is kept.
@MainActor
final class SpeedTest: ObservableObject {
    static let shared = SpeedTest()
    static let flashAttentionKey = "flashAttention"
    static let threadsKey = "whisperThreads"

    /// whisper.cpp's default, which the app used before the test existed.
    nonisolated static var flashAttention: Bool {
        UserDefaults.standard.object(forKey: flashAttentionKey) as? Bool ?? true
    }

    /// 0 means `WhisperContext.defaultThreads`.
    nonisolated static var threads: Int {
        UserDefaults.standard.integer(forKey: threadsKey)
    }

    struct Trial: Identifiable {
        let id = UUID()
        let flashAttention: Bool
        let threads: Int
        let seconds: Double
        /// Whether the text matched the one with the settings in use before the test.
        let sameText: Bool
    }

    @Published private(set) var trials: [Trial] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var hasRecording = FileManager.default.fileExists(atPath: SpeedTest.recordingURL.path)

    private nonisolated static var recordingURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LastRecording.f32")
    }

    /// Keeps the last keyboard recording (16 kHz mono Float32) for the test.
    nonisolated static func save(_ samples: [Float]) {
        guard samples.count >= Int(AudioLoader.sampleRate) else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        Task.detached(priority: .utility) {
            try? data.write(to: recordingURL, options: .atomic)
            await MainActor.run { SpeedTest.shared.hasRecording = true }
        }
    }

    /// Settings in use, as shown in the app.
    static var summary: String {
        describe(flashAttention: flashAttention, threads: threads > 0 ? threads : WhisperContext.defaultThreads)
    }

    static func describe(flashAttention: Bool, threads: Int) -> String {
        "Flash attention \(flashAttention ? "روشن" : "خاموش")، \(threads) رشته"
    }

    func run() {
        guard !isRunning else { return }
        Task { await measureAll() }
    }

    private func measureAll() async {
        guard let data = try? Data(contentsOf: Self.recordingURL) else {
            status = "ابتدا یک بار با کیبورد دیکته کنید."
            return
        }
        // 15 s is enough: shorter clips still fill the encoder's 20 s window.
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(15 * Int(AudioLoader.sampleRate))) }
        isRunning = true
        trials = []
        defer { isRunning = false }

        let model = Transcriber.shared
        let currentAttention = Self.flashAttention
        let currentThreads = Self.threads > 0 ? Self.threads : WhisperContext.defaultThreads
        let threadChoices = Array(2...max(2, min(8, ProcessInfo.processInfo.activeProcessorCount)))
            .filter { $0 != currentThreads }
        let total = 2 + threadChoices.count
        var reference = ""

        func measure(_ flashAttention: Bool, _ threads: Int) async throws -> Double {
            status = "در حال آزمون \(trials.count + 1) از \(total)…"
            let (text, seconds) = try await model.measure(samples: samples, flashAttention: flashAttention, threads: threads)
            if trials.isEmpty { reference = text }
            trials.append(Trial(flashAttention: flashAttention, threads: threads, seconds: seconds, sameText: text == reference))
            log.info("\(flashAttention ? "flash" : "no flash", privacy: .public), \(threads) threads: \(seconds, format: .fixed(precision: 2)) s")
            return seconds
        }

        do {
            status = "در حال آماده شدن…"
            // The first run after loading is slower; it is not counted.
            _ = try await model.measure(samples: samples, flashAttention: currentAttention, threads: currentThreads)
            let base = try await measure(currentAttention, currentThreads)
            let flipped = try await measure(!currentAttention, currentThreads)
            let attention = flipped < base ? !currentAttention : currentAttention
            for threads in threadChoices {
                _ = try await measure(attention, threads)
            }
            guard let best = trials.min(by: { $0.seconds < $1.seconds }) else { return }
            UserDefaults.standard.set(best.flashAttention, forKey: Self.flashAttentionKey)
            UserDefaults.standard.set(best.threads, forKey: Self.threadsKey)
            let saved = (1 - best.seconds / base) * 100
            status = saved >= 1
                ? String(format: "سریع‌ترین انتخاب شد: %.0f٪ سریع‌تر از تنظیم قبلی.", saved)
                : "تنظیم قبلی سریع‌ترین بود و تغییری نکرد."
        } catch {
            status = "آزمون کامل نشد: \(error.localizedDescription)"
        }
        // The model may still be loaded with the other flash attention setting.
        model.useFlashAttentionSetting()
    }
}
