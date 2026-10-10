import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "keyboard")

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
    private let micButton = UIButton(type: .system)
    /// Holds every key; hidden while dictating, when the keyboard shrinks to `orb`.
    private let keysView = UIView()
    private let orb = DictationOrbView()
    private var heightConstraint: NSLayoutConstraint?
    /// Row height: as low as keys stay possible to hit, lower in landscape.
    private var rowHeight: CGFloat { isLandscape ? 30 : 36 }
    /// The suggestion bar above the keys.
    private var barHeight: CGFloat { isLandscape ? 26 : 30 }
    private var fullHeight: CGFloat { barHeight + 4 * rowHeight + 2 }
    private var compactHeight: CGFloat { isLandscape ? 120 : 150 }
    private var isLandscape: Bool { UIScreen.main.bounds.width > UIScreen.main.bounds.height }
    private var messageTimer: Timer?
    private var recordingStart = Date()
    private var isCompact = false
    private var timeout: DispatchWorkItem?
    private var previewTimer: Timer?
    private var previewIndex = 0
    /// Provisional text typed during live transcription; replaced by later results.
    private var liveText = ""
    /// A space put before dictated text that would otherwise join the word before the cursor.
    private var livePrefix = ""
    /// Follows the user's edits of dictated text, to report them as corrections for training.
    private var edits = EditTracker()
    private var editsTimer: Timer?
    /// Seconds without typing after which edits are reported even if the keyboard stays open.
    var reportDelay: TimeInterval = 300

    /// Screenshot support when the keyboard is shown inside the app: fixes the displayed
    /// state ("noSession", "ready", "recording", "transcribing", or "cycle" for all of them).
    var previewState: String?
    /// The simulator test hosts the keyboard inside the app, where it types into this instead.
    var testProxy: UITextDocumentProxy?
    private var proxy: UITextDocumentProxy { testProxy ?? textDocumentProxy }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        observer.observe(DictationBridge.alive) { [weak self] in
            MainActor.assumeIsolated { self?.sessionIsAlive() }
        }
        observer.observe(DictationBridge.recording) { [weak self] in
            MainActor.assumeIsolated { self?.recordingStarted() }
        }
        observer.observe(DictationBridge.partial) { [weak self] in
            MainActor.assumeIsolated { self?.fetchTranscript() }
        }
        observer.observe(DictationBridge.progress) { [weak self] in
            MainActor.assumeIsolated { self?.fetchTranscript() }
        }
        observer.observe(DictationBridge.done) { [weak self] in
            MainActor.assumeIsolated { self?.insertTranscript() }
        }
        observer.observe(DictationBridge.failed) { [weak self] in
            MainActor.assumeIsolated { self?.transcriptionFailed() }
        }
        observer.observe(DictationBridge.stopped) { [weak self] in
            MainActor.assumeIsolated { self?.recordingStoppedByApp() }
        }
        observer.observe(DictationBridge.idle) { [weak self] in
            MainActor.assumeIsolated { self?.nobodySpoke() }
        }
        for step in 0..<DictationBridge.levels {
            observer.observe(DictationBridge.level(step)) { [weak self] in
                MainActor.assumeIsolated { self?.orb.setVoiceLevel(step) }
            }
        }
        Lexicon.shared.load { [weak self] in
            MainActor.assumeIsolated { self?.updateSuggestions() }
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishEdits()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if edits.isTracking { report(edits.documentChanged(documentContext)) }
        updateSuggestions()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if edits.isTracking { report(edits.documentChanged(documentContext)) }
        updateSuggestions()
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
        // The simulator test cannot switch on Full Access.
        #if targetEnvironment(simulator)
        let fullAccess = true
        #else
        let fullAccess = hasFullAccess
        #endif
        guard fullAccess else {
            state = .noSession
            showStatus("Allow Full Access را روشن کنید")
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
            DictationBridge.post(DictationBridge.stop)
            beginTranscribing()
        case .noSession, .checking:
            open(DictationBridge.sessionURL)
        case .transcribing:
            // Stop the transcription; the app discards it.
            cancelTimeout()
            DictationBridge.post(DictationBridge.cancel)
            replaceLiveText(with: "")
            state = .ready
            showStatus("لغو شد", transient: true)
        case .starting:
            break
        }
    }

    private func beginTranscribing() {
        state = .transcribing
        // A first guess, until the app's own estimate arrives.
        let recorded = Date().timeIntervalSince(recordingStart)
        orb.liveRing.reset()
        orb.processingRing.begin(expected: min(15, max(2, recorded * 0.4)))
        schedule(after: 90) { [weak self] in
            if self?.state == .transcribing { self?.transcriptionFailed() }
        }
    }

    /// The app ended the recording after the speaker stopped talking.
    private func recordingStoppedByApp() {
        guard state == .recording else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        beginTranscribing()
    }

    /// The app dropped a recording in which nobody spoke.
    private func nobodySpoke() {
        guard state == .recording || state == .transcribing else { return }
        cancelTimeout()
        replaceLiveText(with: "")
        liveText = ""
        state = .ready
        showStatus("صدایی شنیده نشد", transient: true)
    }

    private func recordingStarted() {
        guard state == .starting else { return }
        cancelTimeout()
        recordingStart = Date()
        orb.liveRing.reset()
        orb.resetVoice()
        state = .recording
        liveText = ""
        // As iOS dictation does: a space after a word, none after a space, a bracket or a ZWNJ.
        let last = proxy.documentContextBeforeInput?.unicodeScalars.last
        livePrefix = last.map { $0.properties.isAlphabetic || $0.properties.numericType != nil
            || ".,!?:;)»؟،؛".unicodeScalars.contains($0) } == true ? " " : ""
        edits.dictationStarted(documentContext, prefix: livePrefix)
    }

    private func insertTranscript() {
        guard state == .transcribing else { return }
        cancelTimeout()
        fetchTranscript(final: true)
    }

    /// Reads what the app is serving, oldest message first: a provisional result replaces the
    /// previous one, the final one completes the dictation, estimates drive the rings. `final`
    /// marks the fetch started by `done`.
    private func fetchTranscript(final: Bool = false) {
        TranscriptClient.fetch { [weak self] batch in
            guard let self else { return }
            let messages = batch.map { $0.split(separator: DictationBridge.separator).map(String.init) } ?? []
            for message in messages { self.handle(message) }
            guard final, self.state == .transcribing else { return }
            // An earlier fetch may have taken the final text and not be handled yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if self?.state == .transcribing { self?.transcriptionFailed() }
            }
        }
    }

    private func handle(_ message: String) {
        guard state == .recording || state == .transcribing, let kind = message.first.map(String.init) else { return }
        let body = String(message.dropFirst())
        switch kind {
        case DictationBridge.finalPrefix where !body.isEmpty:
            // Dictation id + newline + text.
            let parts = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let text = String(parts.last ?? "")
            replaceLiveText(with: text)
            liveText = ""
            if parts.count == 2, !text.isEmpty {
                report(edits.dictationFinished(id: String(parts[0]), text: text))
                log.info("following dictation \(parts[0], privacy: .public) for edits")
            }
            cancelTimeout()
            state = .ready
        case DictationBridge.partialPrefix:
            // Empty after a live pass that found nothing new.
            if !body.isEmpty { replaceLiveText(with: body) }
            if state == .recording { orb.liveTextArrived() }
        case DictationBridge.livePrefix:
            guard state == .recording, let seconds = Double(body) else { return }
            orb.liveProgress(expected: seconds)
        case DictationBridge.estimatePrefix:
            guard state == .transcribing, let seconds = Double(body) else { return }
            orb.processingRing.retarget(expected: seconds)
            // Only a safety net for an app that died: a slow pass must still be able to finish.
            schedule(after: max(90, 3 * seconds + 30)) { [weak self] in
                if self?.state == .transcribing { self?.transcriptionFailed() }
            }
        default:
            break
        }
    }

    /// Swaps the provisional text for `text`, deleting only the part that changed.
    private func replaceLiveText(with text: String) {
        let target = text.isEmpty ? "" : livePrefix + text
        // Characters compare equal across Unicode normalizations; the typed text must match exactly.
        let common = zip(liveText, target).prefix { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }.count
        for _ in 0..<(liveText.count - common) { deleteBackward() }
        insert(String(target.dropFirst(common)), dictated: true)
        liveText = target
    }

    // MARK: - Editing

    private var documentContext: DocumentContext {
        DocumentContext(before: proxy.documentContextBeforeInput ?? "", selected: proxy.selectedText ?? "",
                        after: proxy.documentContextAfterInput ?? "")
    }

    /// Every change the keyboard makes goes through here and `deleteBackward`, so edits of
    /// dictated text can be followed.
    private func insert(_ text: String, dictated: Bool = false) {
        guard !text.isEmpty else { return }
        if edits.isTracking { report(edits.willEdit(dictated ? .dictate(text) : .type(text), in: documentContext)) }
        proxy.insertText(text)
        if !dictated { updateSuggestions() }
    }

    private func deleteBackward() {
        if edits.isTracking { report(edits.willEdit(.deleteBackward, in: documentContext)) }
        proxy.deleteBackward()
        if state != .recording && state != .transcribing { updateSuggestions() }
    }

    /// Sends finished corrections to the app, and restarts the wait for the user to stop editing.
    private func report(_ corrections: [Correction]) {
        for correction in corrections {
            log.info("sending correction for \(correction.id, privacy: .public)")
            correction.send()
        }
        editsTimer?.invalidate()
        editsTimer = nil
        guard edits.isTracking else { return }
        editsTimer = Timer.scheduledTimer(withTimeInterval: reportDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishEdits() }
        }
    }

    private func finishEdits() {
        editsTimer?.invalidate()
        editsTimer = nil
        guard edits.isTracking else { return }
        log.info("edits finished")
        report(edits.finishAll())
    }

    private func transcriptionFailed() {
        guard state == .transcribing else { return }
        cancelTimeout()
        liveText = ""
        state = .ready
        showStatus("متنی تشخیص داده نشد", transient: true)
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
        showStatus("اپ را باز کنید و جلسه را شروع کنید")
    }

    /// Messages show on the space bar, so the keyboard needs no status row. A transient one
    /// disappears after a few seconds.
    private func showStatus(_ text: String?, transient: Bool = false) {
        messageTimer?.invalidate()
        messageTimer = nil
        spaceKey.message = text
        guard transient, text != nil else { return }
        messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceKey.message = nil }
        }
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

    /// Every key has the same width except space, and the keys fill the whole width. A layer
    /// has `columns` keys per row: Persian 11, English 10. The third row ends with backspace
    /// (and in English letters starts with shift), so it has one or two letters fewer.
    /// Persian layout of Apple's iOS keyboard.
    private static let letterRows: [[String]] = [
        ["ض", "ص", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"],
        ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"],
        ["ظ", "ط", "ژ", "ز", "ر", "ذ", "د", "پ", "و", "ث"],
    ]
    private static let symbolRows: [[String]] = [
        ["۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹", "۰", "٪"],
        ["-", "/", ":", "؛", "(", ")", "«", "»", "@", "﷼", "\""],
        ["آ", "ئ", "ء", "أ", "ؤ", "ة", ".", "،", "؟", "!"],
    ]
    private static let englishRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l", "'"],
        ["z", "x", "c", "v", "b", "n", "m", ","],
    ]
    private static let englishSymbolRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'", "#", "%", "*", "+"],
    ]
    private var columns: Int { isEnglish ? 10 : 11 }

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
    private let backspaceKey = KeyView(symbol: "delete.right")
    /// Emoji panel on a tap; a menu with the emoji panel and the app's settings on a long press.
    private let emojiKey = KeyView()
    private let keyMenu = KeyMenuView()
    /// Covers the keys while the menu stays open, and closes it when touched.
    private let menuShield = UIControl()
    private let emojiScroll = UIScrollView()
    private var emojiKeysBuilt = false
    private let layerKey = KeyView(title: "۱۲۳", fontSize: 16)
    private let zwnjKey = KeyView()
    /// No label: arrows around a globe show that swiping it changes the language.
    private let spaceKey = KeyView()
    private let periodKey = KeyView(title: ".", fontSize: 23)
    private let returnKey = KeyView(symbol: "return")
    private var repeatTimer: Timer?
    private let suggestionBar = SuggestionBar()
    private let glideTrail = GlideTrailView()
    private lazy var glidePan = UIPanGestureRecognizer(target: self, action: #selector(glided(_:)))
    private var glidePath: [CGPoint] = []
    /// The last glided word while it is still the text before the cursor: one backspace deletes
    /// it, and the bar offers the other readings of the glide in its place.
    private var lastGlide: (word: String, inserted: String, alternatives: [String])?

    private func render() {
        let title: String
        let symbol: String
        var tint = keyStyle.textColor
        switch state {
        case .checking:
            title = ""; symbol = "mic"
        case .noSession:
            title = "برای شروع جلسه، میکروفون را بزنید"; symbol = "mic.slash"
        case .ready:
            title = ""; symbol = "mic.fill"
        case .starting:
            title = ""; symbol = "mic"
        case .recording:
            title = ""; symbol = "mic.fill"; tint = .systemRed
        case .transcribing:
            title = ""; symbol = "mic.fill"
        }
        showStatus(title.isEmpty ? nil : title)
        updateSuggestions()
        micButton.setImage(UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)),
                           for: .normal)
        micButton.tintColor = tint
        micButton.isEnabled = state != .starting

        switch state {
        case .starting: orb.mode = .starting
        case .recording: orb.mode = .recording
        case .transcribing: orb.mode = .processing
        default: break
        }
        setCompact(state == .starting || state == .recording || state == .transcribing)
    }

    /// While dictating, the keys fade out and the keyboard shrinks to the orb with the mic.
    private func setCompact(_ compact: Bool) {
        guard isCompact != compact else { return }
        isCompact = compact
        heightConstraint?.constant = compact ? compactHeight : fullHeight
        if compact {
            orb.alpha = 0
            orb.isHidden = false
        } else {
            keysView.alpha = 0
            keysView.isHidden = false
        }
        UIView.animate(withDuration: 0.22, animations: {
            self.keysView.alpha = compact ? 0 : 1
            self.orb.alpha = compact ? 1 : 0
            self.view.superview?.layoutIfNeeded()
        }, completion: { _ in
            // A later state change may have reversed this one while it animated.
            self.keysView.isHidden = self.isCompact
            self.orb.isHidden = !self.isCompact
        })
    }

    private func buildUI() {
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear

        view.addSubview(keysView)

        micButton.backgroundColor = .clear
        micButton.accessibilityIdentifier = "dictationMic"
        micButton.accessibilityLabel = "Persian dictation"
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        keysView.addSubview(micButton)

        orb.isHidden = true
        // The simulator renders animations on the CPU, which slowed transcription in the test tenfold.
        orb.animates = testProxy == nil
        orb.accessibilityIdentifier = "dictationOrb"
        orb.isAccessibilityElement = true
        orb.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        view.addSubview(orb)

        // Symbols keep the same direction on every device, whatever the host app's language.
        view.semanticContentAttribute = .forceRightToLeft

        emojiScroll.backgroundColor = .clear
        emojiScroll.showsVerticalScrollIndicator = false
        emojiScroll.isHidden = true
        keysView.addSubview(emojiScroll)

        backspaceKey.accessibilityIdentifier = "backspaceKey"
        backspaceKey.addTarget(self, action: #selector(backspaceDown), for: .touchDown)
        backspaceKey.addTarget(self, action: #selector(backspaceUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        layerKey.addTarget(self, action: #selector(toggleLayer), for: .touchUpInside)
        emojiKey.accessibilityIdentifier = "emojiKey"
        emojiKey.addTarget(self, action: #selector(toggleEmoji), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(emojiPressed(_:)))
        press.minimumPressDuration = 0.35
        emojiKey.addGestureRecognizer(press)
        zwnjKey.image = KeyIcons.zwnj
        zwnjKey.accessibilityLabel = "نیم‌فاصله"
        zwnjKey.addTarget(self, action: #selector(insertZWNJ), for: .touchUpInside)
        spaceKey.image = KeyIcons.space
        spaceKey.dimsImage = true
        spaceKey.accessibilityIdentifier = "spaceKey"
        spaceKey.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
        spaceKey.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(spaceSwiped(_:))))
        periodKey.addTarget(self, action: #selector(insertPeriod), for: .touchUpInside)
        shiftKey.addTarget(self, action: #selector(toggleShift), for: .touchUpInside)
        keysView.addSubview(shiftKey)
        returnKey.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        for key in [backspaceKey, layerKey, emojiKey, zwnjKey, spaceKey, periodKey, returnKey] {
            keysView.addSubview(key)
        }
        suggestionBar.onPick = { [weak self] item in self?.pick(item) }
        keysView.addSubview(suggestionBar)
        buildCharacterKeys()

        glideTrail.color = .systemBlue
        keysView.addSubview(glideTrail)
        glidePan.maximumNumberOfTouches = 1
        glidePan.delegate = self
        keysView.addGestureRecognizer(glidePan)

        keyMenu.items = [
            KeyMenuView.Item(title: "شکلک", symbol: "face.smiling") { [weak self] in self?.toggleEmoji() },
            KeyMenuView.Item(title: "تنظیمات", symbol: "gearshape") { [weak self] in
                self?.open(DictationBridge.settingsURL)
            },
        ]
        keyMenu.onSelect = { [weak self] item in
            self?.closeMenu()
            item.action()
        }
        keyMenu.isHidden = true
        menuShield.isHidden = true
        menuShield.addTarget(self, action: #selector(closeMenu), for: .touchDown)
        keysView.addSubview(menuShield)
        keysView.addSubview(keyMenu)

        let height = view.heightAnchor.constraint(equalToConstant: fullHeight)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
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
        characterKeys = rows.enumerated().map { rowIndex, row in
            row.enumerated().map { column, character in
                let key = KeyView(title: character, fontSize: 23)
                key.accessibilityIdentifier = "letter-\(rowIndex)-\(column)"
                key.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    self.insert(self.isShifted ? character.uppercased() : character)
                    if self.isShifted { self.setShifted(false) }
                }, for: .touchUpInside)
                key.apply(keyStyle)
                keysView.addSubview(key)
                return key
            }
        }
        layerKey.title = isEnglish ? (layer == .symbols ? "ABC" : "123") : (layer == .symbols ? "الفبا" : "۱۲۳")
        // English has no ZWNJ; space takes its place.
        zwnjKey.isHidden = isEnglish
        shiftKey.isHidden = !(isEnglish && layer == .letters)
        setShifted(false)
        emojiKey.image = KeyIcons.menuKey(symbol: layer == .emoji ? "keyboard" : "face.smiling")
        emojiKey.accessibilityLabel = layer == .emoji ? "حروف" : "شکلک"
        lastGlide = nil
        updateSuggestions()
        view.setNeedsLayout()
    }

    private var keyStyle = KeyStyle.standard

    private func applyKeyStyle(_ style: KeyStyle) {
        keyStyle = style
        let functionKeys = [backspaceKey, layerKey, emojiKey, zwnjKey, spaceKey, periodKey, returnKey, shiftKey]
        for key in functionKeys + characterKeys.flatMap({ $0 }) {
            key.apply(style)
        }
        suggestionBar.textColor = style.textColor
        render()
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
                self?.insert(emoji)
            }, for: .touchUpInside)
            emojiScroll.addSubview(key)
        }
    }

    /// Keys sit on a grid of `columns` equal cells across the whole width (inside the safe area,
    /// which is only non-zero beside the notch in landscape), under the suggestion bar. Each
    /// key's frame covers its whole cell so there are no dead zones between keys.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !isCompact, let height = heightConstraint, height.constant != fullHeight {
            height.constant = fullHeight
        }
        orb.frame = view.bounds
        // Keys keep the full-height layout while hidden, so they do not squeeze during the animation.
        let height = max(view.bounds.height, fullHeight)
        keysView.frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        glideTrail.frame = keysView.bounds
        menuShield.frame = keysView.bounds
        let insets = view.safeAreaInsets
        let left = insets.left
        let width = view.bounds.width - insets.left - insets.right
        let bar = barHeight
        suggestionBar.frame = CGRect(x: left, y: 0, width: width, height: bar)
        let row = (height - bar - 2) / 4
        let unit = width / CGFloat(columns)
        let top = bar

        let thirdY = top + 2 * row
        backspaceKey.frame = CGRect(x: left + width - unit, y: thirdY, width: unit, height: row)
        shiftKey.frame = CGRect(x: left, y: thirdY, width: unit, height: row)

        // Emoji grid: fills the three key rows, minus the backspace column.
        emojiScroll.frame = CGRect(x: left, y: top, width: width - unit, height: 3 * row)
        let emojiColumns = isLandscape ? 14 : 8
        let cell = emojiScroll.frame.width / CGFloat(emojiColumns)
        for (index, key) in emojiScroll.subviews.compactMap({ $0 as? KeyView }).enumerated() {
            key.frame = CGRect(x: CGFloat(index % emojiColumns) * cell, y: CGFloat(index / emojiColumns) * row,
                               width: cell, height: row)
        }
        let emojiRows = (Self.emojis.count + emojiColumns - 1) / emojiColumns
        emojiScroll.contentSize = CGSize(width: emojiScroll.frame.width, height: CGFloat(emojiRows) * row)

        for (index, keys) in characterKeys.enumerated() {
            let y = top + CGFloat(index) * row
            var x = left + (index == 2 && !shiftKey.isHidden ? unit : 0)
            for key in keys {
                key.frame = CGRect(x: x, y: y, width: unit, height: row)
                x += unit
            }
        }

        // Bottom row, left to right: 123, emoji (and settings), ZWNJ (Persian only), space, full
        // stop, return, mic.
        let y = top + 3 * row
        var x = left
        func place(_ view: UIView, _ keyWidth: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: keyWidth, height: row)
            x += keyWidth
        }
        place(layerKey, unit)
        place(emojiKey, unit)
        if !isEnglish { place(zwnjKey, unit) }
        place(spaceKey, width - CGFloat(isEnglish ? 5 : 6) * unit)
        place(periodKey, unit)
        place(returnKey, unit)
        place(micButton, unit)
        if !keyMenu.isHidden { placeMenu() }
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
        learnCurrentWord()
        insert(" ")
    }

    /// Zero-width non-joiner (نیم‌فاصله), as in می‌شود.
    @objc private func insertZWNJ() {
        insert("\u{200C}")
    }

    @objc private func insertPeriod() {
        learnCurrentWord()
        insert(".")
    }

    @objc private func insertReturn() {
        learnCurrentWord()
        insert("\n")
    }

    @objc private func backspaceDown() {
        if let glide = lastGlide, (proxy.documentContextBeforeInput ?? "").hasSuffix(glide.inserted) {
            lastGlide = nil
            for _ in 0..<glide.inserted.count { deleteBackward() }
        } else {
            deleteBackward()
        }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.deleteBackward() }
                }
            }
        }
    }

    @objc private func backspaceUp() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Suggestions

    /// The Persian word the cursor is at the end of (letters and ZWNJ).
    private func currentWord() -> String {
        guard let before = proxy.documentContextBeforeInput else { return "" }
        var start = before.endIndex
        while start > before.startIndex {
            let previous = before.index(before: start)
            guard Lexicon.isPersianWord(before[previous..<start]) else { break }
            start = previous
        }
        return String(before[start...])
    }

    /// A typed word counts towards the user's own words, and new ones are learned.
    private func learnCurrentWord() {
        guard !isEnglish, layer == .letters else { return }
        let word = currentWord()
        if !word.isEmpty { Lexicon.shared.learn(word) }
    }

    /// Fills the bar, read right to left: the word as typed in quotes when the list does not
    /// know it (picking it teaches it), the best completion in the middle, then the next ones.
    /// After a glide, the glided word sits in the middle with its other readings beside it.
    private func updateSuggestions() {
        guard isViewLoaded else { return }
        guard layer == .letters, !isEnglish, state != .recording, state != .transcribing, state != .starting else {
            suggestionBar.show([nil, nil, nil])
            return
        }
        if let glide = lastGlide {
            if (proxy.documentContextBeforeInput ?? "").hasSuffix(glide.inserted) {
                let others = glide.alternatives.map { SuggestionBar.Item(text: $0, replacesGlide: true) }
                suggestionBar.show([others.first, SuggestionBar.Item(text: glide.word, replacesGlide: true),
                                    others.dropFirst().first])
                return
            }
            lastGlide = nil
        }
        let word = currentWord()
        guard !word.isEmpty, Lexicon.shared.isLoaded else {
            suggestionBar.show([nil, nil, nil])
            return
        }
        let words = Lexicon.shared.completions(for: word, limit: 3).map { SuggestionBar.Item(text: $0) }
        if word.count >= 2, !Lexicon.shared.isKnown(word) {
            suggestionBar.show([SuggestionBar.Item(text: word, literal: true), words.first, words.dropFirst().first])
        } else {
            suggestionBar.show([words.dropFirst().first, words.first, words.dropFirst(2).first])
        }
    }

    private func pick(_ item: SuggestionBar.Item) {
        if item.replacesGlide, let glide = lastGlide, item.text == glide.word {
            lastGlide = nil
            insert(" ")
            return
        }
        if item.replacesGlide, let glide = lastGlide {
            for _ in 0..<glide.word.count { deleteBackward() }
            let prefix = String(glide.inserted.dropLast(glide.word.count))
            let others = ([glide.word] + glide.alternatives).filter { $0 != item.text }
            lastGlide = (item.text, prefix + item.text, others)
            insert(item.text)
            Lexicon.shared.learn(item.text)
            return
        }
        let word = currentWord()
        lastGlide = nil
        for _ in 0..<word.count { deleteBackward() }
        Lexicon.shared.learn(item.text, confirmed: item.literal)
        insert(item.text + " ")
    }

    // MARK: - Glide typing

    /// The letter keys of the Persian letters layer, by letter.
    private func letterCenters() -> [Character: CGPoint] {
        var centers: [Character: CGPoint] = [:]
        for key in characterKeys.flatMap({ $0 }) {
            if let title = key.title, title.count == 1, let letter = title.first {
                centers[letter] = CGPoint(x: key.frame.midX, y: key.frame.midY)
            }
        }
        return centers
    }

    private func letterKey(at point: CGPoint) -> KeyView? {
        characterKeys.flatMap { $0 }.first { $0.frame.contains(point) }
    }

    private var keyWidth: CGFloat { characterKeys.first?.first?.frame.width ?? 30 }

    @objc private func glided(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: keysView)
        switch pan.state {
        case .began:
            let moved = pan.translation(in: keysView)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            glidePath = [start, point]
            keysView.bringSubviewToFront(glideTrail)
            glideTrail.begin(at: start)
            glideTrail.add(point)
        case .changed:
            glidePath.append(point)
            glideTrail.add(point)
        case .ended:
            glideTrail.end()
            finishGlide()
        default:
            glideTrail.end()
            glidePath = []
        }
    }

    /// Types the word the glide spelled, with a space before it after a word, as Gboard does;
    /// the next best readings go to the bar. A short slide is a tap on the key it started on.
    private func finishGlide() {
        let path = glidePath
        glidePath = []
        guard let start = path.first else { return }
        guard GlideDecoder.length(path) >= 1.2 * keyWidth else {
            if let title = letterKey(at: start)?.title { insert(title) }
            return
        }
        let words = GlideDecoder.decode(path, keys: letterCenters(), unit: keyWidth)
        guard let word = words.first else { return }
        let last = proxy.documentContextBeforeInput?.unicodeScalars.last
        let prefix = last.map { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{200C}" } == true ? " " : ""
        lastGlide = (word, prefix + word, Array(words.dropFirst()))
        insert(prefix + word)
        Lexicon.shared.learn(word)
        log.info("glide: \(words.count) readings")
    }

    // MARK: - Emoji key menu

    @objc private func emojiPressed(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            showMenu()
        case .changed:
            keyMenu.highlight(at: press.location(in: keyMenu))
        case .ended:
            keyMenu.highlight(at: press.location(in: keyMenu))
            // Released on an item: that item. Elsewhere: the menu stays open for a tap.
            if let item = keyMenu.highlightedItem {
                closeMenu()
                item.action()
            }
        case .cancelled, .failed:
            closeMenu()
        default:
            break
        }
    }

    private func showMenu() {
        keyMenu.highlight(at: nil)
        keyMenu.textColor = keyStyle.textColor
        placeMenu()
        keysView.bringSubviewToFront(menuShield)
        keysView.bringSubviewToFront(keyMenu)
        menuShield.isHidden = false
        keyMenu.isHidden = false
        keyMenu.alpha = 0
        keyMenu.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.15) {
            self.keyMenu.alpha = 1
            self.keyMenu.transform = .identity
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Above the emoji key, inside the keyboard: an extension cannot draw outside its view.
    private func placeMenu() {
        let size = keyMenu.preferredSize
        let key = emojiKey.frame
        let x = min(max(4, key.minX), keysView.bounds.width - size.width - 4)
        let y = max(2, key.minY - size.height - 2)
        keyMenu.bounds = CGRect(origin: .zero, size: size)
        keyMenu.center = CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }

    @objc private func closeMenu() {
        menuShield.isHidden = true
        keyMenu.isHidden = true
    }
}

