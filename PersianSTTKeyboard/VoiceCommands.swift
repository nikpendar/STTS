import Foundation

/// Spoken punctuation and editing commands in dictated text.
///
/// Whether «نقطه» is a full stop or the word is decided from what is around it. It is a
/// command before a pause (the app marks pauses with `DictationBridge.pauseMark`), at the end,
/// or before a word it does not go with; it stays a word after «این، یک، در…», before a word it
/// forms a phrase with in Wikipedia (`Lexicon.association`: «نقطه نظر», «نقطه ضعف») and before
/// suffixes («نقطه‌ی», «نقطه ها»). «کلمه‌ی نقطه» always writes the word. Phrases of two words
/// («علامت سؤال», «خط بعد») are commands unless one of those words comes before them.
///
/// Editing commands run only when a stretch of speech between two pauses is nothing but the
/// command, so «اینو پاک کن که…» inside a sentence stays text.
enum VoiceCommands {
    enum Step: Equatable {
        case text(String)
        /// Deletes the last sentence before the cursor.
        case deleteSentence
        /// Deletes everything before the cursor.
        case deleteAll
        /// Undoes the last dictation or voice edit.
        case undo
    }

    struct Result {
        var steps: [Step] = []
        /// Each piece of punctuation that came from spoken words, with the words and which
        /// occurrence of the symbol in `text` it is. A correction of the text is sent for
        /// training with the words put back, since they are what the recording has.
        var spoken: [Spoken] = []

        /// All text of the dictation, without the edits.
        var text: String {
            steps.compactMap { step -> String? in
                if case .text(let text) = step { return text }
                return nil
            }.joined(separator: " ")
        }

        var hasEdits: Bool { steps.contains { !Self.isText($0) } }

        private static func isText(_ step: Step) -> Bool {
            if case .text = step { return true }
            return false
        }
    }

    struct Spoken {
        let symbol: String
        let words: String
        /// 0 for the first occurrence of `symbol` in the dictation's text.
        let occurrence: Int
    }

    private enum Kind {
        /// One ambiguous word: decided by the words around it.
        case word
        /// A phrase that is a command unless a determiner or preposition comes before it.
        case phrase
        /// A phrase that is also common as text («دو نقطه»): a command only before a pause.
        case beforePause
    }

    /// Spoken forms (word keys: no ZWNJ) and what they become.
    private static let punctuation: [(words: [String], symbol: String, kind: Kind)] = [
        (["نقطه", "ویرگول"], "؛", .phrase),
        (["نقطهویرگول"], "؛", .phrase),
        (["علامت", "سوال"], "؟", .phrase),
        (["علامت", "سؤال"], "؟", .phrase),
        (["علامت", "پرسش"], "؟", .phrase),
        (["علامت", "تعجب"], "!", .phrase),
        (["دو", "نقطه"], ":", .beforePause),
        (["دونقطه"], ":", .word),
        (["نقطه"], ".", .word),
        (["ویرگول"], "،", .word),
        (["کاما"], "،", .word),
        (["خط", "بعد"], "\n", .phrase),
        (["خط", "جدید"], "\n", .phrase),
        (["سطر", "بعد"], "\n", .phrase),
        (["سطر", "جدید"], "\n", .phrase),
        (["پاراگراف", "جدید"], "\n\n", .phrase),
        (["پاراگراف", "بعد"], "\n\n", .phrase),
        (["باز", "کردن", "پرانتز"], "(", .phrase),
        (["پرانتز", "باز"], "(", .phrase),
        (["بستن", "پرانتز"], ")", .phrase),
        (["پرانتز", "بسته"], ")", .phrase),
        (["باز", "کردن", "گیومه"], "«", .phrase),
        (["گیومه", "باز"], "«", .phrase),
        (["بستن", "گیومه"], "»", .phrase),
        (["گیومه", "بسته"], "»", .phrase),
    ]

