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
            for candidate in result?.candidates ?? [] {
                let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var onSpace: (() -> Void)?
    /// Deletes the character before the cursor.
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    /// Leaves the pad for the emoji panel.
    var onEmoji: (() -> Void)?
    var onClose: (() -> Void)?

    /// The keyboard's own return and emoji images.
    var returnImage: UIImage? {
        didSet { returnButton.setImage(returnImage, for: .normal) }
    }
    var emojiImage: UIImage? {
        didSet { emojiButton.setImage(emojiImage, for: .normal) }
    }
    /// The text before the cursor, for the recognizer's context.
    var textBefore: (() -> String)?

    var textColor = UIColor.label {
        didSet {
            ink.strokeColor = textColor.cgColor
            status.textColor = textColor.withAlphaComponent(0.6)
            candidateButtons.forEach { $0.setTitleColor(textColor, for: .normal) }
        }
    }

    private let recognizer = InkRecognizer()
    private let ink = CAShapeLayer()
    private let status = UILabel()
    private let candidateRow = UIStackView()
    private var candidateButtons: [UIButton] = []
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)
    private let paper = UIView()

    private var strokes: [InkRecognizer.Stroke] = []
    private var current: InkRecognizer.Stroke = []
    private var path = UIBezierPath()
    private var started: CFTimeInterval = 0
    private var recognizeTimer: Timer?
    /// Readings of the last word, not yet in the text.
    private var pending: [String] = []
    /// Strokes of the word being recognized, to keep the right readings.
    private var generation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        paper.backgroundColor = UIColor.label.withAlphaComponent(0.05)
        paper.layer.cornerRadius = 14
        paper.layer.cornerCurve = .continuous
        paper.isUserInteractionEnabled = false
        addSubview(paper)
        ink.fillColor = UIColor.clear.cgColor
        ink.strokeColor = textColor.cgColor
        ink.lineWidth = 4
        ink.lineCap = .round
        ink.lineJoin = .round
        layer.addSublayer(ink)
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
                self.commit(text)
            }, for: .touchUpInside)
            candidateRow.addArrangedSubview(button)
            candidateButtons.append(button)
        }
        for (button, symbol, label) in [(spaceButton, "space", "فاصله"), (deleteButton, "delete.right", "پاک کردن"),
                                        (closeButton, "keyboard", "صفحه‌کلید"), (emojiButton, "face.smiling", "شکلک"),
                                        (returnButton, "return", "خط بعد")] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            button.accessibilityLabel = label
            button.tintColor = .label
            button.backgroundColor = UIColor.label.withAlphaComponent(0.08)
            button.layer.cornerRadius = 10
            button.layer.cornerCurve = .continuous
            addSubview(button)
        }
        spaceButton.addAction(UIAction { [weak self] _ in self?.commitPending(); self?.onSpace?() }, for: .touchUpInside)
        deleteButton.addAction(UIAction { [weak self] _ in self?.deleteTapped() }, for: .touchUpInside)
        closeButton.addAction(UIAction { [weak self] _ in self?.commitPending(); self?.onClose?() }, for: .touchUpInside)
        emojiButton.addAction(UIAction { [weak self] _ in self?.commitPending(); self?.onEmoji?() }, for: .touchUpInside)
        returnButton.addAction(UIAction { [weak self] _ in self?.commitPending(); self?.onReturn?() }, for: .touchUpInside)
        recognizer.onState = { [weak self] state in self?.show(state) }
        show(.unavailable)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        recognizer.close()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let row: CGFloat = 38
        candidateRow.frame = CGRect(x: 8, y: 0, width: bounds.width - 16, height: row)
        let buttonsY = bounds.height - 46
        // Left to right: back to the keyboard, emoji, space (twice as wide), return, delete.
        let gap: CGFloat = 6
        let unit = (bounds.width - 16 - 4 * gap) / 6
        var x: CGFloat = 8
        for (button, width) in [(closeButton, unit), (emojiButton, unit), (spaceButton, 2 * unit),
                                (returnButton, unit), (deleteButton, unit)] {
            button.frame = CGRect(x: x, y: buttonsY, width: width, height: 40)
            x += width + gap
        }
        paper.frame = CGRect(x: 8, y: row + 2, width: bounds.width - 16, height: buttonsY - row - 8)
        status.frame = paper.frame.insetBy(dx: 20, dy: 20)
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
        guard let touch = touches.first, paperArea.contains(touch.location(in: self)) else { return }
        recognizeTimer?.invalidate()
        if strokes.isEmpty {
            // A new word: the last one's best reading goes in.
            commitPending()
            started = touch.timestamp
            path = UIBezierPath()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ink.setAffineTransform(.identity)
            CATransaction.commit()
        }
        status.text = ""
        current = []
        add(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, !current.isEmpty else { return }
        for t in event?.coalescedTouches(for: touch) ?? [touch] { add(t) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !current.isEmpty else { return }
        strokes.append(current)
        current = []
        // A short pause after the last stroke: the word is done.
        recognizeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.recognizeWord()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func add(_ touch: UITouch) {
        let p = touch.location(in: self)
        let point = InkRecognizer.Point(x: Float(p.x), y: Float(p.y), t: Int((touch.timestamp - started) * 1000))
        if current.isEmpty { path.move(to: p) } else { path.addLine(to: p) }
        current.append(point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.opacity = 1
        ink.path = path.cgPath
        CATransaction.commit()
    }

    private func recognizeWord() {
        let word = strokes
        strokes = []
        generation += 1
        let mine = generation
        // The ink fades as the reading comes.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.25
        fade.duration = 0.25
        ink.add(fade, forKey: "fade")
        ink.opacity = 0.25
        moveInkAside()
        recognizer.recognize(word, before: textBefore?() ?? "", area: paperArea.size) { [weak self] texts in
            guard let self, mine == self.generation else { return }
            self.pending = Array(texts.prefix(4))
            self.showCandidates()
            if texts.isEmpty, self.recognizer.state == .ready { self.status.text = "خوانده نشد؛ دوباره بنویسید" }
        }
    }

    private func showCandidates() {
        for (index, button) in candidateButtons.enumerated() {
            let text = index < pending.count ? pending[index] : ""
            button.setTitle(text, for: .normal)
            button.titleLabel?.font = keyFont(for: text, size: index == 0 ? 21 : 18)
            button.backgroundColor = index == 0 && !text.isEmpty ? UIColor.systemRed.withAlphaComponent(0.15) : .clear
            button.layer.cornerRadius = 9
        }
    }

    /// The last word's best reading goes in (before a new word, space or closing).
    func commitPending() {
        guard let best = pending.first else { return }
        commit(best)
    }

    private func commit(_ text: String) {
        pending = []
        showCandidates()
        clearInk()
        onInsert?(text)
    }

    /// The faded word slides to the paper's right edge (and shrinks if it is wider than half the
    /// paper), leaving room for the next one.
    private func moveInkAside() {
        guard let box = ink.path?.boundingBoxOfPath, !box.isNull, box.width > 0 else { return }
        let area = paper.frame
        let scale = min(1, area.width * 0.45 / box.width)
        let right = area.maxX - 12
        // The ink layer has no size at the pad's origin, so its transform works in pad points.
        let move = CGAffineTransform(translationX: right, y: box.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.maxX, y: -box.midY)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        ink.setAffineTransform(move)
        CATransaction.commit()
    }

    private func clearInk() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.setAffineTransform(.identity)
        ink.path = nil
        CATransaction.commit()
        path = UIBezierPath()
    }

    private func deleteTapped() {
        if !strokes.isEmpty || !pending.isEmpty {
            // Unwritten ink or readings not yet in: thrown away.
            recognizeTimer?.invalidate()
            strokes = []
            pending = []
            generation += 1
            showCandidates()
            clearInk()
        } else {
            onDelete?()
        }
    }

    override func removeFromSuperview() {
        stop()
        super.removeFromSuperview()
    }
}
