import AVFoundation

enum AudioLoaderError: LocalizedError {
    case unsupportedFormat
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "قالب فایل صوتی پشتیبانی نمی‌شود."
        case .conversionFailed: return "تبدیل فایل صوتی ناموفق بود."
        }
    }
}

enum AudioLoader {
    static let sampleRate: Double = 16_000

    /// Reads any audio file AVFoundation can open (wav, m4a, mp3, ...) and
    /// returns 16 kHz mono Float32 samples, the input whisper.cpp expects.
    static func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioLoaderError.unsupportedFormat
        }
        try file.read(into: inBuffer)

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioLoaderError.unsupportedFormat
        }
        converter.downmix = true

        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * sampleRate / inFormat.sampleRate) + 4096
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AudioLoaderError.conversionFailed
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error {
            throw conversionError ?? AudioLoaderError.conversionFailed
        }
        guard let channel = outBuffer.floatChannelData?[0] else {
            throw AudioLoaderError.conversionFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
    }
}
