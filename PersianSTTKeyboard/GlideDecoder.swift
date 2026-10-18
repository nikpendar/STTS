import CoreGraphics
import Foundation

/// Turns a swipe over the letter keys into words, as iOS QuickPath does: every listed
/// word that starts near where the finger went down and ends near where it lifted is drawn as
/// the line through its keys, and the word whose line lies closest to the swipe wins, with
/// words likely after the word before favoured (as the suggestion bar ranks them), else frequent
/// ones. In a simulation with noisy swipes over the 3000 most common words, without the word
/// before, the right word came first 80% of the time and among the first three 97%.
enum GlideDecoder {
    private static let samples = 32
    /// Weight of how likely the word is (Zipf units) against distance (key widths).
    private static let frequencyWeight = 0.15

    /// Best words first. `keys` are the centres of the letter keys, `unit` the key width,
    /// `context` the word before the glide's word.
    static func decode(_ path: [CGPoint], keys: [Character: CGPoint], unit: CGFloat, lexicon: Lexicon = .shared,
                       context: Lexicon.Context = .none, limit: Int = 3) -> [String] {
        guard path.count >= 2, unit > 0, let start = path.first, let end = path.last else { return [] }
        let user = resample(path, samples)
        let length = Self.length(path)
        let firsts = Set(keys.filter { distance($0.value, start) < 1.1 * unit }.keys)
        let lasts = Set(keys.filter { distance($0.value, end) < 1.3 * unit }.keys)
        var scored: [(word: String, cost: Double)] = []
        for candidate in lexicon.glideCandidates(firstLetters: firsts, lastLetters: lasts, maxLetters: 24,
                                                         context: context) {
            let ideal = candidate.letters.compactMap { keys[$0] }
            guard ideal.count == candidate.letters.count else { continue }
            guard abs(Self.length(ideal) - length) <= max(1.5 * unit, 0.6 * length) else { continue }
            let points = resample(ideal, samples)
            var sum: CGFloat = 0
            for i in 0..<samples { sum += distance(points[i], user[i]) }
            let cost = Double(sum / (CGFloat(samples) * unit)) - frequencyWeight * candidate.score
            scored.append((candidate.word, cost))
        }
        scored.sort { $0.cost < $1.cost }
        var words: [String] = []
        for entry in scored where !words.contains(entry.word) {
            words.append(entry.word)
            if words.count == limit { break }
        }
        return words
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func length(_ path: [CGPoint]) -> CGFloat {
        zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// `count` points evenly spaced along the path.
    static func resample(_ path: [CGPoint], _ count: Int) -> [CGPoint] {
        guard let first = path.first else { return [] }
        let total = length(path)
        guard path.count > 1, total > 0 else { return Array(repeating: first, count: count) }
        let step = total / CGFloat(count - 1)
        var result = [first]
        var previous = first
        var carried: CGFloat = 0
        var i = 1
        while i < path.count, result.count < count {
            let d = distance(previous, path[i])
            if carried + d >= step, d > 0 {
                let t = (step - carried) / d
                let point = CGPoint(x: previous.x + t * (path[i].x - previous.x), y: previous.y + t * (path[i].y - previous.y))
                result.append(point)
                previous = point
                carried = 0
            } else {
                carried += d
                previous = path[i]
                i += 1
            }
        }
        while result.count < count { result.append(path[path.count - 1]) }
        return result
    }
}
