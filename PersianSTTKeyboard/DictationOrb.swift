import Accelerate
import AudioToolbox
import CoreMotion
import UIKit

/// A ring that fills towards an estimated end without ever standing still: evenly to 85% at
/// the estimated time, then ever more slowly towards full. A new estimate carries on from where
/// the ring is, and its position is computed rather than read back from Core Animation.
final class ProgressRing {
    let track = CAShapeLayer()
    let ring = CAShapeLayer()
    private(set) var isRunning = false
    private var from = 0.0
    private var start: CFTimeInterval = 0
    private var expected = 1.0

    init(color: UIColor, width: CGFloat) {
        for shape in [track, ring] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = width
            shape.lineCap = .round
        }
        track.strokeColor = UIColor.systemGray.withAlphaComponent(0.3).cgColor
        ring.strokeColor = color.cgColor
        ring.strokeEnd = 0
    }

    var path: CGPath? {
        get { ring.path }
        set { track.path = newValue; ring.path = newValue }
    }

    var isHidden: Bool {
        get { ring.isHidden }
        set { track.isHidden = newValue; ring.isHidden = newValue }
    }

    private static func curve(_ x: Double) -> Double {
        x <= 1 ? 0.85 * x : 0.85 + 0.15 * (1 - exp(-2 * (x - 1)))
    }

    private func value(at time: CFTimeInterval) -> Double {
        guard isRunning else { return Double(ring.strokeEnd) }
        return from + (1 - from) * Self.curve(max(0, time - start) / expected)
    }

    /// Starts from empty.
    func begin(expected seconds: Double) {
        isRunning = false
        set(0)
        retarget(expected: seconds)
    }

    /// Carries on from the current position, to be done in `seconds`.
    func retarget(expected seconds: Double) {
        let now = CACurrentMediaTime()
        from = value(at: now)
        start = now
        expected = max(0.3, seconds)
        isRunning = true
        animate()
    }

    /// Fills the rest quickly, when the result has arrived.
    func finish() {
        guard isRunning else { return }
        let current = value(at: CACurrentMediaTime())
        isRunning = false
        set(1)
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = current
        fill.toValue = 1
        fill.duration = 0.2
        ring.add(fill, forKey: "progress")
    }

    func reset() {
        isRunning = false
        set(0)
    }

    /// Animations are dropped when the view leaves the screen; this puts the ring back on course.
    func resume() {
        if isRunning { animate() }
    }

    private func set(_ value: Double) {
        ring.removeAnimation(forKey: "progress")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = CGFloat(value)
        CATransaction.commit()
    }

    /// The curve from now on, sampled, up to the point where it is all but full.
    private func animate() {
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - start)
        let duration = max(0.5, 4 * expected - elapsed)
        let steps = 48
        let values = (0...steps).map { i in value(at: now + duration * Double(i) / Double(steps)) }
        set(values.last ?? 1)
        let fill = CAKeyframeAnimation(keyPath: "strokeEnd")
        fill.values = values
        fill.duration = duration
        fill.calculationMode = .linear
        ring.add(fill, forKey: "progress")
    }
}

/// The compact dictation view: a turning gradient orb (like Siri's) with the mic in the middle.
/// While the recording starts, an arc turns around it. While recording it swells with the
/// speaker's voice and breathes softly in silence; a teal ring fills until the next piece of
/// live text arrives. After the recording, a blue ring fills while the app transcribes. The
/// rings hug the orb and swell with it.
/// The whole view is one button: it stops the recording, or cancels the transcription.
final class DictationOrbView: UIControl {
    enum Mode { case starting, recording, processing }

    var mode = Mode.starting {
        didSet { if mode != oldValue { update() } }
    }

    /// Over a held space bar: where the orb sits among the keys moved aside, and its size. The
    /// caption is left out, and only the orb itself takes touches.
    var spotlight: (center: CGPoint, diameter: CGFloat)? {
        didSet {
            caption.isHidden = spotlight != nil
            setNeedsLayout()
        }
    }

    /// A locked recording paused: the orb dims and stops moving, and shows a pause sign.
    var paused = false {
        didSet { if paused != oldValue { update() } }
    }

