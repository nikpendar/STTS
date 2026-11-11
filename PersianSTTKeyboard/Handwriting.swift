import UIKit
#if canImport(MLKitDigitalInkRecognition)
import MLKitCommon
import MLKitDigitalInkRecognition
#endif

/// Persian handwriting with Google ML Kit's on-device ink recognizer (language "fa"): the model
/// (about 20 MB) downloads once, the first time the pad opens, and then works offline. Nothing
/// of it is in memory until the pad opens, and it is let go when the pad closes.
/// Builds without ML Kit (the simulator tests) have no recognizer and say so.
final class InkRecognizer {
    struct Point { var x: Float; var y: Float; var t: Int }
    typealias Stroke = [Point]

    enum State: Equatable { case unavailable, downloading, ready, failed(String) }
    private(set) var state = State.unavailable
    /// The recognizer's language (BCP 47).
    var language = "fa"
    /// Written right to left, a bracket drawn opening towards the text is the opening one, which
    /// the recognizer reads as its mirror image: swapped back (Rooz, 2026-11-09).
    var mirrorsBrackets = true
    private static let mirrors: [Character: Character] = ["(": ")", ")": "(", "[": "]", "]": "[",
                                                           "{": "}", "}": "{", "«": "»", "»": "«", "<": ">", ">": "<"]
    /// The download's error in full, for the log.
    private(set) var lastError: String?
    var onState: ((State) -> Void)?

    static var isBuiltIn: Bool {
        #if canImport(MLKitDigitalInkRecognition)
        return true
        #else
        return false
        #endif
    }

    #if canImport(MLKitDigitalInkRecognition)
    private var model: DigitalInkRecognitionModel?
    private var recognizer: DigitalInkRecognizer?
    private var observers: [NSObjectProtocol] = []
    #endif

    /// Loads the model (downloading it the first time).
    func prepare() {
        #if canImport(MLKitDigitalInkRecognition)
        guard let identifier = DigitalInkRecognitionModelIdentifier(forLanguageTag: language) else {
            set(.failed("مدل فارسی دست‌خط پیدا نشد"))
            return
        }
        let model = DigitalInkRecognitionModel(modelIdentifier: identifier)
        self.model = model
        // The Persian model inside the keyboard (build.yml): nothing to download.
        if language == "fa", BundledInkModel.install() {
            makeRecognizer()
            return
        }
        let manager = ModelManager.modelManager()
        if manager.isModelDownloaded(model) {
            makeRecognizer()
            return
        }
        set(.downloading)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mlkitModelDownloadDidSucceed, object: nil, queue: .main) { [weak self] _ in
            self?.makeRecognizer()
        })
        observers.append(center.addObserver(forName: .mlkitModelDownloadDidFail, object: nil, queue: .main) { [weak self] note in
            let error = note.userInfo?[ModelDownloadUserInfoKey.error.rawValue] as? NSError
            NSLog("handwriting model download failed: %@", String(describing: error))
            self?.lastError = error.map { "\($0.domain) \($0.code) \($0.userInfo)" }
            self?.set(.failed("دانلود مدل دست‌خط نشد"))
        })
        manager.download(model, conditions: ModelDownloadConditions(allowsCellularAccess: true, allowsBackgroundDownloading: false))
        #else
        set(.unavailable)
        #endif
    }

    #if canImport(MLKitDigitalInkRecognition)
    private func makeRecognizer() {
        guard let model, recognizer == nil else { return }
        recognizer = DigitalInkRecognizer.digitalInkRecognizer(options: DigitalInkRecognizerOptions(model: model))
        set(.ready)
    }
    #endif

    private func set(_ new: State) {
        state = new
        onState?(new)
    }

    /// The readings of `strokes`, best first; `before` is the text before the cursor, which
    /// helps the recognizer with the next word, `area` the writing area's size.
    func recognize(_ strokes: [Stroke], before: String, area: CGSize, completion: @escaping ([String]) -> Void) {
        #if canImport(MLKitDigitalInkRecognition)
        guard let recognizer, !strokes.isEmpty else { return completion([]) }
        let ink = Ink(strokes: strokes.map { stroke in
            MLKitDigitalInkRecognition.Stroke(points: stroke.map { StrokePoint(x: $0.x, y: $0.y, t: $0.t) })
        })
        let context = DigitalInkRecognitionContext(preContext: String(before.suffix(20)),
                                                   writingArea: WritingArea(width: Float(area.width), height: Float(area.height)))
        recognizer.recognize(ink: ink, context: context) { result, _ in
            // After a word in the context the readings start with a space; the keyboard adds its own.
            var texts: [String] = []
            let mirror = self.mirrorsBrackets
            for candidate in result?.candidates ?? [] {
                var text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if mirror { text = String(text.map { Self.mirrors[$0] ?? $0 }) }
                if !text.isEmpty, !texts.contains(text) { texts.append(text) }
            }
            DispatchQueue.main.async { completion(texts) }
        }
        #else
        completion([])
        #endif
    }

    /// Lets the recognizer and its model go (the file stays for next time).
    func close() {
        #if canImport(MLKitDigitalInkRecognition)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        recognizer = nil
        model = nil
        #endif
        state = .unavailable
    }

    deinit { close() }
}

#if canImport(MLKitDigitalInkRecognition)
/// ML Kit's Persian handwriting files carried in the keyboard (folder HandwritingModel, filled by
/// build.yml from the files ML Kit itself would download: recospec, model, lm), so the pad
/// works without the download, which fails on the phone and in the simulator alike
/// ("com.google.mlkit 2 Download failed"). ML Kit has no public way to take its handwriting
/// model from a file, so its model manager is pointed at these files: the three methods that
/// open the Persian files, and the check whether the model is there. Other languages go on
/// to ML Kit's own code.
enum BundledInkModel {
    /// The keyboard's folder with the files.
    static var directory: URL? {
        return Bundle.main.url(forResource: "HandwritingModel", withExtension: nil)
    }

