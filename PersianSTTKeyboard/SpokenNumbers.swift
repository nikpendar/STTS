import Foundation

/// Numbers the speech model writes in words, written in digits: «بیست و سه» → «۲۳»,
/// «هزار و چهارصد و سه» → «۱۴۰۳», «دو میلیون» → «۲٬۰۰۰٬۰۰۰», «سه ممیز پنج» → «۳٫۵».
/// Kept as words: a lone «یک» or «یه» (mostly "a"), a lone «نه» or «ده» unless a counting word
/// follows («نه تا»), and ordinals («بیست و سوم»). Numbers said one after another stay apart
/// («دو سه روز» → «۲ ۳ روز»).
/// `words(in:)` writes digits back in words, for training on a corrected dictation: the
/// recording has the words.
enum SpokenNumbers {
    private static let units: [String: Int] = [
        "صفر": 0, "یک": 1, "یه": 1, "دو": 2, "سه": 3, "چهار": 4, "پنج": 5, "شش": 6, "شیش": 6,
        "هفت": 7, "هشت": 8, "نه": 9,
    ]
    private static let teens: [String: Int] = [
        "ده": 10, "یازده": 11, "دوازده": 12, "سیزده": 13, "چهارده": 14, "پانزده": 15, "پونزده": 15,
        "شانزده": 16, "شونزده": 16, "هفده": 17, "هیفده": 17, "هجده": 18, "هیجده": 18, "نوزده": 19,
    ]
    private static let tens: [String: Int] = [
        "بیست": 20, "سی": 30, "چهل": 40, "پنجاه": 50, "شصت": 60, "هفتاد": 70, "هشتاد": 80, "نود": 90,
    ]
    private static let hundreds: [String: Int] = [
        "صد": 100, "یکصد": 100, "دویست": 200, "سیصد": 300, "چهارصد": 400, "پانصد": 500, "پونصد": 500,
        "ششصد": 600, "شیشصد": 600, "هفتصد": 700, "هشتصد": 800, "نهصد": 900,
    ]
    private static let scales: [String: Int] = ["هزار": 1_000, "میلیون": 1_000_000, "میلیارد": 1_000_000_000]

    /// Words that count something, after which «نه» and «ده» are numbers.
    private static let counters: Set<String> = [
        "تا", "تای", "نفر", "سال", "ماه", "روز", "هفته", "ساعت", "دقیقه", "ثانیه", "بار", "درصد", "تومان",
        "تومن", "ریال", "دلار", "یورو", "کیلو", "کیلومتر", "متر", "سانت", "سانتیمتر", "گرم", "کیلوگرم", "لیتر",
        "عدد", "دونه", "دانه", "صفحه", "قدم", "سالگی", "ساله", "روزه", "ماهه", "برابر", "مرتبه", "طبقه",
    ]

    private static let persianDigits = Array("۰۱۲۳۴۵۶۷۸۹")

    // MARK: - Words to digits

    private struct Word {
        let text: String
        /// What comes after the word up to the next one: spaces, punctuation, line breaks.
        var gap: String
    }

    static func digits(in text: String) -> String {
        var lead = ""
        var words: [Word] = []
        var current = ""
        var gap = ""
        for scalar in text.unicodeScalars {
            if Lexicon.letters.contains(scalar) {
                if !gap.isEmpty {
                    if current.isEmpty {
                        lead = gap
                    } else {
                        words.append(Word(text: current, gap: gap))
                        current = ""
                    }
                    gap = ""
                }
                current.unicodeScalars.append(scalar)
            } else {
                gap.unicodeScalars.append(scalar)
            }
        }
        guard !current.isEmpty else { return text }
        words.append(Word(text: current, gap: gap))
        let keys = words.map { Lexicon.key($0.text) }
        var out = lead
        var i = 0
        while i < words.count {
            if let number = number(words, keys, at: i) {
                out += number.digits + words[number.end].gap
                i = number.end + 1
            } else {
                out += words[i].text + words[i].gap
                i += 1
            }
        }
        return out
    }

