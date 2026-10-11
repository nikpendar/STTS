import UIKit

/// Turns a swipe over the letter keys into words, as iOS QuickPath does: every listed
/// word that starts near where the finger went down and ends near where it lifted is drawn as
/// the line through its keys, and the word whose line lies closest to the swipe wins, with
/// frequent words favoured. In a simulation with noisy swipes over the 3000 most common words,
/// the right word came first 80% of the time and among the first three 97%.
enum GlideDecoder {
    private static let samples = 32
    /// Weight of word frequency (Zipf units) against distance (key widths).
    private static let frequencyWeight = 0.15

    /// Best words first. `keys` are the centres of the letter keys, `unit` the key width.
    static func decode(_ path: [CGPoint], keys: [Character: CGPoint], unit: CGFloat, lexicon: Lexicon = .shared,
                       limit: Int = 3) -> [String] {
        guard path.count >= 2, unit > 0, let start = path.first, let end = path.last else { return [] }
        let user = resample(path, samples)
        let length = Self.length(path)
        let firsts = Set(keys.filter { distance($0.value, start) < 1.1 * unit }.keys)
        let lasts = Set(keys.filter { distance($0.value, end) < 1.3 * unit }.keys)
        var scored: [(word: String, cost: Double)] = []
        for candidate in lexicon.glideCandidates(firstLetters: firsts, lastLetters: lasts, maxLetters: 24) {
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

/// The line a glide leaves behind: glass that magnifies the keys under it, wide at the finger and
/// narrowing to a point along the path, like the glass lens of the tab bar in Contacts moving
/// over the keys with a tail. It fades within a third of a second.
/// From iOS 26 it is the system's Liquid Glass (`GlassLens`). Before that it is a row of discs
/// along the line, each showing a snapshot of the keys (taken when the glide starts) enlarged
/// around its own centre, the head disc on top, with one outline for the rim and the shadow.
final class GlideTrailView: UIView {
    private struct Point {
        let location: CGPoint
        let time: CFTimeInterval
    }

    private var points: [Point] = []
    private let lens = CALayer()
    private let shadow = CALayer()
    private let rim = CAShapeLayer()
    private let shine = CAShapeLayer()
    private var discs: [CALayer] = []
    private var snapshotSize = CGSize.zero
    private var displayLink: CADisplayLink?
    private var isTracking = false
    private var endTime: CFTimeInterval = 0
    private static let lifetime: CFTimeInterval = 0.32
    private static let fadeTime: CFTimeInterval = 0.22
    private static let headRadius: CGFloat = 19
    private static let maxDiscs = 48

    /// The colour behind the keys, shown in the lens between them.
    var lensBackground: UIColor = .systemGray5

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowOpacity = 0.28
        shadow.shadowRadius = 5
        shadow.shadowOffset = CGSize(width: 0, height: 2)
        lens.addSublayer(shadow)
        for _ in 0..<Self.maxDiscs {
            let disc = CALayer()
            disc.masksToBounds = true
            disc.contentsGravity = .resize
            disc.isHidden = true
            discs.append(disc)
            lens.addSublayer(disc)
        }
        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        rim.lineWidth = 1.2
        lens.addSublayer(rim)
        shine.fillColor = UIColor.white.withAlphaComponent(0.3).cgColor
        lens.addSublayer(shine)
        lens.isHidden = true
        layer.addSublayer(lens)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glass = GlassLens(in: self)
        }
        #endif
    }

    private var glass: GlassTrail?

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func begin(at point: CGPoint) {
        takeSnapshot()
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

    /// The finger lifted: the lens shrinks into the finger and fades.
    func end() {
        guard isTracking else { return }
        isTracking = false
        endTime = CACurrentMediaTime()
        glass?.end()
    }

    /// The keys as they are now, without the trail, for the discs to enlarge.
    private func takeSnapshot() {
        guard let source = superview, source.bounds.width > 0, source.bounds.height > 0 else { return }
        layer.isHidden = true
        let image = UIGraphicsImageRenderer(bounds: source.bounds).image { context in
            source.layer.render(in: context.cgContext)
        }
        layer.isHidden = false
        snapshotSize = source.bounds.size
        let background = lensBackground.resolvedColor(with: traitCollection).cgColor
        if let glass {
            glass.show(image.cgImage, size: snapshotSize, background: background)
            return
        }
        for disc in discs {
            disc.contents = image.cgImage
            disc.backgroundColor = background
        }
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
        let fade = isTracking ? 1 : CGFloat(max(0, 1 - (now - endTime) / Self.fadeTime))
        if fade <= 0 { points.removeAll() }
        if let glass {
            glass.update(trail: points.map(\.location), tracking: isTracking)
        } else {
            draw(fade: fade)
        }
        if points.isEmpty && !isTracking && (glass?.isIdle ?? true) {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Discs every few points from the finger back along the line, shrinking to a point at the
    /// oldest part; the larger a disc, the more it enlarges.
    private func draw(fade: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let head = points.last?.location, snapshotSize.width > 0, fade > 0 else {
            lens.isHidden = true
            return
        }
        lens.isHidden = false
        lens.opacity = Float(fade.squareRoot())
        let line = points.reversed().map(\.location)
        var length: CGFloat = 0
        for i in 1..<max(1, line.count) { length += GlideDecoder.distance(line[i - 1], line[i]) }
        let spacing = max(2.5, length / CGFloat(Self.maxDiscs - 1))
        // Centres from the head back, with their distance from the head.
        var centres: [(point: CGPoint, along: CGFloat)] = [(head, 0)]
        var segment = 1
        var walked: CGFloat = 0
        var target = spacing
        while segment < line.count, centres.count < Self.maxDiscs {
            let a = line[segment - 1], b = line[segment]
            let piece = GlideDecoder.distance(a, b)
            if walked + piece >= target, piece > 0 {
                let t = (target - walked) / piece
                centres.append((CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), target))
                target += spacing
            } else {
                walked += piece
                segment += 1
            }
        }
        let radii = centres.map { centre -> CGFloat in
            let left = length > 0 ? 1 - centre.along / length : 1
            return max(1.5, Self.headRadius * fade * pow(max(0, left), 0.85))
        }
        for (i, disc) in discs.enumerated() {
            guard i < centres.count else {
                disc.isHidden = true
                continue
            }
            let c = centres[i].point, r = radii[i]
            let zoom = 1 + 0.4 * r / Self.headRadius
            disc.isHidden = false
            disc.zPosition = -centres[i].along
            disc.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            disc.cornerRadius = r
            disc.contentsRect = CGRect(x: (c.x - r / zoom) / snapshotSize.width, y: (c.y - r / zoom) / snapshotSize.height,
                                       width: 2 * r / zoom / snapshotSize.width, height: 2 * r / zoom / snapshotSize.height)
        }
        let outline = Self.outline(centres.map(\.point), radii)
        rim.path = outline
        rim.zPosition = 1
        shadow.shadowPath = outline
        shadow.zPosition = -10_000
        let r = radii[0]
        shine.path = UIBezierPath(ovalIn: CGRect(x: head.x - r * 0.75, y: head.y - r * 0.82,
                                                 width: r * 0.8, height: r * 0.4)).cgPath
        shine.zPosition = 2
    }

    /// The outline around discs of the given radii: one side from the tail to the head, round
    /// over the front of the head disc, and the other side back.
    private static func outline(_ centres: [CGPoint], _ radii: [CGFloat]) -> CGPath {
        let path = UIBezierPath()
        guard centres.count > 1 else {
            path.addArc(withCenter: centres[0], radius: radii[0], startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            return path.cgPath
        }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in centres.indices {
            // Direction towards the head.
            let towards = centres[max(0, i - 1)], from = centres[min(centres.count - 1, i + 1)]
            var dx = towards.x - from.x, dy = towards.y - from.y
            let norm = max(0.001, hypot(dx, dy))
            dx /= norm
            dy /= norm
            left.append(CGPoint(x: centres[i].x - dy * radii[i], y: centres[i].y + dx * radii[i]))
            right.append(CGPoint(x: centres[i].x + dy * radii[i], y: centres[i].y - dx * radii[i]))
        }
        let head = centres[0]
        path.move(to: left[left.count - 1])
        for p in left.reversed().dropFirst() { path.addLine(to: p) }
        // From the left point round the front of the head (the side away from the tail).
        let start = atan2(left[0].y - head.y, left[0].x - head.x)
        let end = atan2(right[0].y - head.y, right[0].x - head.x)
        let back = atan2(centres[1].y - head.y, centres[1].x - head.x)
        var sweep = end - start
        while sweep < 0 { sweep += 2 * .pi }
        var middle = start + sweep / 2 - back
        while middle > .pi { middle -= 2 * .pi }
        while middle < -.pi { middle += 2 * .pi }
        // Increasing angles (clockwise on screen) when their middle lies away from the tail.
        path.addArc(withCenter: head, radius: radii[0], startAngle: start, endAngle: end, clockwise: abs(middle) > .pi / 2)
        for p in right.dropFirst() { path.addLine(to: p) }
        path.close()
        return path.cgPath
    }
}

/// The glass trail, which only exists from iOS 26.
@MainActor
private protocol GlassTrail: AnyObject {
    var isIdle: Bool { get }
    /// The keys to magnify for this glide.
    func show(_ snapshot: CGImage?, size: CGSize, background: CGColor)
    func begin(at point: CGPoint)
    func end()
    func update(trail: [CGPoint], tracking: Bool)
}

#if compiler(>=6.2)
/// iOS 26 Liquid Glass for `GlideTrailView`: a glass capsule at the finger, like the lens of a
/// tab bar or a slider, that shows the keys under it enlarged, followed by smaller drops along
/// the line. All are glass views in one glass container, which melts glass that comes close
/// into one shape, so the drops make a tail that narrows to a point. Glass appears and
/// disappears by setting its effect inside an animation, as UIKit asks, not by fading.
@available(iOS 26.0, *)
@MainActor
private final class GlassLens: GlassTrail {
    private let container: UIVisualEffectView
    private let head: UIVisualEffectView
    private let magnifier = UIView()
    private var drops: [UIVisualEffectView] = []
    private var headPosition = CGPoint.zero
    private var target = CGPoint.zero
    private var snapshotSize = CGSize.zero
    private(set) var isIdle = true
    private var dropsShown = false
    private static let headSize = CGSize(width: 58, height: 42)
    private static let dropSizes: [CGFloat] = [32, 26, 21, 17, 13, 10, 7, 5]
    private static let zoom: CGFloat = 1.3

    init(in view: UIView) {
        let effect = UIGlassContainerEffect()
        effect.spacing = 14
        container = UIVisualEffectView(effect: effect)
        container.isUserInteractionEnabled = false
        container.frame = view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(container)
        for size in Self.dropSizes {
            let drop = Self.glassView(size: CGSize(width: size, height: size))
            drops.append(drop)
            container.contentView.addSubview(drop)
        }
        head = Self.glassView(size: Self.headSize)
        container.contentView.addSubview(head)
        magnifier.frame = head.bounds.insetBy(dx: 2.5, dy: 2.5)
        magnifier.layer.cornerRadius = magnifier.bounds.height / 2
        magnifier.layer.cornerCurve = .continuous
        magnifier.layer.masksToBounds = true
        magnifier.layer.contentsGravity = .resize
        magnifier.isUserInteractionEnabled = false
        magnifier.alpha = 0
        head.contentView.addSubview(magnifier)
    }

    private static func glassView(size: CGSize) -> UIVisualEffectView {
        let glass = UIVisualEffectView(effect: nil)
        glass.frame = CGRect(origin: .zero, size: size)
        glass.layer.cornerRadius = size.height / 2
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        return glass
    }

    private static func glass() -> UIGlassEffect {
        let glass = UIGlassEffect(style: .clear)
        glass.isInteractive = false
        return glass
    }

    func show(_ snapshot: CGImage?, size: CGSize, background: CGColor) {
        magnifier.layer.contents = snapshot
        magnifier.layer.backgroundColor = background
        snapshotSize = size
    }

    func begin(at point: CGPoint) {
        headPosition = point
        target = point
        isIdle = false
        head.center = point
        head.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        drops.forEach { $0.center = point }
        updateMagnifier()
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            self.head.effect = Self.glass()
            self.head.transform = .identity
            self.magnifier.alpha = 1
        }
        showDrops(true)
    }

    func end() {
        showDrops(false)
        UIView.animate(withDuration: 0.25, animations: {
            self.head.effect = nil
            self.magnifier.alpha = 0
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

    /// Each frame: the capsule follows the finger with a little lag, like a drop pulled across
    /// glass, and the drops sit evenly along the line behind it, the smallest on the oldest part.
    func update(trail: [CGPoint], tracking: Bool) {
        guard !isIdle else { return }
        if let last = trail.last { target = last }
        headPosition.x += (target.x - headPosition.x) * 0.5
        headPosition.y += (target.y - headPosition.y) * 0.5
        head.center = headPosition
        updateMagnifier()
        let line = [headPosition] + trail.reversed()
        var along: [CGFloat] = [0]
        for i in 1..<line.count { along.append(along[i - 1] + GlideDecoder.distance(line[i - 1], line[i])) }
        let length = along.last ?? 0
        var segment = 1
        for (i, drop) in drops.enumerated() {
            let distance = length * CGFloat(i + 1) / CGFloat(drops.count + 1)
            while segment < line.count - 1, along[segment] < distance { segment += 1 }
            guard line.count > 1 else {
                drop.center = headPosition
                continue
            }
            let a = line[segment - 1], b = line[segment]
            let piece = along[segment] - along[segment - 1]
            let t = piece > 0 ? min(1, max(0, (distance - along[segment - 1]) / piece)) : 0
            drop.center = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// The keys under the capsule, enlarged around its centre.
    private func updateMagnifier() {
        guard snapshotSize.width > 0 else { return }
        let size = magnifier.bounds.size
        let origin = CGPoint(x: headPosition.x - size.width / 2 / Self.zoom, y: headPosition.y - size.height / 2 / Self.zoom)
        magnifier.layer.contentsRect = CGRect(x: origin.x / snapshotSize.width, y: origin.y / snapshotSize.height,
                                              width: size.width / Self.zoom / snapshotSize.width,
                                              height: size.height / Self.zoom / snapshotSize.height)
    }
}
#endif
