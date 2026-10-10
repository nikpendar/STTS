import UIKit

/// Turns a swipe over the Persian letter keys into words, as iOS QuickPath does: every listed
/// word that starts near where the finger went down and ends near where it lifted is drawn as
/// the line through its keys, and the word whose line lies closest to the swipe wins, with
/// frequent words favoured. In a simulation with noisy swipes over the 3000 most common words,
/// the right word came first 80% of the time and among the first three 97%.
enum GlideDecoder {
    private static let samples = 32
    /// Weight of word frequency (Zipf units) against distance (key widths).
    private static let frequencyWeight = 0.15

    /// Best words first. `keys` are the centres of the letter keys, `unit` the key width.
    static func decode(_ path: [CGPoint], keys: [Character: CGPoint], unit: CGFloat, limit: Int = 3) -> [String] {
        guard path.count >= 2, unit > 0, let start = path.first, let end = path.last else { return [] }
        let user = resample(path, samples)
        let length = Self.length(path)
        let firsts = Set(keys.filter { distance($0.value, start) < 1.1 * unit }.keys)
        let lasts = Set(keys.filter { distance($0.value, end) < 1.3 * unit }.keys)
        var scored: [(word: String, cost: Double)] = []
        for candidate in Lexicon.shared.glideCandidates(firstLetters: firsts, lastLetters: lasts, maxLetters: 24) {
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

/// The line a glide leaves behind: a ribbon that tapers off and fades within a quarter of a
/// second, like the system keyboard's. From iOS 26 the finger also drags a drop of Liquid Glass
/// that magnifies the keys under it, followed by smaller drops along the line that merge into
/// it like water on glass.
final class GlideTrailView: UIView {
    private struct Point {
        let location: CGPoint
        let time: CFTimeInterval
    }

    private var points: [Point] = []
    private let ribbon = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var isTracking = false
    private static let lifetime: CFTimeInterval = 0.28
    private var glass: GlassTrail?

    var color: UIColor = .systemBlue {
        didSet { ribbon.fillColor = color.withAlphaComponent(0.55).cgColor }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        ribbon.fillColor = color.withAlphaComponent(0.55).cgColor
        layer.addSublayer(ribbon)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glass = GlassDrops(in: self)
        }
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func begin(at point: CGPoint) {
        points = [Point(location: point, time: CACurrentMediaTime())]
        isTracking = true
        glass?.begin(at: point)
        startDisplayLink()
    }

    func add(_ point: CGPoint) {
        guard isTracking else { return }
        if let last = points.last, GlideDecoder.distance(last.location, point) < 1.5 { return }
        points.append(Point(location: point, time: CACurrentMediaTime()))
    }

    /// The finger lifted: what is left of the line fades out.
    func end() {
        isTracking = false
        glass?.end()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step() {
        let now = CACurrentMediaTime()
        // The head stays while the finger is down; the tail follows it.
        let headTime = isTracking ? points.last?.time : nil
        points.removeAll { now - $0.time > Self.lifetime && $0.time != headTime }
        draw(now: now)
        glass?.update(trail: points.map(\.location), tracking: isTracking)
        if points.isEmpty && !isTracking && (glass?.isIdle ?? true) {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// A filled outline around the line, widest (7 pt) at the finger and narrowing to nothing.
    private func draw(now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard points.count >= 2 else {
            ribbon.path = nil
            return
        }
        let maxWidth: CGFloat = 7
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for (i, point) in points.enumerated() {
            let previous = points[max(0, i - 1)].location
            let next = points[min(points.count - 1, i + 1)].location
            var dx = next.x - previous.x, dy = next.y - previous.y
            let norm = max(0.001, hypot(dx, dy))
            dx /= norm
            dy /= norm
            let age = CGFloat(min(1, (now - point.time) / Self.lifetime))
            let position = CGFloat(i) / CGFloat(points.count - 1)
            let half = maxWidth / 2 * position * (isTracking ? 1 : 1 - age * 0.6)
            left.append(CGPoint(x: point.location.x - dy * half, y: point.location.y + dx * half))
            right.append(CGPoint(x: point.location.x + dy * half, y: point.location.y - dx * half))
        }
        let path = UIBezierPath()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        // A round cap at the finger.
        if let head = points.last?.location {
            path.addArc(withCenter: head, radius: maxWidth / 2 * (isTracking ? 1 : 0.4),
                        startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        }
        for p in right.reversed() { path.addLine(to: p) }
        path.close()
        ribbon.path = path.cgPath
    }
}

/// The glass part of the trail, which only exists from iOS 26.
@MainActor
private protocol GlassTrail: AnyObject {
    var isIdle: Bool { get }
    func begin(at point: CGPoint)
    func end()
    func update(trail: [CGPoint], tracking: Bool)
}

#if compiler(>=6.2)
/// iOS 26 Liquid Glass drops for `GlideTrailView`: glass views in one glass container, which
/// melts glass shapes that come close into one. Glass appears and disappears by setting its
/// effect inside an animation, as UIKit asks, not by fading.
@available(iOS 26.0, *)
@MainActor
private final class GlassDrops: GlassTrail {
    private let container: UIVisualEffectView
    private let head: UIVisualEffectView
    private var drops: [UIVisualEffectView] = []
    private var headPosition = CGPoint.zero
    private var target = CGPoint.zero
    private(set) var isIdle = true
    private var dropsShown = false
    private static let headSize: CGFloat = 40
    private static let dropSizes: [CGFloat] = [26, 20, 15, 11, 8]

    init(in view: UIView) {
        let effect = UIGlassContainerEffect()
        effect.spacing = 18
        container = UIVisualEffectView(effect: effect)
        container.isUserInteractionEnabled = false
        container.frame = view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(container)
        head = Self.drop(size: Self.headSize)
        container.contentView.addSubview(head)
        for size in Self.dropSizes {
            let drop = Self.drop(size: size)
            drops.append(drop)
            container.contentView.addSubview(drop)
        }
    }

    private static func drop(size: CGFloat) -> UIVisualEffectView {
        let drop = UIVisualEffectView(effect: nil)
        drop.frame = CGRect(x: 0, y: 0, width: size, height: size)
        drop.layer.cornerRadius = size / 2
        drop.clipsToBounds = true
        drop.isUserInteractionEnabled = false
        return drop
    }

    private static func glass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .clear)
        glass.isInteractive = false
        return glass
    }

    func begin(at point: CGPoint) {
        headPosition = point
        target = point
        isIdle = false
        head.center = point
        drops.forEach { $0.center = point }
        UIView.animate(withDuration: 0.18) {
            self.head.effect = Self.glass()
        }
        showDrops(true)
    }

    func end() {
        showDrops(false)
        UIView.animate(withDuration: 0.25, animations: {
            self.head.effect = nil
            self.head.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        }, completion: { _ in
            self.head.transform = .identity
            self.isIdle = true
        })
    }

    private func showDrops(_ shown: Bool) {
        guard dropsShown != shown else { return }
        dropsShown = shown
        UIView.animate(withDuration: shown ? 0.2 : 0.15) {
            for drop in self.drops { drop.effect = shown ? Self.glass() : nil }
        }
    }

    /// Each frame: the big drop follows the finger with a little lag, like a drop pulled across
    /// glass; the small ones sit on the line behind it, the smallest on the oldest part.
    func update(trail: [CGPoint], tracking: Bool) {
        guard !isIdle else { return }
        if let last = trail.last { target = last }
        headPosition.x += (target.x - headPosition.x) * 0.45
        headPosition.y += (target.y - headPosition.y) * 0.45
        head.center = headPosition
        guard trail.count > 1 else { return }
        for (i, drop) in drops.enumerated() {
            let back = Double(i + 1) / Double(drops.count + 1)
            drop.center = trail[max(0, Int(Double(trail.count - 1) * (1 - back)))]
        }
    }
}
#endif
