// Runs the app's ShenavaStream on a folder of WAVs as the keyboard does (0.1 s at a time), and
// writes <wav>.txt next to each, for scripts/wer.py: the benchmark and the training workflow's
// check of a fine-tuned model use the app's own code. macOS only (Core ML).
// Usage: shenava-check <model (.mlmodelc, or .mlmodel/.aar compiled as the app imports it)> <sidecars dir>
//        <clips dir> [cpu|all]
import AVFoundation
import CoreML
import Foundation

enum DictationBridge {
    static let pauseMark: Character = "\u{E000}"
}

let args = CommandLine.arguments
let units: MLComputeUnits = args.count > 4 && args[4] == "all" ? .all : .cpuOnly
var modelURL = URL(fileURLWithPath: args[1])
if ModelArchive.extensions.contains(modelURL.pathExtension.lowercased()) {
    modelURL = try await ModelArchive.compile(modelURL)
}
let stream = try ShenavaStream(model: modelURL, resources: URL(fileURLWithPath: args[2]), computeUnits: units)
let clips = URL(fileURLWithPath: args[3])
let files = try FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
var audioSeconds = 0.0
for url in files {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    audioSeconds += Double(samples.count) / 16_000
    stream.reset()
    var i = 0
    while i < samples.count {
        try stream.accept(Array(samples[i..<min(i + 1600, samples.count)]))
        i += 1600
    }
    try stream.finish()
    let text = stream.text.split(separator: DictationBridge.pauseMark).map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: " ")
    try text.write(to: URL(fileURLWithPath: url.path + ".txt"), atomically: true, encoding: .utf8)
}
let memory = MemoryFootprint.megabytes
print(String(format: "TIMING clips=%d steps=%d mean_step_ms=%.1f audio_s=%.1f compute_s=%.1f footprint_mb=%.0f footprint_peak_mb=%.0f",
             files.count, stream.steps, stream.computeSeconds * 1000 / Double(max(stream.steps, 1)), audioSeconds,
             stream.computeSeconds, memory.now, memory.peak))
