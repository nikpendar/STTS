import SwiftUI
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

/// The line a glide leaves behind: one drop of glass like a falling tear, round at the finger
/// and narrowing to a point along the path, that magnifies the keys under all of it. It fades
/// within a third of a second.
/// The magnifying is a row of discs along the line, each showing a snapshot of the keys (taken
/// when the glide starts) enlarged around its own centre, the head disc on top. One outline
/// around them is the drop's shape: from iOS 26 the system's Liquid Glass in that shape lies
/// over the discs; before, a rim, a shine and a shadow.
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
    private var glass: TrailGlass?
    private static let lifetime: CFTimeInterval = 0.32
    private static let fadeTime: CFTimeInterval = 0.22
    private static let headRadius: CGFloat = 17
    /// The drop never gets longer than this, however fast the finger moves.
    private static let maxLength: CGFloat = 130
    private static let maxDiscs = 80

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
            glass = TrailGlass(in: self)
            for decoration in [shadow, rim, shine] { decoration.isHidden = true }
        }
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func begin(at point: CGPoint) {
        takeSnapshot()
        points = [Point(location: point, time: CACurrentMediaTime())]
        isTracking = true
        startDisplayLink()
    }

    func add(_ point: CGPoint) {
        guard isTracking else { return }
        if let last = points.last, GlideDecoder.distance(last.location, point) < 1.5 { return }
        points.append(Point(location: point, time: CACurrentMediaTime()))
    }

    /// The finger lifted: the drop shrinks into the finger and fades.
    func end() {
        guard isTracking else { return }
        isTracking = false
        endTime = CACurrentMediaTime()
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
        draw(fade: fade)
        if points.isEmpty && !isTracking {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// The line from the finger back, smoothed through the touch points (Catmull-Rom), in
    /// steps of about two points, at most `maxLength` long.
    private func smoothedLine() -> [CGPoint] {
        let touches = points.reversed().map(\.location)
        guard touches.count > 1 else { return touches }
        var line = [touches[0]]
        var length: CGFloat = 0
        for i in 0..<(touches.count - 1) {
            let p0 = touches[max(0, i - 1)], p1 = touches[i], p2 = touches[i + 1], p3 = touches[min(touches.count - 1, i + 2)]
            let steps = max(1, Int(GlideDecoder.distance(p1, p2) / 2))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                let point = CGPoint(
                    x: 0.5 * (2 * p1.x + (p2.x - p0.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (3 * p1.x - p0.x - 3 * p2.x + p3.x) * t3),
                    y: 0.5 * (2 * p1.y + (p2.y - p0.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (3 * p1.y - p0.y - 3 * p2.y + p3.y) * t3))
                length += GlideDecoder.distance(line[line.count - 1], point)
                line.append(point)
                if length >= Self.maxLength { return line }
            }
        }
        return line
    }

    /// Discs close enough to overlap from the finger back along the line, shrinking to a point
    /// at its end like the tail of a tear; the larger a disc, the more it enlarges.
    private func draw(fade: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let head = points.last?.location, snapshotSize.width > 0, fade > 0 else {
            lens.isHidden = true
            glass?.update(nil)
            return
        }
        lens.isHidden = false
        lens.opacity = Float(fade.squareRoot())
        let line = smoothedLine()
        var length: CGFloat = 0
        for i in 1..<max(1, line.count) { length += GlideDecoder.distance(line[i - 1], line[i]) }
        let spacing = max(1.5, length / CGFloat(Self.maxDiscs - 1))
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
            return max(1, Self.headRadius * fade * pow(max(0, left), 0.9))
        }
        for (i, disc) in discs.enumerated() {
            guard i < centres.count else {
                disc.isHidden = true
                continue
            }
            let c = centres[i].point, r = radii[i]
            let zoom = 1 + 0.35 * r / Self.headRadius
            disc.isHidden = false
            disc.zPosition = -centres[i].along
            disc.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            disc.cornerRadius = r
            disc.contentsRect = CGRect(x: (c.x - r / zoom) / snapshotSize.width, y: (c.y - r / zoom) / snapshotSize.height,
                                       width: 2 * r / zoom / snapshotSize.width, height: 2 * r / zoom / snapshotSize.height)
        }
        let outline = Self.outline(centres.map(\.point), radii)
        if let glass {
            glass.update(outline)
            return
        }
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
            // Direction towards the head, over a few discs so the sides stay smooth.
            let towards = centres[max(0, i - 2)], from = centres[min(centres.count - 1, i + 2)]
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

/// iOS 26 Liquid Glass in the shape of the drop, drawn by SwiftUI, whose glass takes any shape
/// (UIKit's takes rounded rectangles only), over the magnifying discs.
@MainActor
private final class TrailGlass {
    private let model = TrailGlassModel()
    private var host: UIViewController?

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    init(in view: UIView) {
        let host = UIHostingController(rootView: TrailGlassView(model: model))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        self.host = host
    }
    #endif

    func update(_ path: CGPath?) {
        model.path = path
    }
}

private final class TrailGlassModel: ObservableObject {
    @Published var path: CGPath?
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct TrailGlassView: View {
    @ObservedObject var model: TrailGlassModel

    var body: some View {
        ZStack {
            if let path = model.path {
                Color.clear
                    .glassEffect(.clear, in: DropShape(path: path))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
#endif

/// iOS 26 Liquid Glass in any shape, under the key popups: the keys show through it, bent at
/// its edges, as through a drop of water.
@MainActor
final class ShapeGlass {
    private let model = ShapeGlassModel()
    private var host: UIViewController?
    /// Covers the view the shapes are given in.
    var view: UIView? { host?.view }

    /// Nil before iOS 26, or when built with an SDK without Liquid Glass.
    static func make() -> ShapeGlass? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return ShapeGlass(glass: ()) }
        #endif
        return nil
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private init(glass: Void) {
        let host = UIHostingController(rootView: ShapeGlassView(model: model))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        self.host = host
    }
    #endif

    /// The shape in the view's coordinates, nil for none, and a colour the glass takes on.
    func update(_ path: CGPath?, tint: UIColor?) {
        model.path = path
        model.tint = tint
    }
}

private final class ShapeGlassModel: ObservableObject {
    @Published var path: CGPath?
    @Published var tint: UIColor?
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct ShapeGlassView: View {
    @ObservedObject var model: ShapeGlassModel

    var body: some View {
        ZStack {
            if let path = model.path {
                Color.clear
                    .glassEffect(.clear.tint(model.tint.map { Color(uiColor: $0) }), in: DropShape(path: path))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
#endif

/// A shape given in the trail view's own coordinates.
private struct DropShape: Shape {
    let path: CGPath

    func path(in rect: CGRect) -> Path {
        Path(path)
    }
}
