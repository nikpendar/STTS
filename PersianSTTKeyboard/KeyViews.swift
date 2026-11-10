import AudioToolbox
import UIKit

/// A key with an optional background and outline (see `KeyStyle`) and a faint highlight
/// while pressed. Emoji keys keep no background.
/// The keys' container, which lets TapMap hand a touch on a letter key to a neighbour.
final class KeysView: UIView {
    var retarget: ((CGPoint, KeyView) -> KeyView?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let key = hit as? KeyView, key.superview === self, let other = retarget?(point, key) else { return hit }
        return other
    }
}

/// One key: a rounded face with a letter, a symbol or a status message (the space bar), drawn
/// inside its touch area as the system keyboard draws its keys, in the colours of `KeyStyle`.
final class KeyView: UIControl {
    /// Everything drawn, moved down and in a little while the key is pressed.
    private let content = UIView()
    private let face = UIView()
    private let label = UILabel()
    /// The letter's soft shadow while it tilts (`depth`): drawn once into an image, which only
    /// moves and fades, cheaper than a layer shadow.
    private let shadowView = UIImageView()
    /// What the shadow image was drawn for: text, font size and the letter's box.
    private var shadowDrawn: (text: String, size: CGFloat, box: CGSize, blur: CGFloat)?
    /// Holds the label inside the drawn key: a letter wider than the key is cut off there.
    private let labelClip = UIView()
    /// A faint light on the key's face that slides with the tilt, as on glass (Rooz,
    /// 2026-11-07): drawn once at twice the face's size and only moved, never redrawn.
    private let sheen = CAGradientLayer()
    private let imageView = UIImageView()
    private let highlight = UIView()

    private var textColor = UIColor.label
    private var storedTitle: String?

    var title: String? {
        get { storedTitle }
        set {
            storedTitle = newValue
            updateLabel()
        }
    }

    /// Shown instead of the title, smaller and dimmer (the space bar's status messages).
    var message: String? {
        didSet { updateLabel() }
    }

    /// The phone's tilt (-1...1 each way, 0 when held at 45°) for a letter drawn raised off the
    /// key: it slides with the tilt over a soft shadow that slides the other way. The shadow is
    /// gone in the middle and darkens the further the letter moves (Rooz, 2026-11-05). nil: flat.
    var depth: CGPoint? {
        didSet {
            guard depth != oldValue else { return }
            applyDepth()
        }
    }

    /// How far the letter and its shadow move at full tilt (points), the shadow's opacity there
    /// and its blur (points), as Rooz set them by hand on 2026-11-05.
    static let letterTravel: CGFloat = 3.4
    static let shadowTravel: CGFloat = 4
    static let shadowOpacity: CGFloat = 0.3
    static let shadowBlur: CGFloat = 3.5

    private func applyDepth() {
        let d = depth ?? .zero
        let distance = min(1, (d.x * d.x + d.y * d.y).squareRoot())
        label.transform = CGAffineTransform(translationX: d.x * Self.letterTravel, y: d.y * Self.letterTravel)
        // The light sits on the side the letter leans to, away from its shadow; none in the middle.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let faceSize = face.bounds.size
        sheen.position = CGPoint(x: faceSize.width * (0.5 + d.x * 0.5), y: faceSize.height * (0.5 + d.y * 0.5))
        sheen.opacity = depth == nil ? 0 : Float(min(1, distance * 1.5))
        CATransaction.commit()
        let show = depth != nil && !labelClip.isHidden && message == nil && distance > 0.02
        shadowView.isHidden = !show
        guard show else { return }
        drawShadow()
        // Darker the further from the middle: full at two thirds of the way.
        shadowView.alpha = Self.shadowOpacity * min(1, distance * 1.5)
        shadowView.transform = CGAffineTransform(translationX: -d.x * Self.shadowTravel, y: -d.y * Self.shadowTravel)
    }

