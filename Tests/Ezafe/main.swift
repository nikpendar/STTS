import CoreML
import Foundation

// Checks EzafeTagger against the release's test sentences (scripts/ezafe-app/coreml.py): the Swift
// pieces against Hugging Face's ids, and the labels against the Python Core ML run.
// usage: ezafe-check FOLDER (Ezafe.mlpackage, ezafe-tests.jsonl) PUNCT_FOLDER (punct-vocab.tsv, punct-info.json)

enum DictationBridge {
    static let pauseMark: Character = "\u{E000}"
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let punct = URL(fileURLWithPath: CommandLine.arguments[2])
let compiled = try MLModel.compileModel(at: folder.appendingPathComponent("Ezafe.mlpackage"))
var started = CFAbsoluteTimeGetCurrent()
let tagger = try EzafeTagger(model: compiled, vocabulary: punct.appendingPathComponent("punct-vocab.tsv"))
print(String(format: "load %.0f ms", 1000 * (CFAbsoluteTimeGetCurrent() - started)))

struct Test: Decodable {
    let words: [String]
    let ids: [Int32]
    let labels: [Int]
    let gold: [Int]
}
let tests = try String(contentsOf: folder.appendingPathComponent("ezafe-tests.jsonl"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(Test.self, from: Data($0.utf8)) }

var idMismatches = 0, words = 0, agree = 0, tp = 0, fp = 0, fn = 0
started = CFAbsoluteTimeGetCurrent()
for test in tests {
    let pieces = tagger.pieces(test.words).flatMap { $0 }
    if pieces != Array(test.ids.dropFirst().dropLast()) {
        idMismatches += 1
        if idMismatches <= 6 { print("::warning title=pieces::«\(test.words.joined(separator: " "))»") }
    }
    guard let flags = tagger.flags(test.words) else {
        print("::error::no labels from the tagger")
        exit(1)
    }
    words += flags.count
    agree += zip(flags, test.labels).filter { ($0 ? 1 : 0) == $1 }.count
    for (f, g) in zip(flags, test.gold) {
        if f && g == 1 { tp += 1 } else if f { fp += 1 } else if g == 1 { fn += 1 }
    }
}
let ms = 1000 * (CFAbsoluteTimeGetCurrent() - started) / Double(tests.count)
let p = Double(tp) / Double(max(tp + fp, 1)), r = Double(tp) / Double(max(tp + fn, 1))
let agreement = 100 * Double(agree) / Double(max(words, 1))
print("::notice title=Ezafe in Swift::\(tests.count) sentences: pieces differ in \(idMismatches), labels as in Python on \(String(format: "%.2f", agreement))% of \(words) words, F1 \(String(format: "%.1f", 200 * p * r / max(p + r, 1e-9))), \(String(format: "%.0f", ms)) ms per sentence")
if agreement < 99 { exit(1) }
