// What SpokenNumbers needs from the keyboard's Lexicon, without its word lists, for the Mac check.
enum Lexicon {
    static let letters = Set("آابپتثجچحخدذرزژسشصضطظعغفقکگلمنوهیئءأؤةيك\u{200C}".unicodeScalars)

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
}
