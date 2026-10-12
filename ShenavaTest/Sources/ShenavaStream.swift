import Accelerate
import CoreML
import Foundation

/// One bundled Shenava model: Models/<folder>/ holds model.mlmodelc plus the repo's sidecars
/// (tokens.json, preprocessor.json, mel_filters_slaney_80x257.json, manifest.json).
enum ShenavaModel: String, CaseIterable, Identifiable {
    case koochik, rizeh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .koochik: return "کوچیک ۲۱۲MB"
        case .rizeh: return "ریزه ۵۲MB"
        }
    }

    var folder: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Models/\(rawValue)", isDirectory: true)
    }
}

enum ShenavaError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let what): return "فایل مدل پیدا نشد: \(what)"
        }
    }
}

/// Cache-aware streaming CTC recognizer for the Shenava Core ML step models.
///
/// Mirrors scripts/shenava_stream.py (the CI benchmark): NeMo log-mel features (preemphasis 0.97,
/// 512-point FFT of a 400-sample Hann window, hop 160, centred with reflect padding, Slaney mel,
/// natural log), then one prediction per 8 new feature frames (80 ms) on 17 frames (9 carried over),
/// with the encoder caches fed back each step, and greedy CTC over the per-step logits.
/// Not thread safe: use from one serial queue.
final class ShenavaStream {
    let model: MLModel
    private let tokens: [String]
    private let blank: Int
    private let special: Set<Int>
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

    // Feature extraction state.
    private var head: [Float] = []        // first preemphasized samples, until the start padding is possible
    private var started = false
    private var signal: [Float] = []      // padded, preemphasized samples from frame `nextFrame` on
    private var lastRaw: Float = 0
    private var firstSample = true
    private var nextFrame = 0

    // Model state.
    private var features: [Float] = []    // frame-major, nMels per frame, not yet consumed
    private let input: MLMultiArray
    private var cacheChannel: MLMultiArray
    private var cacheTime: MLMultiArray
    private var previous: Int

    private(set) var text = ""
    private(set) var steps = 0
    private(set) var computeSeconds: Double = 0
    private(set) var lastStepMs: Double = 0

    var audioMsPerStep: Int { shift * hop * 1000 / 16_000 }

    convenience init(model kind: ShenavaModel, computeUnits: MLComputeUnits) throws {
        try self.init(directory: kind.folder, computeUnits: computeUnits)
    }

    init(directory dir: URL, computeUnits: MLComputeUnits) throws {
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
        special = Set(vocabTokens.indices.filter { vocabTokens[$0].hasPrefix("<") && vocabTokens[$0].hasSuffix(">") })
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
        let modelURL = dir.appendingPathComponent("model.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw ShenavaError.missing("model.mlmodelc") }
        model = try MLModel(contentsOf: modelURL, configuration: config)

        let inputs = model.modelDescription.inputDescriptionsByName
        func zeros(_ name: String) throws -> MLMultiArray {
            guard let shape = inputs[name]?.multiArrayConstraint?.shape else { throw ShenavaError.missing(name) }
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            memset(array.dataPointer, 0, array.count * MemoryLayout<Float>.size)
            return array
        }
        input = try zeros("processed_signal")
        cacheChannel = try zeros("cache_last_channel")
        cacheTime = try zeros("cache_last_time")
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
        nextFrame = 0
        features = [Float](repeating: padValue, count: keep * nMels)
        for array in [cacheChannel, cacheTime] {
            memset(array.dataPointer, 0, array.count * MemoryLayout<Float>.size)
        }
        previous = blank
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
            nextFrame += 1
        }
        if consumed > 0 { signal.removeFirst(consumed) }
    }

    private func runSteps() throws -> Bool {
        var changed = false
        let stride = framesIn
        while features.count >= framesIn * nMels {
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: nMels * framesIn)
            for t in 0..<framesIn {
                for m in 0..<nMels {
                    ptr[m * stride + t] = features[t * nMels + m]
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "processed_signal": input,
                "cache_last_channel": cacheChannel,
                "cache_last_time": cacheTime,
            ])
            let start = CFAbsoluteTimeGetCurrent()
            let out = try model.prediction(from: provider)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            computeSeconds += elapsed
            lastStepMs = elapsed * 1000
            steps += 1
            if let next = out.featureValue(for: "cache_last_channel_next")?.multiArrayValue { cacheChannel = next }
            if let next = out.featureValue(for: "cache_last_time_next")?.multiArrayValue { cacheTime = next }
            features.removeFirst(shift * nMels)
            guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { continue }
            let vocabSize = logits.shape.last?.intValue ?? logits.count
            for frame in 0..<(logits.count / vocabSize) {
                let k = argmax(logits, from: frame * vocabSize, count: vocabSize)
                if k != previous, k != blank, !special.contains(k), k < tokens.count {
                    text += tokens[k].replacingOccurrences(of: "▁", with: " ")
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
