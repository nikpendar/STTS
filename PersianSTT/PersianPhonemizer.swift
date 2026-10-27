import Foundation

/// Persian text as the eSpeak-style IPA the Mana Piper voice learned from, without eSpeak (GPL):
/// Homo-GE2PE (MahtaFetrat, MIT), a small ByT5 model, writes each clause in phoneme letters with
/// short vowels, Ezafe and homographs from context («کتاب بزرگ من» → ketabe1 bozorge1 m/n,
/// «کرم ضد آفتاب» → kereme1 …, «خدا کرم کرد» → … k/r/m …); the letters then become IPA with the
/// stress mark. Numbers are spelled out first (SpokenNumbers). scripts/tts_phonemes.py is the same
/// conversion in Python, and Tests/TTS/tts-reference.json holds its output for the check.
final class PersianPhonemizer {
    enum Stress: String, CaseIterable {
        /// Last syllable of the word, the verb prefixes mi-, ne-, be-, na- when they open the word.
        case rules
        /// Always the last syllable of the word.
        case final
        case none
    }

    private let encoder: OnnxModel
    private let decoder: OnnxModel

    /// `directory` holds g2p-encoder.onnx and g2p-decoder.onnx.
    init(directory: URL) throws {
        encoder = try OnnxModel(url: directory.appendingPathComponent("g2p-encoder.onnx"))
        decoder = try OnnxModel(url: directory.appendingPathComponent("g2p-decoder.onnx"))
    }

