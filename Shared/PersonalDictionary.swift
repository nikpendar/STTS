import Foundation

/// The user's own words: names and terms the model writes wrong, each with how it should be
/// written. The keyboard puts them in after recognition, after spoken punctuation, digits and
/// ZWNJ, so an entry always has the last word.
///
/// Matching ignores spaces and ZWNJ inside the words, Arabic ي/ك, diacritics, letter case and
/// the digits' script: «علی رضا», «علیرضا» and «علي‌رضا» are one entry. Only whole words match,
/// and a match never runs across punctuation.
struct PersonalDictionary: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID()
        /// What the model writes.
        var heard: String
        /// What goes in its place.
        var written: String
    }

    var entries: [Entry] = []

    static let standard = PersonalDictionary()

    /// The key two spellings of the same words share.
    static func key(_ text: String) -> String {
        var out = ""
        for scalar in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars {
            switch scalar {
            case "\u{200C}", "\u{200D}", "\u{0640}", " ", "\u{00A0}": continue
            case "\u{064A}", "\u{0649}": out.unicodeScalars.append("\u{06CC}")
            case "\u{0643}": out.unicodeScalars.append("\u{06A9}")
            case "\u{06F0}"..."\u{06F9}":
                out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            case "\u{0660}"..."\u{0669}":
                out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            default:
                guard !CharacterSet.nonBaseCharacters.contains(scalar) else { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static let wordScalars = CharacterSet.letters
        .union(.decimalDigits)
        .union(.nonBaseCharacters)
        .union(CharacterSet(charactersIn: "\u{200C}\u{200D}\u{0640}"))

    /// `text` with every entry's words written the user's way; the longest entry wins.
    func applied(to text: String) -> String {
        var lookup: [String: String] = [:]
        var longest = 0
        for entry in entries {
            let heard = Self.key(entry.heard)
            let written = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !written.isEmpty, lookup[heard] == nil else { continue }
            lookup[heard] = written
            // The model may split a word or join two, so a window of a few more words is read.
            longest = max(longest, entry.heard.split(whereSeparator: { $0 == " " || $0 == "\u{200C}" }).count + 2)
        }
        guard !lookup.isEmpty else { return text }

        // Words and what lies between them.
        let scalars = Array(text.unicodeScalars)
        var words: [Range<Int>] = []
        var i = 0
        while i < scalars.count {
            guard Self.wordScalars.contains(scalars[i]) else { i += 1; continue }
            let start = i
            while i < scalars.count, Self.wordScalars.contains(scalars[i]) { i += 1 }
            words.append(start..<i)
        }

        var out = String.UnicodeScalarView()
        var copied = 0
        var w = 0
        while w < words.count {
            var key = ""
            var match: (end: Int, written: String)?
            var v = w
            while v < words.count, v - w < longest {
                // Only spaces between the words of one entry.
                if v > w, !scalars[words[v - 1].upperBound..<words[v].lowerBound].allSatisfy({ $0 == " " || $0 == "\u{00A0}" }) { break }
                key += Self.key(String(String.UnicodeScalarView(scalars[words[v]])))
                if let written = lookup[key] { match = (v, written) }
                v += 1
            }
            guard let match else { w += 1; continue }
            out.append(contentsOf: scalars[copied..<words[w].lowerBound])
            out.append(contentsOf: match.written.unicodeScalars)
            copied = words[match.end].upperBound
            w = match.end + 1
        }
        guard copied > 0 else { return text }
        out.append(contentsOf: scalars[copied...])
        return String(out)
    }

    /// Words the user replaced in a dictation: each run of one to three words of `original`
    /// that `corrected` has as one to three other words in the same place. Runs with digits are
    /// left out (numbers come back in words for training), and so are spellings of the same key.
    static func replacements(original: String, corrected: String) -> [(heard: String, written: String)] {
        let a = tokens(original)
        let b = tokens(corrected)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 40_000 else { return [] }
        let ka = a.map(Self.key)
        let kb = b.map(Self.key)
        // Longest common subsequence of the words' keys.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = ka[i] == kb[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var found: [(heard: String, written: String)] = []
        var i = 0, j = 0
        var heard: [String] = [], written: [String] = []
        func flush() {
            defer { heard = []; written = [] }
            guard (1...3).contains(heard.count), (1...3).contains(written.count) else { return }
            let h = heard.joined(separator: " "), w = written.joined(separator: " ")
            guard Self.key(h) != Self.key(w), !(h + w).unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else { return }
            found.append((h, w))
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, ka[i] == kb[j] {
                flush()
                i += 1; j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                written.append(b[j]); j += 1
            } else {
                heard.append(a[i]); i += 1
            }
        }
        flush()
        return found
    }

    /// Words with the punctuation around them taken off.
    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            let trimmed = word.unicodeScalars.drop(while: { !wordScalars.contains($0) })
            let scalars = Array(trimmed)
            guard let last = scalars.lastIndex(where: wordScalars.contains) else { return nil }
            return String(String.UnicodeScalarView(scalars[...last]))
        }
    }
}
