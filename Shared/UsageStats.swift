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

    static let zero = UsageStats()

    static func + (a: UsageStats, b: UsageStats) -> UsageStats {
        a.combined(with: b, sign: 1)
    }

    static func - (a: UsageStats, b: UsageStats) -> UsageStats {
        a.combined(with: b, sign: -1)
    }

    private func combined(with b: UsageStats, sign: Int) -> UsageStats {
        let s = Double(sign)
        return UsageStats(voiceWords: voiceWords + sign * b.voiceWords,
                          voiceSeconds: voiceSeconds + s * b.voiceSeconds,
                          dictations: dictations + sign * b.dictations,
                          glideWords: glideWords + sign * b.glideWords,
                          glidePoints: glidePoints + s * b.glidePoints,
                          autoCorrections: autoCorrections + sign * b.autoCorrections,
                          autoCorrectionsUndone: autoCorrectionsUndone + sign * b.autoCorrectionsUndone,
                          voiceFixes: voiceFixes + sign * b.voiceFixes,
                          voiceWordsFixed: voiceWordsFixed + sign * b.voiceWordsFixed,
                          predictionsPicked: predictionsPicked + sign * b.predictionsPicked,
                          lettersSaved: lettersSaved + sign * b.lettersSaved)
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
