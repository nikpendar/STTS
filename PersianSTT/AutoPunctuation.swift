import CoreML
import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "punctuation")

/// Commas, full stops and question marks for a finished dictation: a Persian ALBERT tagger (6
/// layers, 8-bit Core ML, 11 MB in Models/Punct) gives each word the mark that follows it. It was
/// trained on Persian Wikipedia and PersianQA (scripts/punct, release punct-albert6); on FLEURS
/// transcripts it places full stops with F1 94 and commas with precision 80 and recall 36.
///
/// It runs in the app, after the speech model and before the text goes to the keyboard, so the
/// keyboard's memory is not touched. The model loads at the first dictation and stays.
final class AutoPunctuation: @unchecked Sendable {
    static let shared = AutoPunctuation()

    /// The folder with Punct.mlmodelc and punct-vocab.tsv, nil in a build without them.
    static var directory: URL? {
        if let testDirectory { return testDirectory }
        return Bundle.main.url(forResource: "Models", withExtension: nil)
            .map { $0.appendingPathComponent("Punct") }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("punct-vocab.tsv").path) ? $0 : nil }
    }

    /// Tests/Punct: the release's files outside an app.
    nonisolated(unsafe) static var testDirectory: URL?

    private let lock = NSLock()
    private var model: MLModel?
    private var tokenizer: PunctTokenizer?
    private var failed = false

    /// The mark after each word, as the tagger's labels: none, comma, full stop, question mark.
    private static let marks = ["", "،", ".", "؟"]
    /// Model inputs are at most 128 pieces, with [CLS] and [SEP].
    private static let maxPieces = 126

    /// `text` with the marks put in; the text unchanged when the model is missing or fails.
    /// Pause marks (`DictationBridge.pauseMark`) and line breaks stay where they are.
    /// `quiet`: keys (`PersonalDictionary.key`) of words that become marks, after which and
    /// before which no mark is added.
    func punctuate(_ text: String, quiet: Set<String> = []) -> String {
        let started = CFAbsoluteTimeGetCurrent()
        // Words with the separators after them, so the text goes back together as it was.
        var words: [(word: String, after: String)] = []
        var leading = ""
        var current = ""
        for character in text {
            if character == " " || character == DictationBridge.pauseMark || character.isNewline {
                if !current.isEmpty {
                    words.append((current, String(character)))
                    current = ""
                } else if words.isEmpty {
                    leading.append(character)
                } else {
                    words[words.count - 1].after.append(character)
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append((current, "")) }
        guard !words.isEmpty, let labels = labels(for: words.map(\.word)) else { return text }

        var out = leading
        for (index, item) in words.enumerated() {
            out += item.word
            var label = labels[index]
            if !quiet.isEmpty, quiet.contains(PersonalDictionary.key(item.word))
                || (index + 1 < words.count && quiet.contains(PersonalDictionary.key(words[index + 1].word))) {
                label = 0
            }
            // A word that already ends in a mark keeps it.
            if label > 0, let last = item.word.last, !Self.endings.contains(last) {
                out += Self.marks[label]
            }
            out += item.after
        }
        log.info("punctuated \(words.count) words in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        return out
    }

    /// Each word's label (0 none, 1 comma, 2 full stop, 3 question mark), nil without the model.
    func labels(for words: [String]) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let ready = loaded() else { return nil }
        let (model, tokenizer) = ready
        var labels = [Int](repeating: 0, count: words.count)
        var start = 0
        while start < words.count {
            // As many words as fit in one input.
            var pieces: [[Int32]] = []
            var count = 0
            var end = start
            while end < words.count {
                let p = tokenizer.encode(word: Self.modelWord(words[end]))
                if count + p.count > Self.maxPieces, end > start { break }
                pieces.append(p)
                count += p.count
                end += 1
            }
            guard let chunk = predict(model: model, tokenizer: tokenizer, pieces: pieces) else { return nil }
            for (offset, label) in chunk.enumerated() { labels[start + offset] = label }
            start = end
        }
        return labels
    }

    /// A word's pieces, for Tests/Punct.
    func pieces(of word: String) -> [Int32]? {
        lock.lock()
        defer { lock.unlock() }
        return loaded()?.1.encode(word: Self.modelWord(word))
    }

    private static let endings: Set<Character> = [".", "،", "؟", "!", ":", "؛", ",", "?"]

    /// The word as the tagger was trained on it: ی and ک in Persian forms, no diacritics, no ZWNJ
    /// differences (the speech model writes none).
    private static func modelWord(_ word: String) -> String {
        var out = ""
        for scalar in word.unicodeScalars {
            switch scalar {
            case "\u{064A}", "\u{0649}": out.unicodeScalars.append("\u{06CC}")
            case "\u{0643}": out.unicodeScalars.append("\u{06A9}")
            case "\u{0640}", "\u{200F}", "\u{200E}": continue
            case "\u{064B}"..."\u{0652}": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func loaded() -> (MLModel, PunctTokenizer)? {
        if let model, let tokenizer { return (model, tokenizer) }
        guard !failed, let directory = Self.directory else { return nil }
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let tokenizer = try PunctTokenizer(vocabulary: directory.appendingPathComponent("punct-vocab.tsv"))
            let config = MLModelConfiguration()
            // Short inputs: the CPU answers sooner than a trip to the Neural Engine.
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: directory.appendingPathComponent("Punct.mlmodelc"), configuration: config)
            self.model = model
            self.tokenizer = tokenizer
            log.info("punctuation model loaded in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
            return (model, tokenizer)
        } catch {
            failed = true
            log.error("punctuation model failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The label of each word: the tagger's best label on the word's last piece.
    private func predict(model: MLModel, tokenizer: PunctTokenizer, pieces: [[Int32]]) -> [Int]? {
        var ids: [Int32] = [tokenizer.cls]
        var last: [Int] = []
        for p in pieces {
            ids += p
            last.append(ids.count - 1)
        }
        ids.append(tokenizer.sep)
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
            let classes = logits.shape.last?.intValue ?? 4
            return last.map { position in
                var best = 0
                var bestValue = -Float.infinity
                for c in 0..<classes {
                    let value = logits[position * classes + c].floatValue
                    if value > bestValue {
                        bestValue = value
                        best = c
                    }
                }
                return best < Self.marks.count ? best : 0
            }
        } catch {
            log.error("punctuation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// The tagger's SentencePiece unigram tokenizer, as Hugging Face's ALBERT tokenizer runs it on
/// words given one by one: the word normalized, "▁" before it, then the pieces whose scores add up
/// to the most (Viterbi). Unknown characters become one unknown piece.
struct PunctTokenizer {
    let cls: Int32
    let sep: Int32
    let unk: Int32
    let zwnj: Int32?
    private let pieces: [String: (id: Int32, score: Float)]
    private let longest: Int
    private let unkScore: Float

    /// `vocabulary`: punct-vocab.tsv, a piece and its score on each line, in id order.
    init(vocabulary: URL) throws {
        let text = try String(contentsOf: vocabulary, encoding: .utf8)
        var pieces: [String: (id: Int32, score: Float)] = [:]
        var longest = 1
        var lowest: Float = 0
        var id: Int32 = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            guard let tab = line.lastIndex(of: "\t") else { continue }
            let piece = String(line[..<tab])
            let score = Float(line[line.index(after: tab)...]) ?? 0
            if pieces[piece] == nil { pieces[piece] = (id, score) }
            longest = max(longest, piece.unicodeScalars.count)
            lowest = min(lowest, score)
            id += 1
        }
        self.pieces = pieces
        self.longest = longest
        unkScore = lowest - 10
        cls = pieces["[CLS]"]?.id ?? 2
        sep = pieces["[SEP]"]?.id ?? 3
        unk = pieces["<unk>"]?.id ?? 1
        // punct-info.json has the id the tokenizer gives it (an added token, not the piece).
        let info = (try? Data(contentsOf: vocabulary.deletingLastPathComponent().appendingPathComponent("punct-info.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        zwnj = (info?["zwnj"] as? Int).map(Int32.init) ?? pieces["[ZWNJ]"]?.id
    }

    /// The tokenizer's normalizer (tokenizer.json): NFKD without combining marks, then NFKC for
    /// the model's own character map (nmt_nfkc); letter case stays.
    static func normalize(_ word: String) -> String {
        let decomposed = word.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }
        let out = String(String.UnicodeScalarView(decomposed)).precomposedStringWithCompatibilityMapping
        return out.replacingOccurrences(of: "``", with: "\"").replacingOccurrences(of: "''", with: "\"")
    }

    /// The normalizer writes ZWNJ as «[ZWNJ]», a token of its own, and each part around it is
    /// read as a word of its own.
    func encode(word: String) -> [Int32] {
        var ids: [Int32] = []
        // By scalars: ZWNJ joins the letter before it into one Character.
        let parts = word.unicodeScalars.split(separator: "\u{200C}", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if index > 0, let zwnj { ids.append(zwnj) }
            ids += encodePart(String(String.UnicodeScalarView(part)))
        }
        return ids
    }

    private func encodePart(_ word: String) -> [Int32] {
        let scalars = Array(("▁" + Self.normalize(word)).unicodeScalars)
        let n = scalars.count
        guard n > 1 else { return [] }
        var best = [Float](repeating: -.infinity, count: n + 1)
        var back = [(start: Int, id: Int32)](repeating: (0, unk), count: n + 1)
        best[0] = 0
        for end in 1...n {
            for start in max(0, end - longest)..<end where best[start] > -.infinity {
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[start..<end])
                if let entry = pieces[String(piece)] {
                    let score = best[start] + entry.score
                    if score > best[end] {
                        best[end] = score
                        back[end] = (start, entry.id)
                    }
                }
            }
            // An unknown character on its own.
            if best[end] == -.infinity, best[end - 1] > -.infinity {
                best[end] = best[end - 1] + unkScore
                back[end] = (end - 1, unk)
            }
        }
        var ids: [Int32] = []
        var end = n
        while end > 0 {
            let step = back[end]
            // Unknown pieces in a row become one.
            if !(step.id == unk && ids.last == unk) { ids.append(step.id) }
            end = step.start
        }
        return ids.reversed()
    }
}