extension KeyboardViewController: UIGestureRecognizerDelegate {
    /// Glides start on a letter key of the Persian letters layer.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === glidePan else { return true }
        guard layer == .letters, !isEnglish, !isCompact, keyMenu.isHidden, Lexicon.shared.isLoaded else { return false }
        let point = glidePan.location(in: keysView)
        let moved = glidePan.translation(in: keysView)
        return letterKey(at: CGPoint(x: point.x - moved.x, y: point.y - moved.y)) != nil
    }
}

/// A key with an optional background and outline (see `KeyStyle`) and a faint highlight
/// while pressed. Emoji keys keep no background.
private final class KeyView: UIControl {
    private let face = UIView()
    private let label = UILabel()
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

    private func updateLabel() {
        if let message {
            label.text = message
            label.font = AppFont.font(ofSize: 12)
            label.textColor = textColor.withAlphaComponent(0.6)
        } else {
            label.text = storedTitle
            label.font = AppFont.font(ofSize: fontSize)
            label.textColor = textColor
        }
        imageView.isHidden = message != nil
        if message != nil || storedTitle != nil { accessibilityLabel = message ?? storedTitle }
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

    /// Draws the image faintly, as a hint rather than a label.
    var dimsImage = false {
        didSet { imageView.alpha = dimsImage ? 0.4 : 1 }
    }

    private let fontSize: CGFloat

    init(title: String? = nil, symbol: String? = nil, fontSize: CGFloat = 20) {
        self.fontSize = fontSize
        storedTitle = title
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        face.layer.cornerRadius = 6
        face.isUserInteractionEnabled = false
        addSubview(face)
        highlight.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        highlight.layer.cornerRadius = 6
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        addSubview(highlight)

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        updateLabel()
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
        textColor = style.textColor
        imageView.tintColor = textColor
        updateLabel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: 2.5, dy: 3)
        highlight.frame = inner
        face.frame = inner
        label.frame = inner.insetBy(dx: 1, dy: 0)
        imageView.frame = inner
        // Low landscape rows: a tall image shrinks instead of spilling out of the key.
        let size = imageView.image?.size ?? .zero
        imageView.contentMode = size.width > inner.width || size.height > inner.height ? .scaleAspectFit : .center
    }

