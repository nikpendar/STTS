import AVFoundation
import AudioToolbox

/// Reads an audio file a piece at a time as 16 kHz mono Float32, the speech model's input, so
/// an hour-long file never sits in memory whole. Opens what AVFoundation opens (m4a, mp3, wav,
/// aac, caf...) and Ogg Opus, the format of Telegram and WhatsApp voice messages, which
/// AVFoundation does not open: `OggOpusReader` takes the packets out of the Ogg pages and
/// Apple's own Opus decoder (AudioToolbox) decodes them.
protocol AudioStreamReader: AnyObject {
    /// Length in seconds, when the file says (for progress); 0 if unknown.
    var duration: Double { get }
    /// The next piece of about `seconds`, or an empty array at the end.
    func read(seconds: Double) throws -> [Float]
}

enum AudioStream {
    static let sampleRate: Double = 16_000

    static func open(_ url: URL) throws -> AudioStreamReader {
        if OggOpusReader.isOgg(url) { return try OggOpusReader(url: url) }
        return try FileReader(url: url)
    }

    /// The 16 kHz mono format the readers return.
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 1, interleaved: false)!

    /// Resamples and downmixes PCM to `format`, a buffer at a time, keeping the converter's
    /// state between buffers so the pieces join without clicks.
    final class Resampler {
        private let converter: AVAudioConverter
        private let input: AVAudioFormat

        init(from input: AVAudioFormat) throws {
            guard let converter = AVAudioConverter(from: input, to: AudioStream.format) else {
                throw AudioLoaderError.unsupportedFormat
            }
            converter.downmix = true
            self.converter = converter
            self.input = input
        }

        /// The samples of `buffer`; `last` flushes what the converter holds back.
        func convert(_ buffer: AVAudioPCMBuffer?, last: Bool = false) throws -> [Float] {
            let frames = Double(buffer?.frameLength ?? 0)
            let capacity = AVAudioFrameCount(frames * AudioStream.sampleRate / input.sampleRate) + 2048
            guard let out = AVAudioPCMBuffer(pcmFormat: AudioStream.format, frameCapacity: capacity) else {
                throw AudioLoaderError.conversionFailed
            }
            var given = buffer == nil
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = last ? .endOfStream : .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if status == .error { throw error ?? AudioLoaderError.conversionFailed }
            guard let channel = out.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        }
    }
}

/// Files AVFoundation opens.
final class FileReader: AudioStreamReader {
    private let file: AVAudioFile
    private let resampler: AudioStream.Resampler
    private var finished = false
    let duration: Double

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        resampler = try AudioStream.Resampler(from: file.processingFormat)
        duration = file.processingFormat.sampleRate > 0 ? Double(file.length) / file.processingFormat.sampleRate : 0
    }

    func read(seconds: Double) throws -> [Float] {
        guard !finished else { return [] }
        let format = file.processingFormat
        // Reading at the end throws, so the end is found by position.
        let left = max(0, file.length - file.framePosition)
        let frames = AVAudioFrameCount(min(AVAudioFramePosition(max(0.1, seconds) * format.sampleRate), left))
        guard frames > 0 else {
            finished = true
            return try resampler.convert(nil, last: true)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioLoaderError.conversionFailed
        }
        try file.read(into: buffer, frameCount: frames)
        if buffer.frameLength == 0 {
            finished = true
            return try resampler.convert(nil, last: true)
        }
        return try resampler.convert(buffer)
    }
}

/// Ogg Opus (RFC 7845): Ogg pages carry Opus packets; the first packet (OpusHead) gives the
/// channels and the samples to skip at the start, the second holds tags. Audio is always 48 kHz.
final class OggOpusReader: AudioStreamReader {
    private let handle: FileHandle
    private var pending = Data()        // bytes read from the file, not yet parsed into pages
    private var partial = Data()        // a packet continued on the next page
    private var packets: [Data] = []    // whole packets not yet decoded
    private var endOfFile = false
    private var headersSeen = 0
    private var channels: UInt32 = 1
    private var preSkip = 0             // 48 kHz samples to drop at the start
    private var decoder: AVAudioConverter?
    private var decoderFrames: UInt32 = 0
    private var pcm48: AVAudioFormat?
    private var resampler: AudioStream.Resampler?
    private var finished = false
    let duration: Double

