import AudioToolbox
import Accelerate
import CoreMotion
import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "keyboard")

/// Dictation keyboard: records through the app's background session and types the
/// transcript into the focused text field, so the field never loses focus.
final class KeyboardViewController: UIInputViewController {
    enum State {
        case checking, noSession, ready, starting, recording, transcribing
    }

    /// Live-text notifications from the app in this dictation, for the device log.
    var partialsHeard = 0

    var state = State.checking {
        didSet {
            // A pause belongs to one recording.
            if state != .recording, isPaused {
                isPaused = false
                orb.paused = false
                orb.accessibilityLabel = nil
            }
            render()
            updateTilt()
            if (oldValue == .noSession || oldValue == .checking) != (state == .noSession || state == .checking) {
                updateSpaceImage()
            }
        }
    }

    let observer = DarwinObserver()
    let micButton = UIButton(type: .system)
    /// Holds every key; hidden while dictating, when the keyboard shrinks to `orb`.
    let keysView = KeysView()
    let orb = DictationOrbView()
    /// The picture chosen in the app (`KeyboardBackground`), behind everything.
    let backgroundImageView = UIImageView()
    /// The preset drawn last and the size it was drawn at.
    var drawnBackground: (id: String, size: CGSize)?
    var heightConstraint: NSLayoutConstraint?
    /// The heights of the suggestion bar and the rows, fixed per orientation (`KeyboardMetrics`).
    lazy var portraitMetrics = KeyboardMetrics.saved(landscape: false)
    lazy var landscapeMetrics = KeyboardMetrics.saved(landscape: true)
    var metrics: KeyboardMetrics { isLandscape ? landscapeMetrics : portraitMetrics }
    var rowHeight: CGFloat { metrics.row }
    /// The suggestion bar above the keys, or a thin margin in its place when it is switched off.
    var barHeight: CGFloat {
        guard options.suggestionBar else { return isLandscape ? 2 : 3 }
        return metrics.bar
    }
    /// The optional digits over the letters.
    var numberRowHeight: CGFloat { metrics.numberRow }
    /// No margin under the bottom row: the keys sit as low as the extension can draw.
    var fullHeight: CGFloat {
        handwritingPad != nil ? handwritingHeight : keysHeight
    }
    var keysHeight: CGFloat {
        barHeight + 4 * rowHeight + (options.numberRow ? numberRowHeight : 0) + (emojiSearch != nil ? searchExtraHeight : 0)
    }
    /// The handwriting pad's height, one of three sizes (`KeyboardOptions.handwritingSize`, set
    /// in the app or with the pad's handle): in portrait the keyboard's own height, two rows
    /// more, or four and a half rows more; in landscape a little lower (Rooz, 2026-11-09).
    var handwritingHeight: CGFloat {
        let extra: [CGFloat] = isLandscape ? [0, 1, 2.5] : [0, 2, 4.5]
        let size = max(0, min(2, options.handwritingSize))
        return clampedHandwritingHeight(keysHeight + extra[size] * rowHeight)
    }

    func clampedHandwritingHeight(_ height: CGFloat) -> CGFloat {
        let screen = UIScreen.main.bounds.size
        let tall = isLandscape ? min(screen.width, screen.height) : max(screen.width, screen.height)
        return min(height, max(keysHeight, (tall * 0.75).rounded()))
    }

