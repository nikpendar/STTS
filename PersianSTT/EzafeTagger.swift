import CoreML
import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "voice")

/// Which words of a clause take the Ezafe («کتابِ بزرگِ من»), for the voice's phonemizer: an ALBERT-fa
/// tagger (HooshvareLab, Apache-2.0) fine-tuned on HomoRich-G2P-Persian (CC0) Ezafe labels, F1 96
/// against Homo-GE2PE's own 91.5 (scripts/ezafe, release tts-fa-ezafe). A compiled Core ML model with
/// 8-bit weights; it reads the same SentencePiece pieces as the punctuation tagger (punct-vocab.tsv),
/// which .github/workflows/ezafe-coreml.yml checks. Not thread safe; one caller at a time.
final class EzafeTagger {
    private let model: MLModel
    private let tokenizer: PunctTokenizer

    /// `model`: Ezafe.mlmodelc; `vocabulary`: punct-vocab.tsv (with punct-info.json beside it).
    init(model url: URL, vocabulary: URL) throws {
        let started = CFAbsoluteTimeGetCurrent()
        tokenizer = try PunctTokenizer(vocabulary: vocabulary)
        let config = MLModelConfiguration()
        // Clauses of a few words: the CPU answers sooner than a trip to the Neural Engine.
        config.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: url, configuration: config)
        log.info("Ezafe tagger loaded in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }

    /// The tagger's pieces of each word, as the model reads them.
    func pieces(_ words: [String]) -> [[Int32]] {
        words.map { tokenizer.encode(word: AutoPunctuation.modelWord($0)) }
    }

    /// Whether each word takes the Ezafe: the tagger's label on the word's last piece; nil when the
    /// model fails. The phonemizer gives it at most 24 words at a time.
    func flags(_ words: [String]) -> [Bool]? {
        var ids: [Int32] = [tokenizer.cls]
        var last: [Int?] = []
        for p in pieces(words) {
            ids += p
            last.append(p.isEmpty ? nil : ids.count - 1)
        }
        ids.append(tokenizer.sep)
        guard ids.count <= 256 else { return nil }
        do {
            let shape = [1, NSNumber(value: ids.count)]
            let input = try MLMultiArray(shape: shape, dataType: .int32)
            let mask = try MLMultiArray(shape: shape, dataType: .int32)
            for (i, id) in ids.enumerated() {
                input[i] = NSNumber(value: id)
                mask[i] = 1
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask])
            guard let logits = try model.prediction(from: provider).featureValue(for: "logits")?.multiArrayValue else {
                return nil
            }
            return last.map { (position: Int?) -> Bool in
                guard let position else { return false }
                return logits[position * 2 + 1].floatValue > logits[position * 2].floatValue
            }
        } catch {
            log.error("Ezafe tagger failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
