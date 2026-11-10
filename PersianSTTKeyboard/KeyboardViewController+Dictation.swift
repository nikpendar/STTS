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
        }
    }

    @objc func micTapped() {
        switch state {
        case .ready:
            startDictation(held: false)
        case .recording where isLocked:
            // Locked: the orb pauses and resumes; the middle of the orange bar ends it.
            setPaused(!isPaused)
        case .recording:
            endRecording()
        case .noSession, .checking:
            askForSession()
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

    func endRecording() {
        DictationBridge.post(DictationBridge.stop)
        beginTranscribing()
    }

    /// `tell`: false when the app paused it itself and only the orb has to show it.
    func setPaused(_ paused: Bool, tell: Bool = true) {
        guard paused != isPaused else { return }
        isPaused = paused
        if tell {
            haptic(.impact(.light))
            DictationBridge.post(paused ? DictationBridge.pause : DictationBridge.resume)
        }
        orb.paused = paused
        orb.accessibilityLabel = paused ? "ادامه‌ی ضبط" : "مکث ضبط"
    }

    /// iOS took the microphone (a call, Siri, its own dictation) and the app paused the
    /// recording: a locked one shows the pause and goes on after a tap on the orb; a held one
    /// ends with what was said.
    func microphoneTaken() {
        guard state == .recording else { return }
        if isLocked {
            setPaused(true, tell: false)
        } else {
            isHeld = false
            endRecording()
        }
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

    /// Holding the space bar dictates as long as the finger stays down; lifting it ends the
    /// recording (a tap on the orb ends it too).
    @objc func spaceHeld(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard canDictateOnSpace else { return }
            switch state {
            case .ready:
                haptic(.impact(.medium))
                isHeld = true
                isLocked = false
                holdStartY = press.location(in: view).y
                holdLayout = true
                startDictation(held: true)
            case .noSession, .checking:
                askForSession()
            default:
                break
            }
        case .changed:
            guard isHeld, !isLocked, isMagnet, holdStartY - press.location(in: view).y > Self.lockDistance else { return }
            isLocked = true
            haptic(.impact(.rigid))
            orb.lock = .closed
            setLockedKeys(true)
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
        orb.lock = nil
        setLockedKeys(false)
        orb.liveRing.reset()
        orb.processingRing.begin(expected: min(15, max(2, recorded * 0.4)))
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
        orb.liveRing.reset()
        orb.resetVoice()
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
        guard state == .recording || state == .transcribing else { return }
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
            // punctuation (removed 2026-11-05): the personal dictionary writes marks said aloud,
            // and the locked bar deletes and starts a new line.
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
                liveDraft = draft
                let shown = afterSettled(draft)
                if !shown.isEmpty { replaceLiveText(with: shown) }
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

    /// Return on the split orange bar of a locked recording: what was said so far stays, and
    /// the dictation goes on on the next line.
    @objc func lockedReturnTapped() {
        guard state == .recording, isLocked else { return }
        click(.modifier)
        settleLiveText()
        insert("\n", dictated: true)
        livePrefix = ""
    }

    /// Delete on the split orange bar: the last word goes (the line break, right after a return),
    /// and the dictation goes on from there.
    @objc func lockedDeleteTapped() {
        guard state == .recording, isLocked else { return }
        click(.delete)
        settleLiveText()
        if proxy.documentContextBeforeInput?.last == "\n" { deleteBackward() } else { deleteWordBackward() }
        livePrefix = spaceBeforeDictation()
    }

    /// Keeps the provisional text typed so far as it is: later results add only what follows.
    func settleLiveText() {
        settledWords = liveDraft.split(separator: " ").count
        liveText = ""
        dictationEdited = true
    }

    /// Swaps the provisional text for `text`, deleting only the part that changed.
    func replaceLiveText(with text: String) {
        guard isOnScreen else {
            liveText = ""
            return
        }
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
