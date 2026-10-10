// Checks the keyboard's word logic (Lexicon.swift, VoiceCommands.swift) without a simulator:
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
check("whisper's full stop", text("سلام نقطه."), "سلام.")
check("question replaces whisper's stop", text("خوبی. علامت سوال"), "خوبی؟")
check("دو نقطه at a pause", text("موارد دو نقطه"), "موارد:")
check("دو نقطه as text", text("بین دو نقطه خط بکشید"), "بین دو نقطه خط بکشید")
check("off", text("سلام نقطه", punctuation: false), "سلام نقطه")
check("pause marks become spaces", text("سلام" + pause + "خوبی", punctuation: false), "سلام خوبی")

// Editing commands.
check("delete", VoiceCommands.process("پاک کن", punctuation: true, commands: true).steps == [.deleteSentence], true)
check("delete after text", VoiceCommands.process("سلام" + pause + "پاک کن.", punctuation: true, commands: true).steps.count, 2)
check("delete inside a sentence", text("اینو پاک کن که بد است"), "اینو پاک کن که بد است")
check("delete all", VoiceCommands.process("همه رو پاک کن", punctuation: true, commands: true).steps == [.deleteAll], true)
check("undo", VoiceCommands.process("برگردون", punctuation: true, commands: true).steps == [.undo], true)
check("commands off", text("پاک کن", commands: false), "پاک کن")

// Training text gets the spoken words back.
let dictated = VoiceCommands.process("سلام نقطه خوبی علامت سوال", punctuation: true, commands: true)
check("restore", VoiceCommands.restoringSpoken("سلام. خوبید؟", original: dictated.text, spoken: dictated.spoken) ?? "nil",
      "سلام نقطه خوبید علامت سوال")
check("restore skips changed punctuation",
      VoiceCommands.restoringSpoken("سلام خوبید؟", original: dictated.text, spoken: dictated.spoken) ?? "nil", "nil")

// Suggestions.
let afterAz = Lexicon.shared.predictions(after: .word("از"), limit: 3)
check("predictions after از", afterAz.contains("این"), true)
check("prediction at sentence start", Lexicon.shared.predictions(after: .sentenceStart, limit: 3).first ?? "", "در")
check("context completion", Lexicon.shared.completions(for: "متح", context: .word("ایالات"), limit: 1).first ?? "", "متحده")
check("typo سلان", Lexicon.shared.suggestions(forUnknown: "سلان", context: .none, correct: true, limit: 2).first ?? "", "سلام")
check("typo خوبب", Lexicon.shared.suggestions(forUnknown: "خوبب", context: .none, correct: true, limit: 2).first ?? "", "خوب")
check("typo اسفاده", Lexicon.shared.suggestions(forUnknown: "اسفاده", context: .none, correct: true, limit: 2).first ?? "", "استفاده")
Lexicon.shared.learn("خوبی", after: .word("سلام"))
Lexicon.shared.learn("خوبی", after: .word("سلام"))
check("learned pair", Lexicon.shared.predictions(after: .word("سلام"), limit: 1).first ?? "", "خوبی")

let start = Date()
for word in ["سلان", "کتاا", "مرسس", "زندگس", "صحبط", "اسفاده", "دوستت", "ممنوم"] {
    _ = Lexicon.shared.corrections(for: word, limit: 3)
}
print(String(format: "corrections: %.1f ms per word", Date().timeIntervalSince(start) * 1000 / 8))

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