    /// A new handwriting size from the pad, saved like the settings panel saves.
    func setHandwritingSize(_ size: Int) -> Bool {
        let size = max(0, min(2, size))
        guard size != options.handwritingSize else { return false }
        var new = options
        new.handwritingSize = size
        new.save()
        applyOptions(new)
        return true
    }
    /// The emoji search typed so far, while one is typed on the letters (nil otherwise).
    var emojiSearch: String?
    /// What an emoji search adds over the suggestion bar: the row of emoji found, and enough
    /// for the search field when the bar is switched off.
    var searchExtraHeight: CGFloat {
        return searchResultsHeight + 8 + max(0, 36 - barHeight)
    }
    /// The row of emoji found, under the search field.
    var searchResultsHeight: CGFloat {
        max(32, (EmojiSearchView.resultSize(scale: emojiScale) * 1.5).rounded())
    }
    /// The letters' size over the standard one, for the emoji.
    var emojiScale: CGFloat { letterFontSize / CGFloat(KeyStyle.standardLetterSize) }
    var compactHeight: CGFloat { isLandscape ? 120 : 150 }
    /// The orientation the keyboard was last given, from its own width (it is as wide as the
    /// screen) or from the size it turns to. The screen's bounds are only right when the keyboard
    /// loads: in an extension they keep that orientation after the phone turns (iOS 26 and 27),
    /// so the keyboard kept the height it loaded with (too tall in landscape, too short back in
    /// portrait) until another keyboard was switched to and back.
    var knownLandscape: Bool?
    var isLandscape: Bool {
        knownLandscape ?? (UIScreen.main.bounds.width > UIScreen.main.bounds.height)
    }
    /// The screen's short side, whichever way its bounds are stale.
    var screenShortSide: CGFloat { min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) }

    /// Takes the orientation from a width the keyboard is (or will be) given, and asks for the
    /// height of that orientation when it changed.
    func noteWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        let landscape = width > screenShortSide + 1
        guard landscape != isLandscape || knownLandscape == nil else { return }
        let changed = landscape != isLandscape
        knownLandscape = landscape
        guard changed else { return }
        log.info("orientation \(landscape ? "landscape" : "portrait", privacy: .public) from width \(Int(width))")
        heightConstraint?.constant = isCompact ? compactHeight : fullHeight
        view.setNeedsUpdateConstraints()
        view.setNeedsLayout()
    }
    var messageTimer: Timer?
    /// A finger holds the space bar for dictation, from this height in the keyboard; sliding it
    /// up `lockDistance` locks the recording, which then goes on after the finger is lifted
    /// until the orb is tapped (as voice messages in Telegram).
    var isHeld = false
    var holdStartY: CGFloat = 0
    var isLocked = false
    static let lockDistance: CGFloat = 60
    /// The recording was started by holding the space bar: the keyboard keeps its height and the
    /// keys move aside around the orb (`setMagnet`) instead of giving way to the compact orb.
    var holdLayout = false
    /// The keys stand aside around the orb, and the ones moved.
    var isMagnet = false
    var magnetKeys: [KeyView] = []
    /// While a recording is locked, the orange space bar splits in three: return on the left,
    /// the end of the dictation in the middle (wider), delete on the right.
    let lockedReturnKey = KeyView()
    let lockedDeleteKey = KeyView()
    var lockedKeysShown = false
    /// The finger was lifted before the app confirmed the recording.
    var stopWhenRecording = false
    var recordingStart = Date()
    var isCompact = false
    /// While the keyboard grows or shrinks for dictation, the keys keep the full-height layout.
    var isResizing = false
    /// Set once the view is about to show: the height constraint waits for it.
    var willAppear = false
    /// The size last written to the log, which records each size iOS gives the keyboard.
    var loggedSize = CGSize.zero
    var timeout: DispatchWorkItem?
    var previewTimer: Timer?
    var previewIndex = 0
    /// Provisional text typed during live transcription; replaced by later results.
    var liveText = ""
    /// A space put before dictated text that would otherwise join the word before the cursor.
    var livePrefix = ""
    /// The latest provisional text of the whole recording, and how many of its words a return or
    /// delete tapped during a locked recording settled in the document: later results type only
    /// the words after them.
    var liveDraft = ""
    var settledWords = 0
    /// The user edited the text while dictating, so the dictation is not followed for corrections.
    var dictationEdited = false
    /// Follows the user's edits of dictated text, to report them as corrections for training.
    var edits = EditTracker()
    /// Spoken punctuation of the dictations being followed, by dictation id: put back into
    /// corrections, whose recordings have the words.
    var spokenForms: [String: (text: String, spoken: [VoiceCommands.Spoken])] = [:]
    /// Dictations and voice edits that «برگردون» can undo, latest last.
    var undoSteps: [UndoStep] = []
    /// Features turned on or off in the app.
    var options = KeyboardOptions.standard {
        didSet { Haptics.isOn = options.haptics }
    }
    /// The user's own words, put into each dictation (set in the app).
    var dictionary = PersonalDictionary.standard
    /// The handwriting pad (from holding the emoji key); made when opened, let go when closed,
    /// so its recognizer is in memory only while it is used.
    var handwritingPad: HandwritingPadView?
    /// Typed shortcuts («آدف» → the shop's address): the app's shortcuts page and the
    /// iPhone's own text replacements (Settings › Keyboard › Text Replacement), by `PersonalDictionary.key`.
    var shortcuts: [String: String] = [:]
    var systemShortcuts: [String: String] = [:]
    /// Key width the typo search's neighbouring keys were taken at, for English and for Persian.
    var neighboursWidths: [Bool: CGFloat] = [:]
    /// The last space typed, for two spaces typing a full stop and three a comma: 0 after the
    /// space a picked suggestion adds, 1 after a plain space, 2 after the full stop.
    var lastSpace: (time: CFTimeInterval, step: Int)?
    /// The space before the cursor was put there by the keyboard after a picked suggestion: a
    /// mark typed next takes its place, as on iOS («سلام ؟» → «سلام؟ »).
    var autoSpace = false
    static let smartPunctuation: Set<String> = [".", "،", ",", "؟", "?", "!", ":", "؛", ";", "…"]
    var editsTimer: Timer?
    /// The keyboard's last insertion, which the proxy's text can lag behind (`contextBefore`).
    var lastInsertion: (text: String, time: CFTimeInterval)?
    /// The last ZWNJ a space put in by itself, which backspace right after takes back.
    var lastAutoZWNJ: (inserted: String, original: String)?
    /// When viewDidLoad began, for the time to the first appearance in the log.
    var loadStarted: CFTimeInterval = 0
    /// The background picture's average colour, worked out once per picture.
    var averageColour: (id: String, colour: UIColor)?
    /// `lastAutoZWNJ` was a typo correction (for the report's undone corrections).
    var lastChangeWasTypo = false
    /// Seconds the last dictation recorded, for the report (`UsageStats`).
    var lastRecordedSeconds: Double = 0
    /// Typed text whose automatic ZWNJ the user took back, which is left alone from then on.
    var zwnjDeclined = Set(UserDefaults.standard.stringArray(forKey: "zwnjDeclined") ?? [])
    /// The last letter typed by a tap, for a joining letter tapped twice typing ZWNJ.
    var lastLetterTap: (character: String, time: CFTimeInterval)?
    /// ZWNJ typed by a double tap: one backspace right after types the letter instead, and that
    /// spelling («فرضیی» of فرضییات) never gets ZWNJ again.
    var lastDoubleZWNJ: (spelling: String, letter: String)?
    var doubleDeclined = Set(UserDefaults.standard.stringArray(forKey: "doubleDeclined") ?? [])
    /// The last number of a dictation joined from pieces, at the end of what it typed: one
    /// backspace right after puts the pieces back, in Persian digits.
    var lastNumberJoin: (inserted: String, original: String)?
    /// TapMap (`TouchModel`): where the user touches each key, and the touches of the word being
    /// typed, which count once the word is finished.
    var touchModel = TouchModel.load()
    var wordTouches: [TypedTouch] = []
    /// Touches of letters just deleted, latest last: a different letter typed in their place
    /// says what the touch meant.
    var deletedTouches: [TypedTouch] = []
    var touchSaveScheduled = false
    var letterWeightsCache: (word: String, english: Bool, weights: [String: Double])?
    /// Seconds without typing after which edits are reported even if the keyboard stays open.
    var reportDelay: TimeInterval = 300

    /// Screenshot support when the keyboard is shown inside the app: fixes the displayed
    /// state ("noSession", "ready", "recording", "transcribing", or "cycle" for all of them).
    var previewState: String?
    /// The simulator test hosts the keyboard inside the app, where it types into this instead.
    var testProxy: UITextDocumentProxy?
    var proxy: UITextDocumentProxy { testProxy ?? textDocumentProxy }
    /// On screen, with a text proxy that still works. iOS keeps keyboards it has put away
    /// (their views stay in memory), and reading or writing through such a keyboard's proxy
    /// crashed it (report of 2026-11-03), so late work (a word list loaded, a dictation
    /// finished) checks this first.
    var isOnScreen: Bool { testProxy != nil || (isViewLoaded && view.window != nil) }

    /// Each text field gets its own keyboard. UIKit keeps the view of one it has let go of, with
    /// everything in it (about 2 MB a text field), until the extension runs out of memory and iOS
    /// puts its own keyboard back; emptying the view frees the keys, the orb and the glass.
    deinit {
        log.info("controller \(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000) freed")
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            viewIfLoaded?.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadStarted = CACurrentMediaTime()
        // iOS kills a keyboard that takes too long to open (reports of 2026-10-29 to 11-01), so
        // only what the first frame needs runs here. Crash reporting connects to its service later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { CrashReports.shared.start() }
        // The app's options before the keys are built: built with the standard ones, they were
        // all built again in viewWillAppear whenever the number row or digits differed.
        options = KeyboardOptions.load()
        updatePrimaryLanguage()
        log.info("controller \(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000) loaded")
        // Both orientations' sizes are worked out (and kept) on the first run after install.
        _ = (portraitMetrics, landscapeMetrics)
        buildUI()
        observer.observe(DictationBridge.alive) { [weak self] in
            MainActor.assumeIsolated { self?.sessionIsAlive() }
        }
        observer.observe(DictationBridge.ended) { [weak self] in
            MainActor.assumeIsolated {
                if self?.state == .ready { self?.state = .noSession }
            }
        }
        observer.observe(DictationBridge.recording) { [weak self] in
            MainActor.assumeIsolated { self?.recordingStarted() }
        }
        observer.observe(DictationBridge.partial) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.partialsHeard += 1
                if self.partialsHeard == 1 { log.info("live text: first update heard in state \(String(describing: self.state), privacy: .public)") }
                self.fetchTranscript()
            }
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
        observer.observe(DictationBridge.interrupted) { [weak self] in
            MainActor.assumeIsolated { self?.microphoneTaken() }
        }
        for step in 0..<DictationBridge.levels {
            observer.observe(DictationBridge.level(step)) { [weak self] in
                MainActor.assumeIsolated { self?.orb.setVoiceLevel(step) }
            }
        }
        // Spoken punctuation reads the Persian list, so it loads whatever the layout.
        Lexicon.shared.load { [weak self] in
            MainActor.assumeIsolated { self?.updateSuggestions() }
        }
        loadLexicon()
    }

    /// The word list of the layout on screen; the English one loads when it is first shown.
    var lexicon: Lexicon { isEnglish ? .english : .shared }

    func loadLexicon() {
        lexicon.load { [weak self] in
            MainActor.assumeIsolated { self?.updateSuggestions() }
        }
    }

    /// The system's edge gestures hold back touches near the screen's sides, so the keys at the
    /// ends of a row (ض چ ش گ) got their touch late and showed no letter balloon. Touches are
    /// let through at once.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if loadStarted > 0 {
            let ms = Int((CACurrentMediaTime() - loadStarted) * 1000)
            log.info("keyboard opened in \(ms) ms")
            loadStarted = 0
        }
        // A word list that finished loading while the keyboard was not on screen.
        updateSuggestions()
        updateTilt()
        // Tells the app the keyboard is added and has Full Access (the app opens only then).
        if hasFullAccess {
            UIPasteboard(name: DictationBridge.fullAccessPasteboard, create: true)?.string = "on"
            DictationBridge.post(DictationBridge.fullAccess)
        }
        var view: UIView? = self.view.window
        while let current = view {
            current.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
            view = current.superview
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        willAppear = true
        view.setNeedsUpdateConstraints()
        if let previewState {
            showPreview(previewState)
            return
        }
        // The key the app left for talking to it; the observers listen again if it is new.
        BridgeKey.refreshInKeyboard()
        applyKeyStyle(KeyStyle.load())
        // The keys were built with the standard options (the digits on the letters off) before
        // the app's were read here.
        applyOptions(KeyboardOptions.load())
        dictionary = PersonalDictionary.load()
        loadShortcuts()
        if options.touchResets != UserDefaults.standard.integer(forKey: "touchResets") {
            UserDefaults.standard.set(options.touchResets, forKey: "touchResets")
            touchModel = TouchModel()
            touchModel.save()
        }
        // Back to a locked recording paused when the keyboard went away: it waits for the orb.
        if state == .recording, isPaused { return }
        checkSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishEdits()
        UsageStats.publish()
        settingsPanel?.removeFromSuperview()
        hideKeysUnderSettings(false)
        hideHandwriting(animated: false)
        emojiReturnsToHandwriting = false
        motion?.stopDeviceMotionUpdates()
        if touchSaveScheduled { touchModel.save() }
        // A locked recording pauses, as when iOS takes the microphone: when this keyboard comes
        // back it goes on after a tap on the orb, and the app ends it if it stays paused.
        if state == .recording, isLocked {
            setPaused(true)
        } else if state == .starting || state == .recording {
            // One the keyboard can no longer end (a finger still on the space bar) would keep
            // the app's microphone and model running: it is cancelled.
            DictationBridge.post(DictationBridge.cancel)
            isHeld = false
            stopWhenRecording = false
            state = .ready
        }
        for timer in [repeatTimer, previewTimer, messageTimer] { timer?.invalidate() }
        repeatTimer = nil
        previewTimer = nil
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if edits.isTracking { report(edits.documentChanged(documentContext)) }
        updateSuggestions()
        updateAutoShift()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if edits.isTracking { report(edits.documentChanged(documentContext)) }
        updateSuggestions()
        updateAutoShift()
    }

    func showPreview(_ name: String) {
        let states: [String: State] = [
            "noSession": .noSession, "ready": .ready, "recording": .recording, "transcribing": .transcribing,
        ]
        if name == "emoji" {
            layer = .emoji
            buildCharacterKeys()
            emojiPanel.showFromStart()
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

    /// A locked recording paused by a tap on the orb: the app keeps no audio until the next tap.
    var isPaused = false
    // MARK: - Editing

    var documentContext: DocumentContext {
        DocumentContext(before: proxy.documentContextBeforeInput ?? "", selected: proxy.selectedText ?? "",
                        after: proxy.documentContextAfterInput ?? "")
    }

    /// Every change the keyboard makes goes through here and `deleteBackward`, so edits of
    /// dictated text can be followed.
    func insert(_ text: String, dictated: Bool = false) {
        guard !text.isEmpty else { return }
        if emojiSearch != nil, !dictated {
            editEmojiSearch(adding: text)
            return
        }
        if autoSpace, !dictated, Self.smartPunctuation.contains(text),
           proxy.documentContextBeforeInput?.hasSuffix(" ") == true {
            deleteBackward()
            insert(text + " ")
            // Another mark right after joins it too («؟!»).
            autoSpace = true
            return
        }
        autoSpace = false
        lastSpace = nil
        lastAutoZWNJ = nil
        lastDoubleZWNJ = nil
        lastNumberJoin = nil
        manualShift = false
        lastInsertion = (text, CACurrentMediaTime())
        if edits.isTracking { report(edits.willEdit(dictated ? .dictate(text) : .type(text), in: documentContext)) }
        // The proxy's text can lag behind an insertion, so shift goes by the text as it will be.
        let after = (proxy.documentContextBeforeInput ?? "") + text
        proxy.insertText(text)
        if !dictated {
            updateSuggestions()
            updateAutoShift(before: after)
        }
    }

    func deleteBackward() {
        autoSpace = false
        lastSpace = nil
        lastAutoZWNJ = nil
        lastDoubleZWNJ = nil
        lastNumberJoin = nil
        lastInsertion = nil
        manualShift = false
        if edits.isTracking { report(edits.willEdit(.deleteBackward, in: documentContext)) }
        proxy.deleteBackward()
        if state != .recording && state != .transcribing {
            updateSuggestions()
            updateAutoShift()
        }
    }

    /// Sends finished corrections to the app, and restarts the wait for the user to stop editing.
    func report(_ corrections: [Correction]) {
        for var correction in corrections {
            // The user's word error rate (usage report): small edits are recognition errors; a
            // rewrite of more than half the words is the user changing their mind, left out.
            let words = correction.original.split(whereSeparator: \.isWhitespace).count
            let errors = UsageStats.wordErrors(correction.original, correction.corrected)
            if errors > max(3, words / 2) {
                UsageStats.record { $0.addChecked(words: -words, errors: 0) }
            } else if errors > 0 {
                UsageStats.record {
                    $0.addChecked(words: 0, errors: errors)
                    $0.voiceFixes += 1
                    $0.voiceWordsFixed += errors
                }
            }
            var corrected = correction.corrected
            if let forms = spokenForms.removeValue(forKey: correction.id) {
                guard let restored = VoiceCommands.restoringSpoken(corrected, original: forms.text,
                                                                   spoken: forms.spoken) else {
                    log.info("correction for \(correction.id, privacy: .public) not sent: its punctuation changed")
                    continue
                }
                corrected = restored
            }
            // The recording has numbers in words.
            correction = Correction(id: correction.id, original: correction.original,
                                    corrected: SpokenNumbers.words(in: corrected))
            log.info("sending correction for \(correction.id, privacy: .public)")
            correction.send()
        }
        if spokenForms.count > 20 { spokenForms.removeAll() }
        editsTimer?.invalidate()
        editsTimer = nil
        guard edits.isTracking else { return }
        editsTimer = Timer.scheduledTimer(withTimeInterval: reportDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishEdits() }
        }
    }

    func finishEdits() {
        editsTimer?.invalidate()
        editsTimer = nil
        guard edits.isTracking else { return }
        log.info("edits finished")
        report(edits.finishAll())
    }

    func transcriptionFailed() {
        guard state == .transcribing else { return }
        cancelTimeout()
        liveText = ""
        state = .ready
        showStatus("متنی تشخیص داده نشد", transient: true)
    }

    /// No session: the app opens and starts one (`DictationBridge.keyboardOpensApp`), else
    /// the space bar says to.
    func askForSession() {
        if !DictationBridge.keyboardOpensApp || !open(DictationBridge.sessionURL) {
            showStatus("آواک را باز کنید و تایپ صوتی را روشن کنید", transient: true)
        }
    }

    /// Extensions cannot call UIApplication.open, so the host's UIApplication is found
    /// through the responder chain and its open method is called dynamically.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard hasFullAccess else { return false }
        typealias OpenURL = @convention(c) (
            AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)).contains("UIApplication"),
               current.responds(to: selector) {
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// Messages show on the space bar, so the keyboard needs no status row. A transient one
    /// disappears after a few seconds.
    func showStatus(_ text: String?, transient: Bool = false) {
        messageTimer?.invalidate()
        messageTimer = nil
        spaceKey.message = text
        guard transient, text != nil else { return }
        messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceKey.message = nil }
        }
    }

    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        cancelTimeout()
        let item = DispatchWorkItem(block: work)
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    // MARK: - UI

    /// `moreSymbols` is English only: the layer behind #+=.
    enum Layer { case letters, symbols, moreSymbols, emoji }

    /// Keys fill the whole width. A layer has `columns` cells per row: Persian 11, English 10.
    /// Persian: every key one cell, the third row ending with backspace, which takes the cells
    /// its keys leave; Apple's iOS layout, with ژ moved under ز (`variants`). English: as on
    /// iOS, the middle row of letters is centred and the third row has shift (or #+=, 123) and
    /// backspace of one and a half cells at its ends.
    static let letterRows: [[String]] = [
        ["ض", "ص", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"],
        ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"],
        ["ظ", "ط", "ز", "ر", "ذ", "د", "پ", "و", "ث"],
    ]
    /// Other forms of a Persian letter, shown in a row over its key on a long press. The first
    /// is the key's own letter.
    static let variants: [String: [String]] = [
        "ی": ["ی", "ئ", "ي"],
        "ا": ["ا", "آ", "أ", "إ", "ء"],
        "ک": ["ک", "ك"],
        "ز": ["ز", "ژ"],
        "و": ["و", "ؤ"],
        "ه": ["ه", "ة"],
        // The numbers layers: the diacritics in two rows (`diacriticRows`), the rest as on iOS.
        "\u{064B}": KeyboardViewController.diacriticRows.flatMap { $0 },
        ".": [".", "…"],
        "،": ["،", ","],
        "!": ["!", "¡"],
    ]
    /// The diacritics key of the Persian numbers layers: fathatan on a tatweel, as SwiftKey
    /// draws it, and on a long press twelve marks in two rows, as Gboard has them. Rows from the
    /// key up, each left to right so that it reads right to left: fatha, kasra, damma and the
    /// three tanvins, the key's fathatan over the key; then shadda, sukun, hamza, maddah,
    /// superscript alef and tatweel.
    static let diacriticRows: [[String]] = [
        ["\u{064C}", "\u{064D}", "\u{064B}", "\u{064F}", "\u{0650}", "\u{064E}"],
        ["\u{0640}", "\u{0670}", "\u{0653}", "\u{0654}", "\u{0652}", "\u{0651}"],
    ]
    /// Rows that open with another form than the key's own over the key, listed left to right:
    /// «ا» with «آ» over the key and «ا» one cell to its right.
    static let anchoredForms: [String: (forms: [String], anchor: String)] = [
        "ا": (["ء", "إ", "أ", "آ", "ا"], "آ"),
    ]
    /// A mark alone has nothing to sit on: the popup shows it on a dotted circle
    /// (`KeyIcons.mark`), and a key on a tatweel.
    static func isMark(_ text: String) -> Bool {
        text.unicodeScalars.first?.properties.generalCategory == .nonspacingMark
    }
    /// Keys whose forms open to the right of the key instead of the left, where they are
    /// easier to reach with the thumb.
    static let formsToTheRight: Set<String> = ["ز", "ی"]
    /// Brackets of the Persian symbol layers type their mirror image: right-to-left text draws
    /// each of them mirrored, so what appears then looks like the key.
    static let mirrored: [String: String] = [
        "(": ")", ")": "(", "«": "»", "»": "«", "[": "]", "]": "[", "{": "}", "}": "{", "<": ">", ">": "<",
    ]
    /// The Persian numbers and symbols as on iOS: ten digits, ten symbols, then between #+= and
    /// a backspace of two cells the punctuation, the rial and the diacritics key, all one cell
    /// wide so the row lines up with the ones above. #+= opens `persianMoreRows`.
    static let symbolRows: [[String]] = [
        ["۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹", "۰"],
        ["-", "/", ":", "؛", "(", ")", "$", "@", "«", "»"],
        [".", "،", "؟", "!", "٬", "﷼", "\u{064B}"],
    ]
    static let persianMoreRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "&", "•", "’", "”"],
        [".", "،", "؟", "!", "٫", "﷼", "\u{064B}"],
    ]
    static let englishRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    static let englishSymbolRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]
    static let englishMoreRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]
    var columns: Int { isEnglish || hasSideKeys ? 10 : 11 }
    /// Layers laid out like iOS's English ones: a centred middle row, and a third row between
    /// shift (or #+=) and backspace of one and a half cells each. Persian letters fill all
    /// eleven cells instead.
    var hasSideKeys: Bool {
        layer == .symbols || layer == .moreSymbols || (isEnglish && layer == .letters)
    }
    /// The Persian numbers layers, whose third row is in whole cells (`symbolRows`).
    var isPersianSymbols: Bool { !isEnglish && (layer == .symbols || layer == .moreSymbols) }

    var layer = Layer.letters
    /// English QWERTY instead of Persian; switched by swiping left or right on the space bar.
    static let englishKey = "keyboardEnglish"
    var isEnglish = UserDefaults.standard.bool(forKey: KeyboardViewController.englishKey) {
        didSet {
            UserDefaults.standard.set(isEnglish, forKey: Self.englishKey)
            updatePrimaryLanguage()
        }
    }

    /// Tells iOS which language is typed: text views that follow the keyboard's language put
    /// the cursor of an empty line on the left, left to right, for English, and on the right for
    /// Persian, as with the system keyboards. Apps that fix their own alignment ignore it.
    func updatePrimaryLanguage() {
        let language = isEnglish ? "en-US" : "fa-IR"
        if primaryLanguage != language { primaryLanguage = language }
    }
    /// One-shot capital letter in the English layout, also switched on at the start of a sentence.
    var isShifted = false
    /// Capitals until shift is tapped again; a double tap on shift turns it on.
    var isCapsLock = false
    var lastShiftTap: CFTimeInterval = 0
    /// Shift was tapped since the last key, so text changes reported later do not undo it.
    var manualShift = false
    static let languageSwitchesKey = "languageSwitches"
    /// Swipes on the space bar so far: its globe goes once the user knows the gesture.
    var languageSwitches = UserDefaults.standard.integer(forKey: KeyboardViewController.languageSwitchesKey) {
        didSet { UserDefaults.standard.set(languageSwitches, forKey: Self.languageSwitchesKey) }
    }
    let shiftKey = KeyView(symbol: "shift")
    var characterKeys: [[KeyView]] = []
    /// Digits above the letters, when switched on in the app (`KeyboardOptions.numberRow`).
    var numberKeys: [KeyView] = []
    var showsNumberRow: Bool { options.numberRow && !options.digitsOnLetters && layer == .letters }
    let backspaceKey = KeyView(symbol: "delete.right")
    /// The emoji panel on a tap; a menu with the emoji panel and the keyboard's settings on a
    /// long press. The settings open inside the keyboard, as a keyboard may open no app but
    /// Settings (App Store guideline 4.4.1).
    let emojiKey = KeyView()
    let keyMenu = KeyMenuView()
    /// The enlarged letter over a pressed key, or the row of a letter's other forms.
    let keyPopup = KeyPopupView()
    /// Covers the keys while the menu stays open, and closes it when touched.
    let menuShield = UIControl()
    /// The keyboard's own settings over the keys (`KeyboardSettingsPanel`), made when first opened.
    var settingsPanel: KeyboardSettingsPanel?
    let emojiPanel = EmojiPanel()
    let emojiSearchView = EmojiSearchView()
    /// On the emoji panel, beside backspace (Persian) or ABC (English): opens the search.
    let emojiSearchKey = KeyView(symbol: "magnifyingglass")
    let layerKey = KeyView(title: "۱۲۳", fontSize: 16)
    /// The next keyboard, where iOS draws no globe under the keys (Home button iPhones, iPad):
    /// App Store guideline 4.4.1 asks every keyboard for one.
    let globeKey = KeyView(symbol: "globe")
    /// English: #+= on the numbers layer and 123 behind it, where shift is on the letters.
    let moreKey = KeyView(title: "#+=", fontSize: 16)
    /// No label: arrows around a globe show that swiping it changes the language, until the
    /// user has done it a few times. Keys with no fill or outline name it, as iOS does.
    let spaceKey = KeyView(fontSize: 15)
    lazy var spacePan = UIPanGestureRecognizer(target: self, action: #selector(spaceSwiped(_:)))
    let returnKey = KeyView()
    var repeatTimer: Timer?
    let suggestionBar = SuggestionBar()
    let glideTrail = GlideTrailView()
    lazy var glidePan = UIPanGestureRecognizer(target: self, action: #selector(glided(_:)))
    var glidePath: [CGPoint] = []
    /// The last glided word while it is still the text before the cursor: one backspace deletes
    /// it, and the bar offers the other readings of the glide in its place.
    var lastGlide: (word: String, inserted: String, alternatives: [String])?

    func render() {
        let symbol: String
        var tint = keyStyle.textColor
        switch state {
        case .checking, .starting: symbol = "mic"
        case .noSession: symbol = "mic.slash"
        case .ready, .transcribing: symbol = "mic.fill"
        case .recording: symbol = "mic.fill"; tint = .systemRed
        }
        showStatus(nil)
        updateSuggestions()
        micButton.setImage(UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)),
                           for: .normal)
        micButton.tintColor = tint
        micButton.isEnabled = state != .starting

        switch state {
        case .starting: orb.mode = .starting
        case .recording: orb.mode = .recording
        case .transcribing: orb.mode = .processing
        default:
            // Back on the keys (also straight from a recording nobody spoke in): the orb's
            // per-frame motion and the rings stop, not to run on hidden.
            orb.liveRing.reset()
            orb.processingRing.reset()
            orb.mode = .processing
        }
        let active = state == .starting || state == .recording || state == .transcribing
        if holdLayout || isMagnet { setMagnet(active) } else { setCompact(active) }
    }

    /// While a held space bar dictates, the keyboard keeps its height: every row opens sideways
    /// around the orb, which comes up in the middle, and each key turns away like a petal (the
    /// farther out, the closer to edge-on) and leans along the orb's field like an iron filing.
    /// The space bar grows over the emoji key to the middle and turns into an orange button.
    func setMagnet(_ on: Bool) {
        if !on { holdLayout = false }
        guard isMagnet != on else { return }
        isMagnet = on
        // With Reduce Motion on, only the end of the move shows, as a quick fade.
        let calm = !orb.animates || UIAccessibility.isReduceMotionEnabled
        if on {
            keyPopup.hide()
            spaceKey.accent = .systemOrange
            spaceKey.knurled = true
            let spot = magnetSpot()
            orb.spotlight = (center: keysView.convert(spot.center, to: view), diameter: spot.diameter)
            orb.lock = .open
            if !calm, let center = orb.spotlight?.center {
                let offset = CGPoint(x: center.x - view.bounds.midX, y: center.y - view.bounds.midY)
                orb.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: 0.3, y: 0.3)
                    .translatedBy(x: -offset.x, y: -offset.y)
            }
            orb.alpha = 0
            orb.isHidden = false
            let moves = magnetMoves(around: spot.center, radius: spot.diameter / 2 * 1.1 + 10)
            magnetKeys = moves.map(\.key)
            for move in moves {
                move.key.isUserInteractionEnabled = false
                move.key.displace(move.transform, animated: !calm)
                if !calm { move.key.jiggle(true) }
            }
            suggestionBar.isUserInteractionEnabled = false
        } else {
            isLocked = false
            orb.lock = nil
            setLockedKeys(false)
            spaceKey.accent = nil
            spaceKey.knurled = false
            for key in magnetKeys {
                key.isUserInteractionEnabled = true
                key.jiggle(false)
                key.displace(CATransform3DIdentity, animated: !calm)
            }
            magnetKeys = []
            suggestionBar.isUserInteractionEnabled = true
        }
        view.setNeedsLayout()
        UIView.animate(withDuration: calm ? 0.15 : 0.42, delay: 0, usingSpringWithDamping: calm ? 1 : 0.85, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState], animations: {
            self.suggestionBar.alpha = on ? 0 : 1
            self.orb.alpha = on ? 1 : 0
            if on { self.orb.transform = .identity }
            self.view.layoutIfNeeded()
        }, completion: { _ in
            guard !self.isMagnet else { return }
            self.orb.transform = .identity
            self.orb.spotlight = nil
            self.orb.isHidden = !self.isCompact
        })
    }

    /// Splits the orange bar for a locked recording, or joins it again; the symbols on the
    /// three parts spring in.
    func setLockedKeys(_ on: Bool) {
        guard lockedKeysShown != on else { return }
        lockedKeysShown = on
        let calm = !orb.animates || UIAccessibility.isReduceMotionEnabled
        if on {
            for key in [lockedReturnKey, lockedDeleteKey] {
                key.apply(keyStyle)
                key.accent = .systemOrange
                key.knurled = true
                key.imageOnGrip = true
                key.alpha = 0
                key.isHidden = false
            }
            lockedReturnKey.image = KeyIcons.lockedReturn
            lockedDeleteKey.image = KeyIcons.lockedDelete
            spaceKey.dimsImage = false
            spaceKey.imageOnGrip = true
            spaceKey.image = KeyIcons.lockedEnd
            spaceKey.accessibilityLabel = "پایان"
        } else {
            spaceKey.imageOnGrip = false
            spaceKey.dimsImage = true
            updateSpaceImage()
        }
        view.setNeedsLayout()
        UIView.animate(withDuration: calm ? 0.15 : 0.45, delay: 0, usingSpringWithDamping: calm ? 1 : 0.72,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: {
            self.lockedReturnKey.alpha = on ? 1 : 0
            self.lockedDeleteKey.alpha = on ? 1 : 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            guard !self.lockedKeysShown else { return }
            self.lockedReturnKey.isHidden = true
            self.lockedDeleteKey.isHidden = true
        })
        if on {
            for (index, key) in [lockedReturnKey, spaceKey, lockedDeleteKey].enumerated() {
                key.revealImage(delay: calm ? 0 : 0.12 + 0.06 * Double(index), animated: !calm)
            }
        }
    }

    /// Where the orb sits among the keys (in the keys' coordinates): level with the middle
    /// letter row, leaving room above it for the lock.
    func magnetSpot() -> (center: CGPoint, diameter: CGFloat) {
        let top = characterKeys.first?.first?.frame.minY ?? suggestionBar.frame.maxY
        let bottom = characterKeys.last?.first?.frame.maxY ?? spaceKey.frame.minY
        return (CGPoint(x: keysView.bounds.midX, y: (top + bottom) / 2), max(56, min(bottom - top - 40, 100)))
    }

    /// Each row's keys leave the circle sideways, staying in their row, spread out toward the
    /// edges: the ones beside the orb turn a little, the outer ones nearly edge-on.
    func magnetMoves(around center: CGPoint, radius: CGFloat) -> [(key: KeyView, transform: CATransform3D)] {
        let keys = keysView.subviews.compactMap { $0 as? KeyView }.filter { !$0.isHidden && $0 !== spaceKey }
        let rows = Dictionary(grouping: keys) { $0.frame.midY.rounded() }
        let width = keysView.bounds.width
        let bottomRow = spaceKey.frame.midY.rounded()
        var moves: [(key: KeyView, transform: CATransform3D)] = []
        for (y, row) in rows {
            let isBottom = abs(y - bottomRow) < 1
            let dy = abs(y - center.y)
            let half: CGFloat
            if isBottom {
                half = 3.5 * width / 11 + 2
            } else if dy < radius {
                half = (radius * radius - dy * dy).squareRoot() + 4
            } else {
                // Above the orb (the number row): aside from the lock.
                half = 30
            }
            let left = row.filter { $0.frame.midX < center.x }.sorted { $0.frame.midX > $1.frame.midX }
            let right = row.filter { $0.frame.midX >= center.x }.sorted { $0.frame.midX < $1.frame.midX }
            for (group, side) in [(left, CGFloat(-1)), (right, CGFloat(1))] where !group.isEmpty {
                let inner = center.x + side * half
                let outer = side < 0 ? CGFloat(3) : width - 3
                let room = max(12, abs(outer - inner))
                let angles = group.indices.map { index -> CGFloat in
                    let f = group.count == 1 ? 0.35 : CGFloat(index) / CGFloat(group.count - 1)
                    return isBottom ? 25 + 40 * f : 18 + 68 * pow(f, 0.85)
                }
                let widths = zip(group, angles).map { $0.faceFrame.width * cos($1 * .pi / 180) }
                let sum = max(1, widths.reduce(0, +))
                let gap = max(0, (room - sum) / CGFloat(group.count))
                let squeeze = min(1, room / sum)
                var position = inner + side * gap / 2
                for (index, key) in group.enumerated() {
                    let projected = widths[index] * squeeze
                    let x = position + side * projected / 2
                    position += side * (projected + gap)
                    var lean = atan2(x - center.x, center.y - y) * 180 / .pi
                    if lean > 90 { lean -= 180 }
                    if lean < -90 { lean += 180 }
                    // The row level with the orb only turns; the others lean along its field.
                    lean = abs(y - center.y) < rowHeight / 2 ? 0 : -max(-16, min(16, lean * 0.22))
                    var transform = CATransform3DIdentity
                    transform.m34 = -1 / 420
                    transform = CATransform3DTranslate(transform, x - key.frame.midX, 0, 0)
                    transform = CATransform3DRotate(transform, lean * .pi / 180, 0, 0, 1)
                    transform = CATransform3DRotate(transform, -side * angles[index] * .pi / 180, 0, 1, 0)
                    moves.append((key, transform))
                }
            }
        }
        return moves
    }

    /// While dictating, the keys fade out and the keyboard shrinks to the orb with the mic.
    func setCompact(_ compact: Bool) {
        guard isCompact != compact else { return }
        isCompact = compact
        heightConstraint?.constant = compact ? compactHeight : fullHeight
        isResizing = true
        if compact {
            keyPopup.hide()
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
            self.isResizing = false
            self.view.setNeedsLayout()
        })
    }

    func buildUI() {
        view.backgroundColor = .clear
        inputView?.backgroundColor = .clear

        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.layer.cornerRadius = 16
        backgroundImageView.layer.cornerCurve = .continuous
        backgroundImageView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        backgroundImageView.isHidden = true
        view.addSubview(backgroundImageView)

        // A keyboard's fully clear pixels take no touches: between the symbols of clear keys
        // (space, return, the mic) taps were lost. An all but invisible tint takes them.
        keysView.backgroundColor = Self.touchableClear
        view.addSubview(keysView)
        keysView.retarget = { [weak self] point, key in self?.retarget(point, hit: key) }

        micButton.backgroundColor = .clear
        micButton.accessibilityIdentifier = "dictationMic"
        micButton.accessibilityLabel = "Persian dictation"
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.addAction(UIAction { [weak self] _ in
            self?.click(.modifier)
            KeyView.press(self?.micButton, down: true)
        }, for: .touchDown)
        micButton.addAction(UIAction { [weak self] _ in KeyView.press(self?.micButton, down: false) },
                            for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // Dictation is on the space bar (held); the mic button stays only for its state.

        orb.backgroundColor = Self.touchableClear
        orb.isHidden = true
        // The simulator renders animations on the CPU, which slowed transcription in the test tenfold.
        orb.animates = testProxy == nil
        orb.accessibilityIdentifier = "dictationOrb"
        orb.isAccessibilityElement = true
        orb.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        view.addSubview(orb)

        // Symbols keep the same direction on every device, whatever the host app's language.
        view.semanticContentAttribute = .forceRightToLeft

        emojiPanel.isHidden = true
        emojiPanel.onPick = { [weak self] emoji in
            guard let self else { return }
            self.insert(emoji)
            if self.emojiReturnsToHandwriting { self.backToHandwriting() }
        }
        emojiPanel.onCategoryChange = { [weak self] in self?.haptic(.category) }
        keysView.addSubview(emojiPanel)
        emojiSearchKey.accessibilityIdentifier = "emojiSearchKey"
        emojiSearchKey.accessibilityLabel = "جستجوی شکلک"
        emojiSearchKey.plain = true
        emojiSearchKey.isHidden = true
        emojiSearchKey.addAction(UIAction { [weak self] _ in self?.click(.modifier) }, for: .touchDown)
        emojiSearchKey.addAction(UIAction { [weak self] _ in self?.beginEmojiSearch() }, for: .touchUpInside)
        keysView.addSubview(emojiSearchKey)
        emojiSearchView.isHidden = true
        emojiSearchView.onPick = { [weak self] emoji in self?.insertFoundEmoji(emoji) }
        keysView.addSubview(emojiSearchView)

        backspaceKey.accessibilityIdentifier = "backspaceKey"
        backspaceKey.addTarget(self, action: #selector(backspaceDown), for: .touchDown)
        backspaceKey.addTarget(self, action: #selector(backspaceUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        layerKey.accessibilityIdentifier = "layerKey"
        layerKey.addTarget(self, action: #selector(toggleLayer), for: .touchUpInside)
        globeKey.accessibilityIdentifier = "globeKey"
        globeKey.accessibilityLabel = "کیبورد بعدی"
        globeKey.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeKey.isHidden = true
        emojiKey.accessibilityIdentifier = "emojiKey"
        emojiKey.addTarget(self, action: #selector(toggleEmoji), for: .touchUpInside)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(emojiPressed(_:)))
        press.minimumPressDuration = 0.35
        emojiKey.addGestureRecognizer(press)
        updateSpaceImage()
        spaceKey.dimsImage = true
        spaceKey.accessibilityIdentifier = "spaceKey"
        spaceKey.addTarget(self, action: #selector(insertSpace), for: .touchUpInside)
        spacePan.delegate = self
        spaceKey.addGestureRecognizer(spacePan)
        let spaceHold = UILongPressGestureRecognizer(target: self, action: #selector(spaceHeld(_:)))
        spaceHold.minimumPressDuration = 0.35
        spaceKey.addGestureRecognizer(spaceHold)
        spaceKey.accessibilityHint = "برای دیکته نگه دارید"
        shiftKey.accessibilityIdentifier = "shiftKey"
        shiftKey.addTarget(self, action: #selector(toggleShift), for: .touchUpInside)
        keysView.addSubview(shiftKey)
        moreKey.accessibilityIdentifier = "moreKey"
        moreKey.addTarget(self, action: #selector(toggleMoreSymbols), for: .touchUpInside)
        keysView.addSubview(moreKey)
        returnKey.image = KeyIcons.returnKey
        returnKey.accessibilityLabel = "return"
        returnKey.accessibilityIdentifier = "returnKey"
        returnKey.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        for key in [backspaceKey, layerKey, globeKey, emojiKey, lockedReturnKey, lockedDeleteKey, spaceKey, returnKey] {
            keysView.addSubview(key)
        }
        lockedReturnKey.isHidden = true
        lockedReturnKey.accessibilityIdentifier = "lockedReturnKey"
        lockedReturnKey.accessibilityLabel = "خط بعد"
        lockedReturnKey.addTarget(self, action: #selector(lockedReturnTapped), for: .touchUpInside)
        lockedDeleteKey.isHidden = true
        lockedDeleteKey.accessibilityIdentifier = "lockedDeleteKey"
        lockedDeleteKey.accessibilityLabel = "پاک کردن کلمه"
        lockedDeleteKey.addTarget(self, action: #selector(lockedDeleteTapped), for: .touchUpInside)
        for key in [layerKey, moreKey, globeKey, emojiKey, spaceKey, returnKey, shiftKey] {
            key.addAction(UIAction { [weak self] _ in self?.click(.modifier) }, for: .touchDown)
        }
        suggestionBar.onPick = { [weak self] item in self?.pick(item) }
        keysView.addSubview(suggestionBar)
        buildCharacterKeys()

        keysView.addSubview(glideTrail)
        glideTrail.snapshotSource = view
        glideTrail.snapshotExcluded = [keyPopup, keyMenu, menuShield]
        glidePan.maximumNumberOfTouches = 1
        glidePan.delegate = self
        keysView.addGestureRecognizer(glidePan)

        keyMenu.items = [
            KeyMenuView.Item(title: "شکلک", symbol: "face.smiling") { [weak self] in self?.toggleEmoji() },
            KeyMenuView.Item(title: "دست‌خط", symbol: "scribble") { [weak self] in self?.showHandwriting() },
            KeyMenuView.Item(title: "تنظیمات", symbol: "gearshape") { [weak self] in self?.showSettings() },
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
        keysView.addSubview(keyPopup)

        // Just under required, as Apple's guide for keyboard heights has it: a lower priority lost
        // to the height iOS gives the keyboard by default. It is switched on only once the view
        // is about to show (updateViewConstraints): switched on earlier, iOS often kept another
        // height, so the keys were smaller in one app and the suggestion bar taller in another.
        let height = view.heightAnchor.constraint(equalToConstant: fullHeight)
        height.priority = UILayoutPriority(999)
        heightConstraint = height
        // iOS 26 sizes a keyboard by Auto Layout only when something inside it is laid out with
        // constraints. The keys are placed by frames, so without this empty view iOS ignored the
        // height above and gave each app's own (444 points in Spotlight and Safari, 461 in this
        // app, 672 in Reminders, in the simulator, for 260 asked); with it, every app gives 260.
        let sizer = UIView()
        sizer.isHidden = true
        sizer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sizer)
        sizer.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        sizer.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        render()
    }

    func buildCharacterKeys() {
        keyPopup.hide()
        characterKeys.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        numberKeys.forEach { $0.removeFromSuperview() }
        numberKeys = showsNumberRow ? (isEnglish ? Self.englishSymbolRows[0] : Self.symbolRows[0]).enumerated().map { index, digit in
            let key = KeyView(title: digit, fontSize: numberFontSize)
            key.character = digit
            key.accessibilityIdentifier = "number-\(index)"
            key.addAction(UIAction { [weak self] _ in self?.insert(digit) }, for: .touchUpInside)
            key.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
            key.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
            key.addGestureRecognizer(variantsPress())
            key.apply(keyStyle)
            keysView.addSubview(key)
            return key
        } : []
        let rows: [[String]]
        switch layer {
        case .letters: rows = isEnglish ? Self.englishRows : Self.letterRows
        case .symbols: rows = isEnglish ? Self.englishSymbolRows : Self.symbolRows
        case .moreSymbols: rows = isEnglish ? Self.englishMoreRows : Self.persianMoreRows
        case .emoji:
            rows = []
            emojiPanel.refresh(for: proxy.documentContextBeforeInput ?? "")
        }
        emojiPanel.isHidden = layer != .emoji
        emojiPanel.isEnglish = isEnglish
        // On the emoji: الفبا and backspace without a key drawn, either side of the categories,
        // in place of the bottom row.
        let onEmoji = layer == .emoji
        for key in [emojiKey, spaceKey, returnKey] { key.isHidden = onEmoji }
        if emojiSearch != nil { emojiKey.isHidden = true }
        returnKey.accent = emojiSearch != nil ? .systemBlue : nil
        updateSpaceImage()
        layerKey.plain = onEmoji
        backspaceKey.plain = onEmoji
        emojiSearchKey.isHidden = !onEmoji
        emojiSearchView.isHidden = emojiSearch == nil
        characterKeys = rows.enumerated().map { rowIndex, row in
            row.enumerated().map { column, character in
                // English letters follow shift (`setShifted`).
                let key = KeyView(title: Self.isMark(character) ? "\u{0640}" + character : character, fontSize: letterFontSize)
                key.character = character
                key.accessibilityIdentifier = "letter-\(rowIndex)-\(column)"
                key.addAction(UIAction { [weak self, weak key] _ in self?.tapped(key, character) }, for: .touchUpInside)
                key.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
                key.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                // The top row's digits, when switched on: the tenth key has 0.
                if options.digitsOnLetters, layer == .letters, rowIndex == 0, column < 10 {
                    key.hint = isEnglish ? Self.latinDigits[(column + 1) % 10] : Self.persianDigits[(column + 1) % 10]
                }
                if key.hint != nil || Self.digitPair(character) != nil || (!isEnglish && Self.variants[character] != nil) {
                    key.addGestureRecognizer(variantsPress())
                }
                key.apply(keyStyle)
                keysView.addSubview(key)
                return key
            }
        }
        applyTilt()
        let onLetters = layer == .letters
        layerKey.title = layer == .emoji && emojiReturnsToHandwriting ? "برگشت"
            : isEnglish ? (onLetters ? "123" : "ABC") : (onLetters ? "۱۲۳" : "الفبا")
        shiftKey.isHidden = !(isEnglish && layer == .letters)
        moreKey.isHidden = !(layer == .symbols || layer == .moreSymbols)
        moreKey.title = layer == .moreSymbols ? (isEnglish ? "123" : "۱۲۳") : "#+="
        backspaceKey.image = isEnglish ? KeyIcons.deleteLeft : KeyIcons.deleteRight
        isCapsLock = false
        setShifted(false)
        updateAutoShift()
        emojiKey.image = layer == .emoji ? KeyIcons.menuKey(symbol: "keyboard") : KeyIcons.emojiKey
        // A key hidden while it was pressed (emoji, 123) comes back unpressed.
        for key in [emojiKey, globeKey, layerKey, moreKey, shiftKey, returnKey, spaceKey] { key.isHighlighted = false }
        emojiKey.accessibilityLabel = layer == .emoji ? "حروف" : "شکلک"
        lastGlide = nil
        wordTouches.removeAll()
        deletedTouches.removeAll()
        letterWeightsCache = nil
        updateSuggestions()
        // New keys go on top; an open settings panel stays above them until it is closed.
        if let panel = settingsPanel, panel.superview === keysView { keysView.bringSubviewToFront(panel) }
        view.setNeedsLayout()
    }

    var keyStyle = KeyStyle.standard
    /// Letters and digits at the size chosen in the app; the low number row's no larger than fits.
    var letterFontSize: CGFloat { CGFloat(keyStyle.letterSize ?? KeyStyle.standardLetterSize) }
    var numberFontSize: CGFloat { min(letterFontSize, 19) }

    /// Close to the colour iOS draws behind a keyboard, for the glide lens.
    static let systemKeyboardBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1)
    }
    /// Clear to the eye, but it takes touches (see `buildUI`).
    static let touchableClear = UIColor(white: 0.5, alpha: 0.012)

    func applyKeyStyle(_ style: KeyStyle) {
        keyStyle = style
        updateBackgroundImage()
        let picture = backgroundImageView.isHidden ? nil : backgroundImageView.image
        let solid = picture == nil ? style.backgroundColor : nil
        view.backgroundColor = solid ?? .clear
        // iOS draws the strip under the keys (globe and dictation) itself, and it cannot take
        // the colour; rounded top corners make the coloured keyboard sit well on the screen.
        view.layer.cornerRadius = solid == nil ? 0 : 16
        view.layer.cornerCurve = .continuous
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        // Letters left to the system colour turn light on a dark background and dark on a light
        // one. Keys of a solid fill decide it first, as the letters sit on them: white keys kept
        // white letters where the app asked for a dark keyboard (Spotlight on the home screen).
        var average = solid
        if let picture, let id = style.backgroundImage {
            if averageColour?.id != id { averageColour = (id, KeyboardBackground.averageColor(of: picture)) }
            average = averageColour?.colour
        }
        var interface = UIUserInterfaceStyle.unspecified
        if style.text == nil {
            if style.fill.a >= 0.5 {
                interface = KeyboardBackground.luminance(style.fill.color.withAlphaComponent(1)) < 0.5 ? .dark : .light
            } else if let average {
                interface = KeyboardBackground.luminance(average) < 0.5 ? .dark : .light
            }
        }
        view.overrideUserInterfaceStyle = interface
        let functionKeys = [backspaceKey, layerKey, moreKey, globeKey, emojiKey, spaceKey, returnKey, shiftKey, emojiSearchKey]
        for key in functionKeys + characterKeys.flatMap({ $0 }) + numberKeys {
            key.apply(style)
        }
        for key in characterKeys.flatMap({ $0 }) { key.fontSize = letterFontSize }
        for key in numberKeys { key.fontSize = numberFontSize }
        updateSpaceImage()
        suggestionBar.textColor = style.textColor
        emojiPanel.textColor = style.textColor
        emojiPanel.scale = emojiScale
        styleSettingsPanel()
        emojiSearchView.textColor = style.textColor
        emojiSearchView.scale = emojiScale
        suggestionBar.fontSize = (19 * letterFontSize / CGFloat(KeyStyle.standardLetterSize)).rounded()
        glideTrail.lensBackground = average ?? Self.systemKeyboardBackground
        render()
    }

    /// The chosen picture at the keyboard's full size, filling the view however high it is; a
    /// preset is drawn again when the width changes.
    func updateBackgroundImage() {
        guard let id = keyStyle.backgroundImage else {
            backgroundImageView.image = nil
            backgroundImageView.isHidden = true
            drawnBackground = nil
            return
        }
        let size = CGSize(width: view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width, height: fullHeight)
        if let drawn = drawnBackground, drawn.id == id, KeyboardBackground.isPhoto(id) || drawn.size == size { return }
        let image = KeyboardBackground.image(id, size: size)
        backgroundImageView.image = image
        backgroundImageView.isHidden = image == nil
        if image != nil {
            drawnBackground = (id: id, size: size)
        } else {
            drawnBackground = nil
        }
    }

    /// The system keyboard's clicks.
    enum Click: SystemSoundID {
        case character = 1104, delete = 1155, modifier = 1156
    }

    /// Plays on a key's touch down, as on iOS, when switched on in the app; the ring/silent
    /// switch silences it.
    func click(_ sound: Click) {
        haptic(.key)
        guard options.keySounds else { return }
        AudioServicesPlaySystemSound(sound.rawValue)
    }

    /// Feedback through the Taptic Engine, when switched on in the app: a light tap for a key,
    /// a double tap for a corrected word, a tick for each emoji category the grid scrolls into,
    /// and a firmer tap for holds and menus.
    enum Haptic {
        case key, correction, category
        case impact(UIImpactFeedbackGenerator.FeedbackStyle)
    }

    lazy var keyHaptic = UIImpactFeedbackGenerator(style: .light)

    func haptic(_ kind: Haptic) {
        guard Haptics.isOn else { return }
        switch kind {
        case .key:
            keyHaptic.impactOccurred(intensity: 0.6)
        case .correction:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .category:
            UISelectionFeedbackGenerator().selectionChanged()
        case .impact(let style):
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }

    /// English letter keys and their popups show capitals while shift or caps lock is on.
    func setShifted(_ shifted: Bool) {
        isShifted = shifted
        shiftKey.symbol = isCapsLock ? "capslock.fill" : shifted ? "shift.fill" : "shift"
        guard isEnglish, layer == .letters else { return }
        let capitals = shifted || isCapsLock
        for key in characterKeys.flatMap({ $0 }) {
            if let character = key.character { key.title = capitals ? character.uppercased() : character }
        }
    }

    /// A tap switches the next letter to a capital or back; a double tap locks capitals.
    @objc func toggleShift() {
        let now = CACurrentMediaTime()
        manualShift = true
        if isCapsLock {
            isCapsLock = false
            setShifted(false)
        } else if now - lastShiftTap < 0.35 {
            isCapsLock = true
            setShifted(true)
        } else {
            setShifted(!isShifted)
        }
        lastShiftTap = isCapsLock ? 0 : now
    }

    /// English letters start a sentence with a capital, as on iOS, unless the field asks for
    /// something else (none in addresses, every word in names). `before` is the text before
    /// the cursor when the caller knows it better than the proxy; a shift the user set by hand
    /// stays until the next key.
    func updateAutoShift(before known: String? = nil) {
        guard isViewLoaded, isEnglish, layer == .letters, !isCapsLock else { return }
        if known == nil, manualShift { return }
        let before = known ?? proxy.documentContextBeforeInput ?? ""
        let capital: Bool
        switch proxy.autocapitalizationType ?? .sentences {
        case .none: capital = false
        case .allCharacters: capital = true
        case .words: capital = before.isEmpty || before.last == " " || before.last?.isNewline == true
        default:
            let trimmed = before.reversed().drop { $0 == " " || $0 == "\u{00A0}" }
            if let last = trimmed.first {
                capital = last.isNewline || (".!?".contains(last) && trimmed.count < before.count)
            } else {
                capital = true
            }
        }
        if capital != isShifted { setShifted(capital) }
    }

    /// Persian letters that join the next letter, after which ZWNJ makes a difference.
    static let joiningLetters = Set("بپتثجچحخسشصضطظعغفقکگلمنهیئ".map(String.init))

    /// A tap on a character key. A joining letter tapped twice quickly types ZWNJ the second
    /// time (می and another ی: «می‌»), unless the doubled letter starts a word, as in ممنون.
    func tapped(_ key: KeyView?, _ character: String) {
        let now = CACurrentMediaTime()
        if !isEnglish, layer == .letters, let last = lastLetterTap, last.character == character,
           now - last.time < 0.4, Self.joiningLetters.contains(character), lexicon.isLoaded {
            let word = currentWord(before: contextBefore())
            if word.hasSuffix(character), !lexicon.startsWord(word + character), !doubleDeclined.contains(word + character) {
                lastLetterTap = nil
                insert("\u{200C}")
                lastDoubleZWNJ = (word + character, character)
                return
            }
        }
        lastLetterTap = layer == .letters ? (character, now) : nil
        if let point = key?.touchPoint { noteTouch(character, at: point) }
        typeKey(character)
    }

    /// What a character key types: English letters as capitals while shift is on, and the
    /// mirror image of Persian brackets and guillemets (`mirrored`).
    func typeKey(_ character: String) {
        if !isEnglish, layer == .symbols || layer == .moreSymbols, let mirror = Self.mirrored[character] {
            insert(mirror)
        } else if isEnglish, layer == .letters, isShifted || isCapsLock {
            let wasShifted = isShifted && !isCapsLock
            insert(character.uppercased())
            if wasShifted, isShifted { setShifted(false) }
        } else {
            insert(character)
        }
    }

    /// The globe and arrows teach the swipe; after a few switches the bar is left plain. Keys
    /// with neither fill nor outline would leave nothing of the bar to see: it is named instead.
    func updateSpaceImage() {
        let named = keyStyle.keysAreClear
        spaceKey.image = named || languageSwitches >= 3 ? nil : KeyIcons.space
        spaceKey.title = named ? (isEnglish ? "space" : "فاصله") : nil
        spaceKey.accessibilityLabel = isEnglish ? "space" : "فاصله"
        // The mic at the space bar's right end says that holding it dictates: Persian only, and
        // not while an emoji search is typed.
        let sessionOn = state != .noSession && state != .checking
        spaceKey.trailingImage = canDictateOnSpace ? (sessionOn ? KeyIcons.spaceMic : KeyIcons.spaceMicOff) : nil
    }

    /// Holding the space bar dictates (Persian speech) on the Persian letters and symbols.
    var canDictateOnSpace: Bool { !isEnglish && emojiSearch == nil }

    /// A horizontal swipe on the space bar switches between Persian and English, like SwiftKey.
    @objc func spaceSwiped(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, !isHeld, !isCompact, !isMagnet, emojiSearch == nil, abs(pan.translation(in: view).x) > 40 else { return }
        isEnglish.toggle()
        if layer == .emoji || layer == .moreSymbols { layer = .letters }
        languageSwitches += 1
        updateSpaceImage()
        loadLexicon()
        buildCharacterKeys()
        haptic(.impact(.light))
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        guard willAppear, let heightConstraint else { return }
        let height = isCompact ? compactHeight : fullHeight
        if heightConstraint.constant != height { heightConstraint.constant = height }
        if !heightConstraint.isActive { heightConstraint.isActive = true }
    }

    /// Keys sit on a grid of `columns` equal cells across the whole width (inside the safe area,
    /// which is only non-zero beside the notch in landscape), under the suggestion bar. Each
    /// key's frame covers its whole cell so there are no dead zones between keys.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != loggedSize {
            loggedSize = view.bounds.size
            log.info("layout \(Int(self.view.bounds.width))x\(Int(self.view.bounds.height)), asked \(Int(self.fullHeight)), window \(Int(self.view.window?.bounds.height ?? 0))")
        }
        noteWidth(view.bounds.width)
        // The number row, the suggestion bar or the orientation changed the height.
        if !isCompact, let height = heightConstraint, height.isActive, height.constant != fullHeight {
            view.setNeedsUpdateConstraints()
        }
        // Not `frame`: the orb grows out of its place with a transform.
        orb.bounds = view.bounds
        orb.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        backgroundImageView.frame = view.bounds
        updateBackgroundImage()
        // The keys always take the keyboard's own height at the bottom of the view: more height
        // from iOS stays empty above the suggestion bar. They keep it while hidden or resizing,
        // so they do not squeeze during the animation. Only when iOS gives less than asked do
        // they fill what there is, as the suggestion bar must stay on screen.
        let height = isCompact || isResizing ? fullHeight : min(view.bounds.height, fullHeight)
        if !isCompact, !isResizing, height < fullHeight - 0.5 {
            log.info("keyboard given \(Double(height), privacy: .public) of \(Double(self.fullHeight), privacy: .public) points")
        }
        keysView.frame = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        glideTrail.frame = keysView.bounds
        handwritingPad?.frame = keysView.frame
        menuShield.frame = keysView.bounds
        settingsPanel?.frame = keysView.bounds
        if keyPopup.frame != keysView.bounds {
            keyPopup.hide()
            keyPopup.frame = keysView.bounds
        }
        let insets = view.safeAreaInsets
        let left = insets.left
        let width = view.bounds.width - insets.left - insets.right
        // The rows keep the system keyboard's height. Less than asked comes out of the suggestion
        // bar, down to a thin strip, and only then out of the rows. With the number row on, the
        // other layers spread their four rows over the letters' and the digits' height.
        let keysNeeded = 4 * rowHeight + (options.numberRow ? numberRowHeight : 0)
        let searchExtra = emojiSearch != nil ? searchExtraHeight : 0
        let leastBar: CGFloat = (options.suggestionBar ? (isLandscape ? 26 : 30) : barHeight) + searchExtra
        let bar = max(leastBar, height - keysNeeded)
        let scale = min(1, (height - bar) / keysNeeded)
        let numbers = showsNumberRow ? numberRowHeight * scale : 0
        // The bottom row stands a little apart from the letters (not under the emoji grid): the
        // keys give up a little height for it.
        let bottomGap = layer == .emoji ? 0 : (isLandscape ? 6 : 10) * scale
        let row = (keysNeeded * scale - numbers - bottomGap) / 4
        suggestionBar.frame = CGRect(x: left, y: 0, width: width, height: bar)
        suggestionBar.isHidden = !options.suggestionBar || emojiSearch != nil || layer == .emoji
        emojiSearchView.frame = CGRect(x: left, y: 0, width: width, height: bar)
        emojiSearchView.fieldHeight = bar - searchResultsHeight
        let unit = width / CGFloat(columns)
        let top = bar + numbers
        for (index, key) in numberKeys.enumerated() {
            let cell = width / CGFloat(numberKeys.count)
            key.frame = CGRect(x: left + CGFloat(index) * cell, y: bar, width: cell, height: numbers)
        }

        let thirdY = top + 2 * row
        if isPersianSymbols {
            backspaceKey.frame = CGRect(x: left + width - 2 * unit, y: thirdY, width: 2 * unit, height: row)
        } else if hasSideKeys {
            backspaceKey.frame = CGRect(x: left + width - 1.5 * unit, y: thirdY, width: 1.5 * unit, height: row)
        } else {
            // Persian letters: the rest of the third row, two cells (one beside the emoji).
            let thirdRow = characterKeys.count > 2 ? characterKeys[2].count : columns - 1
            let backspaceX = left + CGFloat(thirdRow) * unit
            backspaceKey.frame = CGRect(x: backspaceX, y: thirdY, width: left + width - backspaceX, height: row)
        }
        shiftKey.frame = CGRect(x: left, y: thirdY, width: 1.5 * unit, height: row)
        moreKey.frame = isPersianSymbols ? CGRect(x: left, y: thirdY, width: unit, height: row) : shiftKey.frame

        // Emoji panel: the grid from the top (no search field over it) down to the bottom row,
        // where the categories sit between الفبا with search on the left and backspace on the
        // right; in Persian search sits beside backspace instead.
        let edgeKey = 1.6 * width / 11
        let searchKeyWidth = 1.2 * width / 11
        emojiPanel.bottomHeight = row
        emojiPanel.bottomInsets = isEnglish ? (edgeKey + searchKeyWidth, edgeKey) : (edgeKey, edgeKey + searchKeyWidth)
        emojiPanel.frame = CGRect(x: left, y: 0, width: width, height: top + 4 * row)

        for (index, keys) in characterKeys.enumerated() {
            let y = top + CGFloat(index) * row
            var x = left
            var keyWidth = unit
            if isPersianSymbols, index == 2 {
                // One cell each, between #+= and the two cells of backspace.
                x += unit
            } else if hasSideKeys, index == 2 {
                // Between shift (or #+=, 123) and backspace.
                x += 1.5 * unit
                keyWidth = (width - 3 * unit) / CGFloat(max(keys.count, 1))
            } else if hasSideKeys {
                // The nine English letters of the middle row are centred.
                x += (width - CGFloat(keys.count) * unit) / 2
            }
            for key in keys {
                key.frame = CGRect(x: x, y: y, width: keyWidth, height: row)
                x += keyWidth
            }
        }

        // Bottom row, left to right, in elevenths of the width: 123 two, emoji two, space five
        // (held, it dictates), return two at the right edge, its arrow mirrored in Persian.
        // Where iOS draws no globe, the next-keyboard key takes one and a half of the emoji's
        // and the space bar's cells.
        let eleventh = width / 11
        let showsGlobe = needsInputModeSwitchKey && layer != .emoji
        globeKey.isHidden = !showsGlobe
        let globeWidth = showsGlobe ? 1.5 * eleventh : 0
        let y = top + 3 * row + bottomGap
        var x = left
        func place(_ view: UIView, _ keyWidth: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: keyWidth, height: row)
            x += keyWidth
        }
        if layer == .emoji {
            layerKey.frame = CGRect(x: left, y: y, width: edgeKey, height: row)
            backspaceKey.frame = CGRect(x: left + width - edgeKey, y: y, width: edgeKey, height: row)
            emojiSearchKey.frame = CGRect(x: isEnglish ? left + edgeKey : left + width - edgeKey - searchKeyWidth,
                                          y: y, width: searchKeyWidth, height: row)
        } else {
            place(layerKey, 2 * eleventh)
            if showsGlobe { place(globeKey, globeWidth) }
            if emojiSearch == nil { place(emojiKey, 2 * eleventh - globeWidth / 2) }
            place(spaceKey, (emojiSearch == nil ? 5 : 7) * eleventh - (emojiSearch == nil ? globeWidth / 2 : globeWidth))
            place(returnKey, 2 * eleventh)
            // Dictating: the space bar reaches over the emoji key to the middle of the keyboard;
            // locked, it splits into return, end (wider) and delete.
            if isMagnet {
                let whole = CGRect(x: left + 2 * eleventh, y: y, width: 7 * eleventh, height: row)
                let side = 1.5 * eleventh
                let gap: CGFloat = 4
                lockedReturnKey.frame = CGRect(x: whole.minX, y: y, width: side, height: row)
                lockedDeleteKey.frame = CGRect(x: whole.maxX - side, y: y, width: side, height: row)
                spaceKey.frame = lockedKeysShown ? whole.insetBy(dx: side + gap, dy: 0) : whole
            }
        }
        let returnImage = emojiSearch != nil ? KeyIcons.searchDone : isEnglish ? KeyIcons.returnKey : KeyIcons.returnKeyMirrored
        if returnKey.image !== returnImage { returnKey.image = returnImage }
        if !keyMenu.isHidden { placeMenu() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // The keyboard is as wide as the screen: wider than the screen's short side in landscape.
        noteWidth(size.width)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.noteWidth(self.view.bounds.width)
            self.view.setNeedsUpdateConstraints()
        }
    }

    /// The emoji panel was opened from the handwriting pad: picking an emoji, the back key in
    /// place of الفبا, or the blue key after a search goes back to the pad (Rooz, 2026-11-05).
    var emojiReturnsToHandwriting = false

    func backToHandwriting() {
        emojiReturnsToHandwriting = false
        endEmojiSearch(backToEmoji: false)
        layer = .letters
        buildCharacterKeys()
        showHandwriting()
    }

    @objc func toggleLayer() {
        if layer == .emoji, emojiReturnsToHandwriting { return backToHandwriting() }
        endEmojiSearch(backToEmoji: false)
        layer = layer == .letters ? .symbols : .letters
        buildCharacterKeys()
    }

    @objc func toggleMoreSymbols() {
        layer = layer == .moreSymbols ? .symbols : .moreSymbols
        buildCharacterKeys()
    }

    @objc func toggleEmoji() {
        endEmojiSearch(backToEmoji: false)
        layer = layer == .emoji ? .letters : .emoji
        buildCharacterKeys()
        if layer == .emoji { emojiPanel.showFromStart() }
    }

    // MARK: - Emoji search

    /// As in the iOS emoji keyboard: the letters come up under a search field and a row of
    /// the emoji found; what is typed goes into the search, not the text.
    func beginEmojiSearch() {
        UIDevice.current.playInputClick()
        emojiSearch = ""
        layer = .letters
        emojiSearchView.update(query: "", isEnglish: isEnglish)
        buildCharacterKeys()
        view.setNeedsUpdateConstraints()
    }

    /// Ends the search, back on the emoji grid or wherever the keyboard goes next.
    func endEmojiSearch(backToEmoji: Bool) {
        guard emojiSearch != nil else { return }
        emojiSearch = nil
        emojiSearchView.isHidden = true
        view.setNeedsUpdateConstraints()
        if backToEmoji {
            layer = .emoji
            buildCharacterKeys()
            emojiPanel.showFromStart()
        } else {
            updateSuggestions()
            view.setNeedsLayout()
        }
    }

    /// Typing while searching changes the search: text added, or one character taken back.
    func editEmojiSearch(adding text: String?) {
        guard var query = emojiSearch else { return }
        if let text {
            query += text.lowercased()
        } else if !query.isEmpty {
            query.removeLast()
        }
        emojiSearch = query
        emojiSearchView.update(query: query, isEnglish: isEnglish)
        if isEnglish { setShifted(false) }
    }

    /// An emoji picked from the search goes into the text; the search stays for another one.
    func insertFoundEmoji(_ emoji: String) {
        let query = emojiSearch
        emojiSearch = nil
        insert(emoji)
        emojiSearch = query
    }

    /// Two spaces in quick succession after a word type a full stop and a space, a third turns
    /// it into a comma (، in Persian), when switched on in the app.
    @objc func insertSpace() {
        // While dictating, the orange space bar types nothing; a tap on it ends a locked recording.
        if isMagnet {
            // Not micTapped: there a tap on a locked recording pauses it.
            if state == .recording, !isHeld { endRecording() }
            return
        }
        if emojiSearch != nil {
            editEmojiSearch(adding: " ")
            return
        }
        let now = CACurrentMediaTime()
        // A picked word brings its own space, which stands for the first tap: the next two taps
        // type the full stop and the comma as they would after a typed word.
        if options.doubleSpacePunctuation, let last = lastSpace, last.step == 0,
           (proxy.documentContextBeforeInput ?? " ").hasSuffix(" ") {
            lastSpace = (now, 1)
            return
        }
        if options.doubleSpacePunctuation, let last = lastSpace, now - last.time < 1.2 {
            let before = proxy.documentContextBeforeInput ?? ""
            if last.step == 1, before.hasSuffix(" "), let end = before.dropLast().last, end.isLetter || end.isNumber {
                deleteBackward()
                insert(". ")
                lastSpace = (now, 2)
                return
            }
            if last.step == 2, before.hasSuffix(". ") {
                deleteBackward()
                deleteBackward()
                insert(isEnglish ? ", " : "، ")
                lastSpace = nil
                return
            }
        }
        let word = currentWord()
        if applyShortcut(word) {
            lastSpace = (now, 1)
            return
        }
        if applyAutoCorrection(word) {
            lastSpace = (now, 1)
            return
        }
        commitTouches(typed: word, as: word)
        if applyAutoZWNJ(word) {
            lastSpace = (now, 1)
            return
        }
        learnCurrentWord()
        insert(" ")
        lastSpace = (now, 1)
    }

    /// A space after a word the list writes with ZWNJ puts it in: میخوام becomes می‌خوام, and two
    /// words, می خوام or کتاب ها, become one. Backspace right after puts the typed text back.
    func applyAutoZWNJ(_ word: String) -> Bool {
        guard options.autoZWNJ, !isEnglish, layer == .letters, lexicon.isLoaded, !word.isEmpty else { return false }
        let before = proxy.documentContextBeforeInput ?? ""
        var old = word
        var replacement: String?
        let rest = before.dropLast(word.count)
        if rest.hasSuffix(" "), !rest.hasSuffix("  ") {
            let previous = currentWord(before: String(rest.dropLast()))
            if !previous.isEmpty, let joined = lexicon.zwnjJoin(previous, word) {
                old = previous + " " + word
                replacement = joined
            }
        }
        if replacement == nil { replacement = lexicon.zwnjSpelling(of: word) }
        guard let new = replacement, new != old, !zwnjDeclined.contains(old) else { return false }
        let context = typingContext(before: old)
        for _ in 0..<old.count { deleteBackward() }
        insert(new + " ")
        lexicon.learn(new, after: context)
        lastAutoZWNJ = (new + " ", old + " ")
        lastChangeWasTypo = false
        haptic(.correction)
        if !suggestionBar.isHidden { suggestionBar.flashCorrection(new) }
        return true
    }

    /// With typo correction on, a space puts the word the typed one surely misspells in its
    /// place, read with the word before (`Lexicon.autoCorrection`); a word that cannot be told
    /// for sure stays as typed. Backspace right after puts the typed word back, and that word is
    /// left alone from then on.
    func applyAutoCorrection(_ word: String) -> Bool {
        guard options.correctTypos, layer == .letters, lexicon.isLoaded, lastGlide == nil, word.count >= 3,
              !zwnjDeclined.contains(word) else { return false }
        updateNeighbours()
        let context = typingContext(before: word)
        guard let found = lexicon.autoCorrection(for: word, context: context) else { return false }
        let new = cased(found, like: word)
        commitTouches(typed: word, as: new)
        for _ in 0..<word.count { deleteBackward() }
        insert(new + " ")
        lexicon.learn(new, after: context)
        lastAutoZWNJ = (new + " ", word + " ")
        lastChangeWasTypo = true
        UsageStats.record { $0.autoCorrections += 1 }
        haptic(.correction)
        if !suggestionBar.isHidden { suggestionBar.flashCorrection(new) }
        return true
    }

    @objc func insertReturn() {
        if emojiSearch != nil {
            // The blue key: the search is done, back to the letters (or the handwriting pad).
            if emojiReturnsToHandwriting { return backToHandwriting() }
            endEmojiSearch(backToEmoji: false)
            buildCharacterKeys()
            return
        }
        let word = currentWord()
        commitTouches(typed: word, as: word)
        learnCurrentWord()
        insert("\n")
    }

    @objc func backspaceDown() {
        click(.delete)
        if emojiSearch != nil {
            editEmojiSearch(adding: nil)
            return
        }
        if let change = lastAutoZWNJ, (proxy.documentContextBeforeInput ?? "").hasSuffix(change.inserted) {
            lastAutoZWNJ = nil
            if lastChangeWasTypo { UsageStats.record { $0.autoCorrectionsUndone += 1 } }
            zwnjDeclined.insert(String(change.original.dropLast()))
            if zwnjDeclined.count > 300 { zwnjDeclined.remove(zwnjDeclined.first!) }
            UserDefaults.standard.set(Array(zwnjDeclined), forKey: "zwnjDeclined")
            for _ in 0..<change.inserted.count { deleteBackward() }
            insert(change.original)
            return
        }
        if let double = lastDoubleZWNJ, (proxy.documentContextBeforeInput ?? "").hasSuffix("\u{200C}") {
            doubleDeclined.insert(double.spelling)
            if doubleDeclined.count > 300 { doubleDeclined.remove(doubleDeclined.first!) }
            UserDefaults.standard.set(Array(doubleDeclined), forKey: "doubleDeclined")
            deleteBackward()
            insert(double.letter)
            return
        }
        if let join = lastNumberJoin, (proxy.documentContextBeforeInput ?? "").hasSuffix(join.inserted) {
            for _ in 0..<join.inserted.count { deleteBackward() }
            insert(join.original)
            return
        }
        if let glide = lastGlide, (proxy.documentContextBeforeInput ?? "").hasSuffix(glide.inserted) {
            lastGlide = nil
            for _ in 0..<glide.inserted.count { deleteBackward() }
        } else {
            touchDeleted(repeating: false)
            deleteBackward()
        }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                var repeats = 0
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        self?.click(.delete)
                        self?.touchDeleted(repeating: true)
                        self?.deleteBackward()
                        repeats += 1
                        // As on iOS: held longer, backspace goes a word at a time.
                        if repeats == 14 { self?.repeatWords() }
                    }
                }
            }
        }
    }

    /// The handwriting pad's space: two in a row type a full stop and three a comma when that
    /// option is on, as on the keys (Rooz, 2026-11-09); no correction of handwritten words.
    func handwritingSpace() {
        let now = CACurrentMediaTime()
        if options.doubleSpacePunctuation, let last = lastSpace, now - last.time < 1.2 {
            let before = proxy.documentContextBeforeInput ?? ""
            if last.step == 1, before.hasSuffix(" "), let end = before.dropLast().last, end.isLetter || end.isNumber {
                deleteBackward()
                insert(". ")
                lastSpace = (now, 2)
                return
            }
            if last.step == 2, before.hasSuffix(". ") {
                deleteBackward()
                deleteBackward()
                insert(isEnglish ? ", " : "، ")
                lastSpace = nil
                return
            }
        }
        insert(" ")
        lastSpace = (now, 1)
    }

    func repeatWords() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.click(.delete)
                self.deleteWordBackward()
            }
        }
    }

    /// The word before the cursor with the spaces after it, or one other character.
    func deleteWordBackward() {
        let before = proxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return deleteBackward() }
        var rest = Substring(before)
        while let last = rest.last, last == " " || last == "\u{00A0}" { rest.removeLast() }
        let word = currentWord(before: String(rest))
        let count = before.count - rest.count + (word.isEmpty ? 1 : word.count)
        for _ in 0..<min(count, before.count) { deleteBackward() }
    }

    @objc func backspaceUp() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Suggestions

    /// The word the cursor is at the end of: Persian letters and ZWNJ, or English letters
    /// and inner apostrophes. `known` is the text before the cursor when the caller has it.
    func currentWord(before known: String? = nil) -> String {
        guard let before = known ?? proxy.documentContextBeforeInput else { return "" }
        let lexicon = lexicon
        var start = before.endIndex
        while start > before.startIndex {
            let previous = before.index(before: start)
            guard lexicon.isWord(before[previous..<start]) else { break }
            start = previous
        }
        // A quotation mark before an English word is not part of it.
        while start < before.endIndex, before[start] == "'" || before[start] == "’" {
            start = before.index(after: start)
        }
        return String(before[start...])
    }

    /// What comes before the word at the cursor (`word`, possibly empty): the word before it,
    /// the start of a sentence, or neither. `separated`: the new word will be typed with a space
    /// of its own, as a glide's is, so a word right before the cursor counts.
    func typingContext(before word: String, separated: Bool = false) -> Lexicon.Context {
        let before = proxy.documentContextBeforeInput ?? ""
        var rest = Substring(before).dropLast(word.count)
        let spaces = rest.reversed().prefix { $0 == " " || $0 == "\u{00A0}" }.count
        rest = rest.dropLast(spaces)
        guard let last = rest.last else { return .sentenceStart }
        if last.isNewline || ".!?؟…".contains(last) { return .sentenceStart }
        guard spaces > 0 || !word.isEmpty || separated else { return .none }
        let lexicon = lexicon
        var start = rest.endIndex
        while start > rest.startIndex {
            let previous = rest.index(before: start)
            guard lexicon.isWord(rest[previous..<start]) else { break }
            start = previous
        }
        return start == rest.endIndex ? .none : .word(lexicon.wordKey(String(rest[start...])))
    }

    /// A typed word counts towards the user's own words and word pairs, and new ones are learned.
    func learnCurrentWord() {
        guard layer == .letters else { return }
        var word = currentWord()
        guard !word.isEmpty else { return }
        let context = typingContext(before: word)
        // An English word capitalized only because it starts a sentence is learned in lowercase.
        if isEnglish, context == .sentenceStart, word.count > 1, word.dropFirst().allSatisfy(\.isLowercase) {
            word = word.prefix(1).lowercased() + word.dropFirst()
        }
        lexicon.learn(word, after: context)
    }

    /// Neighbouring letter keys, for the typo search: centres less than one and a half key widths apart.
    func updateNeighbours() {
        guard keyWidth != neighboursWidths[isEnglish] else { return }
        neighboursWidths[isEnglish] = keyWidth
        let centers = Array(letterCenters())
        var pairs: [(Character, Character)] = []
        for (i, a) in centers.enumerated() {
            for b in centers[(i + 1)...] where GlideDecoder.distance(a.value, b.value) < 1.5 * keyWidth {
                pairs.append((a.key, b.key))
            }
        }
        // ژ has no key of its own: it is held on ز, so one easily stands for the other.
        if !isEnglish { pairs.append(("ز", "ژ")) }
        lexicon.setNeighbours(pairs)
    }

    /// English suggestions follow the capitals of the typed word, and start with one where the
    /// keyboard would type a capital.
    func cased(_ suggestion: String, like typed: String) -> String {
        guard isEnglish else { return suggestion }
        let letters = typed.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return suggestion.uppercased() }
        if letters.first?.isUppercase == true || (typed.isEmpty && isShifted) || isCapsLock {
            return isCapsLock ? suggestion.uppercased() : suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }
        return suggestion
    }

    /// Fills the bar, read right to left: the word as typed in quotes when the list does not
    /// know it (picking it teaches it), the best completion or correction in the middle, then
    /// the next ones, ranked by the word before. After a space, the likeliest next words.
    /// After a glide, the glided word sits in the middle with its other readings beside it.
    func updateSuggestions() {
        // The word lists load in the background and may finish after iOS put this keyboard away.
        guard isOnScreen else { return }
        guard options.suggestionBar, layer == .letters, state != .recording, state != .transcribing,
              state != .starting else {
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
        if let text = shortcut(for: word) {
            // The shortcut's text in the middle, the typed word kept on the side.
            suggestionBar.show([SuggestionBar.Item(text: word, literal: true), SuggestionBar.Item(text: text, shortcut: true), nil])
            return
        }
        let lexicon = lexicon
        guard lexicon.isLoaded else {
            suggestionBar.show([nil, nil, nil])
            return
        }
        let context = options.predictNextWord ? typingContext(before: word) : .none
        let item = { (text: String) in SuggestionBar.Item(text: self.cased(text, like: word)) }
        if word.isEmpty {
            let words = lexicon.predictions(after: context, limit: 3).map(item)
            suggestionBar.show([words.dropFirst().first, words.first, words.dropFirst(2).first])
            return
        }
        if word.count >= 2, !lexicon.isKnown(word) {
            if options.correctTypos { updateNeighbours() }
            let words = lexicon.suggestions(forUnknown: word, context: context, correct: options.correctTypos, limit: 2)
                .map(item)
            suggestionBar.show([SuggestionBar.Item(text: word, literal: true), words.first, words.dropFirst().first])
        } else {
            let words = lexicon.completions(for: word, context: context, limit: 3).map(item)
            suggestionBar.show([words.dropFirst().first, words.first, words.dropFirst(2).first])
        }
    }

    /// The shortcuts set in the app (`TypedShortcuts`) and the system's text replacements; the
    /// app's win. The personal dictionary is for dictation only.
    func loadShortcuts() {
        var found = systemShortcuts
        for (key, text) in TypedShortcuts.load().byKey { found[key] = text }
        shortcuts = found
        guard systemShortcuts.isEmpty else { return }
        requestSupplementaryLexicon { [weak self] lexicon in
            var system: [String: String] = [:]
            for entry in lexicon.entries where entry.userInput != entry.documentText {
                let key = PersonalDictionary.key(entry.userInput)
                if !key.isEmpty, !entry.userInput.contains(" ") { system[key] = entry.documentText }
            }
            DispatchQueue.main.async {
                guard let self, !system.isEmpty else { return }
                self.systemShortcuts = system
                self.loadShortcuts()
            }
        }
    }

    /// The text a typed shortcut stands for.
    func shortcut(for word: String) -> String? {
        guard !word.isEmpty, !shortcuts.isEmpty, layer == .letters else { return nil }
        return shortcuts[PersonalDictionary.key(word)]
    }

    /// A space after a shortcut puts its text in; backspace right after puts the shortcut back,
    /// and that word is left alone from then on.
    func applyShortcut(_ word: String) -> Bool {
        guard let text = shortcut(for: word), !zwnjDeclined.contains(word) else { return false }
        commitTouches(typed: word, as: word)
        for _ in 0..<word.count { deleteBackward() }
        insert(text + " ")
        lastAutoZWNJ = (text + " ", word + " ")
        lastChangeWasTypo = false
        haptic(.correction)
        if !suggestionBar.isHidden { suggestionBar.flashCorrection(text) }
        return true
    }

    func pick(_ item: SuggestionBar.Item) {
        if item.replacesGlide, let glide = lastGlide, item.text == glide.word {
            lastGlide = nil
            insert(" ")
            autoSpace = true
            return
        }
        if item.replacesGlide, let glide = lastGlide {
            for _ in 0..<glide.word.count { deleteBackward() }
            let prefix = String(glide.inserted.dropLast(glide.word.count))
            let others = ([glide.word] + glide.alternatives).filter { $0 != item.text }
            lastGlide = (item.text, prefix + item.text, others)
            insert(item.text)
            lexicon.learn(item.text)
            UsageStats.record { $0.predictionsPicked += 1 }
            return
        }
        let word = currentWord()
        let context = typingContext(before: word)
        commitTouches(typed: word, as: item.shortcut ? word : item.text)
        lastGlide = nil
        for _ in 0..<word.count { deleteBackward() }
        if !item.shortcut { lexicon.learn(item.text, after: context, confirmed: item.literal) }
        insert(item.text + " ")
        let spared = max(0, item.text.count - word.count)
        UsageStats.record {
            $0.predictionsPicked += 1
            $0.lettersSaved += spared
        }
        lastSpace = (CACurrentMediaTime(), 0)
        autoSpace = true
    }

    // MARK: - TapMap

    struct TypedTouch {
        let character: String
        /// In the keys area, which had `size`.
        let point: CGPoint
        let size: CGSize
        let time: CFTimeInterval
    }

    /// Touches are learned per language and orientation.
    var touchLayout: String { "\(isEnglish ? "en" : "fa").\(isLandscape ? "l" : "p")" }

    /// The text before the cursor, with the keyboard's last insertion added while the proxy has
    /// not caught up with it yet.
    func contextBefore() -> String {
        let before = proxy.documentContextBeforeInput ?? ""
        // By scalars: a ZWNJ joins the letter before it into one Character.
        if let last = lastInsertion, CACurrentMediaTime() - last.time < 0.3,
           !before.unicodeScalars.reversed().starts(with: last.text.unicodeScalars.reversed()) {
            return before + last.text
        }
        return before
    }

    func noteTouch(_ character: String, at point: CGPoint) {
        guard options.learnTouches, layer == .letters else { return }
        let now = CACurrentMediaTime()
        if let deleted = deletedTouches.popLast(), now - deleted.time < 5, deleted.character != character {
            learnTouch(deleted, meant: character)
        }
        wordTouches.append(TypedTouch(character: character, point: point, size: keysView.bounds.size, time: now))
    }

    /// Backspace took the last letter: a tap or two keeps its touch for the letter typed in its
    /// place; holding backspace is rewriting, not correcting a slip.
    func touchDeleted(repeating: Bool) {
        guard let last = wordTouches.popLast(), !repeating, deletedTouches.count < 2 else {
            deletedTouches.removeAll()
            return
        }
        deletedTouches.append(TypedTouch(character: last.character, point: last.point, size: last.size,
                                         time: CACurrentMediaTime()))
    }

    func learnTouch(_ touch: TypedTouch, meant character: String) {
        guard touch.size == keysView.bounds.size,
              let key = characterKeys.joined().first(where: { $0.character == character }) else { return }
        let frame = key.frame
        touchModel.learn(CGPoint(x: (touch.point.x - frame.midX) / frame.width, y: (touch.point.y - frame.midY) / frame.height),
                         key: character, layout: touchLayout)
        guard !touchSaveScheduled else { return }
        touchSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.touchSaveScheduled else { return }
            self.touchSaveScheduled = false
            self.touchModel.save()
        }
    }

    /// The word at the cursor, `typed` with a tap per letter, is finished as `word`: itself, or
    /// the suggestion that replaced it. Each touch meant the letter of `word` in its place, so a
    /// picked correction teaches the slips it fixed; a completion teaches the letters typed.
    func commitTouches(typed: String, as word: String) {
        let touches = wordTouches
        wordTouches.removeAll()
        deletedTouches.removeAll()
        guard options.learnTouches, layer == .letters, !touches.isEmpty, lexicon.isKnown(word) else { return }
        let tapped = touches.map(\.character)
        guard lexicon.wordKey(typed).map(String.init) == tapped else { return }
        let meant = lexicon.wordKey(word).map(String.init)
        guard meant.count == tapped.count || (meant.count > tapped.count && Array(meant.prefix(tapped.count)) == tapped) else {
            return
        }
        for (touch, letter) in zip(touches, meant) { learnTouch(touch, meant: letter) }
    }

    /// The letter key a touch on `hit` most likely meant, when it is a neighbour; nil keeps `hit`.
    func retarget(_ point: CGPoint, hit: KeyView) -> KeyView? {
        guard options.learnTouches, layer == .letters else { return nil }
        let letters = characterKeys.joined()
        guard letters.contains(where: { $0 === hit }) else { return nil }
        let near = letters.filter { $0.frame.insetBy(dx: -$0.frame.width / 2, dy: -$0.frame.height / 2).contains(point) }
        guard near.count > 1, let hitIndex = near.firstIndex(where: { $0 === hit }) else { return nil }
        let weights = letterWeights()
        let candidates = near.map {
            TouchModel.Candidate(key: $0.character ?? "", frame: $0.frame, weight: weights[$0.character ?? ""] ?? 0)
        }
        let chosen = near[touchModel.choose(point, among: candidates, hit: hitIndex, layout: touchLayout)]
        return chosen === hit ? nil : chosen
    }

    /// How common the words are that each letter of the layout would continue the word at the
    /// cursor with, worked out once per word.
    func letterWeights() -> [String: Double] {
        guard lexicon.isLoaded else { return [:] }
        let word = currentWord(before: contextBefore())
        if let cache = letterWeightsCache, cache.word == word, cache.english == isEnglish { return cache.weights }
        let weights = lexicon.continuationWeights(after: word, letters: characterKeys.joined().compactMap(\.character))
        letterWeightsCache = (word, isEnglish, weights)
        return weights
    }

    // MARK: - Glide typing

    /// The letter keys of the letters layer, by the (lowercase) letter they type.
    func letterCenters() -> [Character: CGPoint] {
        var centers: [Character: CGPoint] = [:]
        for key in characterKeys.flatMap({ $0 }) {
            if let character = key.character, character.count == 1, let letter = character.first, letter.isLetter {
                centers[letter] = CGPoint(x: key.frame.midX, y: key.frame.midY)
            }
        }
        return centers
    }

    func letterKey(at point: CGPoint) -> KeyView? {
        characterKeys.flatMap { $0 }.first { $0.frame.contains(point) }
    }

    var keyWidth: CGFloat { characterKeys.first?.first?.frame.width ?? 30 }

    @objc func glided(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: keysView)
        switch pan.state {
        case .began:
            let moved = pan.translation(in: keysView)
            let start = CGPoint(x: point.x - moved.x, y: point.y - moved.y)
            glidePath = [start, point]
            keysView.bringSubviewToFront(glideTrail)
            // The lens shows the keys as they stand, without the balloon of the first key.
            keyPopup.hide()
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
    func finishGlide() {
        let path = glidePath
        glidePath = []
        guard let start = path.first else { return }
        guard GlideDecoder.length(path) >= 1.2 * keyWidth else {
            if let character = letterKey(at: start)?.character { typeKey(character) }
            return
        }
        let last = proxy.documentContextBeforeInput?.unicodeScalars.last
        let prefix = last.map { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{200C}" } == true ? " " : ""
        // The word before picks among readings the line fits about as well.
        let context = typingContext(before: "", separated: !prefix.isEmpty)
        let words = GlideDecoder.decode(path, keys: letterCenters(), unit: keyWidth, lexicon: lexicon, context: context)
            .map { cased($0, like: "") }
        guard let word = words.first else { return }
        lastGlide = (word, prefix + word, Array(words.dropFirst()))
        wordTouches.removeAll()
        insert(prefix + word)
        lexicon.learn(word, after: typingContext(before: word))
        let length = Double(GlideDecoder.length(path))
        UsageStats.record {
            $0.glideWords += 1
            $0.glidePoints += length
        }
        log.info("glide: \(words.count) readings")
    }

    // MARK: - Key popups

    @objc func keyDown(_ key: KeyView) {
        click(.character)
        guard options.keyPreview else { return }
        guard var shown = key.title else { return }
        // English letters show the case they type, though the keys show capitals.
        if isEnglish, layer == .letters, let character = key.character {
            shown = isShifted || isCapsLock ? character.uppercased() : character
        }
        keysView.bringSubviewToFront(keyPopup)
        keyPopup.showPreview(shown, on: key, style: keyStyle)
    }

    @objc func keyUp(_ key: KeyView) {
        keyPopup.hidePreview(of: key)
    }

    func variantsPress() -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(variantsPressed(_:)))
        press.minimumPressDuration = 0.4
        return press
    }

    /// Holding a key opens its other forms; sliding over them picks one and lifting the finger
    /// types it. Lifting far from them types nothing.
    @objc func variantsPressed(_ press: UILongPressGestureRecognizer) {
        guard let key = press.view as? KeyView else { return }
        switch press.state {
        case .began:
            let character = key.character ?? ""
            if character == "\u{064B}" {
                keyPopup.showGrid(Self.diacriticRows.map { $0.map(Self.popupItem) }, on: key, style: keyStyle,
                                  anchor: Self.diacriticRows[0].firstIndex(of: character) ?? 0)
            } else {
                let anchored = Self.anchoredForms[character]
                let items = (anchored?.forms ?? forms(of: key)).map(Self.popupItem)
                guard !items.isEmpty else { return }
                keyPopup.showVariants(items, on: key, style: keyStyle,
                                      toTheRight: Self.formsToTheRight.contains(character),
                                      anchor: anchored.flatMap { $0.forms.firstIndex(of: $0.anchor) },
                                      // ض keeps the digit where it is, but holding it offers the digit.
                                      select: character == "ض" ? items.count - 1 : nil)
            }
            keysView.bringSubviewToFront(keyPopup)
            haptic(.impact(.light))
        case .changed:
            keyPopup.select(at: press.location(in: keysView))
        case .ended:
            keyPopup.select(at: press.location(in: keysView))
            let item = keyPopup.isShowingVariants ? keyPopup.selectedItem : nil
            keyPopup.hide()
            if let item { insert(item.text) }
        default:
            keyPopup.hide()
        }
    }

    static let persianDigits = ["۰", "۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹"]
    static let latinDigits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// A digit in the other script: Persian and Latin digits each offer the other.
    static func digitPair(_ text: String) -> String? {
        if let index = persianDigits.firstIndex(of: text) { return latinDigits[index] }
        if let index = latinDigits.firstIndex(of: text) { return persianDigits[index] }
        return nil
    }

    /// What holding a key offers, the one over the key first: a digit with the other script's;
    /// a top-row letter its digit (in the layout's script only) over it, then the letter; then
    /// the letter's other forms.
    func forms(of key: KeyView) -> [String] {
        let character = key.character ?? ""
        if let other = Self.digitPair(character) { return [character, other] }
        let own = isEnglish ? (key.title ?? character) : character
        var forms = [own]
        // ض sits at the keyboard's edge: its forms stay inside, the digit beside the letter.
        if let hint = key.hint { if character == "ض" { forms.append(hint) } else { forms.insert(hint, at: 0) } }
        if !isEnglish { forms += (Self.variants[character] ?? []).dropFirst() }
        return forms.count > 1 ? forms : []
    }

    /// A form as the popup shows it: a mark on a dotted circle, anything else as text.
    static func popupItem(_ text: String) -> KeyPopupView.Item {
        isMark(text) ? KeyPopupView.Item(text: text, label: "", image: KeyIcons.mark(text, size: 30))
            : KeyPopupView.Item(text: text, label: text)
    }

    // MARK: - Emoji key menu

    @objc func emojiPressed(_ press: UILongPressGestureRecognizer) {
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

    func showMenu() {
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
        haptic(.impact(.light))
    }

    /// Above the emoji key, inside the keyboard: an extension cannot draw outside its view.
    func placeMenu() {
        let size = keyMenu.preferredSize
        let key = emojiKey.frame
        let x = min(max(4, key.minX), keysView.bounds.width - size.width - 4)
        let y = max(2, key.minY - size.height - 2)
        keyMenu.bounds = CGRect(origin: .zero, size: size)
        keyMenu.center = CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }

    @objc func closeMenu() {
        menuShield.isHidden = true
        keyMenu.isHidden = true
    }

    // MARK: - Tilting letters

    /// Made when the letters first tilt; reads the phone's gravity while the keyboard shows.
    var motion: CMMotionManager?
    /// The last tilt the letters were given, -1...1 on each axis.
    var tilt = CGPoint.zero
    let motionInterval = 1.0 / 30
    /// The way the phone has been held lately (its gravity, slowly followed): the letters sit in
    /// the middle there, so typing lying down with the phone overhead centres them too (Rooz,
    /// 2026-11-07). Nil until the first reading after the keyboard shows.
    var heldGravity: CMAcceleration?
    /// Seconds over which the middle follows the hand: held still, the letters are back in the
    /// middle in about three times this.
    static let followTime: Double = 1.5
    /// How quickly a tilt reaches full travel (Rooz, 2026-11-05). No separate rest on a table:
    /// the following middle covers it (Rooz, 2026-11-07).
    static let tiltSensitivity: CGFloat = 2.6

    /// Starts or stops following the phone's tilt, as the option, Reduce Motion and the
    /// keyboard's visibility allow.
    func updateTilt() {
        // Not while dictating, which keeps the processor for the orb and the speech (Rooz, 2026-11-05).
        let dictating = state == .starting || state == .recording || state == .transcribing
        let wanted = options.tiltLetters && !UIAccessibility.isReduceMotionEnabled && view.window != nil && !dictating
        if wanted {
            if motion == nil { motion = CMMotionManager() }
            guard let motion, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
            motion.deviceMotionUpdateInterval = motionInterval
            heldGravity = nil
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                let gravity = data.gravity
                // Held the way it has been lately, the letters sit in the middle with no shadow;
                // only a turn away from that moves them. The top tipped towards the user moves
                // them down.
                var held = self.heldGravity ?? gravity
                let follow = min(1, self.motionInterval / Self.followTime)
                held.x += (gravity.x - held.x) * follow
                held.y += (gravity.y - held.y) * follow
                held.z += (gravity.z - held.z) * follow
                self.heldGravity = held
                let dx = gravity.x - held.x, dy = gravity.y - held.y
                var x = CGFloat(dx), y = -CGFloat(dy)
                if self.view.bounds.width > self.view.bounds.height * 1.6 {
                    // Landscape, either way round: the screen's down is the side gravity pulls
                    // along the phone's width.
                    let side: Double = held.x >= 0 ? 1 : -1
                    (x, y) = (CGFloat(side * dy), CGFloat(side * dx))
                }
                let gain = Self.tiltSensitivity
                let next = CGPoint(x: max(-1, min(1, x * gain)), y: max(-1, min(1, y * gain)))
                // Smoothed, and only redrawn when it moved enough to see.
                let rate: CGFloat = 0.35
                var smooth = CGPoint(x: self.tilt.x + (next.x - self.tilt.x) * rate, y: self.tilt.y + (next.y - self.tilt.y) * rate)
                if abs(next.x - smooth.x) < 0.01, abs(next.y - smooth.y) < 0.01 { smooth = next }
                guard abs(smooth.x - self.tilt.x) > 0.002 || abs(smooth.y - self.tilt.y) > 0.002 else { return }
                self.tilt = smooth
                self.applyTilt()
            }
        } else {
            motion?.stopDeviceMotionUpdates()
            tilt = .zero
            applyTilt()
        }
    }

    func applyTilt() {
        let depth: CGPoint? = options.tiltLetters && motion?.isDeviceMotionActive == true ? tilt : nil
        keyPopup.depth = depth
        for row in characterKeys {
            for key in row { key.depth = depth }
        }
    }

    /// The keyboard grows or shrinks at once, as when the dictation orb gives way to the keys.
    /// Only setting the constraint's constant left a taller keyboard squeezed in the old height
    /// until the next language switch laid it out again.
    func heightChanged() {
        guard let heightConstraint, !isCompact else { return }
        heightConstraint.constant = fullHeight
        view.setNeedsUpdateConstraints()
        view.superview?.setNeedsLayout()
        view.superview?.layoutIfNeeded()
        view.setNeedsLayout()
        // iOS may resize the input view a moment later: lay the keys out again on its new height.
        DispatchQueue.main.async { [weak self] in
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        }
    }

    func showSettings() {
        endEmojiSearch(backToEmoji: false)
        if layer == .emoji {
            layer = .letters
            buildCharacterKeys()
        }
        let panel = settingsPanel ?? KeyboardSettingsPanel()
        if settingsPanel == nil {
            settingsPanel = panel
            panel.onChange = { [weak self] new in
                guard let self else { return }
                // Saved like the app's settings page: the app reads it back when it opens.
                new.save()
                self.applyOptions(new)
            }
            panel.onClose = { [weak self] in self?.hideSettings() }
            panel.onOpenApp = { [weak self] in
                guard let self else { return }
                if !self.open(DictationBridge.settingsURL) {
                    self.showStatus("برای بقیه‌ی تنظیمات آواک را باز کنید", transient: true)
                }
            }
        }
        panel.textColor = keyStyle.textColor
        panel.headerHeight = metrics.bar + 12
        styleSettingsPanel()
        panel.options = options
        panel.frame = keysView.bounds
        keysView.addSubview(panel)
        keysView.bringSubviewToFront(panel)
        panel.alpha = 0
        UIView.animate(withDuration: 0.2) {
            panel.alpha = 1
            self.hideKeysUnderSettings(true)
        }
    }

    /// The panel in the keyboard's own colour and with its rounded top corners (Rooz,
    /// 2026-11-05): the chosen colour, the picture's average colour, or the colour iOS draws.
    func styleSettingsPanel() {
        guard let panel = settingsPanel else { return }
        // A keyboard with no colour of its own (iOS's, or a picture) leaves the panel clear too,
        // with the keys hidden under it (Rooz, 2026-11-08).
        let solid = backgroundImageView.isHidden ? keyStyle.backgroundColor : nil
        panel.fill = solid ?? .clear
        panel.layer.cornerRadius = solid == nil ? 0 : max(16, view.layer.cornerRadius)
        panel.layer.cornerCurve = .continuous
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        if panel.superview != nil { hideKeysUnderSettings(true) }
    }

    /// The views under the panel, faded while it shows and given back their own alpha after.
    var keysUnderSettings: [(view: UIView, alpha: CGFloat)] = []

    func hideKeysUnderSettings(_ hide: Bool) {
        if hide {
            guard keysUnderSettings.isEmpty, let panel = settingsPanel else { return }
            keysUnderSettings = keysView.subviews.filter { $0 !== panel && $0.alpha > 0 }.map { ($0, $0.alpha) }
            keysUnderSettings.forEach { $0.view.alpha = 0 }
        } else {
            keysUnderSettings.forEach { $0.view.alpha = $0.alpha }
            keysUnderSettings = []
        }
    }

    func hideSettings() {
        guard let panel = settingsPanel else { return }
        UIView.animate(withDuration: 0.15, animations: {
            panel.alpha = 0
            self.hideKeysUnderSettings(false)
        }) { _ in
            panel.removeFromSuperview()
        }
    }
}

