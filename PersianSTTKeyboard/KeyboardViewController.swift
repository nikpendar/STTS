import UIKit

/// Dictation keyboard: records through the app's background session and types the
/// transcript into the focused text field, so the field never loses focus.
final class KeyboardViewController: UIInputViewController {
    private enum State {
        case checking, noSession, ready, starting, recording, transcribing
    }

    private var state = State.checking {
        didSet { render() }
    }

    private let observer = DarwinObserver()
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var timeout: DispatchWorkItem?
    private var previewTimer: Timer?
    private var previewIndex = 0

    /// Screenshot support when the keyboard is shown inside the app: fixes the displayed
    /// state ("noSession", "ready", "recording", "transcribing", or "cycle" for all of them).
    var previewState: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        observer.observe(DictationBridge.alive) { [weak self] in
            MainActor.assumeIsolated { self?.sessionIsAlive() }
        }
        observer.observe(DictationBridge.recording) { [weak self] in
            MainActor.assumeIsolated { self?.recordingStarted() }
        }
        observer.observe(DictationBridge.done) { [weak self] in
            MainActor.assumeIsolated { self?.insertTranscript() }
        }
        observer.observe(DictationBridge.failed) { [weak self] in
            MainActor.assumeIsolated { self?.transcriptionFailed() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let previewState {
            showPreview(previewState)
            return
        }
        applyKeyStyle(KeyStyle.load())
        checkSession()
    }

    private func showPreview(_ name: String) {
        let states: [String: State] = [
            "noSession": .noSession, "ready": .ready, "recording": .recording, "transcribing": .transcribing,
        ]
        if name == "emoji" {
            layer = .emoji
            buildCharacterKeys()
            state = .ready
            return
        }
        if let fixed = states[name] {
            state = fixed
            return
        }
        let cycle: [State] = [.noSession, .ready, .recording, .transcribing, .ready]
        state = cycle[0]
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewIndex = (self.previewIndex + 1) % cycle.count
                self.state = cycle[self.previewIndex]
            }
        }
    }

    // MARK: - Session

    private func checkSession() {
        guard hasFullAccess else {
            state = .noSession
            statusLabel.text = "در تنظیمات کیبورد، Allow Full Access را روشن کنید."
            return
        }
        state = .checking
        DictationBridge.post(DictationBridge.ping)
        schedule(after: 0.6) { [weak self] in
            if self?.state == .checking { self?.state = .noSession }
        }
    }

    private func sessionIsAlive() {
        if state == .checking || state == .noSession {
            cancelTimeout()
            state = .ready
        }
    }

    @objc private func micTapped() {
        switch state {
        case .ready:
            state = .starting
            DictationBridge.post(DictationBridge.start)
            // No answer means the app was closed and the session is gone.
            schedule(after: 0.8) { [weak self] in
                if self?.state == .starting { self?.state = .noSession }
            }
        case .recording:
            state = .transcribing
            DictationBridge.post(DictationBridge.stop)
            schedule(after: 90) { [weak self] in
                if self?.state == .transcribing { self?.transcriptionFailed() }
            }
        case .noSession, .checking:
            open(DictationBridge.sessionURL)
        case .transcribing:
            // Stop the transcription; the app discards it.
            cancelTimeout()
            DictationBridge.post(DictationBridge.cancel)
            state = .ready
            statusLabel.text = "تبدیل لغو شد."
        case .starting:
            break
        }
    }

    private func recordingStarted() {
        guard state == .starting else { return }
        cancelTimeout()
        state = .recording
    }

    private func insertTranscript() {
        guard state == .transcribing else { return }
        cancelTimeout()
        TranscriptClient.fetch { [weak self] text in
            guard let self, self.state == .transcribing else { return }
            if let text, !text.isEmpty {
                self.textDocumentProxy.insertText(text)
                self.state = .ready
            } else {
                self.transcriptionFailed()
            }
        }
    }

    private func transcriptionFailed() {
        guard state == .transcribing else { return }
        cancelTimeout()
        state = .ready
        statusLabel.text = "متنی تشخیص داده نشد. دوباره امتحان کنید."
    }

    /// Extensions cannot call UIApplication.open, so the host's UIApplication is found
    /// through the responder chain and its open method is called dynamically.
    private func open(_ url: URL) {
        guard hasFullAccess else { return }
        typealias OpenURL = @convention(c) (
            AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)).contains("UIApplication"),
               current.responds(to: selector) {
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
        statusLabel.text = "اپ «گفتار به متن» را باز کنید و «شروع جلسه‌ی کیبورد» را بزنید."
    }

    private func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        cancelTimeout()
        let item = DispatchWorkItem(block: work)
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    // MARK: - UI

    private enum Layer { case letters, symbols, emoji }

    private static let emojis: [String] = Array(
        "😀😃😄😁😆😅😂🤣🙂🙃😉😊😇🥰😍🤩😘😗😚😙😋😛😜🤪😝🤑🤗🤭🤫🤔🤐🤨😐😑😶😏😒🙄😬😌😔😪🤤😴😷🤒🤕🤢🤮🥵🥶🥴😵🤯🤠🥳😎🤓🧐😕😟🙁😮😯😲😳🥺😦😧😨😰😥😢😭😱😖😣😞😓😩😫🥱😤😡😠🤬😈👿💀💩🤡👻👽🤖😺😸😹😻😼😽🙀😿😾🙈🙉🙊💋💌💘💝💖💗💓💞💕💟❣💔🧡💛💚💙💜🤎🖤🤍💯💢💥💫💦💨🕳💬💭💤👋🤚🖐✋🖖👌🤏✌🤞🤟🤘🤙👈👉👆🖕👇☝👍👎✊👊🤛🤜👏🙌👐🤲🤝🙏✍💅🤳💪🌹🌷🌸🌼🌻🌺🍀🍁🍂🌱🌲🌳🌴🌵☀🌙⭐🌟✨⚡🔥🌈☁❄💧🌊🍎🍊🍋🍉🍇🍓🍒🍑🥭🍍🥥🥝🍅🍆🥑🥦🥕🌽🍞🧀🍕🍔🍟🌭🥗🍿🍰🎂🍫🍬🍭🍩🍪☕🍵🥤🎉🎊🎁🎈🏆⚽🏀🎵🎶📱💻⌚📷💡📚✏📌📎✂🔒🔑❤✅❌❓❗⚠🇮🇷"
    ).map(String.init)

    /// Persian layout of Apple's iOS keyboard.
    private static let letterRows: [[String]] = [
        ["ض", "ص", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"],
        ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"],
        ["ظ", "ط", "ژ", "ز", "ر", "ذ", "د", "پ", "و", "ث"],
    ]
    private static let englishRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private static let englishSymbolRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'", "#", "%"],
    ]
    private static let symbolRows: [[String]] = [
        ["۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹", "۰"],
        ["-", "/", ":", "؛", "(", ")", "«", "»", "@", "﷼"],
        ["آ", "ئ", "ء", "أ", ".", "،", "؟", "!"],
    ]

    private var layer = Layer.letters
    /// English QWERTY instead of Persian; switched by swiping left or right on the space bar.
    private static let englishKey = "keyboardEnglish"
    private var isEnglish = UserDefaults.standard.bool(forKey: KeyboardViewController.englishKey) {
        didSet { UserDefaults.standard.set(isEnglish, forKey: Self.englishKey) }
    }
    /// One-shot capital letter in the English layout.
    private var isShifted = false
    private let shiftKey = KeyView(symbol: "shift")
    private var characterKeys: [[KeyView]] = []
    private let statusHeight: CGFloat = 26
    private let backspaceKey = KeyView(symbol: "delete.right")
    private let settingsKey = KeyView(symbol: "gearshape")
    private let emojiKey = KeyView(symbol: "face.smiling")
    private let emojiScroll = UIScrollView()
    private var emojiKeysBuilt = false
    private let layerKey = KeyView(title: "۱۲۳", fontSize: 16)
    private let zwnjKey = KeyView(title: "<|>", fontSize: 17)
    private let spaceKey = KeyView(title: "فاصله", fontSize: 15)
    private let returnKey = KeyView(symbol: "return")
    private var repeatTimer: Timer?

    private func render() {
        let title: String
        let symbol: String
        var tint = UIColor.label
        switch state {
        case .checking:
            title = "در حال اتصال…"; symbol = "mic"
        case .noSession:
            title = "برای شروع جلسه، میکروفون را بزنید (اپ یک بار باز می‌شود)"; symbol = "mic.slash"
        case .ready:
            title = ""; symbol = "mic.fill"
        case .starting:
            title = "…"; symbol = "mic"
        case .recording:
            title = "در حال ضبط، برای پایان میکروفون را بزنید"; symbol = "stop.circle.fill"; tint = .systemRed
        case .transcribing:
            title = "در حال تبدیل به متن… برای لغو، میکروفون را بزنید"; symbol = ""
        }
        statusLabel.text = title
        if state == .transcribing {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        micButton.setImage(symbol.isEmpty ? nil : UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)),
                           for: .normal)
        micButton.tintColor = tint
        micButton.isEnabled = state != .starting
    }

    private func buildUI() {
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.7
        view.addSubview(statusLabel)

        micButton.backgroundColor = .clear
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        view.addSubview(micButton)
        spinner.hidesWhenStopped = true
        spinner.color = .label
        spinner.isUserInteractionEnabled = false
        view.addSubview(spinner)

        // Symbols keep the same direction on every device, whatever the host app's language.
        view.semanticContentAttribute = .forceRightToLeft

        emojiScroll.backgroundColor = .clear
        emojiScroll.showsVerticalScrollIndicator = false
        emojiScroll.isHidden = true
        view.addSubview(emojiScroll)

        backspaceKey.addTarget(self, action: #selector(backspaceDown), for: .touchDown)
        backspaceKey.addTarget(self, action: #selector(backspaceUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        layerKey.addTarget(self, action: #selector(toggleLayer), for: .touchUpInside)
        emojiKey.addTarget(self, action: #selector(toggleEmoji), for: .touchUpInside)
        settingsKey.addAction(UIAction { [weak self] _ in
            self?.open(DictationBridge.settingsURL)
        }, for: .touchUpInside)
        zwnjKey.addTarget(self, action: #selector(insertZWNJ), for: .touchUpInside)
        spaceKey.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
        spaceKey.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(spaceSwiped(_:))))
        shiftKey.addTarget(self, action: #selector(toggleShift), for: .touchUpInside)
        view.addSubview(shiftKey)
        returnKey.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        for key in [backspaceKey, layerKey, settingsKey, emojiKey, zwnjKey, spaceKey, returnKey] {
            view.addSubview(key)
        }
        buildCharacterKeys()

        let height = view.heightAnchor.constraint(equalToConstant: 262)
        height.priority = .defaultHigh
        height.isActive = true
        render()
    }

    private func buildCharacterKeys() {
        characterKeys.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        let rows: [[String]]
        switch layer {
        case .letters: rows = isEnglish ? Self.englishRows : Self.letterRows
        case .symbols: rows = isEnglish ? Self.englishSymbolRows : Self.symbolRows
        case .emoji:
            rows = []
            buildEmojiKeysIfNeeded()
        }
        emojiScroll.isHidden = layer != .emoji
        characterKeys = rows.map { row in
            row.map { character in
                let key = KeyView(title: character, fontSize: 23)
                key.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.textDocumentProxy.insertText(self.isShifted ? character.uppercased() : character)
                    if self.isShifted { self.setShifted(false) }
                }, for: .touchUpInside)
                key.apply(keyStyle)
                view.addSubview(key)
                return key
            }
        }
        if isEnglish {
            layerKey.title = layer == .symbols ? "ABC" : "123"
            spaceKey.title = "space"
        } else {
            layerKey.title = layer == .symbols ? "الفبا" : "۱۲۳"
            spaceKey.title = "فاصله"
        }
        shiftKey.isHidden = !(isEnglish && layer == .letters)
        setShifted(false)
        emojiKey.symbol = layer == .emoji ? "keyboard" : "face.smiling"
        view.setNeedsLayout()
    }

    private var keyStyle = KeyStyle.standard

    private func applyKeyStyle(_ style: KeyStyle) {
        keyStyle = style
        let functionKeys = [backspaceKey, layerKey, settingsKey, emojiKey, zwnjKey, spaceKey, returnKey, shiftKey]
        for key in functionKeys + characterKeys.flatMap({ $0 }) {
            key.apply(style)
        }
    }

    private func setShifted(_ shifted: Bool) {
        isShifted = shifted
        shiftKey.symbol = shifted ? "shift.fill" : "shift"
        guard isEnglish, layer == .letters else { return }
        for key in characterKeys.flatMap({ $0 }) {
            key.title = shifted ? key.title?.uppercased() : key.title?.lowercased()
        }
    }

    @objc private func toggleShift() {
        setShifted(!isShifted)
    }

    /// A horizontal swipe on the space bar switches between Persian and English, like SwiftKey.
    @objc private func spaceSwiped(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, abs(pan.translation(in: view).x) > 40 else { return }
        isEnglish.toggle()
        if layer == .emoji { layer = .letters }
        buildCharacterKeys()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The ~250 emoji keys are created the first time the panel opens, not when the keyboard
    /// loads, so switching to this keyboard stays as quick as switching to the system ones.
    private func buildEmojiKeysIfNeeded() {
        guard !emojiKeysBuilt else { return }
        emojiKeysBuilt = true
        for emoji in Self.emojis {
            let key = KeyView(title: emoji, fontSize: 28)
            key.addAction(UIAction { [weak self] _ in
                self?.textDocumentProxy.insertText(emoji)
            }, for: .touchUpInside)
            emojiScroll.addSubview(key)
        }
    }

    /// Keys are laid out on a grid of 12 columns, like the system keyboard. Each key's frame
    /// covers its whole cell so there are no dead zones between keys.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let unit = bounds.width / 12
        let rowHeight = (bounds.height - statusHeight - 4) / 4
        statusLabel.frame = CGRect(x: 12, y: 0, width: bounds.width - 24, height: statusHeight)

        let backspaceY = statusHeight + 2 * rowHeight
        backspaceKey.frame = CGRect(x: bounds.width - 1.5 * unit, y: backspaceY, width: 1.5 * unit, height: rowHeight)

        // Emoji grid: fills the three key rows, minus the backspace column.
        emojiScroll.frame = CGRect(x: 0, y: statusHeight, width: bounds.width - 1.5 * unit, height: 3 * rowHeight)
        let columns = 8
        let cell = emojiScroll.frame.width / CGFloat(columns)
        for (index, key) in emojiScroll.subviews.compactMap({ $0 as? KeyView }).enumerated() {
            key.frame = CGRect(x: CGFloat(index % columns) * cell, y: CGFloat(index / columns) * rowHeight,
                               width: cell, height: rowHeight)
        }
        let emojiRows = (Self.emojis.count + columns - 1) / columns
        emojiScroll.contentSize = CGSize(width: emojiScroll.frame.width, height: CGFloat(emojiRows) * rowHeight)

        // In English the shift key takes the left end of the third row, mirroring backspace.
        shiftKey.frame = CGRect(x: 0, y: backspaceY, width: 1.5 * unit, height: rowHeight)
        let shiftWidth = shiftKey.isHidden ? 0 : 1.5 * unit
        for (index, row) in characterKeys.enumerated() {
            let y = statusHeight + CGFloat(index) * rowHeight
            let isLast = index == characterKeys.count - 1
            let start = isLast ? shiftWidth : 0
            let available = isLast ? bounds.width - 1.5 * unit - shiftWidth : bounds.width
            let keyWidth = min(unit, available / CGFloat(row.count))
            var x = start + (available - keyWidth * CGFloat(row.count)) / 2
            for key in row {
                key.frame = CGRect(x: x, y: y, width: keyWidth, height: rowHeight)
                x += keyWidth
            }
        }

        // Bottom row, left to right: 123, settings, emoji, ZWNJ, space, return, mic in the corner.
        let y = statusHeight + 3 * rowHeight
        var x: CGFloat = 0
        func place(_ view: UIView, _ width: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: width, height: rowHeight)
            x += width
        }
        let fixed = 1.5 * unit + 3 * 1.25 * unit + 1.75 * unit + 1.5 * unit
        place(layerKey, 1.5 * unit)
        place(settingsKey, 1.25 * unit)
        place(emojiKey, 1.25 * unit)
        place(zwnjKey, 1.25 * unit)
        place(spaceKey, bounds.width - fixed)
        place(returnKey, 1.75 * unit)
        place(micButton, 1.5 * unit)
        spinner.center = CGPoint(x: micButton.frame.midX, y: micButton.frame.midY)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        view.setNeedsLayout()
    }

    @objc private func toggleLayer() {
        layer = layer == .symbols ? .letters : .symbols
        buildCharacterKeys()
    }

    @objc private func toggleEmoji() {
        layer = layer == .emoji ? .letters : .emoji
        buildCharacterKeys()
    }

    @objc private func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    /// Zero-width non-joiner (نیم‌فاصله), as in می‌شود.
    @objc private func insertZWNJ() {
        textDocumentProxy.insertText("\u{200C}")
    }

    @objc private func insertReturn() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func backspaceDown() {
        textDocumentProxy.deleteBackward()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.textDocumentProxy.deleteBackward() }
                }
            }
        }
    }

    @objc private func backspaceUp() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// A key with an optional background and outline (see `KeyStyle`) and a faint highlight
