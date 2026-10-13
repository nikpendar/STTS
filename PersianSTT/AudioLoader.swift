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

/// Decodes recordings into the samples whisper.cpp takes (the dictation shortcut's WAV), and
/// finds the pauses long recordings are cut at.
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

    /// RMS level of each 0.1 s of `samples`.
    private static func frameLevels(_ samples: [Float]) -> [Float] {
        let frame = Int(sampleRate) / 10
        return stride(from: 0, to: samples.count - frame + 1, by: frame).map { start in
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            return (sum / Float(frame)).squareRoot()
        }
    }

    /// Where to split a piece of at least 10 s: the latest pause after 6 s (0.3 s quieter than a
    /// third of the average level), else, once the piece reaches 20 s, its quietest point after 10 s.
    static func pause(in samples: [Float]) -> Int? {
        let frame = Int(sampleRate) / 10
        let levels = frameLevels(samples)
        guard levels.count > 64 else { return nil }
        let quiet = levels.reduce(0, +) / Float(levels.count) / 3
        for i in stride(from: levels.count - 3, through: 61, by: -1)
        where levels[i - 1] < quiet && levels[i] < quiet && levels[i + 1] < quiet {
            return i * frame + frame / 2
        }
        guard levels.count >= 200 else { return nil }
        let quietest = (100..<200).min { levels[$0] < levels[$1] } ?? 150
        return quietest * frame + frame / 2
    }

    /// The middle of the quietest 0.1 s after 6 s, for a piece with no pause.
    static func quietest(in samples: [Float]) -> Int {
        let frame = Int(sampleRate) / 10
        let levels = frameLevels(samples)
        guard levels.count > 60 else { return samples.count }
        let quietest = (60..<levels.count).min { levels[$0] < levels[$1] } ?? 60
        return quietest * frame + frame / 2
    }
}
