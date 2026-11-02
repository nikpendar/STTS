import CoreML
import Foundation

// Checks AutoPunctuation against the release's test sentences (scripts/punct/release.py): the
// Swift tokenizer's pieces against Hugging Face's, and the labels against the Python Core ML run.
// usage: punct-check FOLDER (punct-vocab.tsv, punct-tests.jsonl, Punct.mlpackage)

enum DictationBridge {
    static let pauseMark: Character = "\u{E000}"
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let work = FileManager.default.temporaryDirectory.appendingPathComponent("punct-check")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
for file in ["punct-vocab.tsv", "punct-info.json"] {
    try FileManager.default.copyItem(at: folder.appendingPathComponent(file), to: work.appendingPathComponent(file))
}
let compiled = try MLModel.compileModel(at: folder.appendingPathComponent("Punct.mlpackage"))
try FileManager.default.moveItem(at: compiled, to: work.appendingPathComponent("Punct.mlmodelc"))
AutoPunctuation.testDirectory = work

struct Test: Decodable {
    let words: [String]
    let ids: [Int32]
    let labels: [Int]
}
let lines = try String(contentsOf: folder.appendingPathComponent("punct-tests.jsonl"), encoding: .utf8)
    .split(separator: "\n")
let tests = try lines.map { try JSONDecoder().decode(Test.self, from: Data($0.utf8)) }

var idMismatches = 0, words = 0, agree = 0
var notes: [String] = []
let started = CFAbsoluteTimeGetCurrent()
for test in tests {
    let pieces = test.words.flatMap { AutoPunctuation.shared.pieces(of: $0) ?? [] }
    let expected = Array(test.ids.dropFirst().dropLast())
    if pieces != expected {
        idMismatches += 1
        if notes.count < 6 {
            let first = (0..<min(pieces.count, expected.count)).first { pieces[$0] != expected[$0] } ?? min(pieces.count, expected.count)
            notes.append("ids differ at \(first): swift \(Array(pieces[first..<min(pieces.count, first + 6)])) hf \(Array(expected[first..<min(expected.count, first + 6)])) in «\(test.words.joined(separator: " "))»")
        }
    }
    guard let labels = AutoPunctuation.shared.labels(for: test.words) else {
        print("::error::no labels: the model did not load")
        exit(1)
    }
    words += test.words.count
    agree += zip(labels, test.labels).filter { $0 == $1 }.count
}
let ms = 1000 * (CFAbsoluteTimeGetCurrent() - started) / Double(tests.count)
let agreement = 100 * Double(agree) / Double(max(words, 1))
print("::notice title=punctuation::\(tests.count) sentences: pieces differ in \(idMismatches), labels agree on \(String(format: "%.2f", agreement))% of \(words) words, \(String(format: "%.0f", ms)) ms per sentence")
for note in notes { print("::warning title=pieces::\(note)") }
for test in tests.prefix(4) {
    let text = test.words.joined(separator: " ")
    print("::notice title=sample::\(AutoPunctuation.shared.punctuate(text))")
}
let paused = "سلام خوبی\u{E000}امروز کجا رفتی من خیلی دنبالت گشتم"
print("::notice title=sample with pause::\(AutoPunctuation.shared.punctuate(paused).replacingOccurrences(of: "\u{E000}", with: " | "))")
if idMismatches * 50 > tests.count || agreement < 97 { exit(1) }
