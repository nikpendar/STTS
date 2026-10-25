import AudioToolbox
import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "keyboard")

/// Dictation keyboard: records through the app's background session and types the
/// transcript into the focused text field, so the field never loses focus.
final class KeyboardViewController: UIInputViewController {
    private enum State {
        case checking, noSession, ready, starting, recording, transcribing
    }

    /// Live-text notifications from the app in this dictation, for the device log.
    private var partialsHeard = 0

    private var state = State.checking {
        didSet {
            render()
            if (oldValue == .noSession || oldValue == .checking) != (state == .noSession || state == .checking) {
                updateSpaceImage()
            }
        }
    }

    private let observer = DarwinObserver()
    private let micButton = UIButton(type: .system)
    /// Holds every key; hidden while dictating, when the keyboard shrinks to `orb`.
    private let keysView = KeysView()
    private let orb = DictationOrbView()
    /// The picture chosen in the app (`KeyboardBackground`), behind everything.
    private let backgroundImageView = UIImageView()
    /// The preset drawn last and the size it was drawn at.
    private var drawnBackground: (id: String, size: CGSize)?
    private var heightConstraint: NSLayoutConstraint?
    /// The heights of the suggestion bar and the rows, fixed per orientation (`KeyboardMetrics`).
    private lazy var portraitMetrics = KeyboardMetrics.saved(landscape: false)
    private lazy var landscapeMetrics = KeyboardMetrics.saved(landscape: true)
    private var metrics: KeyboardMetrics { isLandscape ? landscapeMetrics : portraitMetrics }
    private var rowHeight: CGFloat { metrics.row }
    /// The suggestion bar above the keys, or a thin margin in its place when it is switched off.
    private var barHeight: CGFloat {
        guard options.suggestionBar else { return isLandscape ? 2 : 3 }
        return metrics.bar
    }
    /// The optional digits over the letters.
    private var numberRowHeight: CGFloat { metrics.numberRow }
    /// No margin under the bottom row: the keys sit as low as the extension can draw.
    private var fullHeight: CGFloat {
        barHeight + 4 * rowHeight + (options.numberRow ? numberRowHeight : 0) + (emojiSearch != nil ? searchExtraHeight : 0)
    }
    /// The emoji search typed so far, while one is typed on the letters (nil otherwise).
    private var emojiSearch: String?
    /// What an emoji search adds over the suggestion bar: the row of emoji found, and enough
    /// for the search field when the bar is switched off.
    private var searchExtraHeight: CGFloat {
        return searchResultsHeight + 8 + max(0, 36 - barHeight)
    }
    /// The row of emoji found, under the search field.
    private var searchResultsHeight: CGFloat {
        max(32, (EmojiSearchView.resultSize(scale: emojiScale) * 1.5).rounded())
    }
    /// The letters' size over the standard one, for the emoji.
    private var emojiScale: CGFloat { letterFontSize / CGFloat(KeyStyle.standardLetterSize) }
    private var compactHeight: CGFloat { isLandscape ? 120 : 150 }
    /// The orientation the keyboard was last given, from its own width (it is as wide as the
    /// screen) or from the size it turns to. The screen's bounds are only right when the keyboard
    /// loads: in an extension they keep that orientation after the phone turns (iOS 26 and 27),
    /// so the keyboard kept the height it loaded with (too tall in landscape, too short back in
    /// portrait) until another keyboard was switched to and back.
    private var knownLandscape: Bool?
    private var isLandscape: Bool {
        knownLandscape ?? (UIScreen.main.bounds.width > UIScreen.main.bounds.height)
    }
    /// The screen's short side, whichever way its bounds are stale.
    private var screenShortSide: CGFloat { min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) }

    /// Takes the orientation from a width the keyboard is (or will be) given, and asks for the
    /// height of that orientation when it changed.
    private func noteWidth(_ width: CGFloat) {
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
    private var messageTimer: Timer?
    /// The space bar held for dictation: where the finger started and whether it locked.
    private var hold: (startHeight: CGFloat, locked: Bool)?
    /// The finger was lifted before the app confirmed the recording.
    private var stopWhenRecording = false
    private var recordingStart = Date()
    private var isCompact = false
    /// While the keyboard grows or shrinks for dictation, the keys keep the full-height layout.
    private var isResizing = false
    /// Set once the view is about to show: the height constraint waits for it.
    private var willAppear = false
    /// The size last written to the log, which records each size iOS gives the keyboard.
    private var loggedSize = CGSize.zero
    private var timeout: DispatchWorkItem?
    private var previewTimer: Timer?
    private var previewIndex = 0
    /// Provisional text typed during live transcription; replaced by later results.
    private var liveText = ""
    /// A space put before dictated text that would otherwise join the word before the cursor.
    private var livePrefix = ""
    /// Follows the user's edits of dictated text, to report them as corrections for training.
    private var edits = EditTracker()
    /// Spoken punctuation of the dictations being followed, by dictation id: put back into
    /// corrections, whose recordings have the words.
    private var spokenForms: [String: (text: String, spoken: [VoiceCommands.Spoken])] = [:]
    /// Dictations and voice edits that «برگردون» can undo, latest last.
    private var undoSteps: [UndoStep] = []
    /// Features turned on or off in the app.
    private var options = KeyboardOptions.standard {
        didSet { Haptics.isOn = options.haptics }
    }
    /// Key width the typo search's neighbouring keys were taken at, for English and for Persian.
    private var neighboursWidths: [Bool: CGFloat] = [:]
    /// The last space typed, for two spaces typing a full stop and three a comma: 0 after the
    /// space a picked suggestion adds, 1 after a plain space, 2 after the full stop.
    private var lastSpace: (time: CFTimeInterval, step: Int)?
    private var editsTimer: Timer?
    /// The keyboard's last insertion, which the proxy's text can lag behind (`contextBefore`).
    private var lastInsertion: (text: String, time: CFTimeInterval)?
    /// The last ZWNJ a space put in by itself, which backspace right after takes back.
    private var lastAutoZWNJ: (inserted: String, original: String)?
    /// Typed text whose automatic ZWNJ the user took back, which is left alone from then on.
    private var zwnjDeclined = Set(UserDefaults.standard.stringArray(forKey: "zwnjDeclined") ?? [])
    /// The last letter typed by a tap, for a joining letter tapped twice typing ZWNJ.
    private var lastLetterTap: (character: String, time: CFTimeInterval)?
    /// TapMap (`TouchModel`): where the user touches each key, and the touches of the word being
    /// typed, which count once the word is finished.
    private var touchModel = TouchModel.load()
    private var wordTouches: [TypedTouch] = []
    /// Touches of letters just deleted, latest last: a different letter typed in their place
    /// says what the touch meant.
    private var deletedTouches: [TypedTouch] = []
    private var touchSaveScheduled = false
    private var letterWeightsCache: (word: String, english: Bool, weights: [String: Double])?
    /// Seconds without typing after which edits are reported even if the keyboard stays open.
    var reportDelay: TimeInterval = 300

    /// Screenshot support when the keyboard is shown inside the app: fixes the displayed
    /// state ("noSession", "ready", "recording", "transcribing", or "cycle" for all of them).
    var previewState: String?
    /// The simulator test hosts the keyboard inside the app, where it types into this instead.
    var testProxy: UITextDocumentProxy?
    private var proxy: UITextDocumentProxy { testProxy ?? textDocumentProxy }

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
    private var lexicon: Lexicon { isEnglish ? .english : .shared }

    private func loadLexicon() {
        lexicon.load { [weak self] in
            MainActor.assumeIsolated { self?.updateSuggestions() }
        }
    }

    /// The system's edge gestures hold back touches near the screen's sides, so the keys at the
    /// ends of a row (ض چ ش گ) got their touch late and showed no letter balloon. Touches are
    /// let through at once.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        applyKeyStyle(KeyStyle.load())
        let hadNumberRow = options.numberRow
        let hadBar = options.suggestionBar
        options = KeyboardOptions.load()
        if options.numberRow != hadNumberRow { buildCharacterKeys() }
        if options.suggestionBar != hadBar {
            view.setNeedsLayout()
            updateSuggestions()
        }
        if options.touchResets != UserDefaults.standard.integer(forKey: "touchResets") {
            UserDefaults.standard.set(options.touchResets, forKey: "touchResets")
            touchModel = TouchModel()
            touchModel.save()
        }
        checkSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishEdits()
        if touchSaveScheduled { touchModel.save() }
        // A recording the keyboard can no longer end (a locked one, or a finger still on the
        // space bar) would keep the app's microphone and model running: it is cancelled.
        if state == .starting || state == .recording {
            DictationBridge.post(DictationBridge.cancel)
            hold = nil
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

    private func showPreview(_ name: String) {
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
            startDictation(held: false)
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

    /// Asks the app to record. `held`: while a finger holds the space bar, which the app then
    /// does not stop by itself after a silence.
    private func startDictation(held: Bool) {
        state = .starting
        DictationBridge.post(held ? DictationBridge.startHeld : DictationBridge.start)
        // No answer means the app was closed and the session is gone.
        schedule(after: 0.8) { [weak self] in
            if self?.state == .starting { self?.state = .noSession }
        }
    }

    /// Holding the space bar dictates, as long as the finger stays down; sliding it up locks
    /// the recording, which a tap on the orb then ends (as voice messages in Telegram).
    @objc private func spaceHeld(_ press: UILongPressGestureRecognizer) {
        // From the bottom of the keyboard, which stays put while it shrinks to the orb.
        let height = view.bounds.height - press.location(in: view).y
        switch press.state {
        case .began:
            guard canDictateOnSpace else { return }
            switch state {
            case .ready:
                haptic(.impact(.medium))
                hold = (startHeight: height, locked: false)
                orb.recordingHint = Self.holdHint
                startDictation(held: true)
            case .noSession, .checking:
                open(DictationBridge.sessionURL)
            default:
                break
            }
        case .changed:
            guard let current = hold, !current.locked, height - current.startHeight > Self.lockDistance else { return }
            hold?.locked = true
            haptic(.impact(.rigid))
            orb.recordingHint = Self.lockedHint
        case .ended, .cancelled, .failed:
            guard let current = hold else { return }
            if current.locked {
                hold = nil
            } else {
                releaseHold()
            }
        default:
            break
        }
    }

    /// The finger left the space bar: the recording ends and its text goes in. A recording the
    /// app has not confirmed yet ends as soon as it does.
    private func releaseHold() {
        hold = nil
        orb.recordingHint = nil
        switch state {
        case .recording:
            DictationBridge.post(DictationBridge.stop)
            beginTranscribing()
        case .starting:
            stopWhenRecording = true
        default:
            break
        }
    }

    private static let lockDistance: CGFloat = 60
    private static let holdHint = "برای پایان رها کنید، برای قفل به بالا بکشید"
    private static let lockedHint = "قفل شد… برای پایان بزنید"

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
        haptic(.impact(.light))
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
        partialsHeard = 0
        liveText = ""
        livePrefix = spaceBeforeDictation()
        edits.dictationStarted(documentContext, prefix: livePrefix)
        if stopWhenRecording {
            stopWhenRecording = false
            DictationBridge.post(DictationBridge.stop)
            beginTranscribing()
        }
    }

    /// As iOS dictation does: a space after a word, none after a space, a bracket or a ZWNJ.
    private func spaceBeforeDictation() -> String {
        let last = proxy.documentContextBeforeInput?.unicodeScalars.last
        return last.map { $0.properties.isAlphabetic || $0.properties.numericType != nil
            || ".,!?:;)»؟،؛".unicodeScalars.contains($0) } == true ? " " : ""
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
            if batch == nil { log.error("transcript fetch failed (\(final ? "final" : "update", privacy: .public))") }
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
        guard state == .recording || state == .transcribing, let kind = message.first.map(String.init) else {
            log.info("transcript message dropped in state \(String(describing: self.state), privacy: .public)")
            return
        }
        let body = String(message.dropFirst())
        switch kind {
        case DictationBridge.finalPrefix where !body.isEmpty:
            // Dictation id + newline + text.
            let parts = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let result = VoiceCommands.process(String(parts.last ?? ""), punctuation: options.voicePunctuation,
                                               commands: options.voiceCommands, zwnj: options.autoZWNJ)
            perform(result)
            cancelTimeout()
            state = .ready
            // Corrections of a dictation that also edited the text could not be matched to its recording.
            if parts.count == 2, !result.hasEdits, case .text(let text)? = result.steps.first {
                let id = String(parts[0])
                if !result.spoken.isEmpty { spokenForms[id] = (text, result.spoken) }
                report(edits.dictationFinished(id: id, text: text))
                log.info("following dictation \(id, privacy: .public) for edits")
            }
        case DictationBridge.partialPrefix:
            // Empty after a live pass that found nothing new.
            if !body.isEmpty {
                let draft = VoiceCommands.draft(body, punctuation: options.voicePunctuation, commands: options.voiceCommands,
                                                zwnj: options.autoZWNJ)
                if liveText.isEmpty { log.info("live text: first shown, \(draft.count) characters") }
                if !draft.isEmpty { replaceLiveText(with: draft) }
            }
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
        // Punctuation and line breaks join the text before them.
        let joins = text.first.map { $0 == "\n" || ".،؟!:؛)»,?".contains($0) } ?? true
        let target = text.isEmpty ? "" : (joins ? "" : livePrefix) + text
        // Characters compare equal across Unicode normalizations; the typed text must match exactly.
        let common = zip(liveText, target).prefix { $0.unicodeScalars.elementsEqual($1.unicodeScalars) }.count
        for _ in 0..<(liveText.count - common) { deleteBackward() }
        insert(String(target.dropFirst(common)), dictated: true)
        liveText = target
    }

    /// A dictation inserted (undone by deleting it while it is still before the cursor) or text
    /// a voice command deleted (put back while the text before the cursor still ends with `anchor`).
    private enum UndoStep {
        case inserted(String)
        case deleted(String, anchor: String)
    }

    /// Puts a finished dictation into the document: its first text replaces the live text, and
    /// editing commands run in order with the text around them.
    private func perform(_ result: VoiceCommands.Result) {
        var first = true
        for step in result.steps {
            switch step {
            case .text(let text):
                if first {
                    replaceLiveText(with: text)
                    remember(.inserted(liveText))
                } else {
                    let joins = text.first.map { $0 == "\n" || ".،؟!:؛)»,?".contains($0) } ?? true
                    let inserted = (joins ? "" : spaceBeforeDictation()) + text
                    insert(inserted, dictated: true)
                    remember(.inserted(inserted))
                }
            case .deleteSentence, .deleteAll, .undo:
                if first { replaceLiveText(with: "") }
                run(step)
            }
            first = false
        }
        if result.steps.isEmpty { replaceLiveText(with: "") }
        liveText = ""
    }

    private func remember(_ step: UndoStep) {
        undoSteps.append(step)
        if undoSteps.count > 20 { undoSteps.removeFirst() }
    }

    private func run(_ command: VoiceCommands.Step) {
        let before = proxy.documentContextBeforeInput ?? ""
        switch command {
        case .deleteSentence:
            let sentence = Self.lastSentence(of: before)
            guard !sentence.isEmpty else { return }
            for _ in 0..<sentence.count { deleteBackward() }
            remember(.deleted(sentence, anchor: String(before.dropLast(sentence.count).suffix(20))))
        case .deleteAll:
            guard !before.isEmpty else { return }
            for _ in 0..<before.count { deleteBackward() }
            remember(.deleted(before, anchor: ""))
        case .undo:
            var undone = false
            switch undoSteps.popLast() {
            case .inserted(let text)? where before.hasSuffix(text):
                for _ in 0..<text.count { deleteBackward() }
                undone = true
            case .deleted(let text, let anchor)? where before.hasSuffix(anchor):
                insert(text, dictated: true)
                undone = true
            default:
                break
            }
            if !undone {
                // The text changed since; older steps would not fit it either.
                undoSteps = []
                showStatus("چیزی برای برگرداندن نیست", transient: true)
            }
        case .text:
            break
        }
    }

    /// The last sentence before the cursor and the spaces around it, back to the mark that ends
    /// the sentence before it (., ؟, !, a line break), which stays.
    static func lastSentence(of text: String) -> String {
        let characters = Array(text)
        var end = characters.count
        while end > 0, characters[end - 1] == " " { end -= 1 }
        while end > 0, ".؟!?…".contains(characters[end - 1]) { end -= 1 }
        var start = end
        while start > 0, !".؟!?…\n".contains(characters[start - 1]) { start -= 1 }
        return String(characters[start...])
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
        if emojiSearch != nil, !dictated {
            editEmojiSearch(adding: text)
            return
        }
        lastSpace = nil
        lastAutoZWNJ = nil
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

    private func deleteBackward() {
        lastSpace = nil
        lastAutoZWNJ = nil
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
    private func report(_ corrections: [Correction]) {
        for var correction in corrections {
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

    /// `moreSymbols` is English only: the layer behind #+=.
    private enum Layer { case letters, symbols, moreSymbols, emoji }

    /// Keys fill the whole width. A layer has `columns` cells per row: Persian 11, English 10.
    /// Persian: every key one cell, the third row ending with backspace, which takes the cells
    /// its keys leave; Apple's iOS layout, with ژ moved under ز (`variants`). English: as on
    /// iOS, the middle row of letters is centred and the third row has shift (or #+=, 123) and
    /// backspace of one and a half cells at its ends.
    private static let letterRows: [[String]] = [
        ["ض", "ص", "ق", "ف", "غ", "ع", "ه", "خ", "ح", "ج", "چ"],
        ["ش", "س", "ی", "ب", "ل", "ا", "ت", "ن", "م", "ک", "گ"],
        ["ظ", "ط", "ز", "ر", "ذ", "د", "پ", "و", "ث"],
    ]
    /// Other forms of a Persian letter, shown in a row over its key on a long press. The first
    /// is the key's own letter.
    private static let variants: [String: [String]] = [
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
    private static let diacriticRows: [[String]] = [
        ["\u{064C}", "\u{064D}", "\u{064B}", "\u{064F}", "\u{0650}", "\u{064E}"],
        ["\u{0640}", "\u{0670}", "\u{0653}", "\u{0654}", "\u{0652}", "\u{0651}"],
    ]
    /// Rows that open with another form than the key's own over the key, listed left to right:
    /// «ا» with «آ» over the key and «ا» one cell to its right.
    private static let anchoredForms: [String: (forms: [String], anchor: String)] = [
        "ا": (["ء", "إ", "أ", "آ", "ا"], "آ"),
    ]
    /// A mark alone has nothing to sit on: the popup shows it on a dotted circle
    /// (`KeyIcons.mark`), and a key on a tatweel.
    private static func isMark(_ text: String) -> Bool {
        text.unicodeScalars.first?.properties.generalCategory == .nonspacingMark
    }
    /// Keys whose forms open to the right of the key instead of the left, where they are
    /// easier to reach with the thumb.
    private static let formsToTheRight: Set<String> = ["ز", "ی"]
    /// Brackets of the Persian symbol layers type their mirror image: right-to-left text draws
    /// each of them mirrored, so what appears then looks like the key.
    private static let mirrored: [String: String] = [
        "(": ")", ")": "(", "«": "»", "»": "«", "[": "]", "]": "[", "{": "}", "}": "{", "<": ">", ">": "<",
    ]
    /// The Persian numbers and symbols as on iOS: ten digits, ten symbols, then between #+= and
    /// a backspace of two cells the punctuation, the rial and the diacritics key, all one cell
    /// wide so the row lines up with the ones above. #+= opens `persianMoreRows`.
    private static let symbolRows: [[String]] = [
        ["۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹", "۰"],
        ["-", "/", ":", "؛", "(", ")", "$", "@", "«", "»"],
        [".", "،", "؟", "!", "٫", "﷼", "\u{064B}"],
    ]
    private static let persianMoreRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "&", "•", "’", "”"],
        [".", "،", "؟", "!", "٬", "﷼", "\u{064B}"],
    ]
    private static let englishRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private static let englishSymbolRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]
    private static let englishMoreRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]
    private var columns: Int { isEnglish || hasSideKeys ? 10 : 11 }
    /// Layers laid out like iOS's English ones: a centred middle row, and a third row between
    /// shift (or #+=) and backspace of one and a half cells each. Persian letters fill all
    /// eleven cells instead.
    private var hasSideKeys: Bool {
        layer == .symbols || layer == .moreSymbols || (isEnglish && layer == .letters)
    }
    /// The Persian numbers layers, whose third row is in whole cells (`symbolRows`).
    private var isPersianSymbols: Bool { !isEnglish && (layer == .symbols || layer == .moreSymbols) }

    private var layer = Layer.letters
    /// English QWERTY instead of Persian; switched by swiping left or right on the space bar.
    private static let englishKey = "keyboardEnglish"
    private var isEnglish = UserDefaults.standard.bool(forKey: KeyboardViewController.englishKey) {
        didSet {
            UserDefaults.standard.set(isEnglish, forKey: Self.englishKey)
            updatePrimaryLanguage()
        }
    }

    /// Tells iOS which language is typed: text views that follow the keyboard's language put
    /// the cursor of an empty line on the left, left to right, for English, and on the right for
    /// Persian, as with the system keyboards. Apps that fix their own alignment ignore it.
    private func updatePrimaryLanguage() {
        let language = isEnglish ? "en-US" : "fa-IR"
        if primaryLanguage != language { primaryLanguage = language }
    }
    /// One-shot capital letter in the English layout, also switched on at the start of a sentence.
    private var isShifted = false
    /// Capitals until shift is tapped again; a double tap on shift turns it on.
    private var isCapsLock = false
    private var lastShiftTap: CFTimeInterval = 0
    /// Shift was tapped since the last key, so text changes reported later do not undo it.
    private var manualShift = false
    private static let languageSwitchesKey = "languageSwitches"
    /// Swipes on the space bar so far: its globe goes once the user knows the gesture.
    private var languageSwitches = UserDefaults.standard.integer(forKey: KeyboardViewController.languageSwitchesKey) {
        didSet { UserDefaults.standard.set(languageSwitches, forKey: Self.languageSwitchesKey) }
    }
    private let shiftKey = KeyView(symbol: "shift")
    private var characterKeys: [[KeyView]] = []
    /// Digits above the letters, when switched on in the app (`KeyboardOptions.numberRow`).
    private var numberKeys: [KeyView] = []
    private var showsNumberRow: Bool { options.numberRow && !options.digitsOnLetters && layer == .letters }
    private let backspaceKey = KeyView(symbol: "delete.right")
    /// Emoji panel on a tap; a menu with the emoji panel and the app's settings on a long press.
    private let emojiKey = KeyView()
    private let keyMenu = KeyMenuView()
    /// The enlarged letter over a pressed key, or the row of a letter's other forms.
    private let keyPopup = KeyPopupView()
    /// Covers the keys while the menu stays open, and closes it when touched.
    private let menuShield = UIControl()
    private let emojiPanel = EmojiPanel()
    private let emojiSearchView = EmojiSearchView()
    /// On the emoji panel, beside backspace (Persian) or ABC (English): opens the search.
    private let emojiSearchKey = KeyView(symbol: "magnifyingglass")
    private let layerKey = KeyView(title: "۱۲۳", fontSize: 16)
    /// English: #+= on the numbers layer and 123 behind it, where shift is on the letters.
    private let moreKey = KeyView(title: "#+=", fontSize: 16)
    /// No label: arrows around a globe show that swiping it changes the language, until the
    /// user has done it a few times. Keys with no fill or outline name it, as iOS does.
    private let spaceKey = KeyView(fontSize: 15)
    private lazy var spacePan = UIPanGestureRecognizer(target: self, action: #selector(spaceSwiped(_:)))
    private let returnKey = KeyView()
    private var repeatTimer: Timer?
    private let suggestionBar = SuggestionBar()
    private let glideTrail = GlideTrailView()
    private lazy var glidePan = UIPanGestureRecognizer(target: self, action: #selector(glided(_:)))
    private var glidePath: [CGPoint] = []
    /// The last glided word while it is still the text before the cursor: one backspace deletes
    /// it, and the bar offers the other readings of the glide in its place.
    private var lastGlide: (word: String, inserted: String, alternatives: [String])?

    private func render() {
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
        setCompact(state == .starting || state == .recording || state == .transcribing)
    }

    /// While dictating, the keys fade out and the keyboard shrinks to the orb with the mic.
    private func setCompact(_ compact: Bool) {
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

    private func buildUI() {
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
        emojiPanel.onPick = { [weak self] emoji in self?.insert(emoji) }
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
        for key in [backspaceKey, layerKey, emojiKey, spaceKey, returnKey] {
            keysView.addSubview(key)
        }
        for key in [layerKey, moreKey, emojiKey, spaceKey, returnKey, shiftKey] {
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

    private func buildCharacterKeys() {
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
        let onLetters = layer == .letters
        layerKey.title = isEnglish ? (onLetters ? "123" : "ABC") : (onLetters ? "۱۲۳" : "الفبا")
        shiftKey.isHidden = !(isEnglish && layer == .letters)
        moreKey.isHidden = !(layer == .symbols || layer == .moreSymbols)
        moreKey.title = layer == .moreSymbols ? (isEnglish ? "123" : "۱۲۳") : "#+="
        backspaceKey.image = isEnglish ? KeyIcons.deleteLeft : KeyIcons.deleteRight
        isCapsLock = false
        setShifted(false)
        updateAutoShift()
        emojiKey.image = KeyIcons.menuKey(symbol: layer == .emoji ? "keyboard" : "face.smiling")
        emojiKey.accessibilityLabel = layer == .emoji ? "حروف" : "شکلک"
        lastGlide = nil
        wordTouches.removeAll()
        deletedTouches.removeAll()
        letterWeightsCache = nil
        updateSuggestions()
        view.setNeedsLayout()
    }

    private var keyStyle = KeyStyle.standard
    /// Letters and digits at the size chosen in the app; the low number row's no larger than fits.
    private var letterFontSize: CGFloat { CGFloat(keyStyle.letterSize ?? KeyStyle.standardLetterSize) }
    private var numberFontSize: CGFloat { min(letterFontSize, 19) }

    /// Close to the colour iOS draws behind a keyboard, for the glide lens.
    private static let systemKeyboardBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1)
    }
    /// Clear to the eye, but it takes touches (see `buildUI`).
    private static let touchableClear = UIColor(white: 0.5, alpha: 0.012)

    private func applyKeyStyle(_ style: KeyStyle) {
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
        let average = picture.map { KeyboardBackground.averageColor(of: $0) } ?? solid
        var interface = UIUserInterfaceStyle.unspecified
        if style.text == nil {
            if style.fill.a >= 0.5 {
                interface = KeyboardBackground.luminance(style.fill.color.withAlphaComponent(1)) < 0.5 ? .dark : .light
            } else if let average {
                interface = KeyboardBackground.luminance(average) < 0.5 ? .dark : .light
            }
        }
        view.overrideUserInterfaceStyle = interface
        let functionKeys = [backspaceKey, layerKey, moreKey, emojiKey, spaceKey, returnKey, shiftKey, emojiSearchKey]
        for key in functionKeys + characterKeys.flatMap({ $0 }) + numberKeys {
            key.apply(style)
        }
        for key in characterKeys.flatMap({ $0 }) { key.fontSize = letterFontSize }
        for key in numberKeys { key.fontSize = numberFontSize }
        updateSpaceImage()
        suggestionBar.textColor = style.textColor
        emojiPanel.textColor = style.textColor
        emojiPanel.scale = emojiScale
        emojiSearchView.textColor = style.textColor
        emojiSearchView.scale = emojiScale
        suggestionBar.fontSize = (19 * letterFontSize / CGFloat(KeyStyle.standardLetterSize)).rounded()
        glideTrail.lensBackground = average ?? Self.systemKeyboardBackground
        render()
    }

    /// The chosen picture at the keyboard's full size, filling the view however high it is; a
    /// preset is drawn again when the width changes.
    private func updateBackgroundImage() {
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
    private enum Click: SystemSoundID {
        case character = 1104, delete = 1155, modifier = 1156
    }

    /// Plays on a key's touch down, as on iOS, when switched on in the app; the ring/silent
    /// switch silences it.
    private func click(_ sound: Click) {
        haptic(.key)
        guard options.keySounds else { return }
        AudioServicesPlaySystemSound(sound.rawValue)
    }

    /// Feedback through the Taptic Engine, when switched on in the app: a light tap for a key,
    /// a double tap for a corrected word, a tick for each emoji category the grid scrolls into,
    /// and a firmer tap for holds and menus.
    private enum Haptic {
        case key, correction, category
        case impact(UIImpactFeedbackGenerator.FeedbackStyle)
    }

    private lazy var keyHaptic = UIImpactFeedbackGenerator(style: .light)

    private func haptic(_ kind: Haptic) {
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
    private func setShifted(_ shifted: Bool) {
        isShifted = shifted
        shiftKey.symbol = isCapsLock ? "capslock.fill" : shifted ? "shift.fill" : "shift"
        guard isEnglish, layer == .letters else { return }
        let capitals = shifted || isCapsLock
        for key in characterKeys.flatMap({ $0 }) {
            if let character = key.character { key.title = capitals ? character.uppercased() : character }
        }
    }

    /// A tap switches the next letter to a capital or back; a double tap locks capitals.
    @objc private func toggleShift() {
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
    private func updateAutoShift(before known: String? = nil) {
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
    private static let joiningLetters = Set("بپتثجچحخسشصضطظعغفقکگلمنهیئ".map(String.init))

    /// A tap on a character key. A joining letter tapped twice quickly types ZWNJ the second
    /// time (می and another ی: «می‌»), unless the doubled letter starts a word, as in ممنون.
    private func tapped(_ key: KeyView?, _ character: String) {
        let now = CACurrentMediaTime()
        if !isEnglish, layer == .letters, let last = lastLetterTap, last.character == character,
           now - last.time < 0.4, Self.joiningLetters.contains(character), lexicon.isLoaded {
            let word = currentWord(before: contextBefore())
            if word.hasSuffix(character), !lexicon.startsWord(word + character) {
                lastLetterTap = nil
                insert("\u{200C}")
                return
            }
        }
        lastLetterTap = layer == .letters ? (character, now) : nil
        if let point = key?.touchPoint { noteTouch(character, at: point) }
        typeKey(character)
    }

    /// What a character key types: English letters as capitals while shift is on, and the
    /// mirror image of Persian brackets and guillemets (`mirrored`).
    private func typeKey(_ character: String) {
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
    private func updateSpaceImage() {
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
    private var canDictateOnSpace: Bool { !isEnglish && emojiSearch == nil }

    /// A horizontal swipe on the space bar switches between Persian and English, like SwiftKey.
    @objc private func spaceSwiped(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended, hold == nil, !isCompact, emojiSearch == nil, abs(pan.translation(in: view).x) > 40 else { return }
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
        orb.frame = view.bounds
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
        menuShield.frame = keysView.bounds
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
        let row = (keysNeeded * scale - numbers) / 4
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

        // Bottom row, left to right, in elevenths of the width: 123 two, emoji (and settings)
        // two, space five (held, it dictates), return two at the right edge, its arrow mirrored
        // in Persian.
        let eleventh = width / 11
        let y = top + 3 * row
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
            if emojiSearch == nil { place(emojiKey, 2 * eleventh) }
            place(spaceKey, (emojiSearch == nil ? 5 : 7) * eleventh)
            place(returnKey, 2 * eleventh)
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

    @objc private func toggleLayer() {
        endEmojiSearch(backToEmoji: false)
        layer = layer == .letters ? .symbols : .letters
        buildCharacterKeys()
    }

    @objc private func toggleMoreSymbols() {
        layer = layer == .moreSymbols ? .symbols : .moreSymbols
        buildCharacterKeys()
    }

    @objc private func toggleEmoji() {
        endEmojiSearch(backToEmoji: false)
        layer = layer == .emoji ? .letters : .emoji
        buildCharacterKeys()
        if layer == .emoji { emojiPanel.showFromStart() }
    }

    // MARK: - Emoji search

    /// As in the iOS emoji keyboard: the letters come up under a search field and a row of
    /// the emoji found; what is typed goes into the search, not the text.
    private func beginEmojiSearch() {
        UIDevice.current.playInputClick()
        emojiSearch = ""
        layer = .letters
        emojiSearchView.update(query: "", isEnglish: isEnglish)
        buildCharacterKeys()
        view.setNeedsUpdateConstraints()
    }

    /// Ends the search, back on the emoji grid or wherever the keyboard goes next.
    private func endEmojiSearch(backToEmoji: Bool) {
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
    private func editEmojiSearch(adding text: String?) {
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
    private func insertFoundEmoji(_ emoji: String) {
        let query = emojiSearch
        emojiSearch = nil
        insert(emoji)
        emojiSearch = query
    }

    /// Two spaces in quick succession after a word type a full stop and a space, a third turns
    /// it into a comma (، in Persian), when switched on in the app.
    @objc private func insertSpace() {
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
    private func applyAutoZWNJ(_ word: String) -> Bool {
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
        haptic(.correction)
        if !suggestionBar.isHidden { suggestionBar.flashCorrection(new) }
        return true
    }

    /// With typo correction on, a space puts the word the typed one surely misspells in its
    /// place, read with the word before (`Lexicon.autoCorrection`); a word that cannot be told
    /// for sure stays as typed. Backspace right after puts the typed word back, and that word is
    /// left alone from then on.
    private func applyAutoCorrection(_ word: String) -> Bool {
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
        haptic(.correction)
        if !suggestionBar.isHidden { suggestionBar.flashCorrection(new) }
        return true
    }

    @objc private func insertReturn() {
        if emojiSearch != nil {
            // The blue key: the search is done, back to the letters.
            endEmojiSearch(backToEmoji: false)
            buildCharacterKeys()
            return
        }
        let word = currentWord()
        commitTouches(typed: word, as: word)
        learnCurrentWord()
        insert("\n")
    }

    @objc private func backspaceDown() {
        click(.delete)
        if emojiSearch != nil {
            editEmojiSearch(adding: nil)
            return
        }
        if let change = lastAutoZWNJ, (proxy.documentContextBeforeInput ?? "").hasSuffix(change.inserted) {
            lastAutoZWNJ = nil
            zwnjDeclined.insert(String(change.original.dropLast()))
            if zwnjDeclined.count > 300 { zwnjDeclined.remove(zwnjDeclined.first!) }
            UserDefaults.standard.set(Array(zwnjDeclined), forKey: "zwnjDeclined")
            for _ in 0..<change.inserted.count { deleteBackward() }
            insert(change.original)
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

    private func repeatWords() {
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
    private func deleteWordBackward() {
        let before = proxy.documentContextBeforeInput ?? ""
        guard !before.isEmpty else { return deleteBackward() }
        var rest = Substring(before)
        while let last = rest.last, last == " " || last == "\u{00A0}" { rest.removeLast() }
        let word = currentWord(before: String(rest))
        let count = before.count - rest.count + (word.isEmpty ? 1 : word.count)
        for _ in 0..<min(count, before.count) { deleteBackward() }
    }

    @objc private func backspaceUp() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Suggestions

    /// The word the cursor is at the end of: Persian letters and ZWNJ, or English letters
    /// and inner apostrophes. `known` is the text before the cursor when the caller has it.
    private func currentWord(before known: String? = nil) -> String {
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
    private func typingContext(before word: String, separated: Bool = false) -> Lexicon.Context {
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
    private func learnCurrentWord() {
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
    private func updateNeighbours() {
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
    private func cased(_ suggestion: String, like typed: String) -> String {
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
    private func updateSuggestions() {
        guard isViewLoaded else { return }
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
            lexicon.learn(item.text)
            return
        }
        let word = currentWord()
        let context = typingContext(before: word)
        commitTouches(typed: word, as: item.text)
        lastGlide = nil
        for _ in 0..<word.count { deleteBackward() }
        lexicon.learn(item.text, after: context, confirmed: item.literal)
        insert(item.text + " ")
        lastSpace = (CACurrentMediaTime(), 0)
    }

    // MARK: - TapMap

    private struct TypedTouch {
        let character: String
        /// In the keys area, which had `size`.
        let point: CGPoint
        let size: CGSize
        let time: CFTimeInterval
    }

    /// Touches are learned per language and orientation.
    private var touchLayout: String { "\(isEnglish ? "en" : "fa").\(isLandscape ? "l" : "p")" }

    /// The text before the cursor, with the keyboard's last insertion added while the proxy has
    /// not caught up with it yet.
    private func contextBefore() -> String {
        let before = proxy.documentContextBeforeInput ?? ""
        // By scalars: a ZWNJ joins the letter before it into one Character.
        if let last = lastInsertion, CACurrentMediaTime() - last.time < 0.3,
           !before.unicodeScalars.reversed().starts(with: last.text.unicodeScalars.reversed()) {
            return before + last.text
        }
        return before
    }

    private func noteTouch(_ character: String, at point: CGPoint) {
        guard options.learnTouches, layer == .letters else { return }
        let now = CACurrentMediaTime()
        if let deleted = deletedTouches.popLast(), now - deleted.time < 5, deleted.character != character {
            learnTouch(deleted, meant: character)
        }
        wordTouches.append(TypedTouch(character: character, point: point, size: keysView.bounds.size, time: now))
    }

    /// Backspace took the last letter: a tap or two keeps its touch for the letter typed in its
    /// place; holding backspace is rewriting, not correcting a slip.
    private func touchDeleted(repeating: Bool) {
        guard let last = wordTouches.popLast(), !repeating, deletedTouches.count < 2 else {
            deletedTouches.removeAll()
            return
        }
        deletedTouches.append(TypedTouch(character: last.character, point: last.point, size: last.size,
                                         time: CACurrentMediaTime()))
    }

    private func learnTouch(_ touch: TypedTouch, meant character: String) {
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
    private func commitTouches(typed: String, as word: String) {
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
    private func retarget(_ point: CGPoint, hit: KeyView) -> KeyView? {
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
    private func letterWeights() -> [String: Double] {
        guard lexicon.isLoaded else { return [:] }
        let word = currentWord(before: contextBefore())
        if let cache = letterWeightsCache, cache.word == word, cache.english == isEnglish { return cache.weights }
        let weights = lexicon.continuationWeights(after: word, letters: characterKeys.joined().compactMap(\.character))
        letterWeightsCache = (word, isEnglish, weights)
        return weights
    }

    // MARK: - Glide typing

    /// The letter keys of the letters layer, by the (lowercase) letter they type.
    private func letterCenters() -> [Character: CGPoint] {
        var centers: [Character: CGPoint] = [:]
        for key in characterKeys.flatMap({ $0 }) {
            if let character = key.character, character.count == 1, let letter = character.first, letter.isLetter {
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
    private func finishGlide() {
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
        log.info("glide: \(words.count) readings")
    }

    // MARK: - Key popups

    @objc private func keyDown(_ key: KeyView) {
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

    @objc private func keyUp(_ key: KeyView) {
        keyPopup.hidePreview(of: key)
    }

    private func variantsPress() -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(variantsPressed(_:)))
        press.minimumPressDuration = 0.4
        return press
    }

    /// Holding a key opens its other forms; sliding over them picks one and lifting the finger
    /// types it. Lifting far from them types nothing.
    @objc private func variantsPressed(_ press: UILongPressGestureRecognizer) {
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
                                      anchor: anchored.flatMap { $0.forms.firstIndex(of: $0.anchor) })
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

    private static let persianDigits = ["۰", "۱", "۲", "۳", "۴", "۵", "۶", "۷", "۸", "۹"]
    private static let latinDigits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// A digit in the other script: Persian and Latin digits each offer the other.
    private static func digitPair(_ text: String) -> String? {
        if let index = persianDigits.firstIndex(of: text) { return latinDigits[index] }
        if let index = latinDigits.firstIndex(of: text) { return persianDigits[index] }
        return nil
    }

    /// What holding a key offers, its own character first: a digit with the other script's;
    /// a top-row letter with its digit in the layout's script, then in the other; then the
    /// letter's other forms.
    private func forms(of key: KeyView) -> [String] {
        let character = key.character ?? ""
        if let other = Self.digitPair(character) { return [character, other] }
        let own = isEnglish ? (key.title ?? character) : character
        var forms = [own]
        if let hint = key.hint, let other = Self.digitPair(hint) { forms += [hint, other] }
        if !isEnglish { forms += (Self.variants[character] ?? []).dropFirst() }
        return forms.count > 1 ? forms : []
    }

    /// A form as the popup shows it: a mark on a dotted circle, anything else as text.
    private static func popupItem(_ text: String) -> KeyPopupView.Item {
        isMark(text) ? KeyPopupView.Item(text: text, label: "", image: KeyIcons.mark(text, size: 30))
            : KeyPopupView.Item(text: text, label: text)
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
        haptic(.impact(.light))
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
    /// Glides start on a letter key of the letters layer. The language swipe on the space bar
    /// waits while a key's forms are open.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === spacePan { return !keyPopup.isShowingVariants }
        guard gestureRecognizer === glidePan else { return true }
        guard layer == .letters, emojiSearch == nil, !isCompact, keyMenu.isHidden, !keyPopup.isShowingVariants,
              lexicon.isLoaded else { return false }
        let point = glidePan.location(in: keysView)
        let moved = glidePan.translation(in: keysView)
        return letterKey(at: CGPoint(x: point.x - moved.x, y: point.y - moved.y)) != nil
    }
}

/// A key with an optional background and outline (see `KeyStyle`) and a faint highlight
/// while pressed. Emoji keys keep no background.
/// The keys' container, which lets TapMap hand a touch on a letter key to a neighbour.
private final class KeysView: UIView {
    var retarget: ((CGPoint, KeyView) -> KeyView?)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let key = hit as? KeyView, key.superview === self, let other = retarget?(point, key) else { return hit }
        return other
    }
}

/// One key: a rounded face with a letter, a symbol or a status message (the space bar), drawn
/// inside its touch area as the system keyboard draws its keys, in the colours of `KeyStyle`.
private final class KeyView: UIControl {
    /// Everything drawn, moved down and in a little while the key is pressed.
    private let content = UIView()
    private let face = UIView()
    private let label = UILabel()
    /// Holds the label inside the drawn key: a letter wider than the key is cut off there.
    private let labelClip = UIView()
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
            label.font = keyFont(for: storedTitle, size: fontSize)
            label.textColor = textColor
        }
        imageView.isHidden = message != nil
        trailingImageView.isHidden = message != nil
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
        content.addSubview(face)
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
        labelClip.frame = inner
        // Words (ABC, 123, status messages) keep off the edges and shrink to fit. Letters all
        // keep the chosen size: one wider than the key (ص ض س ش when large) sits against the
        // key's right edge, where it starts, and the rest is cut off.
        let isLetter = message == nil && (label.text?.count ?? 0) == 1
        label.adjustsFontSizeToFitWidth = !isLetter
        label.lineBreakMode = isLetter ? .byClipping : .byTruncatingTail
        let room = labelClip.bounds.insetBy(dx: isLetter ? 1 : 4, dy: 0)
        let textWidth = isLetter ? ceil(label.intrinsicContentSize.width) : 0
        if isLetter, textWidth > room.width {
            label.frame = CGRect(x: labelClip.bounds.maxX - textWidth, y: 0, width: textWidth, height: labelClip.bounds.height)
        } else {
            label.frame = room
        }
        imageView.frame = inner
        if hint != nil {
            let size = max(9, (inner.height * 0.24).rounded())
            hintLabel.font = AppFont.font(ofSize: size)
            hintLabel.frame = CGRect(x: inner.maxX - size - 3, y: inner.minY + 1, width: size + 2, height: size + 2)
        }
        if let image = trailingImageView.image {
            let width = min(inner.width / 3, image.size.width + 20)
            trailingImageView.frame = CGRect(x: inner.maxX - width, y: inner.minY, width: width, height: inner.height)
        }
        trailingImageView.isHidden = message != nil
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
private enum Haptics {
    @MainActor static var isOn = true
}

private final class KeyPopupView: UIView {
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
    }

    /// A letter's forms start over the key, its own letter first, and run to the left, or to
    /// the right with `toTheRight`. With `anchor`, the items run left to right and the one at
    /// `anchor` starts over the key and is chosen first.
    func showVariants(_ items: [Item], on key: KeyView, style: KeyStyle,
                      toTheRight: Bool = false, anchor: Int? = nil) {
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
        select(index: anchor ?? 0, feedback: false)
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
/// While the recording starts, an arc turns around it. While recording it swells with the
/// speaker's voice and breathes softly in silence; a teal ring fills until the next piece of
/// live text arrives. After the recording, a blue ring fills while the app transcribes. The
/// rings hug the orb and swell with it.
/// The whole view is one button: it stops the recording, or cancels the transcription.
private final class DictationOrbView: UIControl {
    enum Mode { case starting, recording, processing }

    var mode = Mode.starting {
        didSet { if mode != oldValue { update() } }
    }

    /// While the space bar is held: how the recording ends (lift the finger, or tap once locked).
    var recordingHint: String? {
        didSet { if mode == .recording, recordingHint != oldValue { caption.text = recordingHint ?? Self.listeningCaption } }
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
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The size it had before the 2026-10-11 changes, with room for the voice to swell it.
        let diameter = min(bounds.height - 64, 112)
        let center = CGPoint(x: bounds.midX, y: (bounds.height - 30) / 2 + 2)
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
            setLoading(true)
            // The empty track under the turning arc.
            liveRing.track.isHidden = false
            liveRing.ring.isHidden = true
            processingRing.isHidden = true
            caption.text = "…"
        case .recording:
            gradient.opacity = 1
            setLoading(false)
            setMotion(true)
            liveRing.track.isHidden = false
            liveRing.ring.isHidden = !liveRing.isRunning
            processingRing.isHidden = true
            caption.text = recordingHint ?? Self.listeningCaption
        case .processing:
            gradient.opacity = 0.35
            setLoading(false)
            setMotion(false)
            liveRing.isHidden = true
            processingRing.isHidden = false
            caption.text = "در حال تبدیل به متن… برای لغو بزنید"
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
            let text = !heardVoice && now - motionStart > 3.5 ? "صدایی نمی‌شنوم…" : recordingHint ?? Self.listeningCaption
            if caption.text != text { caption.text = text }
        }
    }

    override var isHighlighted: Bool {
        didSet { pulse.opacity = isHighlighted ? 0.7 : 1 }
    }
}

/// The app's font has no Latin letters: Latin text set in it falls back to the system font on
/// the Persian font's taller line and sits high in a key. Text without Persian letters or digits
/// is set in the system font.
private func keyFont(for text: String?, size: CGFloat) -> UIFont {
    let persian = text?.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0xFB50...0xFEFF).contains($0.value) }
    return persian == false ? .systemFont(ofSize: size) : AppFont.font(ofSize: size)
}

/// Images for keys that no SF Symbol fits, drawn as templates so they take the key colour.
private enum KeyIcons {
    /// Return, drawn as in a left-to-right layout: the symbol image itself would be mirrored
    /// in this right-to-left keyboard.
    static let returnKey = leftToRight("return")
    /// Return for Persian, mirrored: the arrow comes down on the left and points right.
    static let returnKeyMirrored: UIImage = {
        let image = returnKey
        return UIGraphicsImageRenderer(size: image.size).image { context in
            context.cgContext.translateBy(x: image.size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.withTintColor(.black).draw(at: .zero)
        }.withRenderingMode(.alwaysTemplate)
    }()
    /// Backspace pointing left for English, and right as before for Persian.
    static let deleteLeft = leftToRight("delete.left")
    static let deleteRight = leftToRight("delete.right")

    /// An SF Symbol as drawn left to right, as a template that no layout direction flips.
    private static func leftToRight(_ name: String) -> UIImage {
        let traits = UITraitCollection(layoutDirection: .leftToRight)
        guard let symbol = UIImage(systemName: name, compatibleWith: traits)?
            .applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 19)) else {
            return UIImage()
        }
        return UIGraphicsImageRenderer(size: symbol.size).image { _ in
            symbol.withTintColor(.black).draw(at: .zero)
        }.withRenderingMode(.alwaysTemplate)
    }

    /// The space bar: a globe between arrows, for swiping between Persian and English.
    /// The space bar's mic in a plain ring: orange while the app's session is on, grey and
    /// struck through once it has ended (holding space then opens the app).
    static let spaceMic = ringedMic("mic.fill", color: .systemOrange)
    static let spaceMicOff = ringedMic("mic.slash.fill", color: .systemGray)

    private static func ringedMic(_ name: String, color: UIColor) -> UIImage {
        let side: CGFloat = 22
        let ring = UIColor(white: 0.56, alpha: 0.9)
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return UIImage() }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let circle = UIBezierPath(ovalIn: CGRect(x: 0.75, y: 0.75, width: side - 1.5, height: side - 1.5))
            circle.lineWidth = 1.2
            ring.setStroke()
            circle.stroke()
            symbol.draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
        }.withRenderingMode(.alwaysOriginal)
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
/// A label with room around its text, for the highlight behind a corrected word.
private final class PaddedLabel: UILabel {
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitted = super.sizeThatFits(size)
        return CGSize(width: fitted.width + 16, height: fitted.height + 6)
    }
}

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
    /// Follows the letters' size setting: 19 points at the standard 23.
    var fontSize: CGFloat = 19 {
        didSet { if fontSize != oldValue { show(items) } }
    }
    private var slots: [UIButton] = []
    private var dividers: [UIView] = []
    /// Right, middle, left.
    private var items: [Item?] = [nil, nil, nil]

    override init(frame: CGRect) {
        super.init(frame: frame)
        for index in 0..<3 {
            let slot = UIButton(type: .custom)
            slot.titleLabel?.font = AppFont.font(ofSize: 19)
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

    private var flash: UILabel?

    /// A word just corrected, on a solid yellow highlight, falls into the middle of the bar and
    /// stays a moment while the suggestions step aside; the host's text cannot be marked by a
    /// keyboard, so the bar shows it instead.
    func flashCorrection(_ word: String) {
        flash?.removeFromSuperview()
        let label = PaddedLabel()
        label.text = word
        label.font = keyFont(for: word, size: fontSize)
        label.textColor = .black
        label.backgroundColor = UIColor(red: 1, green: 0.84, blue: 0.24, alpha: 1)
        label.layer.cornerRadius = 8
        label.layer.cornerCurve = .continuous
        label.layer.masksToBounds = true
        label.textAlignment = .center
        let size = label.sizeThatFits(bounds.size)
        let width = min(bounds.width * 0.6, size.width)
        let height = min(bounds.height - 4, size.height)
        label.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        addSubview(label)
        flash = label
        slots.forEach { $0.isHidden = true }
        dividers.forEach { $0.alpha = 0 }
        label.alpha = 0
        label.transform = CGAffineTransform(translationX: 0, y: -bounds.height * 0.7).scaledBy(x: 1.15, y: 1.15)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.8) {
            label.alpha = 1
            label.transform = .identity
        }
        UIView.animate(withDuration: 0.25, delay: 1.3, options: [.beginFromCurrentState, .allowUserInteraction]) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
            guard self.flash === label else { return }
            self.flash = nil
            self.slots.forEach { $0.isHidden = false }
            self.dividers.forEach { $0.alpha = 1 }
        }
    }

    /// Items right to left; nil leaves a slot empty.
    func show(_ items: [Item?]) {
        self.items = (items + [nil, nil, nil]).prefix(3).map { $0 }
        for (slot, item) in zip(slots, self.items) {
            slot.setTitle(item.map { $0.literal ? "«\($0.text)»" : $0.text }, for: .normal)
            slot.titleLabel?.font = keyFont(for: item?.text, size: fontSize)
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