    /// Words after which a command word is text: «این نقطه», «در نقطه‌ای»…
    private static let textBefore: Set<String> = [
        "این", "آن", "اون", "یک", "یه", "هر", "همین", "همان", "همون", "چند", "چندین", "هیچ", "کدام", "کدوم",
        "چه", "دو", "سه", "چهار", "پنج", "اولین", "آخرین", "دومین", "در", "از", "به", "با", "تا", "بر", "روی",
        "رو", "سر", "توی", "تو", "بین", "میان", "نزدیک", "کنار", "مثل", "مانند", "عنوان",
    ]

    /// Words after which a command word is text: suffixes written apart, and common phrases.
    private static let textAfter: Set<String> = [
        "ی", "ای", "ها", "های", "هایی", "را", "رو", "نظر", "ضعف", "قوت", "عطف", "اوج", "مقابل", "صفر",
        "کور", "شروع", "پایان", "جوش", "ذوب", "تماس", "تلاقی", "مرزی", "اتکا",
    ]

    /// «کلمه‌ی نقطه»: the word itself.
    private static let escapes: Set<String> = ["کلمه", "کلمهی", "کلمهٔ"]

    private static let editCommands: [(words: [[String]], step: Step)] = [
        ([["پاک", "پاکش", "حذف", "حذفش"], ["کن"]], .deleteSentence),
        ([["همه", "همش", "همهاش", "همهش", "همشو", "همهشو", "همهرو"], ["رو", "را", "و"], ["پاک", "حذف"], ["کن"]], .deleteAll),
        ([["همه", "همش", "همهاش", "همهش", "همشو", "همهشو", "همهرو"], ["پاک", "حذف"], ["کن"]], .deleteAll),
        ([["برگردون", "برگردان", "بازگردان", "برگرد", "برگردونش"]], .undo),
    ]

    private enum Token: Equatable {
        case word(String)
        case space
        case other(String)
    }

    /// Reads `raw`, a transcript from the app with pause marks.
    static func process(_ raw: String, punctuation: Bool, commands: Bool, lexicon: Lexicon = .shared) -> Result {
        var result = Result()
        var texts: [String] = []
        func flush() {
            let text = clean(texts.joined(separator: " "))
            if !text.isEmpty { result.steps.append(.text(text)) }
            texts = []
        }
        for piece in raw.split(separator: DictationBridge.pauseMark, omittingEmptySubsequences: true) {
            let tokens = tokenize(piece)
            if commands, let step = editCommand(tokens) {
                flush()
                result.steps.append(step)
                continue
            }
            let before = texts.joined(separator: " ")
            texts.append(punctuation ? convert(tokens, before: before, lexicon: lexicon, spoken: &result.spoken) : String(piece))
        }
        flush()
        return result
    }

    /// Live text: punctuation applied, editing commands left out until the final text.
    static func draft(_ raw: String, punctuation: Bool, commands: Bool, lexicon: Lexicon = .shared) -> String {
        process(raw, punctuation: punctuation, commands: commands, lexicon: lexicon).text
    }