    static func isOgg(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("OggS".utf8)
    }

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        duration = Self.lastGranule(url).map { Double($0) / 48_000 } ?? 0
        // The two header packets.
        while headersSeen < 2 {
            guard let packet = try nextPacket() else { throw AudioLoaderError.unsupportedFormat }
            try header(packet)
        }
    }

    deinit { try? handle.close() }

    private func header(_ packet: Data) throws {
        defer { headersSeen += 1 }
        guard headersSeen == 0 else { return }  // OpusTags
        let bytes = [UInt8](packet)
        guard bytes.count >= 19, Data(bytes[0..<8]) == Data("OpusHead".utf8) else {
            throw AudioLoaderError.unsupportedFormat
        }
        channels = UInt32(max(1, min(2, Int(bytes[9]))))
        // Mapping family 0 (mono, stereo) is the voice message case; more channels are not.
        guard bytes[9] <= 2 else { throw AudioLoaderError.unsupportedFormat }
        preSkip = Int(bytes[10]) | Int(bytes[11]) << 8
    }

    /// Samples (at 48 kHz) in an Opus packet, from its TOC byte (RFC 6716, 3.1).
    static func samplesPerPacket(_ packet: Data) -> UInt32 {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: UInt32   // in 48 kHz samples
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]
        case 12...15: frame = [480, 960][config % 2]
        default: frame = [120, 240, 480, 960][config % 4]
        }
        let count: UInt32
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default: count = packet.count > 1 ? UInt32(packet[packet.startIndex + 1] & 0x3F) : 0
        }
        return frame * count
    }

    /// The granule position of the file's last page: its length in 48 kHz samples.
    private static func lastGranule(_ url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > 65_536 ? size - 65_536 : 0
        try? handle.seek(toOffset: start)
        guard let tail = try? handle.readToEnd() else { return nil }
        let bytes = [UInt8](tail)
        guard bytes.count >= 14 else { return nil }
        var i = bytes.count - 14
        while i >= 0 {
            if bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53 {
                var granule: UInt64 = 0
                for k in 0..<8 { granule |= UInt64(bytes[i + 6 + k]) << (8 * UInt64(k)) }
                return granule == UInt64.max ? nil : granule
            }
            i -= 1
        }
        return nil
    }

    /// The next whole packet from the pages, nil at the end of the file.
    private func nextPacket() throws -> Data? {
        while packets.isEmpty {
            if !(try parsePage()) {
                if endOfFile { return nil }
                guard let more = try handle.read(upToCount: 65_536), !more.isEmpty else {
                    endOfFile = true
                    continue
                }
                pending.append(more)
            }
        }
        return packets.removeFirst()
    }

    /// Takes one page from `pending` into `packets`; false when a whole page is not there yet.
    private func parsePage() throws -> Bool {
        guard pending.count >= 27 else { return false }
        let base = pending.startIndex
        guard pending[base] == 0x4F, pending[base + 1] == 0x67, pending[base + 2] == 0x67, pending[base + 3] == 0x53 else {
            // Lost sync: look for the next page.
            if let next = pending.range(of: Data("OggS".utf8), in: (base + 1)..<pending.endIndex) {
                pending.removeSubrange(base..<next.lowerBound)
                return try parsePage()
            }
            pending.removeAll()
            return false
        }
        let segments = Int(pending[base + 26])
        guard pending.count >= 27 + segments else { return false }
        let lacing = pending[(base + 27)..<(base + 27 + segments)]
        let bodySize = lacing.reduce(0) { $0 + Int($1) }
        guard pending.count >= 27 + segments + bodySize else { return false }
        var offset = base + 27 + segments
        for size in lacing {
            partial.append(pending[offset..<(offset + Int(size))])
            offset += Int(size)
            if size < 255 {
                packets.append(partial)
                partial = Data()
            }
        }
        pending.removeSubrange(base..<offset)
        return true
    }

    /// A decoder for packets of `frames` samples. A file that changes frame size gets a new one.
    private func makeDecoder(frames: UInt32) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: frames, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                      channels: AVAudioChannelCount(channels), interleaved: false),
              let decoder = AVAudioConverter(from: opus, to: pcm) else {
            throw AudioLoaderError.unsupportedFormat
        }
        self.decoder = decoder
        decoderFrames = frames
        if pcm48 == nil {
            pcm48 = pcm
            resampler = try AudioStream.Resampler(from: pcm)
        }
    }

    func read(seconds: Double) throws -> [Float] {
        guard !finished else { return [] }
        var batch: [Data] = []
        var batchFrames: UInt32 = 0
        let wanted = UInt32(max(0.1, seconds) * 48_000)
        var output: [Float] = []
        while batchFrames < wanted {
            guard let packet = try nextPacket() else { break }
            let frames = Self.samplesPerPacket(packet)
            guard frames > 0 else { continue }
            if decoder == nil || frames != decoderFrames {
                if !batch.isEmpty {
                    output += try decode(batch)
                    batch = []
                }
                try makeDecoder(frames: frames)
            }
            batch.append(packet)
            batchFrames += frames
        }
        if !batch.isEmpty { output += try decode(batch) }
        if batchFrames == 0 {
            finished = true
            return try resampler?.convert(nil, last: true) ?? []
        }
        return output
    }

    private func decode(_ batch: [Data]) throws -> [Float] {
        guard let decoder, let pcm48, let resampler else { return [] }
        let totalBytes = batch.reduce(0) { $0 + $1.count }
        let maxPacket = batch.map(\.count).max() ?? 0
        let compressed = AVAudioCompressedBuffer(format: decoder.inputFormat, packetCapacity: AVAudioPacketCount(batch.count),
                                                 maximumPacketSize: maxPacket)
        var offset = 0
        let data = compressed.data.assumingMemoryBound(to: UInt8.self)
        for (i, packet) in batch.enumerated() {
            packet.copyBytes(to: data.advanced(by: offset), count: packet.count)
            compressed.packetDescriptions?[i] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
            offset += packet.count
        }
        compressed.packetCount = AVAudioPacketCount(batch.count)
        compressed.byteLength = UInt32(totalBytes)

        let frames = AVAudioFrameCount(batch.count) * decoderFrames
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm48, frameCapacity: frames + 960) else {
            throw AudioLoaderError.conversionFailed
        }
        var given = false
        var error: NSError?
        let status = decoder.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return compressed
        }
        if status == .error { throw error ?? AudioLoaderError.conversionFailed }
        // The encoder's lookahead at the start (pre-skip).
        if preSkip > 0, out.frameLength > 0 {
            let drop = min(Int(out.frameLength), preSkip)
            preSkip -= drop
            let left = Int(out.frameLength) - drop
            for c in 0..<Int(pcm48.channelCount) {
                if let channel = out.floatChannelData?[c], left > 0 {
                    channel.update(from: channel.advanced(by: drop), count: left)
                }
            }
            out.frameLength = AVAudioFrameCount(left)
        }
        return out.frameLength > 0 ? try resampler.convert(out) : []
    }
}