extension KeyboardViewController: UIGestureRecognizerDelegate {
    /// Glides start on a letter key of the letters layer. The language swipe on the space bar
    /// waits while a key's forms are open.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === spacePan { return !keyPopup.isShowingVariants }
        guard gestureRecognizer === glidePan else { return true }
        guard layer == .letters, emojiSearch == nil, !isCompact, keyMenu.isHidden, settingsPanel?.superview == nil,
              !keyPopup.isShowingVariants,
              lexicon.isLoaded else { return false }
        let point = glidePan.location(in: keysView)
        let moved = glidePan.translation(in: keysView)
        return letterKey(at: CGPoint(x: point.x - moved.x, y: point.y - moved.y)) != nil
    }
}

/// The app's font has no Latin letters: Latin text set in it falls back to the system font on
/// the Persian font's taller line and sits high in a key. Text without Persian letters or digits
/// is set in the system font.
func keyFont(for text: String?, size: CGFloat) -> UIFont {
    // The app font draws these the wrong way up; the system font draws them as the text will show.
    if let text, ["،", "؛", "٫", "٬"].contains(text) { return .systemFont(ofSize: size) }
    let persian = text?.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFB50...0xFEFF).contains($0.value) }
    return persian == false ? .systemFont(ofSize: size) : AppFont.font(ofSize: size)
}