    /// The letter's shape in black, blurred, drawn when the letter, its size, its box or the blur
    /// changed; `alpha` sets how dark it shows.
    private func drawShadow() {
        guard let text = label.text, !text.isEmpty, let font = label.font else { return }
        let box = label.bounds.size
        guard box.width > 0, box.height > 0 else { return }
        if let drawn = shadowDrawn, drawn.text == text, drawn.size == font.pointSize, drawn.box == box,
           drawn.blur == Self.shadowBlur { return }
        shadowDrawn = (text, font.pointSize, box, Self.shadowBlur)
        let pad = ceil(Self.shadowBlur * 2) + 1
        let size = CGSize(width: box.width + 2 * pad, height: box.height + 2 * pad)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black])
        let textSize = attributed.size()
        let glyph = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            attributed.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        }
        let radius = Int((Self.shadowBlur * format.scale).rounded())
        if radius > 0, let image = glyph.cgImage, let soft = Self.blurred(image, radius: radius) {
            shadowView.image = UIImage(cgImage: soft, scale: format.scale, orientation: .up)
        } else {
            shadowView.image = glyph
        }
        shadowView.bounds = CGRect(origin: .zero, size: size)
        shadowView.center = label.center
    }

    /// Two tent passes (close to a Gaussian) of `radius` pixels, with Accelerate on the CPU.
    private static func blurred(_ image: CGImage, radius: Int) -> CGImage? {
        guard let format = vImage_CGImageFormat(cgImage: image),
              var source = try? vImage_Buffer(cgImage: image, format: format),
              var target = try? vImage_Buffer(width: Int(source.width), height: Int(source.height), bitsPerPixel: 32) else {
            return nil
        }
        defer {
            source.free()
            target.free()
        }
        let side = UInt32(radius * 2 + 1)
        var clear: [UInt8] = [0, 0, 0, 0]
        let flags = vImage_Flags(kvImageBackgroundColorFill)
        guard vImageTentConvolve_ARGB8888(&source, &target, nil, 0, 0, side, side, &clear, flags) == kvImageNoError,
              vImageTentConvolve_ARGB8888(&target, &source, nil, 0, 0, side, side, &clear, flags) == kvImageNoError else {
            return nil
        }
        return try? source.createCGImage(format: format)
    }

    private func updateLabel() {
        if let message {
            label.text = message
            label.font = AppFont.font(ofSize: 12)
            label.textColor = textColor.withAlphaComponent(0.6)
        } else {
            label.text = storedTitle
            label.font = keyFont(for: storedTitle, size: fontSize)
            label.textColor = textColor
        }
        imageView.isHidden = message != nil || (knurled && !imageOnGrip)
        trailingImageView.isHidden = message != nil || knurled
        labelClip.isHidden = knurled
        if depth != nil { applyDepth() }
        if message != nil || storedTitle != nil { accessibilityLabel = message ?? storedTitle }
        // A new letter or size moves a wide letter against the key's right edge (`layoutSubviews`):
        // without this, it stayed where the old size put it until the key was next pressed.
        setNeedsLayout()
    }

    var symbol: String? {
        didSet {
            image = symbol.flatMap {
                UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
            }
        }
    }

    /// A template image instead of a symbol (`KeyIcons`).
    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    /// No drawn key, only its label or image (backspace and الفبا beside the emoji categories).
    var plain = false {
        didSet { face.isHidden = plain }
    }

    /// A small digit in the key's top corner (the top row's digits, when switched on in the app).
    var hint: String? {
        didSet {
            hintLabel.text = hint
            hintLabel.isHidden = hint == nil
            setNeedsLayout()
        }
    }
    private let hintLabel = UILabel()
    private static func isPersianDigit(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x06F0...0x06F9).contains($0.value) }
    }

    /// The orange space bar while it dictates: its words and images give way to a fine diamond
    /// grip in a rounded rectangle in its middle, raised like a knurled metal button.
    var knurled = false {
        didSet {
            guard knurled != oldValue else { return }
            grip.isHidden = !knurled
            updateLabel()
            setNeedsLayout()
        }
    }
    private let grip = UIImageView()
    /// The image stays over the grip (the parts of the split orange bar).
    var imageOnGrip = false {
        didSet { if imageOnGrip != oldValue { updateLabel() } }
    }

    /// The image springs in: from small, turned and faint to its place.
    func revealImage(delay: TimeInterval, animated: Bool) {
        let alpha: CGFloat = dimsImage ? 0.4 : 1
        imageView.layer.removeAllAnimations()
        guard animated else {
            imageView.alpha = alpha
            imageView.transform = .identity
            return
        }
        imageView.alpha = 0
        imageView.transform = CGAffineTransform(scaleX: 0.3, y: 0.3).rotated(by: -0.5)
        UIView.animate(withDuration: 0.55, delay: delay, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.4,
                       options: [.allowUserInteraction]) {
            self.imageView.alpha = alpha
            self.imageView.transform = .identity
        }
    }

    /// Moves and turns what is drawn (not the touch area): the keys standing aside around the
    /// dictation orb. Springs there unless `animated` is false.
    func displace(_ transform: CATransform3D, animated: Bool) {
        let from = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        layer.removeAnimation(forKey: "displace")
        layer.sublayerTransform = transform
        guard animated else { return }
        let spring = CASpringAnimation(keyPath: "sublayerTransform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: transform)
        spring.damping = 20
        spring.stiffness = 220
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "displace")
    }

    /// A faint wobble in place, like app icons about to be removed on the Home Screen but
    /// subtler, while the keys stand aside for dictation. Core Animation runs it outside the
    /// app, so it costs no work here.
    func jiggle(_ on: Bool) {
        content.layer.removeAnimation(forKey: "jiggle")
        content.layer.removeAnimation(forKey: "jiggleBob")
        guard on else { return }
        let angle = 2.4 * Double.pi / 180
        let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wobble.values = [0, angle, 0, -angle, 0]
        wobble.duration = Double.random(in: 0.32...0.42)
        wobble.timeOffset = Double.random(in: 0...wobble.duration)
        wobble.repeatCount = .infinity
        wobble.isAdditive = true
        content.layer.add(wobble, forKey: "jiggle")
        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = [0, -0.8, 0, 0.8, 0]
        bob.duration = wobble.duration * 1.3
        bob.timeOffset = Double.random(in: 0...bob.duration)
        bob.repeatCount = .infinity
        bob.isAdditive = true
        content.layer.add(bob, forKey: "jiggleBob")
    }

    /// A second image at the right end of the key (the space bar's mic), in its own colours.
    var trailingImage: UIImage? {
        get { trailingImageView.image }
        set {
            trailingImageView.image = newValue
            setNeedsLayout()
        }
    }
    private let trailingImageView = UIImageView()

    /// Draws the image faintly, as a hint rather than a label.
    var dimsImage = false {
        didSet {
            imageView.alpha = dimsImage ? 0.4 : 1
        }
    }

    var fontSize: CGFloat {
        didSet { if fontSize != oldValue { updateLabel() } }
    }
    /// The gap around the drawn key: as on the system keyboard, a tenth of the row height above
    /// and below (43 of 54 points drawn in portrait).
    private var faceInsets: UIEdgeInsets {
        let vertical = max(3, bounds.height / 10)
        return UIEdgeInsets(top: vertical, left: 2.5, bottom: vertical, right: 2.5)
    }
    /// What a character key types; its title may differ (English capitals).
    var character: String?

    /// The drawn key inside its touch area, in the superview's coordinates.
    var faceFrame: CGRect { frame.inset(by: faceInsets) }

    /// Where the last touch on the key went down, in the superview's coordinates (TapMap).
    private(set) var touchPoint: CGPoint?

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchPoint = touch.location(in: superview)
        return super.beginTracking(touch, with: event)
    }

    init(title: String? = nil, symbol: String? = nil, fontSize: CGFloat = 20) {
        self.fontSize = fontSize
        storedTitle = title
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        content.isUserInteractionEnabled = false
        addSubview(content)
        face.layer.cornerRadius = 6
        face.layer.masksToBounds = true
        sheen.type = .radial
        sheen.colors = [UIColor(white: 1, alpha: 0.22).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 1)
        sheen.opacity = 0
        face.layer.addSublayer(sheen)
        content.addSubview(face)
        grip.isHidden = true
        grip.isUserInteractionEnabled = false
        // Raised: a soft shadow under the button.
        grip.layer.shadowColor = UIColor(red: 0.45, green: 0.2, blue: 0, alpha: 1).cgColor
        grip.layer.shadowOpacity = 0.35
        grip.layer.shadowRadius = 1
        grip.layer.shadowOffset = CGSize(width: 0, height: 0.8)
        content.addSubview(grip)
        highlight.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        highlight.layer.cornerRadius = 6
        highlight.alpha = 0
        content.addSubview(highlight)

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        updateLabel()
        labelClip.clipsToBounds = true
        labelClip.isUserInteractionEnabled = false
        shadowView.isHidden = true
        labelClip.addSubview(shadowView)
        labelClip.addSubview(label)
        content.addSubview(labelClip)

        imageView.tintColor = .label
        imageView.contentMode = .center
        content.addSubview(imageView)
        trailingImageView.contentMode = .center
        content.addSubview(trailingImageView)
        hintLabel.isHidden = true
        hintLabel.textAlignment = .center
        content.addSubview(hintLabel)
        self.symbol = symbol
        imageView.image = symbol.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ style: KeyStyle) {
        lastStyle = style
        face.backgroundColor = accent ?? style.fill.color
        face.layer.borderColor = style.stroke.color.cgColor
        face.layer.borderWidth = style.stroke.a > 0 && accent == nil ? 1 : 0
        textColor = style.textColor
        imageView.tintColor = accent == nil ? textColor : .white
        trailingImageView.tintColor = textColor
        hintLabel.textColor = textColor.withAlphaComponent(0.55)
        updateLabel()
    }

    private var lastStyle: KeyStyle?
    /// A key drawn in this colour with a white symbol, whatever the style (the blue key that
    /// ends an emoji search, as on iOS).
    var accent: UIColor? {
        didSet {
            guard accent != oldValue, let lastStyle else { return }
            apply(lastStyle)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Not `frame`, which a pressed key's transform would distort.
        content.bounds = bounds
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let inner = bounds.inset(by: faceInsets)
        highlight.frame = inner
        face.frame = inner
        // The dictating space bar is a capsule.
        let corner = knurled ? inner.height / 2 : 6
        face.layer.cornerRadius = corner
        highlight.layer.cornerRadius = corner
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sheen.bounds = CGRect(x: 0, y: 0, width: inner.width * 2, height: inner.height * 2)
        CATransaction.commit()
        labelClip.frame = inner
        // Words (ABC, 123, status messages) keep off the edges and shrink to fit. Letters all
        // keep the chosen size: one wider than the key (ص ض س ش when large) sits against the
        // key's right edge, where it starts, and the rest is cut off.
        let isLetter = message == nil && (label.text?.count ?? 0) == 1
        label.adjustsFontSizeToFitWidth = !isLetter
        label.lineBreakMode = isLetter ? .byClipping : .byTruncatingTail
        let room = labelClip.bounds.insetBy(dx: isLetter ? 1 : 4, dy: 0)
        let textWidth = isLetter ? ceil(label.intrinsicContentSize.width) : 0
        let place = isLetter && textWidth > room.width
            ? CGRect(x: labelClip.bounds.maxX - textWidth, y: 0, width: textWidth, height: labelClip.bounds.height)
            : room
        // Not `frame`: a tilting letter has a transform (`depth`).
        label.bounds = CGRect(origin: .zero, size: place.size)
        label.center = CGPoint(x: place.midX, y: place.midY)
        shadowView.center = label.center
        if depth != nil { applyDepth() }
        // Not `frame`: the image springs in with a transform.
        imageView.bounds = CGRect(origin: .zero, size: inner.size)
        imageView.center = CGPoint(x: inner.midX, y: inner.midY)
        if hint != nil {
            let size = max(9, (inner.height * 0.24).rounded())
            hintLabel.font = AppFont.font(ofSize: size)
            // In the top corner where the script starts (left for Persian digits), a little in.
            let persian = hint.map { Self.isPersianDigit($0) } ?? false
            hintLabel.frame = CGRect(x: persian ? inner.minX + 3 : inner.maxX - size - 3, y: inner.minY + 3,
                                     width: size + 2, height: size + 2)
        }
        if let image = trailingImageView.image {
            let width = min(inner.width / 3, image.size.width + 20)
            trailingImageView.frame = CGRect(x: inner.maxX - width, y: inner.minY, width: width, height: inner.height)
        }
        trailingImageView.isHidden = message != nil || knurled
        if knurled {
            // The grip covers the whole capsule.
            grip.frame = inner
            if grip.image?.size != inner.size { grip.image = KeyIcons.knurl(size: inner.size, corner: corner) }
            grip.layer.shadowPath = UIBezierPath(roundedRect: grip.bounds, cornerRadius: corner).cgPath
        }
        // Low landscape rows: a tall image shrinks instead of spilling out of the key.
        let size = imageView.image?.size ?? .zero
        imageView.contentMode = size.width > inner.width || size.height > inner.height ? .scaleAspectFit : .center
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            highlight.alpha = isHighlighted ? 1 : 0
            Self.press(content, down: isHighlighted)
        }
    }

    /// A pressed key sinks a little and shrinks, as if pushed into the keyboard, and springs
    /// back when let go.
    static func press(_ view: UIView?, down: Bool) {
        guard let view else { return }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        if down {
            UIView.animate(withDuration: 0.05, delay: 0, options: options) {
                view.transform = CGAffineTransform(translationX: 0, y: 2).scaledBy(x: 0.94, y: 0.94)
            }
        } else {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
                           options: options) {
                view.transform = .identity
            }
        }
    }
}