    override var isHighlighted: Bool {
        didSet { highlight.alpha = isHighlighted ? 1 : 0 }
    }
}

/// A ring that fills towards an estimated end without ever standing still: evenly to 85% at
/// the estimated time, then ever more slowly towards full. A new estimate carries on from where
/// the ring is, and its position is computed rather than read back from Core Animation.
private final class ProgressRing {
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
/// While recording it swells with the speaker's voice and breathes softly in silence, and a
/// teal ring fills until the next piece of live text arrives; after the recording, a blue ring
/// fills while the app transcribes.
/// The whole view is one button: it stops the recording, or cancels the transcription.
private final class DictationOrbView: UIControl {
    enum Mode { case starting, recording, processing }

    var mode = Mode.starting {
        didSet { if mode != oldValue { update() } }
    }

    private let pulse = CALayer()
    private let gradient = CAGradientLayer()
    private let gradientMask = CAShapeLayer()
    /// Live text while speaking.
    let liveRing = ProgressRing(color: .systemTeal, width: 3)
    /// The transcription after the recording.
    let processingRing = ProgressRing(color: .systemBlue, width: 4)
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
            layer.addSublayer(ring.track)
            layer.addSublayer(ring.ring)
        }

        icon.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold))
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
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.height - 64, 112)
        let center = CGPoint(x: bounds.midX, y: (bounds.height - 30) / 2 + 4)
        let orbFrame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulse.bounds = CGRect(origin: .zero, size: orbFrame.size)
        pulse.position = center
        gradient.frame = pulse.bounds
        gradientMask.path = UIBezierPath(ovalIn: pulse.bounds).cgPath
        let ringPath = UIBezierPath(arcCenter: center, radius: diameter / 2 + 8,
                                    startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        liveRing.path = ringPath
        processingRing.path = ringPath
        CATransaction.commit()
        icon.frame = orbFrame
        caption.frame = CGRect(x: 16, y: bounds.height - 30, width: bounds.width - 32, height: 22)
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
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .starting:
            gradient.opacity = 0.5
            setMotion(false)
            liveRing.isHidden = true
            processingRing.isHidden = true
            caption.text = "…"
        case .recording:
            gradient.opacity = 1
            setMotion(true)
            liveRing.isHidden = !liveRing.isRunning
            processingRing.isHidden = true
            caption.text = Self.listeningCaption
        case .processing:
            gradient.opacity = 0.35
            setMotion(false)
            liveRing.isHidden = true
            processingRing.isHidden = false
            caption.text = "در حال تبدیل به متن… برای لغو بزنید"
        }
        CATransaction.commit()
    }

    /// A live pass started, or its estimate changed: `seconds` until its text.
    func liveProgress(expected seconds: Double) {
        if liveRing.isRunning {
            liveRing.retarget(expected: seconds)
        } else {
            liveRing.begin(expected: seconds)
        }
        if mode == .recording { setLiveRingVisible(true) }
    }

    /// The live text arrived: the ring fills and fades until the next pass.
    func liveTextArrived() {
        guard liveRing.isRunning else { return }
        liveRing.finish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.liveRing.isRunning else { return }
            self.setLiveRingVisible(false)
            self.liveRing.reset()
        }
    }

    private func setLiveRingVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveRing.isHidden = !visible
        CATransaction.commit()
    }

    var animates = true
    private static let listeningCaption = "در حال گوش دادن… برای پایان بزنید"
    private var displayLink: CADisplayLink?
    /// Loudness from the app (0 silence to 1 loud), and the smoothed value the orb shows.
    private var voiceTarget: CGFloat = 0
    private var voice: CGFloat = 0
    private var motionStart: CFTimeInterval = 0
    private var heardVoice = false

    /// One of `DictationBridge.levels` loudness steps of the microphone.
    func setVoiceLevel(_ step: Int) {
        // Steps are 4 dB from -55 dB; room noise is below step 3, speech mostly 4 to 8.
        voiceTarget = min(1, max(0, CGFloat(step - 2) / 6))
        if step >= 4 { heardVoice = true }
    }

    func resetVoice() {
        voiceTarget = 0
        voice = 0
        heardVoice = false
        motionStart = CACurrentMediaTime()
    }

    private func setMotion(_ on: Bool) {
        gradient.removeAnimation(forKey: "spin")
        displayLink?.invalidate()
        displayLink = nil
        pulse.setAffineTransform(.identity)
        guard on, animates else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: "spin")
        let link = CADisplayLink(target: self, selector: #selector(stepMotion))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Each frame: rises quickly with the voice and settles slowly, and in silence a slow
    /// breath of a few percent. Before anyone speaks, the caption says nothing is heard.
    @objc private func stepMotion() {
        let now = CACurrentMediaTime()
        voice += (voiceTarget - voice) * (voiceTarget > voice ? 0.4 : 0.08)
        let breath = CGFloat(0.04 * sin(2 * .pi * (now - motionStart) / 2.4))
        let scale = 1 + breath * (1 - voice) + 0.16 * voice
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulse.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
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

/// Images for keys that no SF Symbol fits, drawn as templates so they take the key colour.
private enum KeyIcons {
    /// ZWNJ, as on Gboard: a dotted bar between two small circles.
    static let zwnj: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 22)).image { _ in
        UIColor.black.setStroke()
        let bar = UIBezierPath()
        bar.move(to: CGPoint(x: 15, y: 2.5))
        bar.addLine(to: CGPoint(x: 15, y: 19.5))
        bar.lineWidth = 1.7
        bar.lineCapStyle = .round
        bar.setLineDash([0.1, 3.3], count: 2, phase: 0)
        bar.stroke()
        for x in [7.0, 23.0] {
            let circle = UIBezierPath(ovalIn: CGRect(x: x - 2.8, y: 11 - 2.8, width: 5.6, height: 5.6))
            circle.lineWidth = 1.5
            circle.stroke()
        }
    }.withRenderingMode(.alwaysTemplate)

    /// The space bar: a globe between arrows, for swiping between Persian and English.
    static let space: UIImage = {
        let small = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let globeConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let parts = [UIImage(systemName: "chevron.left", withConfiguration: small),
                     UIImage(systemName: "globe", withConfiguration: globeConfig),
                     UIImage(systemName: "chevron.right", withConfiguration: small)].compactMap { $0 }
        let gap: CGFloat = 7
        let width = parts.reduce(0) { $0 + $1.size.width } + gap * CGFloat(parts.count - 1)
        let height = parts.map(\.size.height).max() ?? 16
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in
            var x: CGFloat = 0
            for part in parts {
                part.withTintColor(.black).draw(at: CGPoint(x: x, y: (height - part.size.height) / 2))
                x += part.size.width + gap
            }
        }.withRenderingMode(.alwaysTemplate)
    }()

    /// A symbol with three dots under it, for a key that also does something on a long press.
    static func menuKey(symbol: String) -> UIImage? {
        guard let icon = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)) else {
            return nil
        }
        let dot: CGFloat = 2.4, gap: CGFloat = 2.6
        let size = CGSize(width: max(icon.size.width, 3 * dot + 2 * gap), height: icon.size.height + 2 + dot)
        return UIGraphicsImageRenderer(size: size).image { _ in
            icon.withTintColor(.black).draw(at: CGPoint(x: (size.width - icon.size.width) / 2, y: 0))
            UIColor.black.setFill()
            let left = (size.width - (3 * dot + 2 * gap)) / 2
            for i in 0..<3 {
                UIBezierPath(ovalIn: CGRect(x: left + CGFloat(i) * (dot + gap), y: size.height - dot,
                                            width: dot, height: dot)).fill()
            }
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// The row of word suggestions above the keys: three slots, read right to left, with thin
/// dividers between them as on the system keyboard.
private final class SuggestionBar: UIView {
    struct Item {
        let text: String
        /// The typed word itself, shown in quotes; picking it teaches it to the lexicon.
        var literal = false
        /// A reading of the last glide, which replaces the glided word.
        var replacesGlide = false
    }

    var onPick: ((Item) -> Void)?
    var textColor = UIColor.label {
        didSet { slots.forEach { $0.setTitleColor(textColor, for: .normal) } }
    }
    private var slots: [UIButton] = []
    private var dividers: [UIView] = []
    /// Right, middle, left.
    private var items: [Item?] = [nil, nil, nil]

    override init(frame: CGRect) {
        super.init(frame: frame)
        for index in 0..<3 {
            let slot = UIButton(type: .custom)
            slot.titleLabel?.font = AppFont.font(ofSize: 16)
            slot.titleLabel?.adjustsFontSizeToFitWidth = true
            slot.titleLabel?.minimumScaleFactor = 0.6
            slot.titleLabel?.lineBreakMode = .byClipping
            slot.setTitleColor(textColor, for: .normal)
            slot.accessibilityIdentifier = "suggestion-\(index)"
            slot.addAction(UIAction { [weak self] _ in
                guard let item = self?.items[index] else { return }
                self?.onPick?(item)
            }, for: .touchUpInside)
            slots.append(slot)
            addSubview(slot)
        }
        for _ in 0..<2 {
            let divider = UIView()
            divider.backgroundColor = UIColor.label.withAlphaComponent(0.18)
            dividers.append(divider)
            addSubview(divider)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Items right to left; nil leaves a slot empty.
    func show(_ items: [Item?]) {
        self.items = (items + [nil, nil, nil]).prefix(3).map { $0 }
        for (slot, item) in zip(slots, self.items) {
            slot.setTitle(item.map { $0.literal ? "«\($0.text)»" : $0.text }, for: .normal)
            slot.isEnabled = item != nil
        }
        let filled = self.items.compactMap { $0 }.count
        dividers.forEach { $0.isHidden = filled < 2 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width / 3
        // Slot 0 is on the right.
        for (index, slot) in slots.enumerated() {
            slot.frame = CGRect(x: bounds.width - CGFloat(index + 1) * width, y: 0, width: width, height: bounds.height)
                .insetBy(dx: 6, dy: 0)
        }
        for (index, divider) in dividers.enumerated() {
            divider.frame = CGRect(x: CGFloat(index + 1) * width - 0.5, y: bounds.height * 0.25,
                                   width: 1, height: bounds.height * 0.5)
        }
    }
}

/// The emoji key's long-press menu: rows with an icon and a label on a blurred card. While the
/// finger is still down the keyboard moves the highlight (`highlight(at:)`); once it is open,
/// a row is chosen with a tap.
private final class KeyMenuView: UIView {
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
        didSet { buildRows() }
    }
    private(set) var highlighted: Int?
    var highlightedItem: Item? { highlighted.map { items[$0] } }
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
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
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)
    }

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
        if index != nil { UISelectionFeedbackGenerator().selectionChanged() }
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
