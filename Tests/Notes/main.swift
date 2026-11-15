// Checks the notes' Persian text rules (PersianText), the pause cutter (SpeechSegmenter) and
// the audio file reader (AudioStreamReader: Ogg Opus voice messages and AVFoundation files)
// on a Mac, with no app build. Audio files come from notes-check.yml (macOS `say` and ffmpeg).
import AVFoundation
import Foundation

func L(_ fa: String, _ en: String) -> String { fa }

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}
func same(_ name: String, _ got: String, _ want: String) {
    check(name, got == want, "got «\(got)» want «\(want)»")
}

// MARK: Text
same("arabic letters", PersianText.unifyingLetters("كتاب علي ٣٤"), "کتاب علی ۳۴")
same("mi prefix", PersianText.normalized("او می رود و نمی خواهد"), "او می‌رود و نمی‌خواهد")
same("mi not inside word", PersianText.normalized("دائمی شد"), "دائمی شد")
same("ha plural", PersianText.normalized("کتاب ها و درخت های بلند"), "کتاب‌ها و درخت‌های بلند")
same("ha alone kept", PersianText.normalized("تنها او"), "تنها او")
same("zwnj spaces", PersianText.normalized("می \u{200C} رود"), "می\u{200C}رود")
same("double spaces", PersianText.normalized("سلام   دنیا "), "سلام دنیا")
same("latin untouched", PersianText.normalized("iPhone 15 Pro"), "iPhone 15 Pro")
same("persian digits", PersianText.persianDigits("سال 2024 و ٣"), "سال ۲۰۲۴ و ۳")
same("latin digits", PersianText.latinDigits("۱۴۰۳/۰۵/۱۲"), "1403/05/12")
check("search zwnj", PersianText.matches("این کار می‌شود", query: "میشود"))
check("search spaced", PersianText.matches("این کار می شود", query: "می‌شود"))
check("search arabic", PersianText.matches("كتابها", query: "کتاب‌ها"))
check("search digits", PersianText.matches("قیمت ۲۵۰ تومان", query: "250"))
check("search words any order", PersianText.matches("خرید نان و شیر", query: "شیر نان"))
check("search miss", !PersianText.matches("خرید نان", query: "پنیر"))
check("rtl persian with english start", PersianText.isRightToLeft("iPhone من خراب شد", defaultRTL: false))
check("ltr english", !PersianText.isRightToLeft("Meeting at 5 با علی", defaultRTL: true))
check("empty follows default", PersianText.isRightToLeft("123", defaultRTL: true))
check("hashtags", PersianText.hashtags(in: "#کار و #خرید_خانه و باز #کار و a#b") == ["کار", "خرید_خانه"],
      "\(PersianText.hashtags(in: "#کار و #خرید_خانه و باز #کار و a#b"))")
let sentenceText = "سلام. حالت چطوره؟! خوبم\nخداحافظ"
let sentences = PersianText.sentenceRanges(sentenceText).map { (sentenceText as NSString).substring(with: $0) }
check("sentences", sentences == ["سلام.", " حالت چطوره؟!", " خوبم\n", "خداحافظ"], "\(sentences)")

// MARK: Segmenter
func levels(_ pattern: [(Float, Int)]) -> [Float] { pattern.flatMap { Array(repeating: $0.0, count: $0.1) } }
func cuts(_ levels: [Float]) -> [(Int, Bool)] {
    var s = SpeechSegmenter()
    var out: [(Int, Bool)] = []
    for (i, l) in levels.enumerated() { if case .cut(let speech) = s.add(level: l) { out.append((i + 1, speech)) } }
    return out
}
let noise: Float = 0.001, voice: Float = 0.05
var c = cuts(levels([(noise, 10), (voice, 40), (noise, 15), (voice, 30), (noise, 15)]))
check("cut at pauses", c.count == 2 && c[0].1 && c[1].1, "\(c)")
c = cuts(levels([(noise, 120)]))
check("silence dropped", c.count == 2 && !c[0].1, "\(c)")
c = cuts(levels([(noise, 5)] + Array(repeating: [(voice, 8), (noise, 2)], count: 40).flatMap { $0 }))
check("30 s cap", c.first?.0 == 300 && c.first?.1 == true, "\(c)")
// Speech with short gaps (0.2 s) stays one piece until a real pause.
c = cuts(levels(Array(repeating: [(voice, 8), (noise, 2)], count: 15).flatMap { $0 } + [(noise, 15)]))
check("short gaps kept", c.count == 1, "\(c)")

// MARK: Audio files
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "audio"
for name in ["speech.ogg", "speech60.ogg", "speech-stereo.opus", "speech.m4a", "speech.mp3", "speech.wav"] {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { check("file \(name)", false, "missing"); continue }
    do {
        let reader = try AudioStream.open(url)
        var all: [Float] = []
        while true {
            let piece = try reader.read(seconds: 2)
            if piece.isEmpty { break }
            all += piece
        }
        let seconds = Double(all.count) / 16_000
        let reference = try AudioLoader.loadSamples(url: URL(fileURLWithPath: dir).appendingPathComponent("speech.wav"))
        let refSeconds = Double(reference.count) / 16_000
        let rms = SpeechSegmenter.level(all[...])
        // Pieces of the stream, as a note's transcription cuts them.
        var segmenter = SpeechSegmenter()
        var speechPieces = 0
        var i = 0
        var marks: [String] = []
        var levels: [String] = []
        while i + 1600 <= all.count {
            let level = SpeechSegmenter.level(all[i..<(i + 1600)])
            levels.append(String(format: "%.4f", level))
            if case .cut(let speech) = segmenter.add(level: level) {
                marks.append("\(i / 1600 + 1)\(speech ? "" : "s")")
                if speech { speechPieces += 1 }
            }
            i += 1600
        }
        print("     cuts \(marks)")
        if name.hasSuffix("mp3") || name.hasSuffix("wav") { print("     levels \(levels.joined(separator: " "))") }
        if segmenter.end() { speechPieces += 1 }
        print("     \(name): \(String(format: "%.2f", seconds)) s (wav \(String(format: "%.2f", refSeconds)) s), rms \(rms), duration field \(String(format: "%.2f", reader.duration)), pieces \(speechPieces)")
        check("file \(name) length", abs(seconds - refSeconds) < 0.15, "\(seconds) vs \(refSeconds)")
        check("file \(name) has sound", rms > 0.01, "rms \(rms)")
        check("file \(name) pieces", speechPieces == 3, "\(speechPieces)")
    } catch {
        check("file \(name)", false, "\(error)")
    }
}
check("not ogg", !OggOpusReader.isOgg(URL(fileURLWithPath: dir).appendingPathComponent("speech.wav")))

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
