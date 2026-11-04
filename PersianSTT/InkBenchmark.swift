import Foundation
import UIKit

/// CI only (ink-eval.yml): launch argument `-inkBenchmark <samples.json>` runs the keyboard's
/// handwriting recognizer (`InkRecognizer`) on each sample's strokes and writes, to
/// `-inkOut <path>`, the readings, the time of each and the app's memory. Samples are
/// [{"word": "...", "strokes": [[[x, y, t], ...], ...], "width": w, "height": h}].
enum InkBenchmark {
    private struct Sample: Decodable {
        let word: String
        let strokes: [[[Double]]]
        let width: Double
        let height: Double
    }

    private static var recognizer: InkRecognizer?

    static func run(input: String, output: String) {
        guard let data = FileManager.default.contents(atPath: input),
              let samples = try? JSONDecoder().decode([Sample].self, from: data) else {
            write(["error": "no samples at \(input)"], to: output)
            return
        }
        let before = MemoryFootprint.megabytes.now
        let recognizer = InkRecognizer()
        Self.recognizer = recognizer
        let started = Date()
        recognizer.onState = { state in
            switch state {
            case .ready:
                let loaded = MemoryFootprint.megabytes.now
                recognize(samples, index: 0, results: [], with: recognizer) { results in
                    let memory = MemoryFootprint.megabytes
                    write(["built_in": InkRecognizer.isBuiltIn, "samples": samples.count,
                           "memory_before_mb": before, "memory_loaded_mb": loaded,
                           "memory_after_mb": memory.now, "memory_peak_mb": memory.peak,
                           "ready_seconds": Date().timeIntervalSince(started), "results": results], to: output)
                }
            case .failed(let message):
                write(["error": message], to: output)
            case .unavailable:
                write(["error": "ML Kit is not in this build", "built_in": InkRecognizer.isBuiltIn], to: output)
            case .downloading:
                break
            }
        }
        recognizer.prepare()
    }

    private static func recognize(_ samples: [Sample], index: Int, results: [[String: Any]], with recognizer: InkRecognizer,
                                  done: @escaping ([[String: Any]]) -> Void) {
        guard index < samples.count else { return done(results) }
        let sample = samples[index]
        let strokes = sample.strokes.map { stroke in
            stroke.map { InkRecognizer.Point(x: Float($0[0]), y: Float($0[1]), t: Int($0[2])) }
        }
        let start = Date()
        recognizer.recognize(strokes, before: "", area: CGSize(width: sample.width, height: sample.height)) { texts in
            var all = results
            all.append(["word": sample.word, "readings": texts, "ms": Date().timeIntervalSince(start) * 1000])
            recognize(samples, index: index + 1, results: all, with: recognizer, done: done)
        }
    }

    private static func write(_ object: [String: Any], to path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
