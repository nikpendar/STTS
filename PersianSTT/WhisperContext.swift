import Foundation
import os
import whisper

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "whisper")

enum WhisperError: LocalizedError {
    case cannotLoadModel
    case transcriptionFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotLoadModel: return "بارگذاری مدل ناموفق بود."
        case .transcriptionFailed(let code): return "تبدیل ناموفق بود (کد \(code))."
        case .cancelled: return "تبدیل لغو شد."
        }
    }
}

/// Thin wrapper around a whisper.cpp context. The actor serializes access,
/// since a whisper context must not be used from two threads at once.
actor WhisperContext {
    private let context: OpaquePointer

    /// How long one transcription took, split as the time estimate needs it.
    struct Result {
        let text: String
        /// Mel spectrogram and encoder, which scale with the encoder window.
        let encodeSeconds: TimeInterval
        let totalSeconds: TimeInterval
    }

    init(path: String) throws {
        var params = whisper_context_default_params()
        // CPU only: the keyboard session transcribes while the app is in the background,
        // where iOS does not allow GPU (Metal) work.
        params.use_gpu = false
        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw WhisperError.cannotLoadModel
        }
        context = ctx
    }

    deinit {
        whisper_free(context)
    }

    /// `samples` must be 16 kHz mono Float32 PCM.
    /// `minimumAudioContext` limits the encoder to the recorded length (but not below this many
    /// frames) instead of a full 30 s window; 0 keeps the full window. It must be 0 when a Core ML
    /// encoder is loaded: that encoder has a fixed 30 s input and always produces the full context.
    /// Setting `abort` from any thread stops this transcription, even before it has started.
    /// `preview` is for live text while the user is still speaking: one segment, no timestamps,
    /// no temperature fallback and a token cap. Without these a pass over the first second or two
    /// of a recording could loop on repeated tokens for close to a minute.
    /// `onEncoded` is called (on whisper's thread) when the encoder
    /// has finished the first 30 s window, so a progress estimate can be corrected.
    func transcribe(samples: [Float], minimumAudioContext: Int, abort: AbortFlag,
                    preview: Bool = false, onEncoded: (@Sendable () -> Void)? = nil) throws -> Result {
        guard !abort.isSet else { throw WhisperError.cancelled }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let threads = Self.defaultThreads
        let audioContext = minimumAudioContext > 0
            ? Self.audioContext(sampleCount: samples.count, minimum: minimumAudioContext) : 0
        let timing = PassTiming(onEncoded: onEncoded)

        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        params.encoder_begin_callback = { _, _, data in
            if let data { Unmanaged<PassTiming>.fromOpaque(data).takeUnretainedValue().encoderBegan() }
            return true
        }
        params.encoder_begin_callback_user_data = Unmanaged.passUnretained(timing).toOpaque()
        // Called on every decoding step; the logits are left as they are.
        params.logits_filter_callback = { _, _, _, _, _, data in
            if let data { Unmanaged<PassTiming>.fromOpaque(data).takeUnretainedValue().decodeStep() }
        }
        params.logits_filter_callback_user_data = Unmanaged.passUnretained(timing).toOpaque()

        let code: Int32 = "fa".withCString { lang in
            params.language = lang
            params.translate = false
            params.no_context = true
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.n_threads = Int32(threads)
            params.audio_ctx = audioContext
            // When a result fails the confidence checks, whisper.cpp decodes again at a higher
            // temperature, by default with 5 decoders at once. One is as accurate (FLEURS 11.0%,
            // Common Voice 20.2% WER either way) and costs a fifth when it happens.
            params.greedy.best_of = 1
            if preview {
                params.single_segment = true
                params.no_timestamps = true
                params.temperature_inc = 0
                params.max_tokens = Int32(Double(samples.count) / 16_000 * 10) + 16
            }
            let qos = qos_class_self().rawValue
            let code = withExtendedLifetime(timing) {
                samples.withUnsafeBufferPointer { buf in
                    whisper_full(context, params, buf.baseAddress, Int32(buf.count))
                }
            }
            log.info("whisper_full: \(samples.count / 16_000) s, ctx \(audioContext), preview \(preview), threads \(threads), qos \(qos), \(timing.total, format: .fixed(precision: 2)) s (encode \(timing.encode, format: .fixed(precision: 2)) s), code \(code)")
            return code
        }
        guard code == 0 else {
            throw abort.isSet ? WhisperError.cancelled : WhisperError.transcriptionFailed(code)
        }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        return Result(text: text, encodeSeconds: timing.encode, totalSeconds: timing.total)
    }

    /// Two fewer threads than cores, as in whisper.cpp's iOS example.
    static var defaultThreads: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// The encoder produces 50 frames per second of audio, 1500 for a full 30 s window.
    /// Returns 0 (full window) for clips near or over 30 s, which are decoded in 30 s chunks.
    private static func audioContext(sampleCount: Int, minimum: Int) -> Int32 {
        let seconds = Double(sampleCount) / 16_000
        guard seconds < 28 else { return 0 }
        // Margin past the end of speech; very small contexts make Whisper hallucinate.
        let frames = Int(seconds * 50) + 128
        return Int32(min(1500, max(minimum, frames)))
    }
}

/// Times one transcription through whisper.cpp's callbacks: the encoder starts a 30 s window
/// (`encoder_begin_callback`), and the first decoding step after it (`logits_filter_callback`)
/// ends the encoding. The mel spectrogram before the first window counts as encoding.
private final class PassTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var encodeStart: Date?
    private var encodeSeconds: TimeInterval = 0
    private var windows = 0
    private let onEncoded: (@Sendable () -> Void)?

    init(onEncoded: (@Sendable () -> Void)?) {
        self.onEncoded = onEncoded
    }

    func encoderBegan() {
        lock.lock()
        encodeStart = windows == 0 ? started : Date()
        windows += 1
        lock.unlock()
    }

    func decodeStep() {
        lock.lock()
        let first = encodeStart != nil && windows == 1
        if let start = encodeStart {
            encodeSeconds += Date().timeIntervalSince(start)
            encodeStart = nil
        }
        lock.unlock()
        if first { onEncoded?() }
    }

    var encode: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return encodeSeconds
    }

    var total: TimeInterval { Date().timeIntervalSince(started) }
}

final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func clear() {
        lock.lock()
        value = false
        lock.unlock()
    }
}
