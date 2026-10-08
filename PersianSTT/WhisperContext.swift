import Foundation
import whisper

enum WhisperError: LocalizedError {
    case cannotLoadModel
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .cannotLoadModel: return "بارگذاری مدل ناموفق بود."
        case .transcriptionFailed(let code): return "تبدیل ناموفق بود (کد \(code))."
        }
    }
}

/// Thin wrapper around a whisper.cpp context. The actor serializes access,
/// since a whisper context must not be used from two threads at once.
actor WhisperContext {
    private let context: OpaquePointer

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
    /// `shortenAudioContext` limits the encoder to the recorded length instead of a full
    /// 30 s window. It must stay off when a Core ML encoder is loaded: that encoder has a
    /// fixed 30 s input and always produces the full context.
    func transcribe(samples: [Float], shortenAudioContext: Bool) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let audioContext = shortenAudioContext ? Self.audioContext(sampleCount: samples.count) : 0

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
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(context, params, buf.baseAddress, Int32(buf.count))
            }
        }
        guard code == 0 else { throw WhisperError.transcriptionFailed(code) }

        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        return text
    }

    /// The encoder produces 50 frames per second of audio, 1500 for a full 30 s window.
    /// Returns 0 (full window) for clips near or over 30 s, which are decoded in 30 s chunks.
    private static func audioContext(sampleCount: Int) -> Int32 {
        let seconds = Double(sampleCount) / 16_000
        guard seconds < 28 else { return 0 }
        // Margin past the end of speech; very small contexts make Whisper hallucinate.
        let frames = Int(seconds * 50) + 128
        return Int32(min(1500, max(384, frames)))
    }
}
