import Accelerate
import AppleArchive
import CoreML
import Foundation
import System

enum ShenavaError: LocalizedError {
    case missing(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let what): return "فایل مدل پیدا نشد: \(what)"
        case .unreadable(let what): return "فایل مدل باز نشد: \(what)"
        }
    }
}

/// Cache-aware streaming CTC recognizer for the Shenava Core ML step models (Koochik).
///
/// NeMo log-mel features (preemphasis 0.97, 512-point FFT of a 400-sample Hann window, hop 160,
/// centred with reflect padding, Slaney mel, natural log), then one prediction per 8 new feature
/// frames (80 ms) on 17 frames (9 carried over), with the encoder caches fed back each step, and
/// greedy CTC over the per-step logits. Matches scripts/shenava_stream.py, the benchmark.
///
/// `resources` holds the model's sidecars: tokens.json, preprocessor.json,
/// mel_filters_slaney_80x257.json and manifest.json. A fine-tuned model keeps them.
/// Not thread safe: use from one serial queue (`StreamWorker`).
final class ShenavaStream {
    let model: MLModel
    private let tokens: [String]
    private let blank: Int
    /// Tokens never written: <unk> and other markers, and the model's own punctuation, since
    /// punctuation is dictated by voice (`VoiceCommands`), as with Whisper before.
    private let skipped: Set<Int>
    private let melFilters: [[Float]]  // 80 x 257
    private let logGuard: Float
    private let preemphasis: Float
    private let padValue: Float

    private let nFFT = 512
    private let hop = 160
    private let nMels = 80
    private let framesIn: Int     // 17
    private let shift: Int        // 8 feature frames = 80 ms
    private let keep: Int         // 9 pre-encode cache frames
    private let window: [Float]
    private let dft: vDSP.DFT<Float>

    /// Steps without a new token before one that starts after a pause: 0.64 s. The keyboard
    /// reads spoken commands by pauses (`DictationBridge.pauseMark`).
    private let pauseSteps = 8

    // Feature extraction state.
    private var head: [Float] = []        // first preemphasized samples, until the start padding is possible
    private var started = false
    private var signal: [Float] = []      // padded, preemphasized samples not yet framed
    private var lastRaw: Float = 0
    private var firstSample = true

    // Model state.
    private var features: [Float] = []    // frame-major, nMels per frame, not yet consumed
    private let input: MLMultiArray
    private var cacheChannel: MLMultiArray
    private var cacheTime: MLMultiArray
    /// The empty caches a new utterance starts from. The model's own output arrays are fed back as
    /// the next caches, and those can be fp16 or padded (an ML program), so they are replaced, not
    /// cleared in place.
    private let emptyChannel: MLMultiArray
    private let emptyTime: MLMultiArray
    private var previous: Int
    private var lastTokenStep = 0

    /// The text so far, with a pause mark where the speaker paused.
    private(set) var text = ""
    private(set) var steps = 0
    private(set) var computeSeconds: Double = 0