/// while pressed. Emoji keys keep no background.
private final class KeyView: UIControl {
    private let face = UIView()
    private let label = UILabel()
    private let imageView = UIImageView()
    private let highlight = UIView()

    var title: String? {
        get { label.text }
        set { label.text = newValue }
    }

    var symbol: String? {
        didSet {
            imageView.image = symbol.flatMap {
                UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
            }
        }
    }

    init(title: String? = nil, symbol: String? = nil, fontSize: CGFloat = 20) {
        super.init(frame: .zero)
        backgroundColor = .clear
        face.layer.cornerRadius = 6
        face.isUserInteractionEnabled = false
        addSubview(face)
        highlight.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        highlight.layer.cornerRadius = 6
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        addSubview(highlight)

        label.text = title
        label.font = .systemFont(ofSize: fontSize)
        label.textColor = .label
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)

        imageView.tintColor = .label
        imageView.contentMode = .center
        addSubview(imageView)
        self.symbol = symbol
        imageView.image = symbol.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ style: KeyStyle) {
        face.backgroundColor = style.fill.color
        face.layer.borderColor = style.stroke.color.cgColor
        face.layer.borderWidth = style.stroke.a > 0 ? 1 : 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: 2.5, dy: 4)
        highlight.frame = inner
        face.frame = inner
        label.frame = inner.insetBy(dx: 1, dy: 0)
        imageView.frame = inner
    }

    override var isHighlighted: Bool {
        didSet { highlight.alpha = isHighlighted ? 1 : 0 }
    }
}