/// The balloon over a pressed key, as on the system keyboard: the key is its foot and a wider
/// card above it shows the letter large. On a long press the card holds the key's other forms
/// in a row, right to left from the key's own letter, or in rows (the diacritics), the one under
/// the finger in blue. From iOS 26 the balloon is Liquid Glass, through which the keys under it
/// show. An extension cannot draw above its own view, so over the top row the card reaches only
/// the top of the suggestion bar. The view covers the keys area and never takes touches.
/// The app's haptics switch, for the popups and menus as well as the controller.
enum Haptics {
    @MainActor static var isOn = true
}

final class KeyPopupView: UIView {
    struct Item {
        /// What is typed.
        let text: String
        /// What the card shows.
        let label: String
        /// Shown instead of the label, in its colour.
        var image: UIImage? = nil
    }

    private(set) var items: [Item] = []
    private(set) var selected: Int?
    var selectedItem: Item? { selected.map { items[$0] } }
    private(set) var isShowingVariants = false
    private weak var key: KeyView?
    private let shape = CAShapeLayer()
    private let selection = CAShapeLayer()
    private var labels: [UILabel] = []
    private var images: [UIImageView] = []
    private var cells: [CGRect] = []
    private var glass: ShapeGlass?
    private var card = CGRect.zero
    private var foot = CGRect.zero
    private var textColor = UIColor.label

