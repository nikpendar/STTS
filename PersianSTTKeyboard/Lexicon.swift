import Foundation

/// Persian words for the suggestion bar, glide typing and spoken punctuation: the bundled list
/// (fa_words.txt, from wordfreq, most frequent first with Zipf frequencies), the words that most
/// often follow each of them in Persian Wikipedia (fa_bigrams.bin, from scripts/make_bigrams.py),
/// and the words and word pairs the user types, which are counted so that the user's own words
/// and phrases come first and new ones are learned.
final class Lexicon {
    static let shared = Lexicon()

    struct Entry {
        /// As written, with ZWNJ where it belongs (می‌شود).
        let word: String
        /// Compared with what is typed: no ZWNJ, Arabic yeh and kaf as Persian (میشود).
        let key: String
        /// log10 of uses per billion words.
        let zipf: Double
        /// Line in fa_words.txt, by which fa_bigrams.bin refers to words.
        let rank: Int
        /// `key` as UTF-16 code units, for the typo search.
        let codes: [UInt16]
    }

    /// What comes before the word being typed.
    enum Context: Equatable {
        /// After a comma, a digit or other text: nothing to go by.
        case none
        /// At the start of the text or after the end of a sentence.
        case sentenceStart
        /// Right after this word (its `key`).
        case word(String)
    }

