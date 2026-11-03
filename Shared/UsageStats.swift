import UIKit

/// What the keyboard (and the app's own dictations) did for the user, for the report page in
/// the app (`UsageReport`). The keyboard counts from its install on and never resets; it puts
/// its totals on a named pasteboard (no App Group), and the app subtracts the totals it saw
/// when the user last reset the report.
struct UsageStats: Codable, Equatable {
    /// Words written by voice, and the seconds spoken for them.
    var voiceWords = 0
    var voiceSeconds: Double = 0
    var dictations = 0
    /// Words written by sliding over the letters, and the length of those lines in points.
    var glideWords = 0
    var glidePoints: Double = 0
    /// Typos corrected on space, and those the user put back with backspace.
    var autoCorrections = 0
    var autoCorrectionsUndone = 0
    /// Dictations the user edited afterwards, and the words changed in them.
    var voiceFixes = 0
    var voiceWordsFixed = 0
    /// Words taken from the suggestion bar, and the letters that spared typing.
    var predictionsPicked = 0
    var lettersSaved = 0
    /// Dictated words the keyboard followed for edits, and the word errors those edits showed
    /// (substitutions, deletions, insertions): the user's own word error rate. Rewrites (more
    /// than half the words changed) are left out, as they are not recognition errors.
    var checkedWords = 0
    var voiceErrors = 0
    /// The same per ISO week ("2026-45"): [checked words, errors], the last 26 weeks.
    var weeks: [String: [Int]] = [:]

    static let zero = UsageStats()

    init() {}

    /// Totals saved by an older version lack the newer counts; they start at zero.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        func double(_ key: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? 0 }
        voiceWords = int(.voiceWords)
        voiceSeconds = double(.voiceSeconds)
        dictations = int(.dictations)
        glideWords = int(.glideWords)
        glidePoints = double(.glidePoints)
        autoCorrections = int(.autoCorrections)
        autoCorrectionsUndone = int(.autoCorrectionsUndone)
        voiceFixes = int(.voiceFixes)
        voiceWordsFixed = int(.voiceWordsFixed)
        predictionsPicked = int(.predictionsPicked)
        lettersSaved = int(.lettersSaved)
        checkedWords = int(.checkedWords)
        voiceErrors = int(.voiceErrors)
        weeks = (try? c.decodeIfPresent([String: [Int]].self, forKey: .weeks)) ?? [:]
    }

    /// Share of the checked words recognized right, nil before 20 words.
    var accuracy: Double? {
        checkedWords >= 20 ? max(0, 1 - Double(voiceErrors) / Double(checkedWords)) : nil
    }

    static func week(of date: Date = Date()) -> String {
        let calendar = Calendar(identifier: .iso8601)
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// Counts the words of a dictation followed for edits (errors 0), the errors its edits
    /// showed, or (negative words) a rewrite taken back out.
    mutating func addChecked(words: Int, errors: Int) {
        checkedWords += words
        voiceErrors += errors
        let key = Self.week()
        var pair = weeks[key] ?? [0, 0]
        pair[0] += words
        pair[1] += errors
        weeks[key] = pair
        if weeks.count > 26 {
            for old in weeks.keys.sorted().prefix(weeks.count - 26) { weeks[old] = nil }
        }
    }

    /// Word errors between a dictation and its edited text: the edit distance over words.
    static func wordErrors(_ original: String, _ corrected: String) -> Int {
        let a = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = corrected.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    static func + (a: UsageStats, b: UsageStats) -> UsageStats {
        a.combined(with: b, sign: 1)
    }

    static func - (a: UsageStats, b: UsageStats) -> UsageStats {
        a.combined(with: b, sign: -1)
    }

    private func combined(with b: UsageStats, sign: Int) -> UsageStats {
        let s = Double(sign)
        var r = self
        r.voiceWords += sign * b.voiceWords
        r.voiceSeconds += s * b.voiceSeconds
        r.dictations += sign * b.dictations
        r.glideWords += sign * b.glideWords
        r.glidePoints += s * b.glidePoints
        r.autoCorrections += sign * b.autoCorrections
        r.autoCorrectionsUndone += sign * b.autoCorrectionsUndone
        r.voiceFixes += sign * b.voiceFixes
        r.voiceWordsFixed += sign * b.voiceWordsFixed
        r.predictionsPicked += sign * b.predictionsPicked
        r.lettersSaved += sign * b.lettersSaved
        r.checkedWords += sign * b.checkedWords
        r.voiceErrors += sign * b.voiceErrors
        r.weeks = weeks.merging(b.weeks.mapValues { $0.map { sign * $0 } }) { x, y in zip(x, y).map { $0 + $1 } }
        return r
    }

    /// Some count went down: the keyboard was reinstalled and counts from zero again.
    func isBelow(_ other: UsageStats) -> Bool {
        voiceWords < other.voiceWords || dictations < other.dictations || glideWords < other.glideWords
            || autoCorrections < other.autoCorrections || predictionsPicked < other.predictionsPicked
            || voiceFixes < other.voiceFixes
    }

    /// Seconds saved against typing on the phone (about 30 words a minute, a letter in 0.3 s):
    /// the time to type the dictated words less the time spent saying them, plus the letters
    /// the suggestions spared.
    var secondsSaved: Double {
        max(0, Double(voiceWords) * 2 - voiceSeconds) + Double(lettersSaved) * 0.3
    }

    /// The glide lines in meters: a point is about 1/153 inch on iPhones.
    var glideMeters: Double { glidePoints / 153 * 0.0254 }

    // MARK: - Keyboard side

    private static let defaultsKey = "usageStats"
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.usageStats")
    private static let pasteboardType = "public.json"

    private static var current: UsageStats = {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) } ?? UsageStats()
    }()
    private static var unsaved = false

    /// Keyboard side: counts something; `publish()` hands the totals to the app.
    static func record(_ change: (inout UsageStats) -> Void) {
        change(&current)
        unsaved = true
    }

    /// Keyboard side: saves the totals and puts them on the pasteboard for the app.
    static func publish() {
        guard unsaved, let data = try? JSONEncoder().encode(current) else { return }
        unsaved = false
        UserDefaults.standard.set(data, forKey: defaultsKey)
        UIPasteboard(name: pasteboardName, create: true)?.setData(data, forPasteboardType: pasteboardType)
    }

    /// App side: the keyboard's latest totals, nil when it never published any.
    static func fromKeyboard() -> UsageStats? {
        UIPasteboard(name: pasteboardName, create: false)?.data(forPasteboardType: pasteboardType)
            .flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) }
    }
}