    /// The number starting at word `i`, as digits, and the index of its last word. `keys` are the
    /// words without ZWNJ (`Lexicon.key`). `alone` applies the rules for a lone ambiguous word.
    private static func number(_ words: [Word], _ keys: [String], at i: Int, alone: Bool = true) -> (digits: String, end: Int)? {
        /// Word `j` exists and only a space separates it from the word before.
        func joined(_ j: Int) -> Bool { j > 0 && j < words.count && words[j - 1].gap == " " }
        /// Word `j` is «و» between two words.
        func and(_ j: Int) -> Bool { joined(j) && keys[j] == "و" && joined(j + 1) }

        /// 1 to 999 (or a lone «صفر»): «صد و بیست و سه».
        func group(at j: Int) -> (value: Int, end: Int)? {
            guard j < words.count, j == i || joined(j) else { return nil }
            var j = j
            var value = 0
            var end = -1
            if let h = hundreds[keys[j]] {
                value = h
                end = j
                guard and(j + 1), tens[keys[j + 2]] != nil || teens[keys[j + 2]] != nil || (units[keys[j + 2]] ?? 0) > 0 else {
                    return (value, end)
                }
                j += 2
            }
            if let t = tens[keys[j]] {
                value += t
                end = j
                if and(j + 1), let u = units[keys[j + 2]], u > 0 {
                    value += u
                    end = j + 2
                }
                return (value, end)
            }
            if let t = teens[keys[j]] { return (value + t, j) }
            if let u = units[keys[j]], u > 0 || value == 0 { return (value + u, j) }
            return value > 0 ? (value, end) : nil
        }

        var total = 0
        var end = -1
        var lastScale = Int.max
        var j = i
        while true {
            var groupValue = 1
            var groupEnd = j - 1
            if let g = group(at: j) {
                groupValue = g.value
                groupEnd = g.end
            } else if j < words.count, j == i || joined(j), scales[keys[j]] != nil {
                // «هزار» alone is a thousand.
            } else {
                break
            }
            let next = groupEnd + 1
            if next < words.count, next == i || joined(next), let scale = scales[keys[next]], scale < lastScale, groupValue > 0 {
                total += groupValue * scale
                lastScale = scale
                end = groupEnd + 1
                if and(end + 1) {
                    j = end + 2
                    continue
                }
                break
            }
            guard groupEnd >= j, groupValue < lastScale else { break }
            total += groupValue
            end = groupEnd
            break
        }
        guard end >= i else { return nil }

        // «بیست و سوم»: an ordinal, written in words.
        if and(end + 1), isOrdinal(keys[end + 2]) { return nil }
        if end == i, alone {
            let only = keys[i]
            if only == "یک" || only == "یه" { return nil }
            if only == "نه" || only == "ده" {
                guard joined(i + 1), counters.contains(keys[i + 1]) else { return nil }
            }
        }
        var digits = format(total)
        // «سه ممیز پنج».
        if joined(end + 1), keys[end + 1] == "ممیز", joined(end + 2),
           let fraction = number(words, keys, at: end + 2, alone: false) {
            digits += "٫" + fraction.digits.filter { $0 != "٬" }
            end = fraction.end
        }
        return (digits, end)
    }

    private static func isOrdinal(_ word: String) -> Bool {
        if ["اول", "اولین", "نخست", "سوم", "سومین"].contains(word) { return true }
        var stem = word
        if stem.hasSuffix("ین") { stem.removeLast(2) }
        guard stem.hasSuffix("م") else { return false }
        stem.removeLast()
        if stem.hasSuffix("ا") { stem.removeLast() }
        return units[stem] != nil || teens[stem] != nil || tens[stem] != nil || hundreds[stem] != nil || scales[stem] != nil
    }

    /// Persian digits, with thousands separators from 10,000 on (years stay «۱۴۰۳»).
    static func format(_ value: Int) -> String {
        let plain = String(value).map { $0.wholeNumberValue.map { persianDigits[$0] } ?? $0 }
        guard value >= 10_000 else { return String(plain) }
        var out = ""
        for (k, digit) in plain.enumerated() {
            if k > 0, (plain.count - k) % 3 == 0 { out += "٬" }
            out.append(digit)
        }
        return out
    }

