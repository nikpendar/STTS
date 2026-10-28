// Checks the keyboard's word logic (Lexicon, VoiceCommands, PersonalDictionary, TouchModel, GlideDecoder) without a simulator:
// .github/workflows/logic-test.yml compiles these files with this one on a Mac and runs them.
import Foundation

enum DictationBridge {
    static let pauseMark: Character = "\u{E000}"
}

let pause = String(DictationBridge.pauseMark)
var failures = 0

func check(_ name: String, _ actual: some Equatable & CustomStringConvertible, _ expected: some Equatable & CustomStringConvertible) {
    let ok = "\(actual)" == "\(expected)"
    if !ok { failures += 1 }
    print(ok ? "PASS" : "FAIL", name, ok ? "" : "→ got «\(actual)», expected «\(expected)»")
}

func text(_ raw: String, punctuation: Bool = true, commands: Bool = true) -> String {
    let result = VoiceCommands.process(raw, punctuation: punctuation, commands: commands)
    return result.hasEdits ? "edits: \(result.steps)" : result.text
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
var loaded = false
Lexicon.shared.load(words: directory.appendingPathComponent("fa_words.txt"),
                    bigrams: directory.appendingPathComponent("fa_bigrams.bin")) { loaded = true }
while !loaded { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

// Spoken punctuation.
check("full stop at the end", text("سلام نقطه"), "سلام.")
check("full stop before a pause", text("سلام خوبی نقطه" + pause + "من خوبم"), "سلام خوبی. من خوبم")
check("full stop mid-sentence", text("سلام نقطه حالت چطوره علامت سوال"), "سلام. حالت چطوره؟")
check("after a determiner", text("این نقطه مهم است"), "این نقطه مهم است")
check("phrase نقطه نظر", text("از نقطه نظر من"), "از نقطه نظر من")
check("phrase نقطه ضعف", text("نقطه ضعف او همین است"), "نقطه ضعف او همین است")
check("escape", text("کلمه‌ی نقطه را بنویس"), "نقطه را بنویس")
check("comma", text("اول ویرگول دوم"), "اول، دوم")
check("new line", text("سلام خط بعد خوبی"), "سلام\nخوبی")
check("text خط بعد", text("در خط بعد بنویس"), "در خط بعد بنویس")
check("brackets", text("باز کردن پرانتز مثال بستن پرانتز"), "(مثال)")
check("the model's full stop", text("سلام نقطه."), "سلام.")
check("question replaces the model's stop", text("خوبی. علامت سوال"), "خوبی؟")
check("دو نقطه at a pause", text("موارد دو نقطه"), "موارد:")
check("دو نقطه as text", text("بین دو نقطه خط بکشید"), "بین ۲ نقطه خط بکشید")
check("off", text("سلام نقطه", punctuation: false), "سلام نقطه")
check("pause marks become spaces", text("سلام" + pause + "خوبی", punctuation: false), "سلام خوبی")

// Editing commands.
check("delete", VoiceCommands.process("پاک کن", punctuation: true, commands: true).steps == [.deleteSentence], true)
check("delete after text", VoiceCommands.process("سلام" + pause + "پاک کن.", punctuation: true, commands: true).steps.count, 2)
check("delete inside a sentence", text("اینو پاک کن که بد است"), "اینو پاک کن که بد است")
check("delete all", VoiceCommands.process("همه رو پاک کن", punctuation: true, commands: true).steps == [.deleteAll], true)
check("undo", VoiceCommands.process("برگردون", punctuation: true, commands: true).steps == [.undo], true)
check("commands off", text("پاک کن", commands: false), "پاک کن")

// Personal dictionary.
let ownWords = PersonalDictionary(entries: [.init(heard: "روز ساعد", written: "Rooz Saad"),
                                         .init(heard: "کی لس", written: "Keyless"),
                                         .init(heard: "شنوا", written: "شنوا کوچیک"),
                                         .init(heard: "علیرضا", written: "علی‌رضا")])
check("dictionary phrase", ownWords.applied(to: "سلام روز ساعد خوبی"), "سلام Rooz Saad خوبی")
check("dictionary joined by the model", ownWords.applied(to: "برنامه‌ی کیلس."), "برنامه‌ی Keyless.")
check("dictionary split by the model", ownWords.applied(to: "علی رضا آمد"), "علی‌رضا آمد")
check("dictionary Arabic ye and ZWNJ", ownWords.applied(to: "علي‌رضا"), "علی‌رضا")
check("dictionary whole words only", ownWords.applied(to: "شنوایی"), "شنوایی")
check("dictionary not across punctuation", ownWords.applied(to: "روز، ساعد"), "روز، ساعد")
check("dictionary empty", PersonalDictionary().applied(to: "روز ساعد"), "روز ساعد")
check("dictionary in a dictation", VoiceCommands.process("سلام روز ساعد نقطه", punctuation: true, commands: true,
                                                         dictionary: ownWords).text, "سلام Rooz Saad.")
let starters = PersonalDictionary().addingStarters()
check("starters", starters.entries.count, 5)
check("starters once", starters.addingStarters().entries.count, 5)
check("starter marks join the word before", starters.applied(to: "سلام ویرگول خوبی نقطه"), "سلام، خوبی.")
check("starter percent", VoiceCommands.process("بیست درصد", punctuation: false, commands: false, dictionary: starters).text, "۲۰٪")
check("starter emoji", starters.applied(to: "عالی بود شکلک لبخند"), "عالی بود 🙂")
check("symbol words", starters.symbolWords.contains(PersonalDictionary.key("ویرگول")), true)
check("replacements", PersonalDictionary.replacements(original: "با روز ساعد صحبت کردم.", corrected: "با Rooz Saad صحبت کردم.")
        .map { "\($0.heard)>\($0.written)" }.joined(separator: ","), "روز ساعد>Rooz Saad")
check("replacements skip ZWNJ", PersonalDictionary.replacements(original: "می خوام", corrected: "می‌خوام").count, 0)
check("replacements skip numbers", PersonalDictionary.replacements(original: "۲۳ تا", corrected: "بیست و سه تا").count, 0)

// Training text gets the spoken words back.
let dictated = VoiceCommands.process("سلام نقطه خوبی علامت سوال", punctuation: true, commands: true)
check("restore", VoiceCommands.restoringSpoken("سلام. خوبید؟", original: dictated.text, spoken: dictated.spoken) ?? "nil",
      "سلام نقطه خوبید علامت سوال")
check("restore skips changed punctuation",
      VoiceCommands.restoringSpoken("سلام خوبید؟", original: dictated.text, spoken: dictated.spoken) ?? "nil", "nil")

// Numbers said in words are written in digits.
check("number 23", text("بیست و سه نفر"), "۲۳ نفر")
check("year", text("سال هزار و چهارصد و سه"), "سال ۱۴۰۳")
check("hundreds", text("صد و بیست و پنج تومن"), "۱۲۵ تومن")
check("millions", text("دو میلیون و پانصد هزار"), "۲٬۵۰۰٬۰۰۰")
check("thousand alone", text("هزار بار"), "۱۰۰۰ بار")
check("decimal", text("سه ممیز پنج درصد"), "۳٫۵ درصد")
check("lone یک stays", text("یک روز خوب"), "یک روز خوب")
check("یک in a number", text("صد و یک"), "۱۰۱")
check("lone نه stays", text("نه نمی‌خوام"), "نه نمی‌خوام")
check("نه with a counter", text("نه تا سیب"), "۹ تا سیب")
check("lone ده stays", text("ده بزرگ"), "ده بزرگ")
check("ordinal stays", text("بیست و سوم مهر"), "بیست و سوم مهر")
check("two numbers", text("دو سه روز"), "۲ ۳ روز")
check("number then و", text("دو و سه"), "۲ و ۳")
check("number before full stop", text("قیمت بیست تومن نقطه"), "قیمت ۲۰ تومن.")
check("دو نقطه still a colon", text("موارد دو نقطه"), "موارد:")
check("numbers with punctuation off", text("سی و دو", punctuation: false), "۳۲")
check("words back for training", SpokenNumbers.words(in: "۲۳ نفر در سال ۱۴۰۳ و ۲٬۵۰۰٬۰۰۰ تومن، ۳٫۵ درصد."),
      "بیست و سه نفر در سال هزار و چهارصد و سه و دو میلیون و پانصد هزار تومن، سه ممیز پنج درصد.")
check("phone digits back", SpokenNumbers.words(in: "۰۹۱۲"), "صفر نه یک دو")

// The speech model writes no ZWNJ; dictated text gets it where the word list has it.
check("ZWNJ after می", text("من میخوام برم"), "من می‌خوام برم")
check("ZWNJ joins two words", text("این کتاب ها نقطه"), "این کتاب‌ها.")
check("ZWNJ before تر", text("خیلی بزرگ تر"), "خیلی بزرگ‌تر")
check("ZWNJ off", VoiceCommands.process("من میخوام برم", punctuation: true, commands: true, zwnj: false).text, "من میخوام برم")
check("ZWNJ leaves plain words", text("حالت خوبه"), "حالت خوبه")

// Suggestions, with neighbouring keys of the Persian layout as the keyboard sets them.
let rows = ["ضصقفغعهخحجچ", "شسیبلاتنمکگ", "ظطزرذدپوث"].map(Array.init)
var neighbours: [(Character, Character)] = []
for (r, row) in rows.enumerated() {
    for (c, a) in row.enumerated() {
        for r2 in r..<min(rows.count, r + 2) {
            for (c2, b) in rows[r2].enumerated() where abs(c2 - c) <= 1 && (r2 > r || c2 > c) {
                neighbours.append((a, b))
            }
        }
    }
}
neighbours.append(("ز", "ژ"))
Lexicon.shared.setNeighbours(neighbours)
let afterAz = Lexicon.shared.predictions(after: .word("از"), limit: 3)
check("predictions after از", afterAz.contains("این"), true)
check("prediction at sentence start", Lexicon.shared.predictions(after: .sentenceStart, limit: 3).first ?? "", "در")
check("context completion", Lexicon.shared.completions(for: "متح", context: .word("ایالات"), limit: 1).first ?? "", "متحده")
check("typo سلان", Lexicon.shared.suggestions(forUnknown: "سلان", context: .none, correct: true, limit: 2).first ?? "", "سلام")
// ژ is held on ز: a glide over ز can mean ژ, and ز typed for ژ is a cheap typo.
check("ژ glides over ز", String(Lexicon.pathLetters("ویژه")), "ویزه")
check("typo زاپن", Lexicon.shared.suggestions(forUnknown: "زاپن", context: .none, correct: true, limit: 2).first ?? "", "ژاپن")
check("typo خوبب", Lexicon.shared.suggestions(forUnknown: "خوبب", context: .none, correct: true, limit: 2).first ?? "", "خوب")
check("typo اسفاده", Lexicon.shared.suggestions(forUnknown: "اسفاده", context: .none, correct: true, limit: 2).first ?? "", "استفاده")
Lexicon.shared.learn("خوبی", after: .word("سلام"))
Lexicon.shared.learn("خوبی", after: .word("سلام"))
check("learned pair", Lexicon.shared.predictions(after: .word("سلام"), limit: 1).first ?? "", "خوبی")

// English: the same logic on en_words.txt and en_bigrams.bin, with QWERTY neighbours.
var englishLoaded = false
Lexicon.english.load(words: directory.appendingPathComponent("en_words.txt"),
                     bigrams: directory.appendingPathComponent("en_bigrams.bin")) { englishLoaded = true }
while !englishLoaded { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
let qwerty = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map(Array.init)
var englishNeighbours: [(Character, Character)] = []
for (r, row) in qwerty.enumerated() {
    for (c, a) in row.enumerated() {
        if c + 1 < row.count { englishNeighbours.append((a, row[c + 1])) }
        if r + 1 < qwerty.count {
            for (c2, b) in qwerty[r + 1].enumerated() where c2 == c || c2 == c - 1 { englishNeighbours.append((a, b)) }
        }
    }
}
Lexicon.english.setNeighbours(englishNeighbours)
let english = Lexicon.english
check("en word with apostrophe", english.isWord("don't"), true)
check("en not a word", english.isWord("سلام"), false)
check("en predictions after thank", english.predictions(after: .word("thank"), limit: 3).first ?? "", "you")
check("en context completion", (english.completions(for: "sta", context: .word("united"), limit: 1).first ?? "").lowercased(), "states")
check("en name keeps its capital", english.completions(for: "lond", limit: 1).first ?? "", "London")
check("en typo dont", english.suggestions(forUnknown: "dont", context: .none, correct: true, limit: 2).first ?? "", "don't")
check("en typo im", english.corrections(for: "im", limit: 1).first?.word ?? "", "I'm")
check("en typo becuase", english.suggestions(forUnknown: "becuase", context: .none, correct: true, limit: 2).first ?? "", "because")
check("en typo thw", english.corrections(for: "thw", limit: 1).first?.word ?? "", "the")
check("en glide letters skip the apostrophe", String(english.language.pathLetters("don't")), "dont")
english.learn("Keyless", after: .word("the"), confirmed: true)
check("en learned word", english.completions(for: "keyl", limit: 1).first ?? "", "Keyless")

// ZWNJ.
let fa = Lexicon.shared
check("zwnj verb", fa.zwnjSpelling(of: "میخوام") ?? "nil", "می‌خوام")
check("zwnj plural", fa.zwnjSpelling(of: "کتابها") ?? "nil", "کتاب‌ها")
check("zwnj compound left alone", fa.zwnjSpelling(of: "بیشتر") ?? "nil", "nil")
check("zwnj compound left alone 2", fa.zwnjSpelling(of: "همچنین") ?? "nil", "nil")
check("zwnj typed already", fa.zwnjSpelling(of: "می‌خوام") ?? "nil", "nil")
check("zwnj join prefix", fa.zwnjJoin("می", "خوام") ?? "nil", "می‌خوام")
check("zwnj join plural", fa.zwnjJoin("کتاب", "ها") ?? "nil", "کتاب‌ها")
check("zwnj join comparative", fa.zwnjJoin("بیش", "تر") ?? "nil", "بیش‌تر")
check("zwnj no join این که", fa.zwnjJoin("این", "که") ?? "nil", "nil")
check("zwnj no join از این", fa.zwnjJoin("از", "این") ?? "nil", "nil")
check("double letter starts a word", fa.startsWord("مم"), true)
check("double letter starts a word 2", fa.startsWord("بب"), true)
check("doubled ی after می", fa.startsWord("میی"), false)
check("doubled ب after کتاب", fa.startsWord("کتابب"), false)
let afterSala = fa.continuationWeights(after: "سلا", letters: ["م", "ن", "ک"])
check("next letter after سلا", afterSala.max { $0.value < $1.value }?.key ?? "", "م")

// TapMap: three keys in a row, 34 wide and 54 high.
let frames = (0..<3).map { CGRect(x: CGFloat($0) * 34, y: 0, width: 34, height: 54) }
func keys(_ weights: [Double] = [0, 0, 0]) -> [TouchModel.Candidate] {
    zip(["a", "b", "c"], zip(frames, weights)).map { TouchModel.Candidate(key: $0, frame: $1.0, weight: $1.1) }
}
var touches = TouchModel()
check("tap centre", touches.choose(CGPoint(x: 51, y: 27), among: keys(), hit: 1, layout: "t"), 1)
check("tap near the edge, nothing learned", touches.choose(CGPoint(x: 66, y: 27), among: keys(), hit: 1, layout: "t"), 1)
check("likely letter wins the edge", touches.choose(CGPoint(x: 69, y: 27), among: keys([1, 100, 1]), hit: 2, layout: "t"), 1)
check("centre beats the likely letter", touches.choose(CGPoint(x: 85, y: 27), among: keys([1, 100, 1]), hit: 2, layout: "t"), 2)
for _ in 0..<30 { touches.learn(CGPoint(x: 0.55, y: 0), key: "b", layout: "t") }
check("learned habit", touches.choose(CGPoint(x: 70, y: 27), among: keys(), hit: 2, layout: "t"), 1)
check("learned habit keeps centres", touches.choose(CGPoint(x: 85, y: 27), among: keys(), hit: 2, layout: "t"), 2)
check("far touches are not learned", { var m = TouchModel(); m.learn(CGPoint(x: 2, y: 0), key: "b", layout: "t"); return m.isEmpty }(), true)

// Glide typing: the Persian letter rows, 34 points wide and 54 high. A line halfway between
// the lines of two words is read as the one that fits the word before.
let glideRows = ["ضصقفغعهخحجچ", "شسیبلاتنمکگ", "ظطزرذدپوث"]
var glideKeys: [Character: CGPoint] = [:]
for (row, letters) in glideRows.enumerated() {
    for (column, letter) in letters.enumerated() {
        glideKeys[letter] = CGPoint(x: (CGFloat(column) + 0.5) * 34, y: (CGFloat(row) + 0.5) * 54)
    }
}
func glideLine(_ word: String) -> [CGPoint] {
    GlideDecoder.resample(Lexicon.pathLetters(Lexicon.key(word)).compactMap { glideKeys[$0] }, 32)
}
let between = zip(glideLine("خوب"), glideLine("خواب")).map { CGPoint(x: ($0.x + $1.x) / 2, y: ($0.y + $1.y) / 2) }
func glide(after word: String?) -> String {
    let context: Lexicon.Context = word.map { .word(Lexicon.key($0)) } ?? .none
    return GlideDecoder.decode(between, keys: glideKeys, unit: 34, context: context).first ?? "nil"
}
print("glide between خوب and خواب, no word before:", glide(after: nil))
check("glide after خیلی", glide(after: "خیلی"), "خوب")
check("glide after اتاق", glide(after: "اتاق"), "خواب")
check("glide of a whole word", GlideDecoder.decode(glideLine("سلام"), keys: glideKeys, unit: 34).first ?? "nil", "سلام")

// Automatic correction on a space: clear misspellings only.
for word in ["مرسس", "سلان", "صحبط", "ممنوم", "زندگس", "کیلس", "اسفاده", "خوبب", "واتساپ", "کتاپ", "میخام", "دوسن"] {
    let top = fa.costedCorrections(for: word, context: .none, limit: 4, wholeWords: true).map { "\($0.word) \(String(format: "%.2f", $0.score)) c\($0.cost)" }
    print("::notice::fa", word, top, "->", fa.autoCorrection(for: word) ?? "nil")
}
for word in ["teh", "becuase", "recieve", "xqzt", "keyless", "wierd"] {
    let top = english.corrections(for: word, limit: 3).map { "\($0.word) \(String(format: "%.2f", $0.score))" }
    print("::notice::en", word, top, "->", english.autoCorrection(for: word) ?? "nil")
}
check("auto mrsi", fa.autoCorrection(for: "مرسس") ?? "nil", "مرسی")
check("auto sohbat", fa.autoCorrection(for: "صحبط") ?? "nil", "صحبت")
check("auto خوبب is not خوبی", fa.autoCorrection(for: "خوبب") == "خوبی", false)
// سلان reads as سلام or سالن (letters swapped): left alone.
check("auto سلان is unclear", fa.autoCorrection(for: "سلان") ?? "nil", "nil")
check("auto en recieve", english.autoCorrection(for: "recieve") ?? "nil", "receive")
check("auto leaves nonsense", english.autoCorrection(for: "xqzt") ?? "nil", "nil")
check("auto leaves کیلس", fa.autoCorrection(for: "کیلس") ?? "nil", "nil")
check("auto leaves a known word", fa.autoCorrection(for: "سلام") ?? "nil", "nil")

let start = Date()
for word in ["سلان", "کتاا", "مرسس", "زندگس", "صحبط", "اسفاده", "دوستت", "ممنوم"] {
    _ = Lexicon.shared.corrections(for: word, limit: 3)
}
print(String(format: "corrections: %.1f ms per word", Date().timeIntervalSince(start) * 1000 / 8))

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
