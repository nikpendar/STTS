import CoreML
import Foundation

// Automatic punctuation on the speech model's own text (Tests/ShenavaCheck with KEEP_PAUSES=1:
// <clip>.wav.pause, pauses as DictationBridge.pauseMark), with each way of turning the tagger's
// scores into marks (AutoPunctuation.Tuning). Writes a JSON line per clip and variant for
// scripts/punct_score.py.
// usage: punct-eval PUNCT_FOLDER (Punct.mlmodelc, punct-vocab.tsv, punct-info.json) CLIPS_FOLDER OUT.jsonl

enum DictationBridge {
    static let pauseMark: Character = "\u{E000}"
}

let args = CommandLine.arguments
AutoPunctuation.testDirectory = URL(fileURLWithPath: args[1])
let clips = URL(fileURLWithPath: args[2])
let files = try FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "pause" }.sorted { $0.path < $1.path }

typealias Tuning = AutoPunctuation.Tuning
var variants: [(String, Tuning)] = [("base", Tuning())]
variants.append(("end", Tuning(endPeriod: true)))
for m: Float in [2, 4, .infinity] {
    variants.append(("q\(m == .infinity ? "word" : String(Int(m)))", Tuning(questionMargin: m, endPeriod: true)))
}
for b: Float in [1, 2, 3, 5] {
    variants.append(("pause\(Int(b))-qword", Tuning(pauseBias: b, questionMargin: .infinity, endPeriod: true)))
    variants.append(("pause\(Int(b))-q4", Tuning(pauseBias: b, questionMargin: 4, endPeriod: true)))
}

var out = ""
for file in files {
    let text = try String(contentsOf: file, encoding: .utf8)
    for (name, tuning) in variants {
        AutoPunctuation.tuning = tuning
        let punctuated = AutoPunctuation.shared.punctuate(text)
            .replacingOccurrences(of: String(DictationBridge.pauseMark), with: " ")
        let row: [String: String] = ["clip": file.deletingPathExtension().lastPathComponent, "variant": name, "text": punctuated]
        out += String(data: try JSONSerialization.data(withJSONObject: row), encoding: .utf8)! + "\n"
    }
}
try out.write(toFile: args[3], atomically: true, encoding: .utf8)
print("::notice title=punct-eval::\(files.count) clips, \(variants.count) variants")