/// Images for keys that no SF Symbol fits, drawn as templates so they take the key colour.
enum KeyIcons {
    /// Return, drawn as in a left-to-right layout: the symbol image itself would be mirrored
    /// in this right-to-left keyboard.
    static let returnKey = leftToRight("return")
    /// Return for Persian, mirrored: the arrow comes down on the left and points right.
    static let returnKeyMirrored = mirrored(returnKey)

    /// The same image the other way round.
    private static func mirrored(_ image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: image.size).image { context in
            context.cgContext.translateBy(x: image.size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.withTintColor(.black).draw(at: .zero)
        }.withRenderingMode(.alwaysTemplate)
    }
    /// Backspace pointing left for English, and right as before for Persian.
    static let deleteLeft = leftToRight("delete.left")
    static let deleteRight = leftToRight("delete.right")

    /// The split orange bar of a locked recording: fine return and delete as this right-to-left
    /// keyboard draws them, and a check mark for ending the dictation.
    static let lockedReturn = mirrored(leftToRight("return", size: 17, weight: .light))
    static let lockedDelete = leftToRight("delete.right", size: 17, weight: .light)
    static let lockedEnd = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
    /// The emoji key's face, drawn once: always the outline.
    /// Three dots under the face: a long press opens the menu (emoji, settings).
    static let emojiKey = menuKey(symbol: "face.smiling")

