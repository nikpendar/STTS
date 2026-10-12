// CI check of the app's ShenavaStream on real clips (macOS): feeds each WAV in 100 ms pieces, as the
// microphone would, and writes <wav>.txt for scripts/wer.py.
// Usage: shenava-check <model dir> <clips dir>
import AVFoundation
import CoreML
import Foundation

let args = CommandLine.arguments
let stream = try ShenavaStream(directory: URL(fileURLWithPath: args[1]), computeUnits: .cpuOnly)
let clips = URL(fileURLWithPath: args[2])
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
    let text = stream.text.trimmingCharacters(in: .whitespaces)
    try text.write(to: URL(fileURLWithPath: url.path + ".txt"), atomically: true, encoding: .utf8)
    print(text)
}
print(String(format: "TIMING steps=%d mean_step_ms=%.1f audio_s=%.1f", stream.steps,
             stream.computeSeconds * 1000 / Double(max(stream.steps, 1)), audioSeconds))
