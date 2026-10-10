import Foundation

/// Persian words for the suggestion bar and glide typing: the bundled list (fa_words.txt, from
/// wordfreq, most frequent first with Zipf frequencies) and the words the user types, which
/// are counted so that the user's own words come first and new ones are learned.
final class Lexicon {
    static let shared = Lexicon()

    struct Entry {
        /// As written, with ZWNJ where it belongs (می‌شود).
        let word: String
        /// Compared with what is typed: no ZWNJ, Arabic yeh and kaf as Persian (میشود).
        let key: String
        /// log10 of uses per billion words.
        let zipf: Double
    }

    /// Sorted by `key`, for prefix search. Empty until `load()` has finished.
    private var entries: [Entry] = []
    private var index: [String: Int] = [:]
    /// Entries by the key their glide path starts on (`pathLetters`).
    private var byFirstLetter: [Character: [Int]] = [:]
    /// How often the user typed each word (keyed by `key`), with the spelling they used.
    private var userWords: [String: (word: String, count: Int)] = [:]
    private static let userWordsKey = "userWords"
    private var isLoading = false

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.userWordsKey) as? [String: Int] {
            for (word, count) in saved { userWords[Self.key(word)] = (word, count) }
        }
    }

    var isLoaded: Bool { !entries.isEmpty }

    /// Reads the word list off the main thread; suggestions start once it is there.
    func load(completion: @escaping () -> Void = {}) {
        // The app (which hosts the keyboard for tests) reads the keyboard's copy.
        let url = Bundle(for: Lexicon.self).url(forResource: "fa_words", withExtension: "txt")
            ?? Bundle.main.builtInPlugInsURL?.appendingPathComponent("PersianSTTKeyboard.appex/fa_words.txt")
        guard !isLoaded, !isLoading, let url else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var list: [Entry] = []
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                list.reserveCapacity(28_000)
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count == 2, let zipf = Double(parts[1]) else { continue }
                    let word = String(parts[0])
                    list.append(Entry(word: word, key: Self.key(word), zipf: zipf))
                }
            }
            list.sort { $0.key < $1.key }
            var index: [String: Int] = [:]
            var byFirst: [Character: [Int]] = [:]
            for (i, entry) in list.enumerated() {
                index[entry.key] = i
                if let first = Self.pathLetters(entry.key).first { byFirst[first, default: []].append(i) }
            }
            DispatchQueue.main.async {
                self.entries = list
                self.index = index
                self.byFirstLetter = byFirst
                self.isLoading = false
                completion()
            }
        }
    }

    static let zwnj: Character = "\u{200C}"
    /// Letters a Persian word is made of, plus ZWNJ.
    static let letters = Set("آابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهیئءأؤةيك\u{200C}".unicodeScalars)

    static func isPersianWord(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { letters.contains($0) }
    }

    static func key(_ word: String) -> String {
        String(word.unicodeScalars.compactMap { scalar -> Character? in
            switch scalar {
            case "\u{200C}": return nil
            case "ي": return "ی"
            case "ك": return "ک"
            default: return Character(scalar)
            }
        })
    }

    /// The letter keys a glide over `word` passes, in order: letters of the symbols layer map to
    /// the key they are drawn from (آ on ا), hamza alone has no key, and a doubled letter is one key.
    static func pathLetters(_ key: String) -> [Character] {
        var result: [Character] = []
        for scalar in key.unicodeScalars {
            let letter: Character
            switch scalar {
            case "آ", "أ": letter = "ا"
            case "ئ": letter = "ی"
            case "ؤ": letter = "و"
            case "ة": letter = "ه"
            case "ء", "\u{200C}": continue
            default: letter = Character(scalar)
            }
            if result.last != letter { result.append(letter) }
        }
        return result
    }

    /// Ranking score: corpus frequency, raised for words the user types often. A word the user
    /// typed that is not in the list counts once it was typed twice or picked from the bar.
    private func score(key: String, zipf: Double?) -> Double? {
        let count = userWords[key]?.count ?? 0
        let boost = count > 0 ? 1 + 0.5 * log2(Double(count)) : 0
        if let zipf { return zipf + boost }
        return count >= 2 ? 3 + boost : nil
    }

    func isKnown(_ word: String) -> Bool {
        let key = Self.key(word)
        return index[key] != nil || (userWords[key]?.count ?? 0) >= 2
    }

    /// Up to `limit` words that start with `prefix` (ZWNJ ignored), best first; an exact match counts.
    func completions(for prefix: String, limit: Int) -> [String] {
        let key = Self.key(prefix)
        guard !key.isEmpty else { return [] }
        var found: [(word: String, score: Double)] = []
        // Binary search for the first entry not below the prefix.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].key < key { low = mid + 1 } else { high = mid }
        }
        var i = low
        while i < entries.count, entries[i].key.hasPrefix(key) {
            let entry = entries[i]
            if let score = score(key: entry.key, zipf: entry.zipf) { found.append((entry.word, score)) }
            i += 1
        }
        for (userKey, user) in userWords where index[userKey] == nil && userKey.hasPrefix(key) {
            if let score = score(key: userKey, zipf: nil) { found.append((user.word, score)) }
        }
        found.sort { $0.score > $1.score }
        return Array(found.prefix(limit).map(\.word))
    }

    /// Candidates for a glide that starts on one of `firstLetters`, with their scores.
    func glideCandidates(firstLetters: Set<Character>, lastLetters: Set<Character>,
                         maxLetters: Int) -> [(word: String, letters: [Character], score: Double)] {
        var result: [(word: String, letters: [Character], score: Double)] = []
        for first in firstLetters {
            for i in byFirstLetter[first] ?? [] {
                let entry = entries[i]
                let letters = Self.pathLetters(entry.key)
                guard letters.count <= maxLetters, let last = letters.last, lastLetters.contains(last),
                      let score = score(key: entry.key, zipf: entry.zipf) else { continue }
                result.append((entry.word, letters, score))
            }
        }
        for (key, user) in userWords where index[key] == nil {
            let letters = Self.pathLetters(key)
            guard let first = letters.first, let last = letters.last, firstLetters.contains(first),
                  lastLetters.contains(last), letters.count <= maxLetters,
                  let score = score(key: key, zipf: nil) else { continue }
            result.append((user.word, letters, score))
        }
        return result
    }

    /// The user typed or picked `word`. `confirmed` (picked from the bar) makes a new word
    /// suggestible at once.
    func learn(_ word: String, confirmed: Bool = false) {
        guard word.unicodeScalars.filter({ $0 != "\u{200C}" }).count >= 2 else { return }
        let key = Self.key(word)
        var count = (userWords[key]?.count ?? 0) + 1
        if confirmed { count = max(count, 2) }
        // The list's own spelling is kept for listed words; new words keep the user's.
        userWords[key] = (index[key].map { entries[$0].word } ?? word, count)
        if userWords.count > 5000, let rare = userWords.min(by: { $0.value.count < $1.value.count })?.key {
            userWords.removeValue(forKey: rare)
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: userWords.values.map { ($0.word, $0.count) }),
                                  forKey: Self.userWordsKey)
    }
}
