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
        #if targetEnvironment(simulator)
        params.use_gpu = false
        #endif
        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw WhisperError.cannotLoadModel
        }
        context = ctx
    }

    deinit {
        whisper_free(context)
    }

    /// `samples` must be 16 kHz mono Float32 PCM.
    func transcribe(samples: [Float]) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))

        let code: Int32 = "fa".withCString { lang in
            params.language = lang
            params.translate = false
            params.no_context = true
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.n_threads = Int32(threads)
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
}