    /// Between the card and the key's top, bridged by the curved neck.
    private static let gap: CGFloat = 5
    private static let radius: CGFloat = 9
    private static let footRadius: CGFloat = 6
    /// Where a wide card's bottom edge starts curving down into the key.
    private static let neck: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        isHidden = true
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.3
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 1)
        shape.lineWidth = 0.5
        layer.addSublayer(shape)
        glass = ShapeGlass.make()
        if let glass = glass?.view {
            shape.isHidden = true
            addSubview(glass)
        }
        selection.fillColor = UIColor.systemBlue.cgColor
        layer.addSublayer(selection)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass?.view?.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPreview(_ title: String, image: UIImage? = nil, on key: KeyView, style: KeyStyle) {
        let foot = key.faceFrame
        var width = foot.width + 2 * min(10, foot.width * 0.3)
        // The same size on every row, the top one's lower card included.
        let fontSize = min(34, max(foot.height * 1.2, 34) * 0.72)
        // Every letter at the same size: a wide one (ص ض س ش) widens the card instead of being
        // shrunk to fit it.
        if image == nil {
            let textWidth = (title as NSString).size(withAttributes: [.font: keyFont(for: title, size: fontSize)]).width
            width = min(max(width, textWidth.rounded(.up) + 10), bounds.width)
        }
        let card = cardFrame(width: width, midX: foot.midX, foot: foot)
        isShowingVariants = false
        present(on: key, foot: foot, card: card, cells: [card], items: [Item(text: title, label: title, image: image)],
                style: style, fontSize: fontSize)
        select(index: nil, feedback: false)
        // The enlarged letter tilts like the keys, further.
        if let depth, let letter = labels.first {
            let distance = min(1, (depth.x * depth.x + depth.y * depth.y).squareRoot())
            letter.transform = CGAffineTransform(translationX: depth.x * KeyView.letterTravel * 1.6,
                                                 y: depth.y * KeyView.letterTravel * 1.6)
            letter.layer.shadowColor = UIColor.black.cgColor
            letter.layer.shadowOpacity = Float(distance * KeyView.shadowOpacity)
            letter.layer.shadowRadius = KeyView.shadowBlur
            letter.layer.shadowOffset = CGSize(width: -depth.x * KeyView.shadowTravel * 2.6,
                                               height: -depth.y * KeyView.shadowTravel * 2.6)
        }
    }

    /// The phone's tilt for the enlarged letter (`KeyView.depth`), nil when flat.
    var depth: CGPoint?

    /// A letter's forms start over the key, its own letter first, and run to the left, or to
    /// the right with `toTheRight`. With `anchor`, the items run left to right and the one at
    /// `anchor` starts over the key and is chosen first.
    func showVariants(_ items: [Item], on key: KeyView, style: KeyStyle,
                      toTheRight: Bool = false, anchor: Int? = nil, select: Int? = nil) {
        let foot = key.faceFrame
        let pad: CGFloat = 3
        // Narrower cells when a long row would not fit the keyboard's width.
        let cell = min(max(min(foot.width, 44), 30), (bounds.width - 2 * pad - 4) / CGFloat(max(items.count, 1)))
        let width = max(CGFloat(items.count) * cell + 2 * pad, foot.width + 8)
        let inset = (width - 2 * pad - CGFloat(items.count) * cell) / 2
        let leftToRight = toTheRight || anchor != nil
        let midX: CGFloat
        if let anchor {
            midX = foot.midX - (CGFloat(anchor) + 0.5) * cell - pad - inset + width / 2
        } else {
            midX = toTheRight ? foot.midX - cell / 2 - pad + width / 2 : foot.midX + cell / 2 + pad - width / 2
        }
        let card = cardFrame(width: width, midX: midX, foot: foot)
        let cells = items.indices.map { index in
            let x = leftToRight ? card.minX + pad + inset + CGFloat(index) * cell
                : card.maxX - pad - inset - CGFloat(index + 1) * cell
            return CGRect(x: x, y: card.minY + pad, width: cell, height: card.height - 2 * pad)
        }
        isShowingVariants = true
        present(on: key, foot: foot, card: card, cells: cells, items: items,
                style: style, fontSize: min(26, card.height * 0.62))
        self.select(index: select ?? anchor ?? 0, feedback: false)
    }

    /// Forms in rows, `rows[0]` nearest the key, each left to right, with `rows[0][anchor]` over
    /// the key and chosen first.
    func showGrid(_ rows: [[Item]], on key: KeyView, style: KeyStyle, anchor: Int) {
        let foot = key.faceFrame
        let pad: CGFloat = 3
        let columns = CGFloat(rows.map(\.count).max() ?? 1)
        let cellWidth = min(max(min(foot.width, 42), 30), (bounds.width - 2 * pad - 4) / columns)
        let width = columns * cellWidth + 2 * pad
        let midX = foot.midX - (CGFloat(anchor) + 0.5) * cellWidth - pad + width / 2
        let wanted = CGFloat(rows.count) * max(min(foot.height, 44), 32) + 2 * pad
        let card = cardFrame(width: width, midX: midX, foot: foot, height: wanted)
        let cellHeight = (card.height - 2 * pad) / CGFloat(rows.count)
        var cells: [CGRect] = []
        for (row, items) in rows.enumerated() {
            for column in items.indices {
                cells.append(CGRect(x: card.minX + pad + CGFloat(column) * cellWidth,
                                    y: card.maxY - pad - CGFloat(row + 1) * cellHeight, width: cellWidth, height: cellHeight))
            }
        }
        isShowingVariants = true
        present(on: key, foot: foot, card: card, cells: cells, items: rows.flatMap { $0 },
                style: style, fontSize: min(26, cellHeight * 0.62))
        select(index: anchor, feedback: false)
    }

    /// Selects the form nearest the finger, or none once it is far from them.
    func select(at point: CGPoint) {
        guard isShowingVariants, let first = cells.first else { return }
        // A row runs either way from the key.
        let rowMin = cells.map(\.minX).min() ?? first.minX, rowMax = cells.map(\.maxX).max() ?? first.maxX
        let near = point.x > rowMin - first.width && point.x < rowMax + first.width
            && point.y > card.minY - 2 * first.height && point.y < foot.maxY + foot.height
        let distance = { (cell: CGRect) in hypot(cell.midX - point.x, max(0, abs(cell.midY - point.y) - cell.height / 2)) }
        let index = near ? cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } : nil
        select(index: index, feedback: true)
    }

    /// The finger left `key`; a row of forms stays until its long press ends.
    func hidePreview(of key: KeyView) {
        guard !isShowingVariants, self.key === key else { return }
        hide()
    }

    func hide() {
        isHidden = true
        isShowingVariants = false
        key = nil
        selected = nil
        // Not shown for a frame at the old place when the next balloon opens.
        glass?.update(nil, tint: nil)
    }

    /// Above the foot and inside the view, covering the foot's width. Where the view ends
    /// little above the key the card first gets lower, down to the key's own height, and only
    /// then comes down over the top of the key.
    private func cardFrame(width: CGFloat, midX: CGFloat, foot: CGRect, height wanted: CGFloat? = nil) -> CGRect {
        let lowest = max(bounds.minX + 1, foot.maxX - width)
        let highest = min(foot.minX, bounds.maxX - 1 - width)
        let x = max(lowest, min(highest, midX - width / 2))
        let height = wanted ?? max(foot.height * 1.2, 34)
        // Over the top row there is only the suggestion bar's height: the card is made lower
        // to stay above the key rather than drop over it.
        let room = foot.minY - Self.gap - 1
        if room >= min(foot.height, 30) {
            let cardHeight = min(height, room)
            return CGRect(x: x, y: foot.minY - Self.gap - cardHeight, width: width, height: cardHeight)
        }
        let bottom = min(1 + foot.height, foot.minY + foot.height * 0.45)
        return CGRect(x: x, y: 1, width: width, height: max(2 * Self.radius, bottom - 1))
    }

    private func present(on key: KeyView, foot: CGRect, card: CGRect, cells: [CGRect], items: [Item],
                         style: KeyStyle, fontSize: CGFloat) {
        self.key = key
        self.foot = foot
        self.card = card
        self.cells = cells
        self.items = items
        // The card contrasts with the letters, whatever colour they were given.
        textColor = style.textColor.resolvedColor(with: traitCollection)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        textColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lightText = 0.299 * r + 0.587 * g + 0.114 * b > 0.5
        let path = Self.balloon(card: card, foot: foot).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        shape.shadowPath = path
        shape.fillColor = (lightText ? UIColor(white: 0.36, alpha: 1) : UIColor.white).cgColor
        shape.strokeColor = UIColor.black.withAlphaComponent(lightText ? 0.35 : 0.1).cgColor
        CATransaction.commit()
        // A light veil (dark under light letters) sets the letters off from the keys below.
        glass?.update(path, tint: lightText ? UIColor(white: 0.1, alpha: 0.2) : UIColor(white: 1, alpha: 0.25))
        while labels.count < items.count {
            let label = UILabel()
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.lineBreakMode = .byClipping
            addSubview(label)
            labels.append(label)
            let image = UIImageView()
            image.contentMode = .center
            addSubview(image)
            images.append(image)
        }
        for (index, label) in labels.enumerated() {
            let image = images[index]
            label.isHidden = index >= items.count || items[index].image != nil
            image.isHidden = index >= items.count || items[index].image == nil
            guard index < items.count else { continue }
            label.text = items[index].label
            label.font = keyFont(for: items[index].label, size: fontSize)
            // A single letter is never shrunk: its card was made wide enough for it.
            label.adjustsFontSizeToFitWidth = items.count > 1
            label.transform = .identity
            label.layer.shadowOpacity = 0
            label.frame = cells[index]
            image.image = items[index].image
            image.frame = cells[index]
            let size = image.image?.size ?? .zero
            image.contentMode = size.width > cells[index].width || size.height > cells[index].height ? .scaleAspectFit : .center
        }
        isHidden = false
    }

    private func select(index: Int?, feedback: Bool) {
        let changed = index != selected
        selected = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.path = index.map {
            UIBezierPath(roundedRect: cells[$0].insetBy(dx: 1, dy: 1), cornerRadius: 6).cgPath
        }
        CATransaction.commit()
        for (i, label) in labels.enumerated() where i < items.count {
            label.textColor = i == index ? .white : textColor
            images[i].tintColor = label.textColor
        }
        if feedback, changed, index != nil, Haptics.isOn { UISelectionFeedbackGenerator().selectionChanged() }
    }

    /// The card with rounded corners, joined to the foot (the key) by a curved neck: an S-curve
    /// when the card is only a little wider than the key, a fillet under a wide card's edge.
    private static func balloon(card c: CGRect, foot k: CGRect) -> UIBezierPath {
        let r = radius, kr = footRadius
        let footTop = max(k.minY, c.maxY) + min(4, k.height / 4)
        let mid = (c.maxY + footTop) / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: c.minX + r, y: c.minY))
        path.addLine(to: CGPoint(x: c.maxX - r, y: c.minY))
        path.addArc(withCenter: CGPoint(x: c.maxX - r, y: c.minY + r), radius: r,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        if c.maxX - k.maxX >= r + neck {
            path.addLine(to: CGPoint(x: c.maxX, y: c.maxY - r))
            path.addArc(withCenter: CGPoint(x: c.maxX - r, y: c.maxY - r), radius: r,
                        startAngle: 0, endAngle: .pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: k.maxX + neck, y: c.maxY))
            path.addQuadCurve(to: CGPoint(x: k.maxX, y: footTop), controlPoint: CGPoint(x: k.maxX, y: c.maxY))
        } else {
            path.addLine(to: CGPoint(x: c.maxX, y: c.maxY))
            path.addCurve(to: CGPoint(x: k.maxX, y: footTop), controlPoint1: CGPoint(x: c.maxX, y: mid),
                          controlPoint2: CGPoint(x: k.maxX, y: mid))
        }
        path.addLine(to: CGPoint(x: k.maxX, y: k.maxY - kr))
        path.addArc(withCenter: CGPoint(x: k.maxX - kr, y: k.maxY - kr), radius: kr,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: k.minX + kr, y: k.maxY))
        path.addArc(withCenter: CGPoint(x: k.minX + kr, y: k.maxY - kr), radius: kr,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: k.minX, y: footTop))
        if k.minX - c.minX >= r + neck {
            path.addQuadCurve(to: CGPoint(x: k.minX - neck, y: c.maxY), controlPoint: CGPoint(x: k.minX, y: c.maxY))
            path.addLine(to: CGPoint(x: c.minX + r, y: c.maxY))
            path.addArc(withCenter: CGPoint(x: c.minX + r, y: c.maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        } else {
            path.addCurve(to: CGPoint(x: c.minX, y: c.maxY), controlPoint1: CGPoint(x: k.minX, y: mid),
                          controlPoint2: CGPoint(x: c.minX, y: mid))
        }
        path.addLine(to: CGPoint(x: c.minX, y: c.minY + r))
        path.addArc(withCenter: CGPoint(x: c.minX + r, y: c.minY + r), radius: r,
                    startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        path.close()
        return path
    }
}

/// The emoji key's long-press menu: rows with an icon and a label on a blurred card. While the
/// finger is still down the keyboard moves the highlight (`highlight(at:)`); once it is open,
/// a row is chosen with a tap.
final class KeyMenuView: UIView {
    struct Item {
        let title: String
        let symbol: String
        let action: () -> Void
    }

    var items: [Item] = [] {
        didSet { buildRows() }
    }
    var onSelect: ((Item) -> Void)?
    var textColor = UIColor.label {
        didSet {
            buildRows()
            updateGlass()
        }
    }
    private(set) var highlighted: Int?
    var highlightedItem: Item? { highlighted.map { items[$0] } }
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    /// Under the rows: a faint wash of the app icon's colours, a shine along the top and a fine
    /// grain, like frosted glass.
    private let texture = UIView()
    private let wash = CAGradientLayer()
    private let shine = CAGradientLayer()
    private var rows: [UIView] = []
    private static let rowHeight: CGFloat = 40
    private static let padding: CGFloat = 4

    var preferredSize: CGSize {
        CGSize(width: 150, height: CGFloat(items.count) * Self.rowHeight + 2 * Self.padding)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)
        texture.isUserInteractionEnabled = false
        texture.backgroundColor = UIColor(patternImage: Self.grain)
        wash.startPoint = CGPoint(x: 0, y: 0)
        wash.endPoint = CGPoint(x: 1, y: 1)
        shine.colors = [UIColor(white: 1, alpha: 0.5).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        shine.endPoint = CGPoint(x: 0.5, y: 0.45)
        shine.startPoint = CGPoint(x: 0.35, y: 0)
        texture.layer.insertSublayer(wash, at: 0)
        texture.layer.addSublayer(shine)
        card.contentView.addSubview(texture)
        updateGlass()
    }

    /// Frosted: the keys behind are blurred out of the way of the words. From iOS 26 that is
    /// Liquid Glass, as on the key popups, with a veil for the words' colour.
    private func updateGlass() {
        let lightText = KeyboardBackground.luminance(textColor.resolvedColor(with: traitCollection)) > 0.5
        let colours: [UIColor] = [.systemPink, .systemPurple, .systemBlue, .systemTeal]
        wash.colors = colours.map { $0.withAlphaComponent(lightText ? 0.22 : 0.13).cgColor }
        shine.opacity = lightText ? 0.35 : 1
        card.effect = UIBlurEffect(style: lightText ? .systemThickMaterialDark : .systemThickMaterialLight)
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor(white: 1, alpha: lightText ? 0.2 : 0.6).cgColor
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = lightText ? UIColor(white: 0.08, alpha: 0.55) : UIColor(white: 1, alpha: 0.6)
            card.effect = glass
            card.layer.borderWidth = 0
            layer.shadowOpacity = 0
        }
        #endif
    }

    /// Specks of light and shade, half a point each, few enough to feel rather than see.
    private static let grain: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let side = 64
        var random = SystemRandomNumberGenerator()
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            for y in 0..<(2 * side) {
                for x in 0..<(2 * side) {
                    let speck = Double.random(in: 0..<1, using: &random)
                    guard speck < 0.35 else { continue }
                    UIColor(white: speck < 0.15 ? 0 : 1, alpha: speck < 0.15 ? 0.05 : 0.09).setFill()
                    context.fill(CGRect(x: CGFloat(x) / 2, y: CGFloat(y) / 2, width: 0.5, height: 0.5))
                }
            }
        }
    }()

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = UIView()
            row.layer.cornerRadius = 8
            let icon = UIImageView(image: UIImage(systemName: item.symbol,
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)))
            icon.tintColor = textColor
            icon.contentMode = .center
            icon.tag = 1
            let label = UILabel()
            label.text = item.title
            label.font = AppFont.font(ofSize: 16)
            label.textColor = textColor
            label.textAlignment = .right
            label.tag = 2
            row.addSubview(icon)
            row.addSubview(label)
            row.isAccessibilityElement = true
            row.accessibilityLabel = item.title
            row.accessibilityTraits = .button
            card.contentView.addSubview(row)
            return row
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = bounds
        texture.frame = card.contentView.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = texture.bounds
        shine.frame = texture.bounds
        CATransaction.commit()
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: Self.padding, y: Self.padding + CGFloat(index) * Self.rowHeight,
                               width: bounds.width - 2 * Self.padding, height: Self.rowHeight)
            // Right to left: icon on the right, label before it.
            row.viewWithTag(1)?.frame = CGRect(x: row.bounds.width - 36, y: 0, width: 32, height: row.bounds.height)
            row.viewWithTag(2)?.frame = CGRect(x: 8, y: 0, width: row.bounds.width - 48, height: row.bounds.height)
        }
    }

    /// Highlights the row under `point` (in this view), or none.
    func highlight(at point: CGPoint?) {
        let index = point.flatMap { point in
            bounds.insetBy(dx: -12, dy: 0).contains(point)
                ? rows.firstIndex { $0.frame.insetBy(dx: -12, dy: 0).contains(point) } : nil
        }
        guard index != highlighted else { return }
        highlighted = index
        for (i, row) in rows.enumerated() {
            row.backgroundColor = i == index ? UIColor.label.withAlphaComponent(0.12) : .clear
        }
        if index != nil, Haptics.isOn { UISelectionFeedbackGenerator().selectionChanged() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        highlight(at: touches.first?.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        highlight(at: touches.first?.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        highlight(at: touches.first?.location(in: self))
        if let item = highlightedItem { onSelect?(item) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        highlight(at: nil)
    }
}
