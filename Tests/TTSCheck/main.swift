// Checks the app's Persian voice code (PersianPhonemizer, PiperVoice, OnnxModel) on a Mac against
// the Python export (Tests/TTS/tts-reference.json: phonemes and IPA of the test sentences), writes
// each sentence as a WAV and prints the speed (real-time factor, 2 threads as in the app).
// Usage: tts-check <voice files dir> <tts-reference.json> <output dir>
import AVFoundation
import Foundation

struct Reference: Decodable {
    let text: String
    let phonemes: String
    let ipa: String
}

let args = CommandLine.arguments
let models = URL(fileURLWithPath: args[1])
let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let out = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var start = Date()
let phonemizer = try PersianPhonemizer(directory: models)
let voice = try PiperVoice(directory: models)
print(String(format: "load %.2f s", Date().timeIntervalSince(start)))

var failures = 0
var g2pSeconds = 0.0, synthSeconds = 0.0, audioSeconds = 0.0
for (i, ref) in references.enumerated() {
    start = Date()
    let phonemes = try phonemizer.phonemes(PersianPhonemizer.clean(ref.text))
    g2pSeconds += Date().timeIntervalSince(start)
    let ipa = phonemes.split(separator: " ").map { PersianPhonemizer.ipa(word: $0, stress: .rules) }.joined(separator: " ")
    let ok = phonemes == ref.phonemes && ipa == ref.ipa
    if !ok { failures += 1 }
    print("\(ok ? "OK  " : "FAIL") \(ref.text)\n     swift  \(phonemes)\n     python \(ref.phonemes)\n     ipa    \(ipa)")
    if ipa != ref.ipa { print("     pyipa  \(ref.ipa)") }

    start = Date()
    var samples: [Float] = []
    for sentence in try phonemizer.sentences(ref.text) {
        samples += try voice.synthesize(sentence)
    }
    synthSeconds += Date().timeIntervalSince(start)
    audioSeconds += Double(samples.count) / voice.sampleRate
    let format = AVAudioFormat(standardFormatWithSampleRate: voice.sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: out.appendingPathComponent("swift-\(i).wav"), settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: voice.sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    try file.write(from: buffer)
}
print(String(format: "phonemizer %.0f ms/sentence; voice and phonemizer RTF %.3f (audio %.1f s)",
             1000 * g2pSeconds / Double(references.count), synthSeconds / audioSeconds, audioSeconds))
print("\(references.count - failures)/\(references.count) sentences as in Python")
