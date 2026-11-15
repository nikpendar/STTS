import Foundation

/// Persian text rules for the notes: one spelling for letters that look alike, ZWNJ where
/// Persian writes it, digits in one script, search that ignores spelling variants, and the
/// direction of a paragraph. Foundation only, so Tests/Notes checks it on a Mac.
enum PersianText {
    static let zwnj: Character = "\u{200C}"

    /// Arabic letters and digits written the Persian way, kashida and doubled spaces removed.
    /// Safe on any text: it never changes Latin text or the words themselves.
    static func unifyingLetters(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x064A, 0x0649: out.append("ی")          // Arabic yeh, alef maksura
            case 0x0643: out.append("ک")                  // Arabic kaf
            case 0x0640: continue                          // kashida
            case 0x0660...0x0669:                          // Arabic-Indic digits
                out.append(Unicode.Scalar(scalar.value - 0x0660 + 0x06F0)!)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// `unifyingLetters`, then ZWNJ for the verb prefixes «می» and «نمی» and the plural «ها»
    /// written apart («می شود» → «می‌شود», «کتاب ها» → «کتاب‌ها»), and spaces tidied: one between
    /// words, none before a ZWNJ or at a line's ends.
    static func normalized(_ text: String) -> String {
        var text = unifyingLetters(text)
        text = text.replacingOccurrences(of: "[ \\t]*\u{200C}+[ \\t]*", with: "\u{200C}", options: .regularExpression)
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^[ \\t]+|[ \\t]+$", with: "", options: .regularExpression)
        let letter = "[\\u0621-\\u063A\\u0641-\\u064A\\u067E\\u0686\\u0698\\u06A9\\u06AF\\u06CC\\u0622]"
        // «می»/«نمی» standing alone before a word of two letters or more: the verb prefix.
        text = text.replacingOccurrences(of: "(?<!\(letter)|\u{200C})(ن?می) (?=\(letter){2})",
                                         with: "$1\u{200C}", options: .regularExpression)
        // «ها» and its forms after a word of two letters or more.
        text = text.replacingOccurrences(of: "(\(letter){2}) (ها(?:ی|یی|یم|یت|یش|یمان|یتان|یشان)?)(?!\(letter))",
                                         with: "$1\u{200C}$2", options: .regularExpression)
        return text
    }

    // MARK: - Digits

    static let persianDigits: [Character] = ["۰", "۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹"]

    /// Every digit (Latin, Persian, Arabic) written in Persian.
    static func persianDigits(_ text: String) -> String {
        String(unifyingDigits(text).map { c -> Character in
            guard let v = c.asciiValue, (48...57).contains(v) else { return c }
            return persianDigits[Int(v - 48)]
        })
    }

    /// Every digit written in Latin, and the Persian decimal and thousands separators with it.
    static func latinDigits(_ text: String) -> String {
        unifyingDigits(text)
    }

    private static func unifyingDigits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x06F0...0x06F9: out.append(Unicode.Scalar(scalar.value - 0x06F0 + 48)!)
            case 0x0660...0x0669: out.append(Unicode.Scalar(scalar.value - 0x0660 + 48)!)
            case 0x066B: out.append(".")   // Arabic decimal separator
            case 0x066C: out.append(",")   // Arabic thousands separator
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Search

    /// The form search compares: letter variants unified, diacritics, kashida, ZWNJ and spaces
    /// dropped, آ/أ/إ as ا, ة/ۀ as ه, ؤ as و, digits Latin, Latin lower-case. «میشود»,
    /// «می شود» and «می‌شود» are the same, as are «كتاب‌ها» and «کتابها».
    static func searchKey(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in unifyingDigits(unifyingLetters(text)).lowercased().unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0654, 0x0655: continue     // diacritics, hamza marks
            case 0x200C, 0x200D, 0x200E, 0x200F, 0x00A0: continue      // ZWNJ, ZWJ, marks
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append("ا")
            case 0x0629, 0x06C0: out.append("ه")
            case 0x0624: out.append("و")
            case 0x0626: out.append("ی")
            default:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whether `text` contains every word of `query`, by `searchKey`.
    static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { searchKey(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let key = searchKey(text)
        return words.allSatisfy { key.contains($0) }
    }

    // MARK: - Direction

    /// Right to left when most letters of `paragraph` are Persian (or it has none and the app
    /// is in Persian), so a Persian line that starts with an English word still reads from the
    /// right, and an English line among Persian ones reads from the left.
    static func isRightToLeft(_ paragraph: Substring, defaultRTL: Bool) -> Bool {
        var rtl = 0
        var ltr = 0
        for scalar in paragraph.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x024F, 0x0370...0x04FF: ltr += 1
            default: break
            }
        }
        if rtl == 0 && ltr == 0 { return defaultRTL }
        return rtl >= ltr
    }

    // MARK: - Sentences

    /// The sentences of `text` as UTF-16 ranges (for highlighting in a text view), each with
    /// its closing mark; split where the voice splits (`.!?؟` and line breaks). Ranges without
    /// a letter or digit are left out.
    static func sentenceRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        let ends = CharacterSet(charactersIn: ".!?؟\n")
        let content = CharacterSet.letters.union(.decimalDigits)
        var ranges: [NSRange] = []
        var start = 0
        func add(_ end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            if ns.substring(with: range).unicodeScalars.contains(where: content.contains) { ranges.append(range) }
            start = end
        }
        var i = 0
        while i < ns.length {
            let unit = ns.character(at: i)
            if let scalar = Unicode.Scalar(unit), ends.contains(scalar) {
                // Marks in a row («؟!» or «...») stay with their sentence.
                var j = i + 1
                while j < ns.length, let next = Unicode.Scalar(ns.character(at: j)), ends.contains(next), next != "\n" { j += 1 }
                add(j)
                i = j
                continue
            }
            i += 1
        }
        add(ns.length)
        return ranges
    }

    // MARK: - Hashtags

    /// The #tags in `text` («#کار», «#خرید_خانه»), without the sign, in order, once each.
    static func hashtags(in text: String) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])[#＃]([\\p{L}\\p{N}_\u{200C}]+)")
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\u{200C}_"))
            let key = searchKey(tag)
            guard !tag.isEmpty, !key.isEmpty, seen.insert(key).inserted else { continue }
            tags.append(tag)
        }
        return tags
    }
}