    enum Lock { case open, closed }
    /// Over a held space bar: an open lock floats above the orb with an arrow bobbing over it,
    /// for sliding up to lock; once locked, the lock closes in orange and the arrow fades.
    var lock: Lock? {
        didSet { if lock != oldValue { updateLock() } }
    }
    private let lockGroup = UIView()
    private let lockIcon = UIImageView()
    private let lockArrow = UIImageView()

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let spotlight else { return super.point(inside: point, with: event) }
        return hypot(point.x - spotlight.center.x, point.y - spotlight.center.y) <= spotlight.diameter / 2 + 12
    }

    private let pulse = CALayer()
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    /// The arc that turns while the recording starts.
    private let loading = CAShapeLayer()
    /// The track around the orb while recording. (Whisper's live passes filled it; the
    /// streaming model has no passes to wait for.)
    let liveRing = ProgressRing(color: .systemTeal, width: 3)
    /// The transcription after the recording.
    let processingRing = ProgressRing(color: .systemBlue, width: 3)
    /// Holds the rings and the arc, centred on the orb and scaled with it.
    private let rings = CALayer()
    /// Between the orb's edge and the rings.
    private static let ringGap: CGFloat = 5
    private let icon = UIImageView()
    private let caption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [UIColor.systemPink, .systemPurple, .systemBlue, .systemTeal, .systemPink].map(\.cgColor)
        gradient.mask = gradientMask
        pulse.addSublayer(gradient)
        layer.addSublayer(pulse)

        for ring in [liveRing, processingRing] {
            rings.addSublayer(ring.track)
            rings.addSublayer(ring.ring)
        }
        loading.fillColor = UIColor.clear.cgColor
        loading.strokeColor = UIColor.systemTeal.cgColor
        loading.lineWidth = 3
        loading.lineCap = .round
        rings.addSublayer(loading)
        layer.addSublayer(rings)

        icon.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        addSubview(icon)

        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.7
        addSubview(caption)

        lockGroup.isUserInteractionEnabled = false
        lockGroup.isHidden = true
        for view in [lockArrow, lockIcon] {
            view.tintColor = .secondaryLabel
            view.contentMode = .center
            lockGroup.addSubview(view)
        }
        lockArrow.image = UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        addSubview(lockGroup)
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The size it had before the 2026-10-11 changes, with room for the voice to swell it.
        let diameter = spotlight?.diameter ?? min(bounds.height - 64, 112)
        let center = spotlight?.center ?? CGPoint(x: bounds.midX, y: (bounds.height - 30) / 2 + 2)
        let ringRadius = diameter / 2 + Self.ringGap
        let orbFrame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulse.bounds = CGRect(origin: .zero, size: orbFrame.size)
        pulse.position = center
        // Not `frame`: the gradient turns.
        gradient.bounds = pulse.bounds
        gradient.position = CGPoint(x: pulse.bounds.midX, y: pulse.bounds.midY)
        gradientMask.path = UIBezierPath(ovalIn: pulse.bounds).cgPath
        let side = 2 * ringRadius + 8
        rings.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        rings.position = center
        let middle = CGPoint(x: side / 2, y: side / 2)
        let ringPath = UIBezierPath(arcCenter: middle, radius: ringRadius,
                                    startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        liveRing.path = ringPath
        processingRing.path = ringPath
        loading.bounds = CGRect(x: 0, y: 0, width: 2 * ringRadius, height: 2 * ringRadius)
        loading.position = middle
        loading.path = UIBezierPath(arcCenter: CGPoint(x: ringRadius, y: ringRadius), radius: ringRadius,
                                    startAngle: -.pi / 2, endAngle: -.pi / 2 + 0.56 * .pi, clockwise: true).cgPath
        CATransaction.commit()
        icon.frame = orbFrame
        caption.frame = CGRect(x: 16, y: bounds.height - 30, width: bounds.width - 32, height: 22)
        // Above the orb, clear of it at full voice: the arrow over the lock.
        let lockBottom = max(34, center.y - diameter / 2 * (1 + Self.voiceGrowth) - Self.ringGap - 2)
        lockGroup.bounds = CGRect(x: 0, y: 0, width: 30, height: 34)
        lockGroup.center = CGPoint(x: center.x, y: lockBottom - 17)
        lockArrow.frame = CGRect(x: 0, y: 0, width: 30, height: 12)
        lockIcon.frame = CGRect(x: 0, y: 12, width: 30, height: 22)
    }

    private func updateLock() {
        lockGroup.isHidden = lock == nil
        lockGroup.layer.removeAnimation(forKey: "float")
        lockArrow.layer.removeAnimation(forKey: "bob")
        guard let lock else { return }
        let image = UIImage(systemName: lock == .open ? "lock.open.fill" : "lock.fill",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        let calm = !animates || UIAccessibility.isReduceMotionEnabled
        let change = {
            self.lockIcon.image = image
            self.lockIcon.tintColor = lock == .closed ? .systemOrange : .secondaryLabel
            self.lockArrow.alpha = lock == .open ? 1 : 0
        }
        if lock == .closed, !calm {
            UIView.transition(with: lockIcon, duration: 0.18, options: .transitionCrossDissolve, animations: change)
            lockIcon.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0, options: []) {
                self.lockIcon.transform = .identity
            }
        } else {
            change()
        }
        startFloating()
    }

    /// The lock hovers gently; the arrow over the open lock rises and falls.
    private func startFloating() {
        guard lock != nil, animates, !UIAccessibility.isReduceMotionEnabled, window != nil else { return }
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = 2.5
        float.toValue = -2.5
        float.duration = 1.6
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lockGroup.layer.add(float, forKey: "float")
        guard lock == .open else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = 0
        bob.toValue = -4
        bob.duration = 0.55
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lockArrow.layer.add(bob, forKey: "bob")
    }

    /// Animations are dropped when the keyboard leaves the screen; restart them on return.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        update()
        liveRing.resume()
        processingRing.resume()
        startFloating()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .starting:
            gradient.opacity = 0.5
            setMotion(false)
            setLoading(true)
            // The empty track under the turning arc.
            liveRing.track.isHidden = false
            liveRing.ring.isHidden = true
            processingRing.isHidden = true
            caption.text = "…"
        case .recording:
            gradient.opacity = paused ? 0.45 : 1
            setLoading(false)
            setMotion(!paused)
            liveRing.track.isHidden = false
            liveRing.ring.isHidden = !liveRing.isRunning
            processingRing.isHidden = true
            caption.text = Self.listeningCaption
        case .processing:
            gradient.opacity = 0.35
            setLoading(false)
            setMotion(false)
            liveRing.isHidden = true
            processingRing.isHidden = false
            caption.text = "در حال تبدیل به متن… برای لغو بزنید"
        }
        let symbol = mode == .recording && paused ? "pause.fill" : "mic.fill"
        if icon.accessibilityIdentifier != symbol {
            icon.accessibilityIdentifier = symbol
            let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
            if animates, window != nil {
                UIView.transition(with: icon, duration: 0.15, options: .transitionCrossDissolve) { self.icon.image = image }
            } else {
                icon.image = image
            }
        }
        CATransaction.commit()
    }

    private func setLoading(_ on: Bool) {
        loading.removeAnimation(forKey: "spin")
        loading.isHidden = !on
        guard on, animates else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        loading.add(spin, forKey: "spin")
    }

    var animates = true
    /// How much larger than at rest the orb gets at full voice.
    private static let voiceGrowth: CGFloat = 0.22
    private static let listeningCaption = "در حال گوش دادن… برای پایان بزنید"
    private var displayLink: CADisplayLink?
    /// Loudness from the app (0 silence to 1 loud), and the value the orb shows, which follows
    /// it like a spring.
    private var voiceTarget: CGFloat = 0
    private var voice: CGFloat = 0
    private var voiceSpeed: CGFloat = 0
    private var motionStart: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var spin: CGFloat = 0
    private var heardVoice = false

    /// One of `DictationBridge.levels` loudness steps of the microphone, 2 dB each from -55 dB.
    func setVoiceLevel(_ step: Int) {
        // Room noise stays under -44 dB; quiet speech already moves the orb, loud speech fills it.
        let db = -55 + 2 * CGFloat(step)
        voiceTarget = pow(min(1, max(0, (db + 44) / 20)), 0.75)
        if step >= 8 { heardVoice = true }
    }

    func resetVoice() {
        voiceTarget = 0
        voice = 0
        voiceSpeed = 0
        heardVoice = false
        motionStart = CACurrentMediaTime()
    }

    private func setMotion(_ on: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        pulse.setAffineTransform(.identity)
        rings.setAffineTransform(.identity)
        guard on, animates else { return }
        lastFrame = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepMotion))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Each frame: the shown loudness follows the app's like a stiff spring, quick to rise and
    /// a little slower to settle, so the steps blend into one motion that keeps up with the
    /// voice, and the orb swells and turns faster with it. In silence it breathes a few percent.
    /// Before anyone speaks, the caption says nothing is heard.
    @objc private func stepMotion() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - lastFrame)))
        lastFrame = now
        // Steps of at most 1/120 s keep the stiff spring stable when frames are slow.
        let steps = max(1, Int((dt * 120).rounded(.up)))
        for _ in 0..<steps {
            let stiffness: CGFloat = voiceTarget > voice ? 520 : 170
            let step = dt / CGFloat(steps)
            voiceSpeed += (stiffness * (voiceTarget - voice) - 1.7 * stiffness.squareRoot() * voiceSpeed) * step
            voice = min(1.05, max(-0.05, voice + voiceSpeed * step))
        }
        spin += dt * 2 * .pi / 3 * (1 + 2.5 * max(0, voice))
        let t = CGFloat(now - motionStart)
        let breath = 0.04 * sin(2 * .pi * t / 2.4)
        let scale = 1 + breath * (1 - max(0, voice)) + Self.voiceGrowth * voice
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulse.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        rings.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        gradient.setAffineTransform(CGAffineTransform(rotationAngle: spin))
        CATransaction.commit()
        if mode == .recording {
            let text = !heardVoice && now - motionStart > 3.5 ? "صدایی نمی‌شنوم…" : Self.listeningCaption
            if caption.text != text { caption.text = text }
        }
    }

    override var isHighlighted: Bool {
        didSet { pulse.opacity = isHighlighted ? 0.7 : 1 }
    }
}
