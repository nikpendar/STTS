import Foundation

/// The word pieces of HooshvareLab's Persian ALBERT (punct-vocab.tsv in Models/Punct, from release
/// punct-albert6), which the Ezafe tagger (EzafeTagger.swift) reads. The punctuation tagger that
/// came with them was removed (Rooz, 2026-11-05); only its tokenizer stays.
enum AutoPunctuation {
    /// The folder with punct-vocab.tsv, nil in a build without it.
    static var directory: URL? {
        Bundle.main.url(forResource: "Models", withExtension: nil)
            .map { $0.appendingPathComponent("Punct") }
            .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("punct-vocab.tsv").path) ? $0 : nil }
    }

    /// The word as ALBERT-fa was trained on it: ی and ک in Persian forms, no diacritics, no ZWNJ
    /// differences (the speech model writes none).
    static func modelWord(_ word: String) -> String {
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

    /// The normalizer writes ZWNJ as «[ZWNJ]», a token of its own; the parts after it go on
    /// without "▁".
    func encode(word: String) -> [Int32] {
        var ids: [Int32] = []
        // By scalars: ZWNJ joins the letter before it into one Character.
        let parts = word.unicodeScalars.split(separator: "\u{200C}", omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if index > 0, let zwnj { ids.append(zwnj) }
            ids += encodePart(String(String.UnicodeScalarView(part)), prefix: index == 0)
        }
        return ids
    }

    /// `prefix`: "▁" before it, which only the word's first part has.
    private func encodePart(_ word: String, prefix: Bool) -> [Int32] {
        let scalars = Array(((prefix ? "▁" : "") + Self.normalize(word)).unicodeScalars)
        let n = scalars.count
        guard n > (prefix ? 1 : 0) else { return [] }
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