    static func file(_ name: String) -> URL? {
        guard let url = directory?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var isPresent: Bool { ["recospec", "model", "lm"].allSatisfy { file($0) != nil } }

    private static var installed: Bool?

    /// Points ML Kit at the files; false when they or ML Kit's methods are not there.
    static func install() -> Bool {
        if let installed { return installed }
        let done = isPresent && replace()
        installed = done
        NSLog("handwriting bundled model: %@", done ? "in use" : (isPresent ? "ML Kit methods not found" : "not in this build"))
        return done
    }

    private static func isPersian(_ model: AnyObject) -> Bool {
        (model as? DigitalInkRecognitionModel)?.modelIdentifier.languageTag.hasPrefix("fa") ?? false
    }

    private static func encoding(_ method: Method) -> String {
        method_getTypeEncoding(method).map { String(cString: $0) } ?? ""
    }

    private static func replace() -> Bool {
        guard let cls = NSClassFromString("MLKDigitalInkRecognitionModelManager") else { return false }
        let files: [(String, String)] = [("modelFileHandleForModel:error:", "model"),
                                          ("languageModelFileHandleForModel:error:", "lm"),
                                          ("recospecFileHandleForModel:error:", "recospec")]
        var methods: [(Method, String)] = []
        for (name, file) in files {
            guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return false }
            let types = encoding(method)
            // An object back, taking an object and an error pointer.
            guard types.hasPrefix("@"), types.contains("^@") else { return false }
            methods.append((method, file))
        }
        guard let downloaded = class_getInstanceMethod(cls, NSSelectorFromString("isModelDownloaded:")) else { return false }
        guard encoding(downloaded).hasPrefix("B") else { return false }

        typealias Opener = @convention(c) (AnyObject, Selector, AnyObject, OpaquePointer?) -> AnyObject?
        for (method, file) in methods {
            let original = unsafeBitCast(method_getImplementation(method), to: Opener.self)
            let selector = method_getName(method)
            let block: @convention(block) (AnyObject, AnyObject, OpaquePointer?) -> AnyObject? = { manager, model, error in
                if isPersian(model), let url = BundledInkModel.file(file), let handle = try? FileHandle(forReadingFrom: url) {
                    return handle
                }
                return original(manager, selector, model, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        typealias Check = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let original = unsafeBitCast(method_getImplementation(downloaded), to: Check.self)
        let selector = method_getName(downloaded)
        let block: @convention(block) (AnyObject, AnyObject) -> Bool = { manager, model in
            isPersian(model) || original(manager, selector, model)
        }
        method_setImplementation(downloaded, imp_implementationWithBlock(block))
        return true
    }
}
#endif

/// The handwriting pad over the keys (from holding the emoji key): words written with a finger
/// turn into text a moment after the finger lifts. The readings line up at the top: the first
/// goes in by itself when the next word is started, or a tap picks another.
final class HandwritingPadView: UIView {
    var onInsert: ((String) -> Void)?
    /// A word already put in, read again: the first text is replaced by the second.
    var onReplace: ((String, String) -> Void)?
    /// A word turned into text, for a light tap when haptics are on.
    var onWordRead: (() -> Void)?
    /// The handle dragged a stretch up (+1) or down (-1): true when the pad changed size.
    var onStepSize: ((Int) -> Bool)?
    /// The handle double-tapped: the middle size.
    var onResetSize: (() -> Void)?
    /// The pen lifted this long ends a word (`KeyboardOptions.handwritingPause`).
    var pause: TimeInterval = 0.3
    var onSpace: (() -> Void)?
    /// The delete button pressed and let go, as the keyboard's backspace: one character, and
    /// held, more and more, then words.
    var onDeleteDown: (() -> Void)?
    var onDeleteUp: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Leaves the pad for the emoji panel.
    var onEmoji: (() -> Void)?
    var onClose: (() -> Void)?
    /// A button or reading tapped, or a word read: for the keyboard's haptics when they are on.
    var onFeedback: (() -> Void)?

    /// The keyboard's own return image.
    var returnImage: UIImage? {
        didSet { returnButton.setImage(returnImage, for: .normal) }
    }
    /// The text before the cursor, for the recognizer's context.
    var textBefore: (() -> String)?

    var textColor = UIColor.label {
        didSet {
            applyInkStyle()
            gripPill.backgroundColor = textColor.withAlphaComponent(0.3)
            status.textColor = textColor.withAlphaComponent(0.6)
            hint.textColor = textColor.withAlphaComponent(0.4)
            candidateButtons.forEach { $0.setTitleColor(textColor, for: .normal) }
            updateGuide()
        }
    }

    /// The pen chosen in the app: its colour (nil, the letters' colour) and width.
    var inkColor: UIColor? {
        didSet { applyInkStyle() }
    }
    var inkWidth: CGFloat = 4 {
        didSet { applyInkStyle() }
    }
    /// Which way the paper moves under the pen once a word is read: right for Persian, left
    /// for English, as if the paper slid under the hand (Rooz, 2026-11-09).
    var rightToLeft = true {
        didSet {
            recognizer.mirrorsBrackets = rightToLeft
            deleteButton.setImage(UIImage(systemName: rightToLeft ? "delete.right" : "delete.left",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            // The language beside the keyboard symbol, so the way the paper moves is plain.
            closeButton.setTitle(rightToLeft ? " فا" : " EN", for: .normal)
            stripIcon.image = UIImage(systemName: rightToLeft ? "arrow.right.to.line" : "arrow.left.to.line",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            setNeedsLayout()
        }
    }
    /// Off, each word fades as soon as it is read instead of sliding aside.
    var slides = true
    /// The handwriting speed setting (0 slow … 1 fast): the smoke goes as quickly.
    var speed: Double = 1
    /// Orders the recognizer's readings: the keyboard's language and the words it knows first.
    var rank: (([String]) -> [String])?
    /// A faint guide line across the paper (`KeyboardOptions.handwritingGuide`).
    var showsGuide = true {
        didSet { updateGuide() }
    }
    private let guide = CAShapeLayer()
    /// The one touch that writes; a second finger makes it a two-finger gesture instead.
    private var pen: UITouch?
    private var twoFingers = false
    /// Two fingers swiped left or right: a word deleted (Rooz, 2026-11-11).
    private let swipe = UISwipeGestureRecognizer()
    /// Two fingers swiped down: return (Rooz, 2026-11-11), the full paper having no return key.
    private let swipeDown = UISwipeGestureRecognizer()
    /// On the full paper, which has no delete or return key: how to do both.
    private let hint = UILabel()
    /// Gone once the pen first touches the full paper; back each time the full paper opens.
    private var hintSeen = false
    /// The strip at the paper's outer edge (right for Persian, left for English): a tap on it
    /// sends the word aside at once (Rooz, 2026-11-11). Writing over it stays ink.
    var showsStrip = true {
        didSet { setNeedsLayout() }
    }
    private let strip = UIView()
    private let stripFill = CAShapeLayer()
    private let stripEdge = CAShapeLayer()
    private let stripIcon = UIImageView()
    /// The handle taken (true) and let go (false), and a size step: for a firmer tap.
    var onGripFeedback: ((Bool) -> Void)?

    private let recognizer = InkRecognizer()
    private let ink = CAShapeLayer()
    /// Words already read stay on the paper, moved aside, until the pen rests a few seconds.
    private let trail = CALayer()
    /// The glowing head over the last stretch of the stroke being written.
    private let inkHead = CAShapeLayer()
    /// How far the paper has moved since the last word was read (for a dot added to it).
    private var shiftSinceLastWord: CGFloat = 0
    /// The layers of the word last read (its ink, and a dot added to it): a delete takes them off.
    private var lastWordLayers: [CALayer] = []
    private var trailFadeTimer: Timer?
    private static let trailRest: TimeInterval = 2.5
    private let status = UILabel()
    private let candidateRow = UIStackView()
    private var candidateButtons: [UIButton] = []
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    /// Full paper (Rooz, 2026-11-09): everything but the paper, delete and the button back goes,
    /// and the paper takes the whole pad; the keyboard keeps its size.
    private let expandButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private var fullPaper = false
    private let paper = UIView()
    /// The handle: a short pill at the very top, dragged to make the pad taller or shorter. It
    /// takes a wide band across the top, and the touch at once (no movement needed first).
    private let grip = UIView()
    private let gripPill = UIView()
    private static let gripHeight: CGFloat = 12
    private static let gripTouchHeight: CGFloat = 26

    private var strokes: [InkRecognizer.Stroke] = []
    private var current: InkRecognizer.Stroke = []
    private var path = UIBezierPath()
    private var started: CFTimeInterval = 0
    private var recognizeTimer: Timer?
    /// Readings of the last word; the first is already in the text, a tap on another swaps it.
    private var pending: [String] = []
    /// Strokes of the word being recognized, to keep the right readings.
    private var generation = 0
    /// The word last put in: its text, strokes, where its ink was and when, so a dot or bar
    /// added just after it joins it rather than starting a word of its own.
    private var lastWord: (text: String, strokes: [InkRecognizer.Stroke], box: CGRect, time: CFTimeInterval)?
    /// Readings while a word is still being written, shown dimmed in the first slot.
    private var previewGeneration = 0
    /// Words being read now, and what waits for them: a space or return typed after the word,
    /// and letting the recognizer go once the pad closes.
    private var reading = 0
    private var afterReading: [() -> Void] = []
    private var closeWhenRead = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        paper.backgroundColor = UIColor.label.withAlphaComponent(0.05)
        paper.layer.cornerRadius = 14
        paper.layer.cornerCurve = .continuous
        paper.isUserInteractionEnabled = false
        addSubview(paper)
        // Over the paper and under the ink.
        strip.isUserInteractionEnabled = false
        strip.clipsToBounds = true
        strip.layer.cornerRadius = 14
        strip.layer.cornerCurve = .continuous
        stripEdge.fillColor = nil
        stripEdge.lineWidth = 1
        strip.layer.addSublayer(stripFill)
        strip.layer.addSublayer(stripEdge)
        stripIcon.contentMode = .center
        stripIcon.image = UIImage(systemName: "arrow.right.to.line",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        strip.addSubview(stripIcon)
        addSubview(strip)
        guide.fillColor = nil
        guide.lineWidth = 1
        guide.lineCap = .round
        layer.addSublayer(guide)
        trail.masksToBounds = true
        layer.addSublayer(trail)
        layer.addSublayer(ink)
        layer.addSublayer(inkHead)
        applyInkStyle()
        status.font = keyFont(for: "دست‌خط", size: 15)
        status.textAlignment = .center
        status.numberOfLines = 3
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.7
        status.textColor = textColor.withAlphaComponent(0.6)
        status.isUserInteractionEnabled = false
        addSubview(status)
        candidateRow.axis = .horizontal
        candidateRow.distribution = .fillEqually
        candidateRow.semanticContentAttribute = .forceRightToLeft
        addSubview(candidateRow)
        for _ in 0..<4 {
            let button = UIButton(type: .custom)
            button.setTitleColor(textColor, for: .normal)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.6
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let text = button?.title(for: .normal), !text.isEmpty else { return }
                self.onFeedback?()
                self.choose(text)
            }, for: .touchUpInside)
            candidateRow.addArrangedSubview(button)
            candidateButtons.append(button)
        }
        for (button, symbol, label) in [(spaceButton, "space", "فاصله"), (deleteButton, "delete.right", "پاک کردن"),
                                        (closeButton, "keyboard", "صفحه‌کلید"), (emojiButton, "face.smiling", "شکلک"),
                                        (returnButton, "return", "خط بعد"),
                                        (collapseButton, "arrow.down.right.and.arrow.up.left", "کوچک کردن")] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            button.accessibilityLabel = label
            button.tintColor = .label
            button.backgroundColor = UIColor.label.withAlphaComponent(0.08)
            button.layer.cornerRadius = 10
            button.layer.cornerCurve = .continuous
            addSubview(button)
        }
        expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        expandButton.accessibilityLabel = "تمام‌صفحه"
        expandButton.tintColor = .label
        expandButton.addAction(UIAction { [weak self] _ in self?.setFullPaper(true) }, for: .touchUpInside)
        expandButton.addAction(UIAction { [weak self] _ in self?.onFeedback?() }, for: .touchDown)
        addSubview(expandButton)
        collapseButton.addAction(UIAction { [weak self] _ in self?.setFullPaper(false) }, for: .touchUpInside)
        collapseButton.addAction(UIAction { [weak self] _ in self?.onFeedback?() }, for: .touchDown)
        collapseButton.isHidden = true
        spaceButton.addAction(UIAction { [weak self] _ in self?.commitPending { self?.onSpace?() } }, for: .touchUpInside)
        deleteButton.addAction(UIAction { [weak self] _ in self?.deleteDown() }, for: .touchDown)
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDeleteUp?() },
                               for: [.touchUpInside, .touchUpOutside, .touchCancel])
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        closeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        closeButton.setTitleColor(.label, for: .normal)
        emojiButton.addAction(UIAction { [weak self] _ in self?.onEmoji?() }, for: .touchUpInside)
        returnButton.addAction(UIAction { [weak self] _ in self?.commitPending { self?.onReturn?() } }, for: .touchUpInside)
        for button in [spaceButton, deleteButton, closeButton, emojiButton, returnButton] {
            button.addAction(UIAction { [weak self] _ in self?.onFeedback?() }, for: .touchDown)
        }
        gripPill.backgroundColor = UIColor.label.withAlphaComponent(0.3)
        gripPill.layer.cornerRadius = 2.5
        gripPill.isUserInteractionEnabled = false
        grip.addSubview(gripPill)
        grip.accessibilityLabel = "اندازه‌ی صفحه‌ی دست‌خط"
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(dragGrip(_:)))
        hold.minimumPressDuration = 0
        hold.allowableMovement = .greatestFiniteMagnitude
        grip.addGestureRecognizer(hold)
        addSubview(grip)
        recognizer.onState = { [weak self] state in self?.show(state) }
        show(.unavailable)
        isMultipleTouchEnabled = true
        swipe.numberOfTouchesRequired = 2
        // A lifted pen is not held back while the swipe waits to fail: dots and word ends stay prompt.
        swipe.delaysTouchesEnded = false
        // Either way, in either language (Rooz, 2026-11-11).
        swipe.direction = [.right, .left]
        swipe.addTarget(self, action: #selector(swipeDelete))
        addGestureRecognizer(swipe)
        swipeDown.numberOfTouchesRequired = 2
        swipeDown.delaysTouchesEnded = false
        swipeDown.direction = .down
        swipeDown.addTarget(self, action: #selector(swipeReturn))
        addGestureRecognizer(swipeDown)
        hint.font = keyFont(for: "پاک کردن", size: 13)
        hint.textAlignment = .center
        hint.textColor = textColor.withAlphaComponent(0.4)
        hint.adjustsFontSizeToFitWidth = true
        hint.minimumScaleFactor = 0.7
        hint.isUserInteractionEnabled = false
        hint.isHidden = true
        hint.text = "پاک کردن: دو انگشت به چپ یا راست   ·   اینتر: دو انگشت به پایین"
        addSubview(hint)
    }

    @objc private func swipeReturn() {
        onFeedback?()
        commitPending { [weak self] in self?.onReturn?() }
    }

    @objc private func swipeDelete() {
        onFeedback?()
        deleteDown()
        onDeleteUp?()
    }

    /// The guide line a little below the paper's middle, where letters sit, in the letters'
    /// colour, faint enough not to look like ink.
    private func updateGuide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let area = paper.frame
        let line = UIBezierPath()
        let y = area.minY + area.height * 0.62
        line.move(to: CGPoint(x: area.minX + 18, y: y))
        line.addLine(to: CGPoint(x: area.maxX - 18, y: y))
        guide.path = area.width > 40 ? line.cgPath : nil
        guide.strokeColor = textColor.resolvedColor(with: traitCollection).withAlphaComponent(0.16).cgColor
        guide.isHidden = !showsGuide
        CATransaction.commit()
    }

    /// The strip in the pen's colour (Rooz, 2026-11-11), faint, like the ink it sends aside.
    private func updateStripLook() {
        let colour = penColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripFill.fillColor = colour.withAlphaComponent(0.08).cgColor
        stripEdge.strokeColor = colour.withAlphaComponent(0.2).cgColor
        CATransaction.commit()
        stripIcon.tintColor = colour.withAlphaComponent(0.4)
    }

    /// The strip's place and shape from the paper as it is now (any size, landscape, full
    /// paper): its inner edge bows in towards the middle of the paper.
    private func layoutStrip() {
        let area = paper.frame
        // On the full paper it stops above the button back, which sits in a bottom corner.
        let bottom = fullPaper ? collapseButton.frame.minY - 6 : area.maxY
        let height = bottom - area.minY
        let width = max(28, min(44, area.width * 0.07))
        strip.isHidden = !showsStrip || area.width < 160 || height < 36
        guard !strip.isHidden else { return }
        strip.frame = CGRect(x: rightToLeft ? area.maxX - width : area.minX, y: area.minY, width: width, height: height)
        strip.layer.maskedCorners = rightToLeft
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        // Local x of the inner edge: a little in at the ends, all the way in at the middle.
        let ends = width * 0.45
        let inner = { (x: CGFloat) in self.rightToLeft ? x : width - x }
        let edge = UIBezierPath()
        edge.move(to: CGPoint(x: inner(ends), y: 0))
        edge.addCurve(to: CGPoint(x: inner(0), y: height / 2),
                      controlPoint1: CGPoint(x: inner(ends), y: height * 0.2),
                      controlPoint2: CGPoint(x: inner(0), y: height * 0.3))
        edge.addCurve(to: CGPoint(x: inner(ends), y: height),
                      controlPoint1: CGPoint(x: inner(0), y: height * 0.7),
                      controlPoint2: CGPoint(x: inner(ends), y: height * 0.8))
        let fill = UIBezierPath()
        fill.append(edge)
        fill.addLine(to: CGPoint(x: rightToLeft ? width : 0, y: height))
        fill.addLine(to: CGPoint(x: rightToLeft ? width : 0, y: 0))
        fill.close()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripFill.frame = strip.bounds
        stripEdge.frame = strip.bounds
        stripFill.path = fill.cgPath
        stripEdge.path = edge.cgPath
        CATransaction.commit()
        stripIcon.isHidden = height < 60
        let iconX = rightToLeft ? width * 0.6 : width * 0.4
        stripIcon.frame = CGRect(x: iconX - 12, y: height / 2 - 12, width: 24, height: 24)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateStripLook()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Where the finger was when the handle last moved the pad a size, and when that was.
    private var gripStart: CGFloat?
    private var gripStepped: CFTimeInterval = 0
    private var gripMoved = false
    /// When the last touch on the handle that did not drag let go, for a double tap.
    private var lastGripTap: CFTimeInterval = 0
    private static let gripStep: CGFloat = 36

    /// The handle moves the pad between three sizes while the finger is held on it: up a size
    /// for each stretch dragged up, down a size for each stretch dragged down (Rooz,
    /// 2026-11-09: following the finger point by point lagged and jumped, as the keyboard is
    /// resized by iOS a moment later). After each size the finger is measured afresh, once the
    /// keyboard has settled. A double tap puts the middle size back.
    @objc private func dragGrip(_ hold: UILongPressGestureRecognizer) {
        guard let window else { return }
        let fromBottom = window.bounds.height - hold.location(in: window).y
        let now = CACurrentMediaTime()
        switch hold.state {
        case .began:
            gripStart = fromBottom
            gripMoved = false
            onGripFeedback?(true)
            setGripTaken(true)
        case .changed:
            guard now - gripStepped > 0.35 else { return }
            guard let start = gripStart else {
                gripStart = fromBottom
                return
            }
            let moved = fromBottom - start
            if abs(moved) > 6 { gripMoved = true }
            guard abs(moved) >= Self.gripStep else { return }
            if onStepSize?(moved > 0 ? 1 : -1) == true {
                onGripFeedback?(false)
                gripStepped = now
                gripStart = nil
            } else {
                gripStart = fromBottom
            }
        default:
            gripStart = nil
            setGripTaken(false)
            guard !gripMoved, hold.state == .ended else { return }
            if now - lastGripTap < 0.35 {
                lastGripTap = 0
                onFeedback?()
                onResetSize?()
            } else {
                lastGripTap = now
            }
        }
    }

    /// The handle grows longer and darker while held, so it shows it was taken.
    private var gripTaken = false
    private func setGripTaken(_ taken: Bool) {
        gripTaken = taken
        UIView.animate(withDuration: 0.15) {
            self.layoutGripPill()
            self.gripPill.alpha = taken ? 1 : 0.75
        }
    }

    private func layoutGripPill() {
        let width: CGFloat = gripTaken ? 76 : 40
        gripPill.frame = CGRect(x: 90 - width / 2, y: gripTaken ? 3.5 : 4, width: width, height: gripTaken ? 6 : 5)
        gripPill.layer.cornerRadius = gripPill.frame.height / 2
    }

    /// Loads the recognizer: called when the pad opens.
    func start() {
        recognizer.prepare()
        if !InkRecognizer.isBuiltIn { show(.unavailable) }
    }

    /// Lets the recognizer go: called when the pad closes or the keyboard goes away.
    func stop() {
        recognizeTimer?.invalidate()
        recognizeTimer = nil
        if reading > 0 { closeWhenRead = true } else { recognizer.close() }
    }

    /// A word read (or given up): what waited for it runs, in order.
    private func doneReading() {
        reading = max(0, reading - 1)
        guard reading == 0 else { return }
        let waiting = afterReading
        afterReading = []
        waiting.forEach { $0() }
        if closeWhenRead {
            closeWhenRead = false
            recognizer.close()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y0: CGFloat = 0
        let top = y0 + Self.gripHeight
        grip.frame = CGRect(x: bounds.midX - 90, y: y0, width: 180, height: Self.gripTouchHeight)
        layoutGripPill()
        let row: CGFloat = 36
        // Full paper only in landscape (Rooz, 2026-11-09); turned to portrait, back to normal.
        let screen = window?.screen.bounds.size ?? UIScreen.main.bounds.size
        let landscape = screen.width > screen.height
        if !landscape, fullPaper { fullPaper = false }
        // The full-paper button at the top left, beside the readings.
        expandButton.frame = CGRect(x: 4, y: top, width: 36, height: row)
        let readingsX: CGFloat = landscape ? 42 : 8
        candidateRow.frame = CGRect(x: readingsX, y: top, width: bounds.width - readingsX - 8, height: row)
        let buttonsY = bounds.height - 46
        // Left to right: back to the keyboard, emoji, return, space (twice as wide), delete.
        let gap: CGFloat = 6
        let unit = (bounds.width - 16 - 4 * gap) / 6
        let hidden = fullPaper
        for view in [grip, expandButton, candidateRow, closeButton, emojiButton, returnButton, spaceButton] as [UIView] {
            view.isHidden = hidden
        }
        collapseButton.isHidden = !hidden
        // The full paper deletes with two fingers only (Rooz, 2026-11-11): no delete key there.
        deleteButton.isHidden = hidden
        hint.isHidden = !hidden
        hint.alpha = hintSeen ? 0 : 1
        expandButton.isHidden = hidden || !landscape
        if fullPaper {
            // The whole pad is paper; the button back sits in its bottom corner, outlined so it
            // stands apart from the ink, with a line on deleting and return beside it.
            paper.frame = CGRect(x: 8, y: 8, width: bounds.width - 16, height: max(24, bounds.height - 16))
            let size = CGSize(width: min(unit, 64), height: 38)
            collapseButton.frame = CGRect(x: paper.frame.minX + 8, y: paper.frame.maxY - size.height - 8,
                                          width: size.width, height: size.height)
            let hintX = collapseButton.frame.maxX + 12
            hint.frame = CGRect(x: hintX, y: collapseButton.frame.minY,
                                width: paper.frame.maxX - 8 - size.width - 12 - hintX, height: size.height)
        } else {
            var x: CGFloat = 8
            for (button, width) in [(closeButton, unit), (emojiButton, unit), (returnButton, unit),
                                    (spaceButton, 2 * unit), (deleteButton, unit)] {
                button.frame = CGRect(x: x, y: buttonsY, width: width, height: 40)
                x += width + gap
            }
            paper.frame = CGRect(x: 8, y: top + row + 2, width: bounds.width - 16, height: max(24, buttonsY - top - row - 8))
        }
        // The mask is cut after the paper and the buttons have their new frames: cut before,
        // it kept the old paper size and the old button places (full paper showed half a page).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutPaper(around: hidden ? [collapseButton] : [])
        CATransaction.commit()
        status.frame = paper.frame.insetBy(dx: 20, dy: 20)
        updateGuide()
        layoutStrip()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if trail.frame != paper.frame {
            clearTrail()
            trail.frame = paper.frame
        }
        CATransaction.commit()
    }

    private func show(_ state: InkRecognizer.State) {
        switch state {
        case .unavailable:
            status.text = InkRecognizer.isBuiltIn ? "" : "دست‌خط در این نسخه نیست"
        case .downloading:
            status.text = "دانلود مدل دست‌خط فارسی (یک بار، حدود ۱۳ مگابایت)…"
        case .ready:
            status.text = strokes.isEmpty && pending.isEmpty ? "اینجا بنویسید" : ""
        case .failed(let message):
            status.text = message + "\nدسترسی کامل کیبورد و اینترنت لازم است"
        }
    }

    // MARK: Writing

    private var paperArea: CGRect { paper.frame }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if pen != nil || touches.count > 1 || (event?.allTouches?.count ?? 1) > 1 {
            // A second finger: a two-finger gesture, not writing.
            cancelStroke()
            pen = nil
            twoFingers = true
            return
        }
        guard !twoFingers, paperArea.contains(touch.location(in: self)) else { return }
        pen = touch
        hideHint()
        recognizeTimer?.invalidate()
        trailFadeTimer?.invalidate()
        if strokes.isEmpty {
            started = touch.timestamp
            path = UIBezierPath()
        }
        status.text = ""
        current = []
        add(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pen, touches.contains(touch), !current.isEmpty else { return }
        for t in event?.coalescedTouches(for: touch) ?? [touch] { add(t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { if allLifted(event) { twoFingers = false } }
        guard let touch = pen, touches.contains(touch) else { return }
        pen = nil
        guard !current.isEmpty else { return }
        var stroke = current
        current = []
        if isStripTap(stroke) {
            pushAside()
            return
        }
        if stroke.count == 1, let point = stroke.first {
            // A tap, the dot of ب or ف: drawn as a round dot, and given a second point so the
            // recognizer takes it as a stroke.
            stroke.append(InkRecognizer.Point(x: point.x + 0.5, y: point.y, t: point.t + 1))
            path.addLine(to: CGPoint(x: CGFloat(point.x) + 0.5, y: CGFloat(point.y)))
            setInkPath(path.cgPath)
        }
        dropHead()
        if strokes.isEmpty, joinsLastWord(stroke) {
            // A dot or a bar put on the word just read: read it again with it.
            readAgain(adding: stroke)
            return
        }
        strokes.append(stroke)
        scheduleTrailFade()
        preview()
        scheduleRecognize()
    }

    /// The pen lifted a moment: the word is done, and the next can start straight away.
    private func scheduleRecognize() {
        recognizeTimer?.invalidate()
        recognizeTimer = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            self?.recognizeWord()
        }
    }

    /// A touch taken by the system or by the two-finger swipe: the stroke it drew goes.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelStroke()
        pen = nil
        if allLifted(event) { twoFingers = false }
    }

    private func hideHint() {
        guard !hintSeen else { return }
        hintSeen = true
        UIView.animate(withDuration: 0.3) { self.hint.alpha = 0 }
    }

    /// A short, still touch on the strip, not a dot: a dot falls on the word being written (or
    /// on the word just read), anything else there is the strip being tapped.
    private func isStripTap(_ stroke: InkRecognizer.Stroke) -> Bool {
        guard !strip.isHidden, let first = stroke.first, let last = stroke.last else { return false }
        let start = CGPoint(x: CGFloat(first.x), y: CGFloat(first.y))
        guard strip.frame.contains(start), last.t - first.t < 250 else { return false }
        let box = Self.box(of: [stroke])
        guard max(box.width, box.height) < 10 else { return false }
        if strokes.isEmpty { return !joinsLastWord(stroke) }
        return !Self.box(of: strokes).insetBy(dx: -14, dy: -14).contains(start)
    }

    /// The strip tapped: the tap leaves no ink, the word being written is read and goes aside
    /// now, and with none, the words on the paper glide off it.
    private func pushAside() {
        onFeedback?()
        rebuildInk()
        dropHead(animated: false)
        if !strokes.isEmpty {
            recognizeTimer?.invalidate()
            recognizeTimer = nil
            recognizeWord()
            return
        }
        let words = (trail.sublayers ?? []).filter { $0 is CAShapeLayer }
        guard !words.isEmpty else { return }
        let step = trail.bounds.width * (rightToLeft ? 1 : -1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { words.forEach { $0.removeFromSuperlayer() } }
        for word in words {
            let from = (word.presentation() ?? word).position
            var to = word.position
            to.x += step
            word.position = to
            let glide = CABasicAnimation(keyPath: "position")
            glide.fromValue = NSValue(cgPoint: from)
            glide.toValue = NSValue(cgPoint: to)
            glide.duration = 0.25
            glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            word.add(glide, forKey: "glide")
        }
        CATransaction.commit()
        lastWordLayers = []
        shiftSinceLastWord = 0
    }

    /// The ink of the word's finished strokes only.
    private func rebuildInk() {
        path = UIBezierPath()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
            for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
        }
        setInkPath(strokes.isEmpty ? nil : path.cgPath)
    }

    private func allLifted(_ event: UIEvent?) -> Bool {
        event?.allTouches?.allSatisfy { $0.phase == .ended || $0.phase == .cancelled } ?? true
    }

    /// Drops the stroke being drawn; the word's earlier strokes stay and are read as before.
    private func cancelStroke() {
        // The head goes even with no stroke left: its glow stayed behind as a faint dot.
        dropHead(animated: false)
        guard !current.isEmpty else { return }
        current = []
        rebuildInk()
        if strokes.isEmpty { scheduleTrailFade() } else { scheduleRecognize() }
    }

    private func add(_ touch: UITouch) {
        let p = touch.location(in: self)
        let point = InkRecognizer.Point(x: Float(p.x), y: Float(p.y), t: Int((touch.timestamp - started) * 1000))
        if current.isEmpty { path.move(to: p) } else { path.addLine(to: p) }
        current.append(point)
        setInkPath(path.cgPath)
        updateHead()
    }

    private static func box(of strokes: [InkRecognizer.Stroke]) -> CGRect {
        var box = CGRect.null
        for point in strokes.joined() { box = box.union(CGRect(x: CGFloat(point.x), y: CGFloat(point.y), width: 0, height: 0)) }
        return box
    }

    /// A small stroke (a dot, or the bar of ک and گ) on the word read a moment ago.
    private func joinsLastWord(_ stroke: InkRecognizer.Stroke) -> Bool {
        guard let last = lastWord, CACurrentMediaTime() - last.time < 1 else { return false }
        let box = Self.box(of: [stroke])
        let small = max(box.width, box.height) < 12 || (box.height < 8 && box.width < 28)
        let shown = last.box.offsetBy(dx: slides ? shiftSinceLastWord : 0, dy: 0)
        return small && shown.insetBy(dx: -10, dy: -10).contains(CGPoint(x: box.midX, y: box.midY))
    }

    /// The word being written, read as it grows: its best reading shows dimmed in the first slot.
    private func preview() {
        previewGeneration += 1
        let mine = previewGeneration
        recognizer.recognize(strokes, before: textBefore?() ?? "", area: paperArea.size) { [weak self] found in
            guard let self, mine == self.previewGeneration, !self.strokes.isEmpty else { return }
            guard let best = (self.rank?(found) ?? found).first else { return }
            self.showCandidates(preview: best)
        }
    }

    private func recognizeWord() {
        let word = strokes
        guard !word.isEmpty else { return }
        strokes = []
        previewGeneration += 1
        generation += 1
        let mine = generation
        let box = Self.box(of: word)
        moveInkAside(width: box.width)
        reading += 1
        recognizer.recognize(word, before: textBefore?() ?? "", area: paperArea.size) { [weak self] found in
            guard let self else { return }
            defer { self.doneReading() }
            guard mine == self.generation else { return }
            let texts = self.rank?(found) ?? found
            guard let best = texts.first else {
                self.lastWord = nil
                if self.recognizer.state == .ready { self.status.text = "خوانده نشد؛ دوباره بنویسید" }
                return
            }
            // In the text at once, with a light tap; the other readings stay a tap away.
            self.pending = Array(texts.prefix(4))
            self.lastWord = (best, word, box, CACurrentMediaTime())
            self.onInsert?(best)
            self.onWordRead?()
            if self.strokes.isEmpty { self.showCandidates() }
        }
    }

    /// The last word with a dot or bar added, read again and swapped in the text.
    private func readAgain(adding stroke: InkRecognizer.Stroke) {
        guard let last = lastWord else { return }
        // Where the dot is on the word as the recognizer saw it, before the paper moved.
        let back = Float(slides ? shiftSinceLastWord : 0)
        let moved = stroke.map { InkRecognizer.Point(x: $0.x - back, y: $0.y, t: $0.t) }
        let word = last.strokes + [moved]
        lastWord = (last.text, word, last.box.union(Self.box(of: [moved])), CACurrentMediaTime())
        moveInkAside(width: nil)
        scheduleTrailFade()
        generation += 1
        let mine = generation
        reading += 1
        recognizer.recognize(word, before: textBefore?() ?? "", area: paperArea.size) { [weak self] found in
            guard let self else { return }
            defer { self.doneReading() }
            let texts = self.rank?(found) ?? found
            guard mine == self.generation, let best = texts.first, let current = self.lastWord else { return }
            self.pending = Array(texts.prefix(4))
            if best != current.text { self.onReplace?(current.text, best) }
            self.lastWord = (best, current.strokes, current.box, current.time)
            if self.strokes.isEmpty { self.showCandidates() }
        }
    }

    /// The word just written joins the words on the paper, and the paper slides (right for
    /// Persian, left for English) until the word sits in the outer third. With no
    /// width (a dot added to the last word), the ink stays where it is.
    private func moveInkAside(width: CGFloat?) {
        var toTrail = CGAffineTransform(translationX: -trail.frame.minX, y: -trail.frame.minY)
        let wordPath = ink.path?.copy(using: &toTrail)
        let word = wordLayer(wordPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trail.addSublayer(word)
        CATransaction.commit()
        if width == nil { lastWordLayers.append(word) } else { lastWordLayers = [word] }
        setInkPath(nil)
        dropHead(animated: false)
        path = UIBezierPath()
        guard slides else {
            let box = wordPath?.boundingBoxOfPath ?? .zero
            if box.isEmpty { word.removeFromSuperlayer() } else { smoke(word, box: box.insetBy(dx: -inkWidth, dy: -inkWidth)) }
            return
        }
        guard let width else { return }
        // Far enough that the word's last letter ends up in the outer third of the paper, so the
        // middle stays free for the next word (Rooz, 2026-11-11); never less than its width.
        let paperWidth = trail.bounds.width
        let box = wordPath?.boundingBoxOfPath ?? .zero
        let clear = rightToLeft ? paperWidth * 0.7 - box.minX : box.maxX - paperWidth * 0.3
        let step = min(max(width + 22, clear), paperWidth) * (rightToLeft ? 1 : -1)
        shiftSinceLastWord = step
        // Each layer glides from where it is seen now to its new place (Rooz, 2026-11-11): an
        // implicit move had no start for the word just added, so it jumped.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in trail.sublayers ?? [] {
            let from = (layer.presentation() ?? layer).position
            var to = layer.position
            to.x += step
            // Gone past the edge: off the paper for good.
            if abs(to.x - trail.bounds.midX) > trail.bounds.width * 1.6 {
                layer.removeFromSuperlayer()
                continue
            }
            layer.position = to
            let glide = CABasicAnimation(keyPath: "position")
            glide.fromValue = NSValue(cgPoint: from)
            glide.toValue = NSValue(cgPoint: to)
            glide.duration = 0.25
            glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(glide, forKey: "glide")
        }
        CATransaction.commit()
    }

    /// Once the pen has rested a few seconds, the words on the paper fade away.
    private func scheduleTrailFade() {
        trailFadeTimer?.invalidate()
        trailFadeTimer = Timer.scheduledTimer(withTimeInterval: Self.trailRest, repeats: false) { [weak self] _ in
            guard let self, self.strokes.isEmpty, self.current.isEmpty else { return }
            let words = self.trail.sublayers ?? []
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setCompletionBlock { words.forEach { $0.removeFromSuperlayer() } }
            words.forEach { $0.opacity = 0 }
            CATransaction.commit()
            // The readings stay a tap away after the ink has gone: forgetting the word here
            // left a reading tapped later, a bracket or a slash, doing nothing (Rooz, 2026-11-09).
            self.shiftSinceLastWord = 0
        }
    }

    private func clearTrail() {
        trail.sublayers?.forEach { $0.removeFromSuperlayer() }
        lastWordLayers = []
        shiftSinceLastWord = 0
    }

    /// A word deleted from the text: its ink fades off the paper too (the last word read, then
    /// the words before it, newest first).
    private func dropLastTrailWord() {
        var gone = lastWordLayers.filter { $0.superlayer === trail }
        lastWordLayers = []
        if gone.isEmpty, let word = trail.sublayers?.last(where: { $0 is CAShapeLayer && $0.opacity > 0 }) {
            gone = [word]
        }
        guard !gone.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { gone.forEach { $0.removeFromSuperlayer() } }
        gone.forEach { $0.opacity = 0 }
        CATransaction.commit()
    }

    private func showCandidates(preview: String? = nil) {
        if let preview {
            for (index, button) in candidateButtons.enumerated() {
                let text = index == 0 ? preview : ""
                button.setTitle(text, for: .normal)
                button.setTitleColor(textColor.withAlphaComponent(0.45), for: .normal)
                button.titleLabel?.font = keyFont(for: text, size: 21)
                button.backgroundColor = .clear
                button.isEnabled = false
            }
            return
        }
        for (index, button) in candidateButtons.enumerated() {
            let text = index < pending.count ? pending[index] : ""
            button.setTitle(text, for: .normal)
            button.setTitleColor(textColor, for: .normal)
            button.isEnabled = true
            button.titleLabel?.font = keyFont(for: text, size: index == 0 ? 21 : 18)
            button.backgroundColor = index == 0 && !text.isEmpty ? UIColor.systemRed.withAlphaComponent(0.15) : .clear
            button.layer.cornerRadius = 9
        }
    }

    /// Ink still being written is read now (before a space, return, emoji or closing); `then`
    /// runs once the word is in the text.
    func commitPending(then: (() -> Void)? = nil) {
        if !strokes.isEmpty {
            recognizeTimer?.invalidate()
            recognizeTimer = nil
            recognizeWord()
        }
        guard let then else { return }
        if reading > 0 { afterReading.append(then) } else { then() }
    }

    /// Another reading of the last word tapped: it takes the first one's place in the text.
    private func choose(_ text: String) {
        guard let last = lastWord, let index = pending.firstIndex(of: text) else { return }
        if text != last.text { onReplace?(last.text, text) }
        lastWord = (text, last.strokes, last.box, last.time)
        pending.remove(at: index)
        pending.insert(text, at: 0)
        showCandidates()
    }

    private func clearInk() {
        setInkPath(nil)
        dropHead(animated: false)
        path = UIBezierPath()
    }

    // MARK: Ink look

    private var penColor: UIColor { (inkColor ?? textColor).resolvedColor(with: traitCollection) }

    /// The pen is drawn like a shooting star (Rooz, 2026-11-09): a plain, solid line, and at the
    /// pen's tip a wider, glowing head that narrows back into the line over its last stretch.
    private static let headLength: CGFloat = 70

    private func applyInkStyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plain(ink)
        updateStripLook()
        inkHead.fillColor = penColor.cgColor
        inkHead.strokeColor = nil
        inkHead.shadowColor = penColor.cgColor
        inkHead.shadowOpacity = 0.7
        inkHead.shadowRadius = max(3, inkWidth * 0.9)
        inkHead.shadowOffset = .zero
        CATransaction.commit()
    }

    /// A solid stroke in the pen's colour and width, no glow.
    private func plain(_ shape: CAShapeLayer) {
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = penColor.cgColor
        shape.lineWidth = inkWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.shadowOpacity = 0
    }

    private func setInkPath(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.path = path
        CATransaction.commit()
    }

    /// The head over the last stretch of the stroke being written: as wide as the line where it
    /// starts, twice as wide at the tip, with a round tip; it glows, the line does not.
    private func updateHead() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        inkHead.removeAnimation(forKey: "fade")
        inkHead.opacity = 1
        guard let last = current.last else { inkHead.path = nil; return }
        // The points of the last stretch, from its start to the tip: only the stroke's tail is
        // read, whatever its length (a long line used to be copied whole on every move).
        var stretch = [CGPoint(x: CGFloat(last.x), y: CGFloat(last.y))]
        var length: CGFloat = 0
        var index = current.count - 2
        while index >= 0, length < Self.headLength {
            let p = CGPoint(x: CGFloat(current[index].x), y: CGFloat(current[index].y))
            let d = hypot(p.x - stretch[stretch.count - 1].x, p.y - stretch[stretch.count - 1].y)
            if d > 0.5 {
                length += d
                stretch.append(p)
            }
            index -= 1
        }
        stretch.reverse()
        // Round dots along the stretch, from the line's width at its start to twice that at
        // the tip, all filled the same way: a smooth taper with no gaps or notches where they
        // overlap (an outline with a round tip on top left holes in it).
        let tipWidth = inkWidth * 2.1
        var run: [CGFloat] = [0]
        for i in stride(from: 1, to: stretch.count, by: 1) {
            run.append(run[i - 1] + hypot(stretch[i].x - stretch[i - 1].x, stretch[i].y - stretch[i - 1].y))
        }
        let total = max(run.last ?? 1, 1)
        let shape = CGMutablePath()
        var lastDot: CGPoint?
        for i in stretch.indices {
            let t = stretch.count == 1 ? 1 : run[i] / total
            let width = inkWidth + (tipWidth - inkWidth) * t * t
            let p = stretch[i]
            // Dots no further apart than a third of their width, filled in between.
            if let from = lastDot {
                let gap = hypot(p.x - from.x, p.y - from.y)
                let steps = Int(gap / max(1, width / 3))
                if steps > 1 {
                    for k in 1..<steps {
                        let f = CGFloat(k) / CGFloat(steps)
                        let q = CGPoint(x: from.x + (p.x - from.x) * f, y: from.y + (p.y - from.y) * f)
                        shape.addEllipse(in: CGRect(x: q.x - width / 2, y: q.y - width / 2, width: width, height: width))
                    }
                }
            }
            shape.addEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
            lastDot = p
        }
        inkHead.path = shape
        inkHead.shadowPath = shape
    }

    /// The pen lifted: the head fades back into the line.
    private func dropHead(animated: Bool = true) {
        guard inkHead.path != nil else { return }
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkHead.removeAnimation(forKey: "fade")
            inkHead.path = nil
            inkHead.shadowPath = nil
            CATransaction.commit()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.25
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkHead.opacity = 0
        CATransaction.commit()
        inkHead.add(fade, forKey: "fade")
    }

    /// A word's ink as a layer of its own: the plain line.
    private func wordLayer(_ path: CGPath?) -> CAShapeLayer {
        let word = CAShapeLayer()
        word.frame = trail.bounds
        word.path = path
        plain(word)
        return word
    }

    /// The word goes up in smoke along its own line, from where it was started to where it
    /// ended (Rooz, 2026-11-09): the line is eaten from its start while puffs rise from the
    /// point being eaten.
    private func smoke(_ word: CAShapeLayer, box: CGRect) {
        guard let path = word.path else { word.removeFromSuperlayer(); return }
        let length = Self.length(of: path)
        // With the handwriting speed (Rooz, 2026-11-09): slow about twice as long as medium,
        // fast a little quicker than medium.
        let level = CGFloat(max(0, min(1, speed)))
        let pace = 450 + 500 * level
        let duration = CFTimeInterval(max(0.4 - 0.2 * level, min(1.1 - 0.6 * level, length / pace)))

        let eat = CABasicAnimation(keyPath: "strokeStart")
        eat.fromValue = 0
        eat.toValue = 1
        eat.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        word.strokeStart = 1
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { word.removeFromSuperlayer() }
        word.add(eat, forKey: "eat")
        CATransaction.commit()

        let puffs = CAEmitterLayer()
        puffs.frame = trail.bounds
        puffs.emitterShape = .circle
        puffs.emitterMode = .surface
        puffs.emitterSize = CGSize(width: inkWidth, height: inkWidth)
        let cell = CAEmitterCell()
        cell.contents = Self.puffImage
        cell.birthRate = 220
        cell.lifetime = 0.7
        cell.lifetimeRange = 0.25
        cell.velocity = 48
        cell.velocityRange = 14
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 10
        cell.yAcceleration = -70
        cell.xAcceleration = 0
        cell.scale = 0.05 * max(1, inkWidth / 3)
        cell.scaleSpeed = 0.14
        cell.alphaSpeed = -1.3
        cell.color = penColor.withAlphaComponent(0.35).cgColor
        cell.spin = 0.6
        cell.spinRange = 1.2
        puffs.emitterCells = [cell]
        trail.addSublayer(puffs)
        // The puffs follow the line at the speed the line is eaten.
        let follow = CAKeyframeAnimation(keyPath: "emitterPosition")
        follow.path = path
        follow.calculationMode = .paced
        follow.duration = duration
        follow.fillMode = .forwards
        follow.isRemovedOnCompletion = false
        puffs.add(follow, forKey: "follow")
        // Thinning out towards the end of the line, and none once it is gone: left running, the
        // puffs piled up on the last point into one big blot.
        let thin = CAKeyframeAnimation(keyPath: "birthRate")
        thin.values = [1, 1, 0]
        thin.keyTimes = [0, 0.6, 1]
        thin.duration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        puffs.birthRate = 0
        CATransaction.commit()
        puffs.add(thin, forKey: "thin")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1.2) { [weak puffs] in
            puffs?.removeFromSuperlayer()
        }
    }