    /// An SF Symbol as drawn left to right, as a template that no layout direction flips.
    private static func leftToRight(_ name: String, size: CGFloat = 19, weight: UIImage.SymbolWeight = .regular) -> UIImage {
        let traits = UITraitCollection(layoutDirection: .leftToRight)
        guard let symbol = UIImage(systemName: name, compatibleWith: traits)?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: weight)) else {
            return UIImage()
        }
        return UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.withTintColor(.black).draw(at: .zero)
        }.withRenderingMode(.alwaysTemplate)
    }

    /// The space bar: a globe between arrows, for swiping between Persian and English.
    /// The space bar's mic, as on iOS: in a filled orange circle while the app's session is on,
    /// an outline in the key's colour once it has ended (holding space then opens the app).
    static let spaceMic = UIImage(systemName: "mic.circle.fill", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 25, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemOrange])))?.withRenderingMode(.alwaysOriginal)
    static let spaceMicOff = UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
    /// The dictating space bar's face: rows of tiny diamond pyramids, as knurled on a metal
    /// button, lit from above, each with a bright upper facet and a shaded lower one, inside a
    /// shape rounded by `corner`.
    static func knurl(size: CGSize, corner knurlCorner: CGFloat) -> UIImage? {
        guard size.width > 4, size.height > 4 else { return nil }
        let pitch: CGFloat = 3.2
        let half = pitch / 2
        let rect = CGRect(origin: .zero, size: size)
        func orange(_ light: CGFloat) -> CGColor {
            // 0 = deep groove, 1 = lit facet.
            UIColor(red: 0.78 + 0.22 * light, green: 0.36 + 0.42 * light, blue: 0.02 + 0.38 * light * light, alpha: 1).cgColor
        }
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            UIBezierPath(roundedRect: rect, cornerRadius: knurlCorner).addClip()
            context.setFillColor(orange(0.05))
            context.fill(rect)
            var row = 0
            var y: CGFloat = -half
            while y < size.height + half {
                var x: CGFloat = row % 2 == 0 ? 0 : half
                x -= pitch
                while x < size.width + pitch {
                    let c = CGPoint(x: x, y: y)
                    let r = half * 0.86
                    let top = CGPoint(x: c.x, y: c.y - r), right = CGPoint(x: c.x + r, y: c.y)
                    let bottom = CGPoint(x: c.x, y: c.y + r), left = CGPoint(x: c.x - r, y: c.y)
                    for (a, b, light) in [(left, top, 1.0), (top, right, 0.78), (right, bottom, 0.3), (bottom, left, 0.5)] as [(CGPoint, CGPoint, CGFloat)] {
                        context.move(to: a)
                        context.addLine(to: b)
                        context.addLine(to: c)
                        context.closePath()
                        context.setFillColor(orange(light))
                        context.fillPath()
                    }
                    x += pitch
                }
                y += half
                row += 1
            }
            // Light from above across the whole grip, and a soft shade inside the edge.
            let space = CGColorSpaceCreateDeviceRGB()
            if let sheen = CGGradient(colorsSpace: space, colors: [UIColor(white: 1, alpha: 0.22).cgColor,
                                                                   UIColor(white: 1, alpha: 0).cgColor,
                                                                   UIColor(red: 0.4, green: 0.15, blue: 0, alpha: 0.18).cgColor] as CFArray,
                                      locations: [0, 0.5, 1]) {
                context.drawLinearGradient(sheen, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            context.setStrokeColor(UIColor(red: 0.5, green: 0.2, blue: 0, alpha: 0.35).cgColor)
            context.setLineWidth(1)
            UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, knurlCorner - 0.5)).stroke()
        }
    }
    static let searchDone = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))

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

    /// Marks drawn under the letter; the rest go over it.
    private static let marksBelow: Set<String> = ["\u{0650}", "\u{064D}", "\u{0655}", "\u{0656}"]

    /// A mark alone, as Gboard shows the diacritics: on a dotted circle standing for the letter
    /// it goes on, centred over it or under it a little apart. The mark is taken from the font
    /// as it sits on a tatweel, so it keeps the shape and size it has in text.
    static func mark(_ mark: String, size: CGFloat) -> UIImage {
        let cacheKey = "\(mark) \(size)"
        if let image = marks[cacheKey] { return image }
        let font = AppFont.font(ofSize: size * 1.15) as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{0640}" + mark, attributes: [.font: font]))
        var bounds = CGRect.null
        var glyphs: [(font: CTFont, glyph: CGGlyph, position: CGPoint)] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let all = CFRange(location: 0, length: 0)
            CTRunGetGlyphs(run, all, &ids)
            CTRunGetPositions(run, all, &positions)
            CTRunGetStringIndices(run, all, &indices)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            // The tatweel is the string's first character.
            for i in 0..<count where indices[i] > 0 {
                var glyph = ids[i]
                let box = CTFontGetBoundingRectsForGlyphs(runFont, .default, &glyph, nil, 1)
                guard !box.isEmpty else { continue }
                bounds = bounds.union(box.offsetBy(dx: positions[i].x, dy: positions[i].y))
                glyphs.append((runFont, ids[i], positions[i]))
            }
        }
        let radius = size * 0.2
        let gap = size * 0.08
        let below = marksBelow.contains(mark)
        let markSize = bounds.isNull ? .zero : bounds.size
        // The circle at the image's centre, so it sits at the middle of its cell.
        let imageSize = CGSize(width: ceil(2 * max(radius, markSize.width / 2) + 4),
                               height: ceil(2 * (radius + gap + markSize.height) + 4))
        let image = UIGraphicsImageRenderer(size: imageSize).image { context in
            let mid = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            UIColor.black.setStroke()
            let ring = UIBezierPath(arcCenter: mid, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            ring.lineWidth = max(1.2, size / 22)
            ring.lineCapStyle = .round
            ring.setLineDash([0.01, 2 * .pi * radius / 10 - 0.01], count: 2, phase: 0)
            ring.stroke()
            guard !bounds.isNull else { return }
            let cg = context.cgContext
            cg.saveGState()
            cg.textMatrix = .identity
            // Core Text's y axis points up.
            cg.translateBy(x: 0, y: imageSize.height)
            cg.scaleBy(x: 1, y: -1)
            let dy = below ? mid.y - radius - gap - bounds.maxY : mid.y + radius + gap - bounds.minY
            cg.translateBy(x: mid.x - bounds.midX, y: dy)
            cg.setFillColor(UIColor.black.cgColor)
            for glyph in glyphs {
                var id = glyph.glyph
                var position = glyph.position
                CTFontDrawGlyphs(glyph.font, &id, &position, 1, cg)
            }
            cg.restoreGState()
        }.withRenderingMode(.alwaysTemplate)
        marks[cacheKey] = image
        return image
    }
    private static var marks: [String: UIImage] = [:]

    /// A symbol alone, for a key with no long press.
    static func plainKey(symbol: String) -> UIImage? {
        UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16))
    }

    /// A symbol with three dots under it, for a key with a long-press menu.
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