    /// `text` as sentences of IPA, each with its punctuation, for the voice one at a time.
    func sentences(_ text: String, stress: Stress = .rules) throws -> [String] {
        var out: [String] = []
        for sentence in Self.split(SpokenNumbers.words(in: text), at: ".!?؟\n") {
            var ipa = ""
            for clause in Self.split(sentence, at: "،,;؛:") {
                let mark = clause.last.flatMap { Self.punctuation[$0] }
                let words = Self.clean(clause).split(separator: " ")
                // Long clauses in pieces: the model learned from sentences of usual length.
                for start in stride(from: 0, to: words.count, by: 24) {
                    let piece = words[start..<min(start + 24, words.count)].joined(separator: " ")
                    let phonemes = try self.phonemes(piece)
                    if !ipa.isEmpty, ipa.last != " " { ipa += " " }
                    ipa += phonemes.split(separator: " ").map { Self.ipa(word: $0, stress: stress) }.joined(separator: " ")
                }
                if let mark, !ipa.isEmpty { ipa += mark }
            }
            if !ipa.isEmpty { out.append(ipa.trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    /// One clause in GE2PE phoneme letters, greedy decoding: «کتاب بزرگ» → "ketabe1 bozorg".
    func phonemes(_ clause: String) throws -> String {
        let input = Self.modelText(clause)
        guard !input.isEmpty else { return "" }
        // ByT5: UTF-8 bytes shifted by 3 (0 pad and decoder start, 1 end, 2 unknown).
        let bytes = Array(input.utf8).map { Int64($0) + 3 }
        let hidden = try encoder.run([.int64(bytes, [1, Int64(bytes.count)])])
        var out: [Int64] = [0]
        while out.count < 4 * bytes.count + 16 {
            let logits = try decoder.run([.int64(out, [1, Int64(out.count)]), .float(hidden.values, hidden.shape)]).values
            var best = 0
            for i in logits.indices where logits[i] > logits[best] { best = i }
            if best == 1 { break }
            out.append(Int64(best))
        }
        let result = out.dropFirst().filter { $0 >= 3 && $0 < 259 }.map { UInt8($0 - 3) }
        return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Text

    private static let punctuation: [Character: String] = [
        ".": ".", "!": "!", "?": "?", "؟": "?", "،": ",", ",": ",", ";": ";", "؛": ";", ":": ":",
    ]

    /// Pieces of `text` that end at one of `marks` (kept), or at the end.
    static func split(_ text: String, at marks: String) -> [String] {
        var pieces: [String] = []
        var piece = ""
        for character in text {
            piece.append(character)
            if marks.contains(character) {
                pieces.append(piece)
                piece = ""
            }
        }
        pieces.append(piece)
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Persian letters, ZWNJ and single spaces only.
    static func clean(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x0621...0x063A).contains(v) || (0x0641...0x064A).contains(v) || [0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x06C0, 0x0622, 0x200C].contains(v) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != " " {
                // Diacritics and tatweel go; anything else separates words.
                if !(0x064B...0x0652).contains(v), v != 0x0640 { out += " " }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The text as the model saw it in training (the Parsivar normalizer): Arabic yeh, Persian kaf.
    static func modelText(_ text: String) -> String {
        String(text.map { c -> Character in
            switch c {
            case "ی", "ى": return "ي"
            case "ك": return "ک"
            case "ۀ": return "ه"
            default: return c
            }
        })
    }

    // MARK: - Phonemes to IPA

    /// GE2PE letters to the IPA symbols in the voice's phoneme map.
    private static let letters: [Character: String] = [
        "a": "ɑ", "/": "a", "e": "e", "o": "o", "i": "i", "u": "u",
        "@": "ʔ", "?": "ʔ", "c": "tʃ", "C": "tʃ", "$": "ʃ", "S": "ʃ", "Z": "ʒ", "j": "dʒ", "y": "j", "q": "q", "x": "x",
        "g": "ɡ", "b": "b", "p": "p", "t": "t", "d": "d", "k": "k", "f": "f", "v": "v", "s": "s",
        "z": "z", "h": "h", "m": "m", "n": "n", "l": "l", "r": "r",
    ]
    private static let vowels: Set<Character> = ["ɑ", "a", "e", "o", "i", "u"]
    private static let verbPrefixes = ["mi", "nemi", "ne", "be", "na"]

    /// One word: the Ezafe (a 1 after the word's e or ye) after the stress, no glottal stop at the
    /// start (eSpeak, which the voice learned from, writes none there).
    static func ipa(word: Substring, stress: Stress) -> String {
        var word = String(word)
        var ezafe = ""
        if word.hasSuffix("1") {
            word.removeLast()
            if word.hasSuffix("ye"), word.count > 2 {
                word.removeLast(2)
                ezafe = "je"
            } else if word.hasSuffix("e") {
                word.removeLast()
                ezafe = "e"
            }
        }
        if word.hasPrefix("@") { word.removeFirst() }
        var body = Array(word.compactMap { letters[$0] }.joined())
        if stress != .none {
            let vowelAt = body.indices.filter { vowels.contains(body[$0]) }
            if var target = vowelAt.last {
                let text = String(body)
                if stress == .rules, vowelAt.count > 1,
                   verbPrefixes.contains(where: { text.hasPrefix($0) && body.count > $0.count && !vowels.contains(body[$0.count]) }) {
                    target = vowelAt[0]
                }
                // The mark goes before the syllable's first consonant, as eSpeak writes it.
                let start = target > 0 && !vowels.contains(body[target - 1]) ? target - 1 : target
                body.insert("ˈ", at: start)
            }
        }
        return String(body) + ezafe
    }
}

/// The Mana Persian Piper voice (MahtaFetrat, MIT; Mana-TTS data, CC0): IPA in, 22 kHz audio out.
final class PiperVoice {
    let sampleRate: Double
    private let model: OnnxModel
    private let ids: [Unicode.Scalar: Int64]
    private let noise: Float, length: Float, noiseWidth: Float

    /// `directory` holds mana.onnx and mana.onnx.json.
    init(directory: URL) throws {
        model = try OnnxModel(url: directory.appendingPathComponent("mana.onnx"))
        let data = try Data(contentsOf: directory.appendingPathComponent("mana.onnx.json"))
        struct Config: Decodable {
            struct Audio: Decodable { let sample_rate: Double }
            struct Inference: Decodable { let noise_scale: Float; let length_scale: Float; let noise_w: Float }
            let audio: Audio
            let inference: Inference
            let phoneme_id_map: [String: [Int64]]
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        sampleRate = config.audio.sample_rate
        noise = config.inference.noise_scale
        length = config.inference.length_scale
        noiseWidth = config.inference.noise_w
        var ids: [Unicode.Scalar: Int64] = [:]
        for (key, value) in config.phoneme_id_map {
            if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, let id = value.first { ids[scalar] = id }
        }
        self.ids = ids
    }

    /// Audio for one sentence of IPA; `speed` above 1 speaks faster.
    func synthesize(_ ipa: String, speed: Float = 1) throws -> [Float] {
        // Piper's ids: start, then each phoneme followed by the pad, then the end.
        guard let start = ids["^"], let pad = ids["_"], let end = ids["$"] else { return [] }
        var input: [Int64] = [start, pad]
        for scalar in ipa.unicodeScalars {
            guard let id = ids[scalar] else { continue }
            input += [id, pad]
        }
        input.append(end)
        let audio = try model.run([
            .int64(input, [1, Int64(input.count)]),
            .int64([Int64(input.count)], [1]),
            .float([noise, length / max(0.5, speed), noiseWidth], [3]),
        ]).values
        // Piper's own level: the loudest sample at 90 % of full scale.
        let peak = max(0.01, audio.map(abs).max() ?? 0)
        return audio.map { $0 / peak * 0.9 }
    }
}