    /// Sorted by `key`, for prefix search. Empty until `load()` has finished.
    private var entries: [Entry] = []
    private var index: [String: Int] = [:]
    /// Position in `entries` of each rank.
    private var byRank: [Int] = []
    /// Entries by the key their glide path starts on (`pathLetters`).
    private var byFirstLetter: [Character: [Int]] = [:]
    /// Next words: those of rank r are at followerStart[r]..<followerStart[r + 1] of the two
    /// arrays, best first, with costs as in fa_bigrams.bin (P = 2^(-cost/8)).
    private var followerStart: [Int32] = []
    private var followerRanks: [UInt16] = []
    private var followerCosts: [UInt8] = []
    private var starters: [(rank: Int, cost: UInt8)] = []
    /// How often the user typed each word (keyed by `key`), with the spelling they used.
    private var userWords: [String: (word: String, count: Int)] = [:]
    private static let userWordsKey = "userWords"
    /// How often the user typed a word right after another: previous key, then word key, then
    /// count. The previous key of a word at the start of a sentence is "^".
    private var userPairs: [String: [String: Int]] = [:]
    private static let userPairsKey = "userPairs"
    private static let sentenceStartKey = "^"
    /// A user pair counts like this many Wikipedia ones in `nextProbability`.
    private static let userPairWeight = 5.0
    private var saveScheduled = false
    private var isLoading = false
    /// Substitution costs between letters, in half edits, by `letterIndex`.
    private var substitution = [UInt8](repeating: 2, count: 256 * 256)

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.userWordsKey) as? [String: Int] {
            for (word, count) in saved { userWords[Self.key(word)] = (word, count) }
        }
        userPairs = UserDefaults.standard.dictionary(forKey: Self.userPairsKey) as? [String: [String: Int]] ?? [:]
        setNeighbours([])
    }

    var isLoaded: Bool { !entries.isEmpty }

    /// Reads the word lists off the main thread; suggestions start once they are there.
    func load(completion: @escaping () -> Void = {}) {
        guard let url = Self.resource("fa_words.txt") else { return }
        load(words: url, bigrams: Self.resource("fa_bigrams.bin"), completion: completion)
    }

    func load(words url: URL, bigrams bigramsURL: URL?, completion: @escaping () -> Void = {}) {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var list: [Entry] = []
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                list.reserveCapacity(28_000)
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count == 2, let zipf = Double(parts[1]) else { continue }
                    list.append(Self.entry(String(parts[0]), zipf: zipf, rank: list.count))
                }
                // The list leaves out one-letter words; fa_bigrams.bin has و after the last line.
                list.append(Self.entry("و", zipf: 7.6, rank: list.count))
            }
            let count = list.count
            list.sort { $0.key < $1.key }
            var index: [String: Int] = [:]
            var byRank = [Int](repeating: 0, count: count)
            var byFirst: [Character: [Int]] = [:]
            for (i, entry) in list.enumerated() {
                index[entry.key] = i
                byRank[entry.rank] = i
                if let first = Self.pathLetters(entry.key).first { byFirst[first, default: []].append(i) }
            }
            let bigrams = bigramsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { Self.readBigrams($0, words: count) }
            DispatchQueue.main.async {
                self.entries = list
                self.index = index
                self.byRank = byRank
                self.byFirstLetter = byFirst
                if let bigrams {
                    (self.followerStart, self.followerRanks, self.followerCosts, self.starters) = bigrams
                }
                self.isLoading = false
                completion()
            }
        }
    }

    /// The keyboard's copy; the app (which hosts the keyboard for tests and reads spoken
    /// commands the same way) finds it in the extension.
    private static func resource(_ name: String) -> URL? {
        let parts = name.split(separator: ".").map(String.init)
        return Bundle(for: Lexicon.self).url(forResource: parts[0], withExtension: parts[1])
            ?? Bundle.main.builtInPlugInsURL?.appendingPathComponent("PersianSTTKeyboard.appex/\(name)")
    }

    private static func entry(_ word: String, zipf: Double, rank: Int) -> Entry {
        let key = Self.key(word)
        return Entry(word: word, key: key, zipf: zipf, rank: rank, codes: Array(key.utf16))
    }

    /// Parses fa_bigrams.bin (format in scripts/make_bigrams.py). Nil if it does not belong to
    /// this word list.
    private static func readBigrams(_ data: Data, words: Int)
        -> (start: [Int32], ranks: [UInt16], costs: [UInt8], starters: [(rank: Int, cost: UInt8)])? {
        let bytes = [UInt8](data)
        var p = 0
        func byte() -> Int? {
            guard p < bytes.count else { return nil }
            p += 1
            return Int(bytes[p - 1])
        }
        func short() -> Int? {
            guard let low = byte(), let high = byte() else { return nil }
            return low | high << 8
        }
        guard bytes.count > 10, bytes[0..<4].elementsEqual("FABG".utf8) else { return nil }
        p = 4
        guard let low = short(), let high = short(), low | high << 16 == words, let startCount = short() else { return nil }
        var starters: [(rank: Int, cost: UInt8)] = []
        for _ in 0..<startCount {
            guard let rank = short(), let cost = byte(), rank < words else { return nil }
            starters.append((rank, UInt8(cost)))
        }
        var start: [Int32] = [0]
        var ranks: [UInt16] = []
        var costs: [UInt8] = []
        start.reserveCapacity(words + 1)
        ranks.reserveCapacity((bytes.count - p) / 3)
        costs.reserveCapacity((bytes.count - p) / 3)
        for _ in 0..<words {
            guard let count = byte() else { return nil }
            for _ in 0..<count {
                guard let rank = short(), let cost = byte(), rank < words else { return nil }
                ranks.append(UInt16(rank))
                costs.append(UInt8(cost))
            }
            start.append(Int32(ranks.count))
        }
        return (start, ranks, costs, starters)
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
            case "آ", "أ", "إ": letter = "ا"
            case "ئ": letter = "ی"
            // ژ is held on the ز key.
            case "ژ": letter = "ز"
            case "ؤ": letter = "و"
            case "ة": letter = "ه"
            case "ء", "\u{200C}": continue
            default: letter = Character(scalar)
            }
            if result.last != letter { result.append(letter) }
        }
        return result
    }

    // MARK: - Ranking

    /// Corpus frequency, raised for words the user types often. A word the user typed that is
    /// not in the list counts once it was typed twice or picked from the bar.
    private func score(key: String, zipf: Double?) -> Double? {
        let count = userWords[key]?.count ?? 0
        let boost = count > 0 ? 1 + 0.5 * log2(Double(count)) : 0
        if let zipf { return zipf + boost }
        return count >= 2 ? 3 + boost : nil
    }

    private static func probability(_ cost: UInt8) -> Double {
        pow(2, -Double(cost) / 8)
    }

    /// Wikipedia's P(word of rank `rank` | word of rank `previous`).
    private func bundledProbability(of rank: Int, after previous: Int) -> Double {
        guard previous + 1 < followerStart.count else { return 0 }
        for i in Int(followerStart[previous])..<Int(followerStart[previous + 1]) where Int(followerRanks[i]) == rank {
            return Self.probability(followerCosts[i])
        }
        return 0
    }

    private func previousKey(_ context: Context) -> String? {
        switch context {
        case .none: return nil
        case .sentenceStart: return Self.sentenceStartKey
        case .word(let key): return key
        }
    }

    /// How likely the word with `key` comes next in `context`: Wikipedia's estimate, which the
    /// user's own pairs outweigh once they have typed a few after the same word.
    private func nextProbability(key: String, context: Context) -> Double {
        guard let previous = previousKey(context) else { return 0 }
        var bundled = 0.0
        if let rank = index[key].map({ entries[$0].rank }) {
            if case .word(let word) = context {
                if let before = index[word].map({ entries[$0].rank }) {
                    bundled = bundledProbability(of: rank, after: before)
                }
            } else if let starter = starters.first(where: { $0.rank == rank }) {
                bundled = Self.probability(starter.cost)
            }
        }
        let pairs = userPairs[previous]
        let count = Double(pairs?[key] ?? 0)
        let total = Double(pairs?.values.reduce(0, +) ?? 0)
        return (count + Self.userPairWeight * bundled) / (total + Self.userPairWeight)
    }

    /// Ranking score in Zipf units: how likely the word is here, mixing how likely it follows
    /// the word before with how common it is.
    private func rankScore(key: String, zipf: Double?, context: Context) -> Double? {
        guard let unigram = score(key: key, zipf: zipf) else { return nil }
        guard context != .none else { return unigram }
        let next = nextProbability(key: key, context: context)
        return log10(0.7 * next + 0.3 * pow(10, unigram - 9)) + 9
    }

    func isKnown(_ word: String) -> Bool {
        let key = Self.key(word)
        return index[key] != nil || (userWords[key]?.count ?? 0) >= 2
    }

    /// The spelling to show for a word key: the list's, else the user's.
    private func spelling(_ key: String) -> String? {
        index[key].map { entries[$0].word } ?? userWords[key]?.word
    }

    /// Up to `limit` words that start with `prefix` (ZWNJ ignored), best first; an exact match counts.
    func completions(for prefix: String, context: Context = .none, limit: Int) -> [String] {
        Array(scoredCompletions(for: Self.key(prefix), context: context).prefix(limit).map(\.word))
    }

    private func scoredCompletions(for key: String, context: Context) -> [(word: String, score: Double)] {
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
            if let score = rankScore(key: entry.key, zipf: entry.zipf, context: context) { found.append((entry.word, score)) }
            i += 1
        }
        for (userKey, user) in userWords where index[userKey] == nil && userKey.hasPrefix(key) {
            if let score = rankScore(key: userKey, zipf: nil, context: context) { found.append((user.word, score)) }
        }
        found.sort { $0.score > $1.score }
        return found
    }

    /// The words most likely to come next, best first: after a word, what followed it in
    /// Wikipedia and in the user's own typing; at the start of a sentence, common first words.
    func predictions(after context: Context, limit: Int) -> [String] {
        guard let previous = previousKey(context) else { return [] }
        var keys = Set<String>()
        if case .word(let word) = context {
            if let rank = index[word].map({ entries[$0].rank }), rank + 1 < followerStart.count {
                for i in Int(followerStart[rank])..<Int(followerStart[rank + 1]) {
                    keys.insert(entries[byRank[Int(followerRanks[i])]].key)
                }
            }
        } else {
            for starter in starters { keys.insert(entries[byRank[starter.rank]].key) }
        }
        for key in (userPairs[previous] ?? [:]).keys { keys.insert(key) }
        let scored = keys.compactMap { key -> (word: String, probability: Double)? in
            guard let word = spelling(key), isKnown(word) else { return nil }
            return (word, nextProbability(key: key, context: context))
        }
        return Array(scored.sorted { $0.probability > $1.probability }.prefix(limit).map(\.word))
    }

    /// Wikipedia's P(`next` | `word`) divided by how common `next` is: far above 1 for words
    /// that go together, as in «نقطه نظر». Spoken punctuation uses it to tell a command from a word.
    func association(_ word: String, _ next: String) -> Double {
        guard let a = index[Self.key(word)].map({ entries[$0] }), let b = index[Self.key(next)].map({ entries[$0] }) else {
            return 0
        }
        let conditional = bundledProbability(of: b.rank, after: a.rank)
        guard conditional >= 0.002 else { return 0 }
        return conditional / pow(10, b.zipf - 9)
    }

    // MARK: - Typos

    /// Persian letters sit at U+0620...U+06FF; everything else shares the last index.
    private static func letterIndex(_ code: UInt16) -> Int {
        code >= 0x0620 && code < 0x071F ? Int(code - 0x0620) : 255
    }

    /// Letters that are spelled for one another because they sound alike, or are typed from
    /// the same key on the symbols layer.
    private static let soundAlike: [String] = ["سصث", "زذضظ", "تط", "هحة", "قغ", "اعآأ", "یئ", "وؤ"]

    /// Keys next to each other on the letters layer (from the keyboard's layout); a slip onto one
    /// of them, like a letter that sounds the same, costs half an edit.
    func setNeighbours(_ pairs: [(Character, Character)]) {
        var table = [UInt8](repeating: 2, count: 256 * 256)
        for i in 0..<256 { table[i * 256 + i] = 0 }
        func cheap(_ a: Character, _ b: Character) {
            guard let x = a.utf16.first, let y = b.utf16.first else { return }
            let i = Self.letterIndex(x), j = Self.letterIndex(y)
            guard i != 255, j != 255, i != j else { return }
            table[i * 256 + j] = 1
            table[j * 256 + i] = 1
        }
        for group in Self.soundAlike {
            let letters = Array(group)
            for a in letters { for b in letters { cheap(a, b) } }
        }
        for (a, b) in pairs { cheap(a, b) }
        substitution = table
    }

    /// Listed or learned words that `typed` is probably a misspelling of, with their cost in
    /// edits: one edit for words of up to four letters, one and a half up to seven, two beyond
    /// (a neighbouring key or a sound-alike letter, a doubled letter typed or a swapped pair
    /// costs half; another letter, a missing or an extra one costs one). From four letters a
    /// misspelt beginning of a longer word counts too, at up to one edit.
    func corrections(for typed: String, context: Context = .none, limit: Int) -> [(word: String, score: Double)] {
        let key = Self.key(typed)
        let a = Array(key.utf16).map(Self.letterIndex)
        let n = a.count
        guard n >= 3, isLoaded else { return [] }
        let maxCost = n <= 4 ? 2 : n <= 7 ? 3 : 4
        let maxPrefixCost = n >= 4 ? 2 : -1
        let span = maxCost / 2
        var previous2 = [Int](repeating: 0, count: n + span + 2)
        var previous = previous2
        var current = previous2
        var b = [Int](repeating: 255, count: n + span + 1)
        var found: [(word: String, score: Double)] = []

        func consider(word: String, key: String, zipf: Double?, cost: Int) {
            guard let score = rankScore(key: key, zipf: zipf, context: context) else { return }
            // Half an edit costs as much as a word about five times rarer.
            found.append((word, score - 0.75 * Double(cost)))
        }

        func distance(_ codes: [UInt16]) -> (full: Int?, prefix: Int?) {
            let m = codes.count
            guard m >= n - span else { return (nil, nil) }
            let fullAllowed = m <= n + span
            guard fullAllowed || maxPrefixCost >= 0 else { return (nil, nil) }
            let columns = min(m, n + span)
            guard columns >= 1 else { return (nil, nil) }
            for j in 0..<columns { b[j] = Self.letterIndex(codes[j]) }
            // Rows are letters of the typed word, columns letters of the listed one, costs in half edits.
            for j in 0...columns { previous[j] = 2 * j }
            for i in 1...n {
                current[0] = 2 * i
                var rowMin = current[0]
                // A letter typed twice by mistake costs half.
                let extra = i >= 2 && a[i - 1] == a[i - 2] ? 1 : 2
                for j in 1...columns {
                    var cost = previous[j - 1] + Int(substitution[a[i - 1] * 256 + b[j - 1]])
                    cost = min(cost, previous[j] + extra, current[j - 1] + 2)
                    if i >= 2, j >= 2, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1], a[i - 1] != a[i - 2] {
                        cost = min(cost, previous2[j - 2] + 1)
                    }
                    current[j] = cost
                    rowMin = min(rowMin, cost)
                }
                if rowMin > max(maxCost, maxPrefixCost) { return (nil, nil) }
                swap(&previous2, &previous)
                swap(&previous, &current)
            }
            // `previous` now holds the last row.
            let full = fullAllowed && columns == m ? previous[m] : nil
            var prefix: Int?
            if maxPrefixCost >= 0, m > n {
                for j in max(1, n - 1)...min(columns, n + 1) { prefix = min(prefix ?? previous[j], previous[j]) }
            }
            return (full, prefix)
        }

        for entry in entries {
            let (full, prefix) = distance(entry.codes)
            if let full, full > 0, full <= maxCost {
                consider(word: entry.word, key: entry.key, zipf: entry.zipf, cost: full)
            } else if let prefix, prefix > 0, prefix <= maxPrefixCost {
                consider(word: entry.word, key: entry.key, zipf: entry.zipf, cost: prefix)
            }
        }
        for (userKey, user) in userWords where index[userKey] == nil && user.count >= 2 {
            let (full, _) = distance(Array(userKey.utf16))
            if let full, full > 0, full <= maxCost {
                consider(word: user.word, key: userKey, zipf: nil, cost: full)
            }
        }
        found.sort { $0.score > $1.score }
        return Array(found.prefix(limit))
    }

    /// Completions and corrections of an unknown typed word together, best first.
    func suggestions(forUnknown typed: String, context: Context, correct: Bool, limit: Int) -> [String] {
        var ranked = scoredCompletions(for: Self.key(typed), context: context)
        if correct { ranked += corrections(for: typed, context: context, limit: limit + 2) }
        ranked.sort { $0.score > $1.score }
        var words: [String] = []
        for entry in ranked where !words.contains(entry.word) {
            words.append(entry.word)
            if words.count == limit { break }
        }
        return words
    }

    // MARK: - Glide

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

    // MARK: - Learning

    /// The user typed or picked `word` after `context`. `confirmed` (picked from the bar) makes
    /// a new word suggestible at once.
    func learn(_ word: String, after context: Context = .none, confirmed: Bool = false) {
        guard word.unicodeScalars.filter({ $0 != "\u{200C}" }).count >= 2 else { return }
        let key = Self.key(word)
        var count = (userWords[key]?.count ?? 0) + 1
        if confirmed { count = max(count, 2) }
        // The list's own spelling is kept for listed words; new words keep the user's.
        userWords[key] = (index[key].map { entries[$0].word } ?? word, count)
        if userWords.count > 5000, let rare = userWords.min(by: { $0.value.count < $1.value.count })?.key {
            userWords.removeValue(forKey: rare)
        }
        if let previous = previousKey(context) {
            userPairs[previous, default: [:]][key, default: 0] += 1
            if userPairs.count > 3000,
               let rare = userPairs.min(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) })?.key {
                userPairs.removeValue(forKey: rare)
            }
        }
        scheduleSave()
    }

    /// Writes learned words a second after the last change, not on every word.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            saveScheduled = false
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: userWords.values.map { ($0.word, $0.count) }),
                                      forKey: Self.userWordsKey)
            UserDefaults.standard.set(userPairs, forKey: Self.userPairsKey)
        }
    }
}
