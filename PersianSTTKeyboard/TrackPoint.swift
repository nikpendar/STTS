import UIKit

/// The red cursor dot in the middle of the letters, after the old ThinkPad TrackPoint. Pushing
/// it moves the text cursor: the keys fade, the dot grows into a joystick (`CursorPadView`), and
/// a jelly lens shows the text around the cursor. A plain tap on it types the key under it.
final class TrackPointView: UIView {
    /// A tap that did not move: the point, in the superview, for the key under the dot.
    var onTap: ((CGPoint) -> Void)?
    /// The push began (the finger moved or stayed down a moment).
    var onPushBegan: (() -> Void)?
    /// Where the finger is, in the superview, while pushing.
    var onPush: ((CGPoint) -> Void)?
    var onPushEnded: (() -> Void)?

    static let diameter: CGFloat = 15
    /// Touches count this far from the centre: about a fingertip, but no farther, as the dot
    /// sits on the corner of four keys.
    private static let touchRadius: CGFloat = 13

    private let dot = TrackPointFace()
    private var start: (point: CGPoint, time: CFTimeInterval)?
    private var pushing = false
    private var holdTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "جابه‌جایی مکان‌نما"
        accessibilityTraits = .adjustable
        dot.isUserInteractionEnabled = false
        addSubview(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = Self.diameter
        dot.frame = CGRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= Self.touchRadius
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let superview else { return }
        start = (touch.location(in: superview), touch.timestamp)
        pushing = false
        dot.pressed = true
        // Held still a moment: a push without moving yet.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.beginPush()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let superview, let start else { return }
        let point = touch.location(in: superview)
        if !pushing, hypot(point.x - start.point.x, point.y - start.point.y) > 5 { beginPush() }
        if pushing { onPush?(point) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(tap: !pushing)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(tap: false)
    }

    private func beginPush() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard !pushing, start != nil else { return }
        pushing = true
        onPushBegan?()
    }

    private func finish(tap: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        dot.pressed = false
        if tap, let start { onTap?(start.point) }
        if pushing { onPushEnded?() }
        pushing = false
        start = nil
    }

    /// The keyboard went away mid-push.
    func cancel() {
        finish(tap: false)
    }
}