    private static func tokenize(_ text: Substring) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentKind = 0 // 1 word, 2 other
        func end() {
            if currentKind == 1 { tokens.append(.word(current)) }
            if currentKind == 2 { tokens.append(.other(current)) }
            current = ""
            currentKind = 0
        }
        for scalar in text.unicodeScalars {
            if Lexicon.letters.contains(scalar) {
                if currentKind != 1 { end() }
                currentKind = 1
                current.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                end()
                if tokens.last != .space { tokens.append(.space) }
            } else {
                if currentKind != 2 { end() }
                currentKind = 2
                current.unicodeScalars.append(scalar)
            }
        }
        end()
        return tokens
    }

    private static func editCommand(_ tokens: [Token]) -> Step? {
        var words: [String] = []
        for token in tokens {
            switch token {
            case .word(let word): words.append(Lexicon.key(word))
            case .space: continue
            // Whisper's own full stop or comma after the command does not matter.
            case .other(let text) where text.unicodeScalars.allSatisfy({ ".،,!؟?".unicodeScalars.contains($0) }): continue
            case .other: return nil
            }
        }
        for command in editCommands where command.words.count == words.count {
            if zip(command.words, words).allSatisfy({ $0.contains($1) }) { return command.step }
        }
        return nil
    }

    /// Indices of the word tokens, skipping spaces only; nil where something else comes between.
    private static func words(_ tokens: [Token], from start: Int, count: Int) -> [Int]? {
        var result: [Int] = []
        var i = start
        while result.count < count, i < tokens.count {
            switch tokens[i] {
            case .word: result.append(i)
            case .space: break
            case .other: return nil
            }
            i += 1
        }
        return result.count == count ? result : nil
    }

    private static func word(_ token: Token) -> String? {
        if case .word(let word) = token { return word }
        return nil
    }

    /// The word right before token `i`, with only spaces between.
    private static func previousWord(_ tokens: [Token], before i: Int) -> (index: Int, word: String)? {
        var j = i - 1
        while j >= 0 {
            switch tokens[j] {
            case .space: j -= 1
            case .word(let word): return (j, word)
            case .other: return nil
            }
        }
        return nil
    }

    private static func nextWord(_ tokens: [Token], after i: Int) -> String? {
        var j = i + 1
        while j < tokens.count {
            switch tokens[j] {
            case .space: j += 1
            case .word(let word): return word
            case .other: return nil
            }
        }
        return nil
    }

    private static let closing: Set<String> = [".", "،", "؟", "!", ":", "؛", ")", "»"]
    private static let ending = Set(".،؟!:؛,?".unicodeScalars)

    private static func match(_ tokens: [Token], at i: Int) -> (end: Int, symbol: String, kind: Kind, words: String)? {
        for phrase in punctuation {
            guard let indices = words(tokens, from: i, count: phrase.words.count), indices.first == i else { continue }
            let spoken = indices.compactMap { word(tokens[$0]) }
            if spoken.map(Lexicon.key) == phrase.words {
                return (indices.last!, phrase.symbol, phrase.kind, spoken.joined(separator: " "))
            }
        }
        return nil
    }

    private static func occurrences(of symbol: String, in text: String) -> Int {
        text.components(separatedBy: symbol).count - 1
    }

    /// `before` is the dictation's text before this piece, for counting occurrences.
    private static func convert(_ tokens: [Token], before: String, lexicon: Lexicon, spoken: inout [Spoken]) -> String {
        var out = ""
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard case .word(let text) = token, let found = match(tokens, at: i) else {
                switch token {
                case .word(let text), .other(let text): out += text
                case .space: out += " "
                }
                i += 1
                continue
            }
            let previous = previousWord(tokens, before: i)
            let next = nextWord(tokens, after: found.end)
            let nextIsCommand = next != nil && words(tokens, from: found.end + 1, count: 1).map { match(tokens, at: $0[0]) != nil } == true
            let atPause = next == nil || nextIsCommand
            let previousKey = previous.map { Lexicon.key($0.word) }
            let first = Lexicon.key(text)
            var isCommand: Bool
            if let previousKey, escapes.contains(previousKey) {
                // «کلمه‌ی نقطه»: drop «کلمه‌ی», keep the word.
                if let range = out.range(of: previous!.word, options: .backwards) { out.removeSubrange(range) }
                spoken.append(Spoken(symbol: found.words, words: previous!.word + " " + found.words,
                                     occurrence: occurrences(of: found.words, in: before + " " + out)))
                isCommand = false
            } else if let previousKey, textBefore.contains(previousKey) {
                isCommand = false
            } else {
                switch found.kind {
                case .phrase:
                    isCommand = true
                case .beforePause:
                    isCommand = atPause
                case .word:
                    if let previous, lexicon.association(previous.word, first) >= 20 {
                        isCommand = false
                    } else if atPause {
                        isCommand = true
                    } else if let next {
                        isCommand = !textAfter.contains(Lexicon.key(next)) && lexicon.association(first, next) < 10
                    } else {
                        isCommand = true
                    }
                }
            }
            guard isCommand else {
                for j in i...found.end {
                    switch tokens[j] {
                    case .word(let text), .other(let text): out += text
                    case .space: out += " "
                    }
                }
                i = found.end + 1
                continue
            }
            let symbol = found.symbol
            while out.last == " " { out.removeLast() }
            // Whisper's own punctuation in the same place gives way to the spoken one.
            if closing.contains(symbol), symbol != ")", symbol != "»",
               let last = out.unicodeScalars.last, ending.contains(last) {
                out.unicodeScalars.removeLast()
            }
            spoken.append(Spoken(symbol: symbol, words: found.words, occurrence: occurrences(of: symbol, in: before + " " + out)))
            if closing.contains(symbol) {
                out += symbol
            } else if symbol == "(" || symbol == "«" {
                out += (out.isEmpty ? "" : " ") + symbol
            } else {
                out += symbol
            }
            i = found.end + 1
            // Whisper's punctuation right after the spoken one is dropped, and so are spaces
            // after an opening bracket or a line break.
            while i < tokens.count {
                if tokens[i] == .space, !closing.contains(symbol) { i += 1; continue }
                if case .other(let text) = tokens[i], text.unicodeScalars.allSatisfy({ ending.contains($0) }) { i += 1; continue }
                if tokens[i] == .space, i + 1 < tokens.count, case .other(let text) = tokens[i + 1],
                   text.unicodeScalars.allSatisfy({ ending.contains($0) }) { i += 2; continue }
                break
            }
        }
        return out
    }

    /// One space between words, none before closing punctuation or around line breaks, none
    /// after an opening bracket.
    private static func clean(_ text: String) -> String {
        var out = ""
        for character in text {
            if character == " " {
                if out.isEmpty || out.last == " " || out.last == "\n" || out.last == "(" || out.last == "«" { continue }
                out.append(character)
            } else if character == "\n" || closing.contains(String(character)) {
                while out.last == " " { out.removeLast() }
                out.append(character)
            } else {
                out.append(character)
            }
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// The corrected text of a dictation with spoken punctuation turned back into the words
    /// the recording has; nil when the punctuation no longer matches the dictation's (the user
    /// added or removed some), as the text could then not be matched to the recording.
    static func restoringSpoken(_ corrected: String, original: String, spoken: [Spoken]) -> String? {
        guard !spoken.isEmpty else { return corrected }
        let symbols = Set(spoken.map(\.symbol))
        // A paragraph break holds two line breaks, which would be counted twice.
        guard !(symbols.contains("\n") && symbols.contains("\n\n")) else { return nil }
        var text = corrected
        for symbol in symbols {
            guard occurrences(of: symbol, in: text) == occurrences(of: symbol, in: original) else { return nil }
        }
        // Escaped words first: the words put back for punctuation can contain them («نقطه»).
        let isWord = { (symbol: String) in symbol.unicodeScalars.contains { Lexicon.letters.contains($0) } }
        for symbol in symbols.sorted(by: { isWord($0) && !isWord($1) }) {
            var ranges: [Range<String.Index>] = []
            var start = text.startIndex
            while let range = text.range(of: symbol, range: start..<text.endIndex) {
                ranges.append(range)
                start = range.upperBound
            }
            // From the end, so the earlier ranges stay valid.
            for form in spoken.filter({ $0.symbol == symbol }).sorted(by: { $0.occurrence > $1.occurrence }) {
                guard form.occurrence < ranges.count else { return nil }
                text.replaceSubrange(ranges[form.occurrence], with: " \(form.words) ")
            }
        }
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }
}
