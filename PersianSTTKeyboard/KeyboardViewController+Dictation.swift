import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "keyboard")

extension KeyboardViewController {
    // MARK: - Session

    func checkSession() {
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

    func sessionIsAlive() {
        if state == .checking || state == .noSession {
            cancelTimeout()
            state = .ready
            askToRejoin()
        }
    }

    func endRecording() {
        DictationBridge.post(DictationBridge.stop)
        beginTranscribing()
    }

    /// iOS took the microphone (a call, Siri, its own dictation) and the app paused the
    /// recording: it ends with what was said.
    func microphoneTaken() {
        guard state == .recording else { return }
        isHeld = false
        isLocked = false
        endRecording()
    }

    /// Asks the app to record. `held`: while a finger holds the space bar, which the app then
    /// does not stop by itself after a silence.
    func startDictation(held: Bool) {
        state = .starting
        DictationBridge.post(held ? DictationBridge.startHeld : DictationBridge.start)
        // No answer means the app was closed and the session is gone.
        schedule(after: 0.8) { [weak self] in
            if self?.state == .starting { self?.state = .noSession }
        }
    }

    // MARK: - Screen lock

    /// A locked recording when the keyboard goes off screen (the screen locking, or another app
    /// or keyboard): what it typed so far is kept, and the app decides whether to go on.
    func leaveLockedRecording() {
        let before = isOnScreen ? proxy.documentContextBeforeInput ?? "" : ""
        AwayDictation(tail: String(before.suffix(40)), liveText: liveText, livePrefix: livePrefix,
                      liveDraft: liveDraft, settledWords: settledWords, recordingStart: recordingStart,
                      savedAt: Date()).save()
        log.info("keyboard left a locked recording")
        DictationBridge.post(DictationBridge.away)
        isHeld = false
        isLocked = false
        stopWhenRecording = false
        liveText = ""
        state = .ready
    }

    /// Once the session answers: a recording this keyboard (or an earlier one) left is asked for.
    func askToRejoin() {
        guard AwayDictation.load() != nil else { return }
        rejoinAsked = true
        DictationBridge.post(DictationBridge.rejoin)
        // No answer: the app cancelled it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.rejoinAsked else { return }
            self.rejoinAsked = false
            AwayDictation.clear()
        }
    }

    /// The app still has the recording: back in the same text field, the text said meanwhile
    /// follows the words typed before, and a recording still going on goes on locked.
    func rejoin(recording: Bool) {
        guard rejoinAsked, let away = AwayDictation.load(), state == .ready else { return }
        rejoinAsked = false
        AwayDictation.clear()
        let before = isOnScreen ? proxy.documentContextBeforeInput ?? "" : ""
        let same = away.tail.isEmpty ? before.isEmpty : before.hasSuffix(String(away.tail.suffix(24)))
        guard isOnScreen, same else {
            log.info("back in another text field: the recording left behind is dropped")
            DictationBridge.post(DictationBridge.cancel)
            return
        }
        log.info("back to a recording that \(recording ? "goes on" : "ended", privacy: .public)")
        liveText = away.liveText
        livePrefix = away.livePrefix
        liveDraft = away.liveDraft
        settledWords = away.settledWords
        recordingStart = away.recordingStart
        // Its corrections could not be matched to the recording.
        dictationEdited = true
        isHeld = false
        if recording {
            isLocked = true
            state = .recording
        } else {
            isLocked = false
            lastRecordedSeconds = Date().timeIntervalSince(recordingStart)
            state = .transcribing
            schedule(after: 90) { [weak self] in
                if self?.state == .transcribing { self?.transcriptionFailed() }
            }
        }
        fetchTranscript()
    }