/// The dot's face: the dictation orb's turning colours, in reds, with a soft rubber shine.
final class TrackPointFace: UIView {
    private let gradient = CAGradientLayer()
    private let faceMask = CAShapeLayer()
    private let shine = CAGradientLayer()
    var pressed = false {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.pressed ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = Self.colors
        gradient.mask = faceMask
        layer.addSublayer(gradient)
        shine.type = .radial
        shine.colors = [UIColor.white.withAlphaComponent(0.55).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        shine.startPoint = CGPoint(x: 0.35, y: 0.3)
        shine.endPoint = CGPoint(x: 0.85, y: 0.8)
        layer.addSublayer(shine)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static let colors = [UIColor.systemRed, UIColor(red: 1, green: 0.27, blue: 0.42, alpha: 1), .systemOrange,
                         UIColor(red: 0.85, green: 0.05, blue: 0.15, alpha: 1), .systemRed].map(\.cgColor)

    /// Turns the colours by `angle` (radians): the joystick turns them as it is pushed.
    func turn(to angle: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Bigger than the face so that it covers it while it turns.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        faceMask.frame = gradient.bounds
        let inset = (side - bounds.width) / 2
        faceMask.path = UIBezierPath(ovalIn: CGRect(x: inset, y: (side - bounds.height) / 2, width: bounds.width, height: bounds.height)).cgPath
        shine.frame = bounds
        let round = UIBezierPath(ovalIn: bounds).cgPath
        let shineMask = CAShapeLayer()
        shineMask.path = round
        shine.mask = shineMask
        layer.shadowPath = round
        CATransaction.commit()
    }
}

/// Over the faded keys while the TrackPoint is pushed: the joystick where the dot was, the
/// jelly lens with the text around the cursor above it, and buttons to select, copy, cut,
/// delete and paste. It stays after the finger lifts, for those buttons; a tap on an empty
/// part, or «تمام», closes it.
final class CursorPadView: UIView {
    /// Move the cursor by one character: true forward in the text (later), false back.
    var onStep: ((_ forward: Bool) -> Bool)?
    /// Move the cursor a line up (false) or down (true).
    var onLine: ((_ down: Bool) -> Void)?
    /// Right on screen is back in the text (Persian, Arabic).
    var isRightToLeft: (() -> Bool)?
    var onAction: ((Action) -> Void)?
    var onClose: (() -> Void)?

    enum Action { case select, copy, cut, delete, paste }

    var textColor = UIColor.label {
        didSet { buttons.forEach { $0.setTitleColor(textColor, for: .normal) }; lens.textColor = textColor }
    }

    /// The text around the cursor, and the part selected (before or after it).
    func showText(before: String, after: String, selected: String, selectedForward: Bool) {
        lens.show(before: before, after: after, selected: selected, selectedForward: selectedForward)
        let has = !selected.isEmpty
        for (button, action) in zip(buttons, actions) where [.copy, .cut, .delete].contains(action) {
            button.isEnabled = has
            button.alpha = has ? 1 : 0.35
        }
    }

    var selecting = false {
        didSet { selectButton.isSelected = selecting; selectButton.backgroundColor = selecting ? UIColor.systemRed.withAlphaComponent(0.25) : buttonFill }
    }

    var canPaste = false {
        didSet { pasteButton.isEnabled = canPaste; pasteButton.alpha = canPaste ? 1 : 0.35 }
    }

    private let base = UIView()
    private let knob = TrackPointFace()
    private let lens = JellyLensView()
    private let actions: [Action] = [.select, .copy, .cut, .delete, .paste]
    private var buttons: [UIButton] = []
    private var selectButton: UIButton { buttons[0] }
    private var pasteButton: UIButton { buttons[4] }
    private let doneButton = UIButton(type: .system)
    private var buttonFill: UIColor { UIColor.label.withAlphaComponent(0.08) }

    /// Where the joystick stands, in this view.
    var stickCenter = CGPoint.zero {
        didSet { setNeedsLayout() }
    }
    private static let baseDiameter: CGFloat = 96
    private static let knobDiameter: CGFloat = 54
    /// The knob's farthest reach from the centre, the full push.
    private static let reach: CGFloat = 34

    var isPushing: Bool { pushStart != nil }

    /// The push, -1...1 on each axis, from the finger.
    private var push = CGVector.zero
    private var pushStart: CGPoint?
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var carried: Double = 0
    private var lineWait: Double = 0
    private var turnAngle: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        base.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        base.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.35).cgColor
        base.layer.borderWidth = 1.5
        base.isUserInteractionEnabled = false
        addSubview(base)
        knob.isUserInteractionEnabled = false
        addSubview(knob)
        lens.isUserInteractionEnabled = false
        addSubview(lens)
        let titles = ["انتخاب", "کپی", "برش", "حذف", "چسباندن"]
        let symbols = ["selection.pin.in.out", "doc.on.doc", "scissors", "delete.left", "doc.on.clipboard"]
        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .custom)
            button.setTitle(titles[index], for: .normal)
            button.setImage(UIImage(systemName: symbols[index], withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
            button.tintColor = .systemRed
            button.titleLabel?.font = keyFont(for: titles[index], size: 14)
            button.setTitleColor(textColor, for: .normal)
            button.semanticContentAttribute = .forceRightToLeft
            button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
            button.backgroundColor = buttonFill
            button.layer.cornerRadius = 9
            button.layer.cornerCurve = .continuous
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
        doneButton.setTitle("تمام", for: .normal)
        doneButton.titleLabel?.font = keyFont(for: "تمام", size: 15)
        doneButton.tintColor = .systemRed
        doneButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        addSubview(doneButton)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = Self.baseDiameter
        base.frame = CGRect(x: stickCenter.x - b / 2, y: stickCenter.y - b / 2, width: b, height: b)
        base.layer.cornerRadius = b / 2
        placeKnob()
        // The lens over the stick, in the strip above the keys (an extension draws only inside).
        let lensWidth = min(bounds.width - 32, 260)
        let lensHeight: CGFloat = 46
        let lensY = max(4, min(base.frame.minY - lensHeight - 8, bounds.height - lensHeight))
        lens.frame = CGRect(x: (bounds.width - lensWidth) / 2, y: lensY, width: lensWidth, height: lensHeight)
        // The buttons in a column on either side of the stick: selection on the right, the rest
        // on the left (for the right thumb on the stick, the left one on the buttons).
        let buttonWidth = min(96, (bounds.width - b) / 2 - 24)
        let buttonHeight: CGFloat = 34
        let gap: CGFloat = 8
        let leftX = max(8, stickCenter.x - b / 2 - 16 - buttonWidth)
        let rightX = min(bounds.width - 8 - buttonWidth, stickCenter.x + b / 2 + 16)
        let left: [UIButton] = [buttons[1], buttons[2], buttons[3]]
        let right: [UIButton] = [buttons[0], buttons[4]]
        let leftTop = stickCenter.y - (CGFloat(left.count) * buttonHeight + CGFloat(left.count - 1) * gap) / 2
        for (i, button) in left.enumerated() {
            button.frame = CGRect(x: leftX, y: leftTop + CGFloat(i) * (buttonHeight + gap), width: buttonWidth, height: buttonHeight)
        }
        let rightTop = stickCenter.y - (CGFloat(right.count + 1) * buttonHeight + CGFloat(right.count) * gap) / 2
        for (i, button) in right.enumerated() {
            button.frame = CGRect(x: rightX, y: rightTop + CGFloat(i) * (buttonHeight + gap), width: buttonWidth, height: buttonHeight)
        }
        doneButton.frame = CGRect(x: rightX, y: rightTop + 2 * (buttonHeight + gap), width: buttonWidth, height: buttonHeight)
    }

    private func placeKnob() {
        let k = Self.knobDiameter
        let offset = CGPoint(x: push.dx * Self.reach, y: push.dy * Self.reach)
        knob.bounds = CGRect(x: 0, y: 0, width: k, height: k)
        knob.center = CGPoint(x: stickCenter.x + offset.x, y: stickCenter.y + offset.y)
    }

    /// Grows out of the dot: the keys fade in the controller, the joystick swells here.
    func appear(from dotCenter: CGPoint) {
        stickCenter = dotCenter
        layoutIfNeeded()
        let start = TrackPointView.diameter / Self.knobDiameter
        knob.transform = CGAffineTransform(scaleX: start, y: start)
        base.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        let others = buttons + [doneButton, lens]
        others.forEach { $0.alpha = 0 }
        alpha = 1
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0.5) {
            self.knob.transform = .identity
            self.base.transform = .identity
        }
        UIView.animate(withDuration: 0.2, delay: 0.08) {
            others.forEach { $0.alpha = 1 }
            self.canPaste = self.canPaste
        }
        lens.wobble(1)
    }