    init(model modelURL: URL, resources dir: URL, computeUnits: MLComputeUnits) throws {
        func json(_ name: String) throws -> Any {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw ShenavaError.missing(name) }
            return try JSONSerialization.jsonObject(with: data)
        }
        let pre = try json("preprocessor.json") as? [String: Any] ?? [:]
        let manifest = try json("manifest.json") as? [String: Any] ?? [:]
        let vocab = try json("tokens.json") as? [String: Any] ?? [:]
        let vocabTokens = vocab["tokens"] as? [String] ?? []
        tokens = vocabTokens
        blank = vocab["blank_id"] as? Int ?? vocabTokens.count
        // Punctuation, the tatweel and direction marks (U+202B is in the vocabulary).
        let unwritten = CharacterSet(charactersIn: ".،,؛;:؟?!«»\"()*ـ")
            .union(.punctuationCharacters).union(.symbols).union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x202A)!...Unicode.Scalar(0x202E)!))
        skipped = Set(vocabTokens.indices.filter { k in
            let token = vocabTokens[k]
            if token.hasPrefix("<"), token.hasSuffix(">") { return true }
            let visible = token.replacingOccurrences(of: "▁", with: "")
            return !visible.isEmpty && visible.unicodeScalars.allSatisfy { unwritten.contains($0) }
        })
        let filters = (try json("mel_filters_slaney_80x257.json") as? [[Double]] ?? []).map { $0.map(Float.init) }
        guard filters.count == 80, filters.allSatisfy({ $0.count == 257 }) else {
            throw ShenavaError.missing("mel_filters_slaney_80x257.json")
        }
        melFilters = filters
        logGuard = Float(pre["log_zero_guard_value"] as? Double ?? 5.960464477539063e-08)
        preemphasis = Float(pre["preemphasis"] as? Double ?? 0.97)
        padValue = Float(pre["pad_value"] as? Double ?? 0)
        shift = manifest["shift_size"] as? Int ?? 8
        framesIn = manifest["feature_frames"] as? Int ?? 17
        keep = framesIn - shift

        let winLength = pre["win_length"] as? Int ?? 400
        var w = [Float](repeating: 0, count: nFFT)
        let offset = (nFFT - winLength) / 2
        for i in 0..<winLength {
            w[offset + i] = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(winLength - 1))
        }
        window = w
        dft = vDSP.DFT(count: nFFT, direction: .forward, transformType: .complexComplex, ofType: Float.self)!

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw ShenavaError.missing(modelURL.lastPathComponent) }
        model = try MLModel(contentsOf: modelURL, configuration: config)

        let inputs = model.modelDescription.inputDescriptionsByName
        func zeros(_ name: String) throws -> MLMultiArray {
            guard let shape = inputs[name]?.multiArrayConstraint?.shape else { throw ShenavaError.missing(name) }
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            memset(array.dataPointer, 0, array.count * MemoryLayout<Float>.size)
            return array
        }
        input = try zeros("processed_signal")
        emptyChannel = try zeros("cache_last_channel")
        emptyTime = try zeros("cache_last_time")
        cacheChannel = emptyChannel
        cacheTime = emptyTime
        previous = blank
        reset()
    }

    /// Starts a new utterance: fresh caches, features and text.
    func reset() {
        head = []
        started = false
        signal = []
        lastRaw = 0
        firstSample = true
        features = [Float](repeating: padValue, count: keep * nMels)
        cacheChannel = emptyChannel
        cacheTime = emptyTime
        previous = blank
        lastTokenStep = steps
        text = ""
    }

    /// Feeds 16 kHz mono samples; runs every model step the new audio completes.
    /// Returns true when the text changed.
    @discardableResult
    func accept(_ samples: [Float]) throws -> Bool {
        var emphasized = [Float]()
        emphasized.reserveCapacity(samples.count)
        for x in samples {
            emphasized.append(firstSample ? x : x - preemphasis * lastRaw)
            firstSample = false
            lastRaw = x
        }
        if started {
            signal.append(contentsOf: emphasized)
        } else {
            head.append(contentsOf: emphasized)
            let pad = nFFT / 2
            if head.count > pad {
                // Reflect padding at the start, as torch.stft(center=True, pad_mode="reflect").
                signal = Array(head[1...pad].reversed()) + head
                head = []
                started = true
            }
        }
        computeFrames()
        return try runSteps()
    }

    /// Ends the utterance: reflect-pads the end, pads the last chunk and runs the remaining steps.
    func finish() throws {
        let pad = nFFT / 2
        if started, signal.count > pad {
            signal.append(contentsOf: signal[(signal.count - pad - 1)..<(signal.count - 1)].reversed())
            computeFrames()
        }
        let frames = features.count / nMels - keep
        let missing = (shift - frames % shift) % shift
        features.append(contentsOf: [Float](repeating: padValue, count: missing * nMels))
        try runSteps()
    }

    private func computeFrames() {
        var real = [Float](repeating: 0, count: nFFT)
        let zeroImag = [Float](repeating: 0, count: nFFT)
        var outReal = [Float](repeating: 0, count: nFFT)
        var outImag = [Float](repeating: 0, count: nFFT)
        var power = [Float](repeating: 0, count: nFFT / 2 + 1)
        var consumed = 0
        while consumed + nFFT <= signal.count {
            signal.withUnsafeBufferPointer { s in
                vDSP.multiply(UnsafeBufferPointer(rebasing: s[consumed..<(consumed + nFFT)]), window, result: &real)
            }
            dft.transform(inputReal: real, inputImaginary: zeroImag, outputReal: &outReal, outputImaginary: &outImag)
            for k in 0...(nFFT / 2) {
                power[k] = outReal[k] * outReal[k] + outImag[k] * outImag[k]
            }
            for m in 0..<nMels {
                features.append(log(vDSP.dot(melFilters[m], power) + logGuard))
            }
            consumed += hop
        }
        if consumed > 0 { signal.removeFirst(consumed) }
    }

    private func runSteps() throws -> Bool {
        var changed = false
        while features.count >= framesIn * nMels {
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: nMels * framesIn)
            for t in 0..<framesIn {
                for m in 0..<nMels {
                    ptr[m * framesIn + t] = features[t * nMels + m]
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "processed_signal": input,
                "cache_last_channel": cacheChannel,
                "cache_last_time": cacheTime,
            ])
            let start = CFAbsoluteTimeGetCurrent()
            let out = try model.prediction(from: provider)
            computeSeconds += CFAbsoluteTimeGetCurrent() - start
            steps += 1
            if let next = out.featureValue(for: "cache_last_channel_next")?.multiArrayValue { cacheChannel = next }
            if let next = out.featureValue(for: "cache_last_time_next")?.multiArrayValue { cacheTime = next }
            features.removeFirst(shift * nMels)
            guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { continue }
            let vocabSize = logits.shape.last?.intValue ?? logits.count
            for frame in 0..<(logits.count / vocabSize) {
                let k = argmax(logits, from: frame * vocabSize, count: vocabSize)
                if k != previous, k != blank, k < tokens.count, !skipped.contains(k) {
                    var piece = tokens[k].replacingOccurrences(of: "▁", with: " ")
                    if !text.isEmpty, steps - lastTokenStep >= pauseSteps {
                        text.append(DictationBridge.pauseMark)
                        piece = piece.trimmingCharacters(in: .whitespaces)
                    }
                    text += piece
                    lastTokenStep = steps
                    changed = true
                }
                previous = k
            }
        }
        return changed
    }

    private func argmax(_ array: MLMultiArray, from start: Int, count: Int) -> Int {
        var best = 0
        var bestValue = -Float.infinity
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for i in 0..<count where p[start + i] > bestValue {
                bestValue = p[start + i]
                best = i
            }
        case .float16:
            let p = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for i in 0..<count where Float(p[start + i]) > bestValue {
                bestValue = Float(p[start + i])
                best = i
            }
        default:
            for i in 0..<count {
                let v = array[start + i].floatValue
                if v > bestValue {
                    bestValue = v
                    best = i
                }
            }
        }
        return best
    }
}