    /// The drawn length of a path (its lines; moves between strokes do not count).
    private static func length(of path: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var last = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                last = e.points[0]
            case .addLineToPoint:
                total += hypot(e.points[0].x - last.x, e.points[0].y - last.y)
                last = e.points[0]
            case .addQuadCurveToPoint:
                total += hypot(e.points[1].x - last.x, e.points[1].y - last.y)
                last = e.points[1]
            case .addCurveToPoint:
                total += hypot(e.points[2].x - last.x, e.points[2].y - last.y)
                last = e.points[2]
            default:
                break
            }
        }
        return total
    }

    /// A soft white round puff, drawn once.
    private static let puffImage: CGImage? = {
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let center = CGPoint(x: 32, y: 32)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 32, options: [])
        }
        return image.cgImage
    }()

    /// In full paper the two buttons keep their colour; a clear ring is cut out of the paper
    /// around them so they stand apart from it (Rooz, 2026-11-09).
    private func cutPaper(around buttons: [UIButton]) {
        guard !buttons.isEmpty else {
            paper.layer.mask = nil
            return
        }
        let mask = (paper.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let shape = UIBezierPath(rect: paper.bounds)
        for button in buttons {
            let ring = convert(button.frame, to: paper).insetBy(dx: -4, dy: -4)
            shape.append(UIBezierPath(roundedRect: ring, cornerRadius: 14))
        }
        mask.frame = paper.bounds
        mask.path = shape.cgPath
        mask.fillRule = .evenOdd
        paper.layer.mask = mask
    }

    private func setFullPaper(_ on: Bool) {
        guard fullPaper != on else { return }
        commitPending()
        fullPaper = on
        if on { hintSeen = false }
        UIView.animate(withDuration: 0.2) {
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    private func deleteDown() {
        if !strokes.isEmpty {
            // Ink not yet read: thrown away.
            recognizeTimer?.invalidate()
            strokes = []
            previewGeneration += 1
            generation += 1
            showCandidates()
            clearInk()
        } else {
            // The text itself, a word per tap, more words while held; the last word's readings go.
            lastWord = nil
            pending = []
            showCandidates()
            dropLastTrailWord()
            onDeleteDown?()
        }
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
