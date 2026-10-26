import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// TapMap: where the user actually touches each letter key, learned from the letters of words
/// they keep and from the letters they correct, together with how likely each letter is next.
/// A touch near the edge between keys goes to the key it most likely meant; the drawn keys do
/// not move, and a touch in the middle of a key always types that key.
struct TouchModel: Codable, Equatable {
    /// A running mean of touch offsets from a key's centre, in key widths and heights.
    struct Mean: Codable, Equatable {
        var x = 0.0, y = 0.0, count = 0.0

        /// Older touches fade out once `limit` are counted, so the model follows a changed grip.
        mutating func add(_ offset: CGPoint, limit: Double) {
            count = min(count + 1, limit)
            x += (Double(offset.x) - x) / count
            y += (Double(offset.y) - y) / count
        }
    }

    /// By layout and key: "fa.p" + "ب".
    private(set) var keys: [String: Mean] = [:]
    /// By layout: the offset common to all keys, which a key's own mean starts from.
    private(set) var layouts: [String: Mean] = [:]

    static let keyLimit = 40.0
    static let layoutLimit = 300.0
    /// Touches a key needs before its own mean counts as much as the layout's.
    static let keyPrior = 6.0
    static let layoutPrior = 15.0
    /// Spread of touches around their centre, in key widths.
    static let spread = 0.45
    /// The key drawn under the finger wins ties.
    static let hitBonus = 0.25
    /// How much the next-letter guess counts, and at most, in log-probability units.
    static let priorWeight = 0.6
    static let priorCap = 1.2

    var isEmpty: Bool { keys.isEmpty }

    /// The finger at `offset` from the key's centre (in key widths and heights) meant `key`.
    /// Touches more than about one key away are a different slip, not a habit, and are left out.
    mutating func learn(_ offset: CGPoint, key: String, layout: String) {
        guard abs(offset.x) <= 1.2, abs(offset.y) <= 1 else { return }
        keys[layout + key, default: Mean()].add(offset, limit: Self.keyLimit)
        layouts[layout, default: Mean()].add(offset, limit: Self.layoutLimit)
    }

    /// Where the user's touches for `key` centre, in key widths and heights from its centre.
    func offset(key: String, layout: String) -> CGPoint {
        let all = layouts[layout] ?? Mean()
        let shrink = all.count / (all.count + Self.layoutPrior)
        let base = (x: all.x * shrink, y: all.y * shrink)
        let own = keys[layout + key] ?? Mean()
        let total = own.count + Self.keyPrior
        return CGPoint(x: (own.x * own.count + base.x * Self.keyPrior) / total,
                       y: (own.y * own.count + base.y * Self.keyPrior) / total)
    }

    struct Candidate {
        let key: String
        let frame: CGRect
        /// How likely the key's letter comes next (any scale), or 0 when unknown.
        var weight: Double = 0
    }

    /// Index of the candidate a touch at `point` most likely meant; `hit` is the key drawn under it.
    func choose(_ point: CGPoint, among candidates: [Candidate], hit: Int, layout: String) -> Int {
        guard candidates.indices.contains(hit) else { return hit }
        let hitFrame = candidates[hit].frame
        // A touch in the middle of a key types it, whatever the model says.
        let core = hitFrame.insetBy(dx: hitFrame.width * 0.3, dy: hitFrame.height * 0.3)
        if core.contains(point) { return hit }
        let maxWeight = candidates.map(\.weight).max() ?? 0
        var best = hit
        var bestScore = Double.infinity
        for (index, candidate) in candidates.enumerated() {
            let frame = candidate.frame
            let shift = offset(key: candidate.key, layout: layout)
            let centre = CGPoint(x: frame.midX + shift.x * frame.width, y: frame.midY + shift.y * frame.height)
            // Distances in points over the key's width: rows are taller than keys are wide, and
            // fingers miss by about as much across as down.
            let sigma = Self.spread * Double(frame.width)
            let dx = Double(point.x - centre.x) / sigma
            let dy = Double(point.y - centre.y) / sigma
            var score = (dx * dx + dy * dy) / 2
            if index == hit { score -= Self.hitBonus }
            if maxWeight > 0 {
                // Smoothed, so a letter no listed word continues with is unlikely, not impossible.
                let weight = candidate.weight + 0.01 * maxWeight
                score += min(Self.priorCap, Self.priorWeight * log(1.01 * maxWeight / weight))
            }
            if score < bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }

    // MARK: - Storage

    private static let defaultsKey = "touchModel"

    static func load() -> TouchModel {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let model = try? JSONDecoder().decode(TouchModel.self, from: data) else { return TouchModel() }
        return model
    }

    /// Keyboard side: keeps the model, and hands a copy to the app on a named pasteboard (as the
    /// app hands its settings to the keyboard) for the map in its settings.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            #if canImport(UIKit)
            UIPasteboard(name: Self.pasteboardName, create: true)?.setData(data, forPasteboardType: "public.json")
            #endif
        }
    }

    #if canImport(UIKit)
    private static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.touchModel")

    /// App side: the keyboard's latest model, if it has saved one.
    static func fromKeyboard() -> TouchModel? {
        guard let data = UIPasteboard(name: pasteboardName, create: false)?.data(forPasteboardType: "public.json") else { return nil }
        return try? JSONDecoder().decode(TouchModel.self, from: data)
    }

    /// App side: forgets the keyboard's copy when the learned touches are cleared.
    static func clearFromKeyboard() {
        UIPasteboard.remove(withName: pasteboardName)
    }
    #endif

    /// How many touches a key's own mean is built on.
    func touches(key: String, layout: String) -> Double { keys[layout + key]?.count ?? 0 }
}