    // MARK: Pushing

    /// The finger on the stick (from the dot, or a new touch on the knob): `point` in this view.
    func beginPush(at point: CGPoint) {
        pushStart = point
        push = .zero
        startLink()
    }

    func movePush(to point: CGPoint) {
        guard let pushStart else { return }
        var v = CGVector(dx: (point.x - pushStart.x) / Self.reach, dy: (point.y - pushStart.y) / Self.reach)
        let length = hypot(v.dx, v.dy)
        if length > 1 { v = CGVector(dx: v.dx / length, dy: v.dy / length) }
        push = v
        placeKnob()
    }

    func endPush() {
        pushStart = nil
        stopLink()
        lens.wobble(0.8)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8) {
            self.push = .zero
            self.placeKnob()
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = 0
        carried = 0
        lineWait = 0
    }

    func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.1, now - lastFrame)
        lastFrame = now
        let dx = Double(push.dx), dy = Double(push.dy)
        let strength = hypot(dx, dy)
        turnAngle += CGFloat(dx * dt * 8)
        knob.turn(to: turnAngle)
        lens.stretch(CGVector(dx: push.dx, dy: push.dy))
        // A dead zone in the middle, then faster the farther it is pushed, as the TrackPoint.
        guard strength > 0.18 else {
            carried = 0
            lineWait = 0
            return
        }
        if abs(dy) > 0.55, abs(dy) > abs(dx) * 1.3 {
            // Up or down: a line at a time, quicker when pushed harder.
            lineWait -= dt
            if lineWait <= 0 {
                onLine?(dy > 0)
                lineWait = 0.55 - 0.35 * min(1, (abs(dy) - 0.55) / 0.45)
            }
            carried = 0
            return
        }
        let x = (abs(dx) - 0.12) / 0.88
        guard x > 0 else { return }
        let perSecond = 2 + 30 * x * x
        carried += perSecond * dt
        let rightIsBack = isRightToLeft?() ?? false
        let forward = (dx > 0) != rightIsBack
        while carried >= 1 {
            carried -= 1
            if !(onStep?(forward) ?? false) {
                carried = 0
                break
            }
        }
    }

    // MARK: Touches on the pad itself

    private var knobTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if knobTouch == nil, hypot(point.x - stickCenter.x, point.y - stickCenter.y) <= Self.baseDiameter / 2 + 10 {
                knobTouch = touch
                beginPush(at: stickCenter)
                movePush(to: point)
            } else if knobTouch == nil, touches.count == 1, event?.allTouches?.count == 1 {
                // An empty part: done.
                onClose?()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let knobTouch, touches.contains(knobTouch) { movePush(to: knobTouch.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let knobTouch, touches.contains(knobTouch) {
            self.knobTouch = nil
            endPush()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    override func removeFromSuperview() {
        stopLink()
        lens.stopLink()
        super.removeFromSuperview()
    }
}

/// Holds its target weakly, so a display link does not keep a view alive.
private final class WeakTarget: NSObject {
    weak var pad: CursorPadView?
    weak var lens: JellyLensView?
    init(_ pad: CursorPadView) { self.pad = pad }
    init(lens: JellyLensView) { self.lens = lens }

    @objc func tick(_ link: CADisplayLink) {
        if let pad { pad.tick(link) } else if let lens { lens.tick(link) } else { link.invalidate() }
    }
}

/// A soft bubble over the joystick with the text around the cursor, after the jelly look of
/// Siri: its edge wobbles when touched and stretches the way the stick is pushed, then settles.
/// The keyboard cannot see the app's own text on screen, so the lens shows the text as the app
/// hands it over (`documentContextBeforeInput`), not a magnified picture.
final class JellyLensView: UIView {
    var textColor = UIColor.label {
        didSet { label.textColor = textColor }
    }
    private let shape = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let label = UILabel()
    private var link: CADisplayLink?
    private var energy: CGFloat = 0
    private var stretchVector = CGVector.zero
    private var phase: CGFloat = 0
    private var lastFrame: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.fillColor = UIColor.systemBackground.withAlphaComponent(0.92).cgColor
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.18
        shape.shadowRadius = 8
        shape.shadowOffset = CGSize(width: 0, height: 3)
        layer.addSublayer(shape)
        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor.systemRed.withAlphaComponent(0.4).cgColor
        rim.lineWidth = 1.2
        layer.addSublayer(rim)
        label.textAlignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 16, dy: 4)
        drawShape()
    }

    func show(before: String, after: String, selected: String, selectedForward: Bool) {
        // About a dozen characters each side, on the cursor's line.
        func line(_ s: Substring) -> Substring { s.split(separator: "\n", omittingEmptySubsequences: false).last ?? "" }
        let left = line(Substring(before.suffix(14)))
        let right = Substring(after.prefix(14)).split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        let font = keyFont(for: before + after, size: 19)
        let text = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        var marked = plain
        marked[.backgroundColor] = UIColor.systemRed.withAlphaComponent(0.25)
        let caret = NSAttributedString(string: "\u{2009}|\u{2009}", attributes: [.font: UIFont.systemFont(ofSize: 21, weight: .bold), .foregroundColor: UIColor.systemRed])
        let leftText = String(left), rightText = String(right)
        if !selected.isEmpty, selectedForward, leftText.hasSuffix(selected.suffix(leftText.count)) {
            let n = min(selected.count, leftText.count)
            text.append(NSAttributedString(string: String(leftText.dropLast(n)), attributes: plain))
            text.append(NSAttributedString(string: String(leftText.suffix(n)), attributes: marked))
            text.append(caret)
            text.append(NSAttributedString(string: rightText, attributes: plain))
        } else if !selected.isEmpty, !selectedForward {
            let n = min(selected.count, rightText.count)
            text.append(NSAttributedString(string: leftText, attributes: plain))
            text.append(caret)
            text.append(NSAttributedString(string: String(rightText.prefix(n)), attributes: marked))
            text.append(NSAttributedString(string: String(rightText.dropFirst(n)), attributes: plain))
        } else {
            text.append(NSAttributedString(string: leftText, attributes: plain))
            text.append(caret)
            text.append(NSAttributedString(string: rightText, attributes: plain))
        }
        label.attributedText = text
    }

    /// A poke: the edge wobbles with `amount` (0...1) and settles.
    func wobble(_ amount: CGFloat) {
        energy = max(energy, amount)
        startLink()
    }

    /// The stick's push: the bubble leans that way.
    func stretch(_ vector: CGVector) {
        let moved = hypot(vector.dx - stretchVector.dx, vector.dy - stretchVector.dy)
        stretchVector = vector
        if moved > 0.02 { wobble(min(1, energy + moved * 0.6)) }
    }

    private func startLink() {
        guard link == nil, window != nil else { drawShape(); return }
        let link = CADisplayLink(target: WeakTarget(lens: self), selector: #selector(WeakTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = 0
    }

    func stopLink() {
        link?.invalidate()
        link = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let dt = lastFrame == 0 ? 1.0 / 60 : CGFloat(min(0.1, link.timestamp - lastFrame))
        lastFrame = link.timestamp
        phase += dt * 9
        // Settles in about a second; stays still once calm and unpushed.
        energy *= pow(0.12, dt)
        if energy < 0.01, hypot(stretchVector.dx, stretchVector.dy) < 0.01 {
            energy = 0
            drawShape()
            stopLink()
            return
        }
        drawShape()
    }

    /// A rounded capsule whose edge points move with the wobble and lean with the push.
    private func drawShape() {
        let rect = bounds.insetBy(dx: 4, dy: 3)
        guard rect.width > 0, rect.height > 0 else { return }
        let count = 36
        let cx = rect.midX, cy = rect.midY
        let a = rect.width / 2, b = rect.height / 2
        var points: [CGPoint] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count) * 2 * .pi
            // A superellipse: a capsule with soft ends.
            let c = cos(t), s = sin(t)
            let n: CGFloat = 0.45
            var x = a * copysign(pow(abs(c), n), c)
            var y = b * copysign(pow(abs(s), n), s)
            let wave = energy * (2.4 * sin(3 * t + phase) + 1.4 * sin(5 * t - phase * 1.3))
            let lean = stretchVector.dx * c * 5 + stretchVector.dy * s * 4
            let grow = wave + lean
            let len = max(1, hypot(x, y))
            x += x / len * grow
            y += y / len * grow
            points.append(CGPoint(x: cx + x, y: cy + y))
        }
        let path = UIBezierPath()
        // A smooth closed curve through the points (Catmull-Rom).
        for i in 0..<count {
            let p0 = points[(i - 1 + count) % count], p1 = points[i], p2 = points[(i + 1) % count], p3 = points[(i + 2) % count]
            if i == 0 { path.move(to: p1) }
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        rim.path = path.cgPath
        CATransaction.commit()
    }
}