/// Speech model files: a .mlmodel (the NeuralNetwork version, one file) or an Apple Archive
/// (.aar) of an ML program's .mlpackage folder, so that Files and a release asset carry one file.
enum ModelArchive {
    static let extensions = ["mlmodel", "aar"]

    /// Compiles a model file (kind: its extension, if the file's name lacks it) into a temporary
    /// .mlmodelc, which the caller moves or deletes.
    static func compile(_ file: URL, kind: String? = nil) async throws -> URL {
        guard (kind ?? file.pathExtension).lowercased() == "aar" else { return try await MLModel.compileModel(at: file) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent("Koochik.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try extract(file, to: package)
        return try await MLModel.compileModel(at: package)
    }

    /// Unpacks an archive made with `aa archive -d Koochik.mlpackage -o Koochik.aar`.
    static func extract(_ archive: URL, to folder: URL) throws {
        let name = archive.lastPathComponent
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [],
                                                      permissions: FilePermissions(rawValue: 0o644)) else {
            throw ShenavaError.unreadable(name)
        }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw ShenavaError.unreadable(name) }
        defer { try? decompressed.close() }
        guard let decoded = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw ShenavaError.unreadable(name) }
        defer { try? decoded.close() }
        guard let extracted = ArchiveStream.extractStream(extractingTo: FilePath(folder.path),
                                                          flags: [.ignoreOperationNotPermitted]) else {
            throw ShenavaError.unreadable(name)
        }
        defer { try? extracted.close() }
        _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extracted)
    }
}

/// The memory iOS counts against the app (and ends it for): physical footprint now and at its peak, in MB.
enum MemoryFootprint {
    static var megabytes: (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6)
    }
}