    /// Holding the space bar dictates as long as the finger stays down; lifting it ends the
    /// recording. Sliding left to the lock keeps it going after the finger is lifted.
    @objc func spaceHeld(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard canDictateOnSpace else { return }
            switch state {
            case .ready:
                haptic(.impact(.medium))
                isHeld = true
                isLocked = false
                holdStartX = press.location(in: view).x
                startDictation(held: true)
            case .noSession, .checking:
                askForSession()
            default:
                break
            }
        case .changed:
            guard isHeld, !isLocked, state == .starting || state == .recording else { return }
            let slid = holdStartX - press.location(in: view).x
            spaceVoice.lockProgress = max(0, min(1, slid / Self.lockDistance))
            guard slid > Self.lockDistance else { return }
            isLocked = true
            haptic(.impact(.rigid))
            updateSpaceVoice()
        case .ended, .cancelled, .failed:
            if isLocked {
                isHeld = false
            } else if isHeld {
                releaseHold()
            }
        default:
            break
        }
    }

    /// The finger left the space bar: the recording ends and its text goes in. A recording the
    /// app has not confirmed yet ends as soon as it does.
    func releaseHold() {
        isHeld = false
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


    func beginTranscribing() {
        state = .transcribing
        // A first guess, until the app's own estimate arrives.
        let recorded = Date().timeIntervalSince(recordingStart)
        lastRecordedSeconds = recorded
        isLocked = false
        schedule(after: 90) { [weak self] in
            if self?.state == .transcribing { self?.transcriptionFailed() }
        }
    }

    /// The app ended the recording after the speaker stopped talking.
    func recordingStoppedByApp() {
        guard state == .recording else { return }
        haptic(.impact(.light))
        beginTranscribing()
    }

    /// The app dropped a recording in which nobody spoke.
    func nobodySpoke() {
        guard state == .recording || state == .transcribing else { return }
        cancelTimeout()
        replaceLiveText(with: "")
        liveText = ""
        state = .ready
        showStatus("صدایی شنیده نشد", transient: true)
    }

    func recordingStarted() {
        guard state == .starting else { return }
        cancelTimeout()
        recordingStart = Date()
        state = .recording
        partialsHeard = 0
        liveText = ""
        liveDraft = ""
        settledWords = 0
        dictationEdited = false
        livePrefix = spaceBeforeDictation()
        edits.dictationStarted(documentContext, prefix: livePrefix)
        if stopWhenRecording {
            stopWhenRecording = false
            DictationBridge.post(DictationBridge.stop)
            beginTranscribing()
        }
    }

    /// As iOS dictation does: a space after a word, none after a space, a bracket or a ZWNJ.
    func spaceBeforeDictation() -> String {
        let last = proxy.documentContextBeforeInput?.unicodeScalars.last
        return last.map { $0.properties.isAlphabetic || $0.properties.numericType != nil
            || ".,!?:;)»؟،؛".unicodeScalars.contains($0) } == true ? " " : ""
    }

    func insertTranscript() {
        guard state == .transcribing else { return }
        cancelTimeout()
        fetchTranscript(final: true)
    }

    /// Reads what the app is serving, oldest message first: a provisional result replaces the
    /// previous one, the final one completes the dictation, estimates drive the rings. `final`
    /// marks the fetch started by `done`.
    func fetchTranscript(final: Bool = false) {
        // The app hands each message out once. A keyboard iOS has not freed yet hears the same
        // notifications; were it to fetch, it would take this dictation's text and drop it.
        // Nor one off screen, which would take the text and have nowhere to put it.
        guard state == .recording || state == .transcribing, isOnScreen else { return }
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

    func handle(_ message: String) {
        guard isOnScreen else {
            // A dictation that ends after the keyboard was put away has no text field to go to.
            log.info("transcript message dropped: keyboard not on screen")
            liveText = ""
            if message.first.map(String.init) == DictationBridge.finalPrefix { state = .ready }
            return
        }
        guard state == .recording || state == .transcribing, let kind = message.first.map(String.init) else {
            log.info("transcript message dropped in state \(String(describing: self.state), privacy: .public)")
            return
        }
        let body = String(message.dropFirst())
        switch kind {
        case DictationBridge.finalPrefix where !body.isEmpty:
            // Dictation id + newline + text.
            let parts = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            // No spoken punctuation or edit commands (Rooz, 2026-10-28) and no automatic
            // punctuation (removed 2026-11-05): the personal dictionary writes marks said aloud.
            let result = VoiceCommands.process(String(parts.last ?? ""), punctuation: false,
                                               commands: false, zwnj: options.autoZWNJ,
                                               dictionary: dictionary)
            perform(result)
            noteNumberJoin(result)
            cancelTimeout()
            state = .ready
            let words = result.steps.reduce(0) { count, step in
                if case .text(let text) = step { return count + text.split(whereSeparator: \.isWhitespace).count }
                return count
            }
            let seconds = lastRecordedSeconds
            UsageStats.record {
                $0.voiceWords += words
                $0.voiceSeconds += seconds
                $0.dictations += 1
            }
            UsageStats.publish()
            // Corrections of a dictation that also edited the text could not be matched to its recording.
            if parts.count == 2, !result.hasEdits, !dictationEdited, case .text(let text)? = result.steps.first {
                let id = String(parts[0])
                if !result.spoken.isEmpty { spokenForms[id] = (text, result.spoken) }
                let followed = text.split(whereSeparator: \.isWhitespace).count
                UsageStats.record { $0.addChecked(words: followed, errors: 0) }
                report(edits.dictationFinished(id: id, text: text))
                log.info("following dictation \(id, privacy: .public) for edits")
            }
        case DictationBridge.partialPrefix:
            // Empty after a live pass that found nothing new.
            if !body.isEmpty {
                let draft = VoiceCommands.draft(body, punctuation: false, commands: false,
                                                zwnj: options.autoZWNJ, dictionary: dictionary)
                if liveText.isEmpty { log.info("live text: first shown, \(draft.count) characters") }
                if draft != liveDraft { lastHeard = Date() }
                settleIfMoved()
                liveDraft = draft
                let shown = afterSettled(draft)
                if !shown.isEmpty { replaceLiveText(with: shown) }
            }
        case DictationBridge.estimatePrefix:
            guard state == .transcribing, let seconds = Double(body) else { return }
            // Only a safety net for an app that died: a slow pass must still be able to finish.
            schedule(after: max(90, 3 * seconds + 30)) { [weak self] in
                if self?.state == .transcribing { self?.transcriptionFailed() }
            }
        default:
            break
        }
    }

    /// A dictation ending in a number joined from pieces (a mark or two may follow it): one
    /// backspace puts the pieces back.
    func noteNumberJoin(_ result: VoiceCommands.Result) {
        guard let join = result.joins.last, case .text(let text)? = result.steps.last,
              let range = text.range(of: join.joined, options: .backwards) else { return }
        let tail = String(text[range.upperBound...])
        guard tail.count <= 2, !tail.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        let persian = join.spaced.map { $0.wholeNumberValue.map { Array("۰۱۲۳۴۵۶۷۸۹")[$0] } ?? $0 }
        lastNumberJoin = (join.joined + tail, String(persian) + tail)
    }

    /// A dictation's text without the words a return or delete already settled.
    func afterSettled(_ text: String) -> String {
        guard settledWords > 0 else { return text }
        return text.split(separator: " ").dropFirst(settledWords).joined(separator: " ")
    }

    /// The words shown so far stay as they are (typing while dictating): later results add only
    /// what follows them.
    func settleShownText() {
        settledWords += liveText.split(whereSeparator: \.isWhitespace).count
        liveText = ""
        dictationEdited = true
    }

    /// The live text is no longer right before the cursor (the cursor moved, or text was typed
    /// after it): it is left where it is, and the speech goes on at the cursor.
    func settleIfMoved() {
        // Only the end is compared: iOS hands out a limited stretch of the text before the cursor.
        guard !liveText.isEmpty,
              !(proxy.documentContextBeforeInput ?? "").hasSuffix(String(liveText.suffix(24))) else { return }
        settleShownText()
    }

    /// Swaps the provisional text for `text`, deleting only the part that changed.
    func replaceLiveText(with text: String) {
        guard isOnScreen else {
            liveText = ""
            return
        }
        // A new piece after typing or a moved cursor: spaced from whatever is before it now.
        if liveText.isEmpty { livePrefix = spaceBeforeDictation() }
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
    enum UndoStep {
        case inserted(String)
        case deleted(String, anchor: String)
    }

    /// Puts a finished dictation into the document: its first text replaces the live text, and
    /// editing commands run in order with the text around them.
    func perform(_ result: VoiceCommands.Result) {
        settleIfMoved()
        var first = true
        for step in result.steps {
            switch step {
            case .text(let text):
                if first {
                    replaceLiveText(with: afterSettled(text))
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

    func remember(_ step: UndoStep) {
        undoSteps.append(step)
        if undoSteps.count > 20 { undoSteps.removeFirst() }
    }

    func run(_ command: VoiceCommands.Step) {
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
}

/// What a keyboard keeps of a locked recording when it goes off screen, in its own defaults,
/// so it or the next keyboard iOS opens can go on with it in the same text field.
struct AwayDictation: Codable {
    /// The last characters before the cursor when it left, to know the text field again.
    var tail: String
    var liveText: String
    var livePrefix: String
    var liveDraft: String
    var settledWords: Int
    var recordingStart: Date
    var savedAt: Date

    private static let key = "awayDictation"

    /// nil once it is older than the longest recording.
    static func load() -> AwayDictation? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let away = try? JSONDecoder().decode(AwayDictation.self, from: data),
              Date().timeIntervalSince(away.savedAt) < 400 else { return nil }
        return away
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