    // MARK: - Digits to words

    private static let unitWords = ["صفر", "یک", "دو", "سه", "چهار", "پنج", "شش", "هفت", "هشت", "نه"]
    private static let teenWords = ["ده", "یازده", "دوازده", "سیزده", "چهارده", "پانزده", "شانزده", "هفده", "هجده", "نوزده"]
    private static let tenWords = ["", "", "بیست", "سی", "چهل", "پنجاه", "شصت", "هفتاد", "هشتاد", "نود"]
    private static let hundredWords = ["", "صد", "دویست", "سیصد", "چهارصد", "پانصد", "ششصد", "هفتصد", "هشتصد", "نهصد"]

    /// Digits in `text` (Persian, Arabic or Latin, with separators) written in words.
    static func words(in text: String) -> String {
        var out = ""
        var number = ""
        func flush() {
            guard !number.isEmpty else { return }
            out += spell(number)
            number = ""
        }
        for character in text {
            if character.wholeNumberValue != nil, character.isNumber {
                number.append(character)
            } else if !number.isEmpty, "٬,٫.".contains(character) {
                number.append(character)
            } else {
                // A separator after the last digit is punctuation.
                var trailing = ""
                while let last = number.last, "٬,٫.".contains(last) {
                    trailing = String(last) + trailing
                    number.removeLast()
                }
                flush()
                out += trailing
                out.append(character)
            }
        }
        var trailing = ""
        while let last = number.last, "٬,٫.".contains(last) {
            trailing = String(last) + trailing
            number.removeLast()
        }
        flush()
        return out + trailing
    }

    /// «۱۴۰۳» → «هزار و چهارصد و سه»; a number with a leading zero digit by digit; a decimal
    /// with «ممیز».
    private static func spell(_ number: String) -> String {
        let parts = number.split(whereSeparator: { $0 == "٫" || $0 == "." }).map { String($0.filter { $0 != "٬" && $0 != "," }) }
        let digits = parts.map { $0.compactMap(\.wholeNumberValue) }
        guard let whole = digits.first, !whole.isEmpty else { return number }
        var spoken: String
        if whole.count > 1, whole[0] == 0 || whole.count > 15 {
            spoken = whole.map { unitWords[$0] }.joined(separator: " ")
        } else {
            spoken = spell(whole.reduce(0) { $0 * 10 + $1 })
        }
        if parts.count == 2, !digits[1].isEmpty {
            let fraction = digits[1]
            spoken += " ممیز " + (fraction[0] == 0 && fraction.count > 1
                ? fraction.map { unitWords[$0] }.joined(separator: " ")
                : spell(fraction.reduce(0) { $0 * 10 + $1 }))
        }
        return spoken
    }

    private static func spell(_ value: Int) -> String {
        guard value > 0 else { return "صفر" }
        var parts: [String] = []
        var rest = value
        for (scale, name) in [(1_000_000_000_000, "هزار میلیارد"), (1_000_000_000, "میلیارد"), (1_000_000, "میلیون"), (1_000, "هزار")] {
            let count = rest / scale
            guard count > 0 else { continue }
            rest %= scale
            parts.append(count == 1 && scale == 1_000 ? name : spellGroup(count) + " " + name)
        }
        if rest > 0 { parts.append(spellGroup(rest)) }
        return parts.joined(separator: " و ")
    }

    /// 1 to 999.
    private static func spellGroup(_ value: Int) -> String {
        var parts: [String] = []
        if value >= 100 { parts.append(hundredWords[value / 100]) }
        let rest = value % 100
        if rest >= 20 {
            parts.append(tenWords[rest / 10])
            if rest % 10 > 0 { parts.append(unitWords[rest % 10]) }
        } else if rest >= 10 {
            parts.append(teenWords[rest - 10])
        } else if rest > 0 {
            parts.append(unitWords[rest])
        }
        return parts.joined(separator: " و ")
    }
}
