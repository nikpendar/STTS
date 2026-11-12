import UIKit
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "keyboard")

extension KeyboardViewController {
    // MARK: - Handwriting

    func showHandwriting() {
        guard handwritingPad == nil else { return }
        emojiReturnsToHandwriting = false
        endEmojiSearch(backToEmoji: false)
        if layer == .emoji {
            layer = .letters
            buildCharacterKeys()
        }
        let pad = HandwritingPadView(frame: keysView.frame)
        pad.rightToLeft = !isEnglish
        pad.slides = options.handwritingSlide
        pad.speed = options.handwritingSpeed
        pad.onGripFeedback = { [weak self] taken in self?.haptic(.impact(taken ? .heavy : .medium)) }
        pad.textColor = keyStyle.textColor
        pad.onInsert = { [weak self] text in
            guard let self else { return }
            // A word after a word: one space between, as typing would leave it.
            let before = self.proxy.documentContextBeforeInput ?? ""
            // No space before a mark (؟ ! . ، ؛ : and closing brackets), nor after an opening one.
            let closes = text.unicodeScalars.first.map { CharacterSet.punctuationCharacters.contains($0) && !"([{«".unicodeScalars.contains($0) } ?? false
            let opened = before.last.map { "([{«".contains($0) } ?? false
            let gap = before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n") || closes || opened ? "" : " "
            self.insert(gap + text)
        }
        pad.onReplace = { [weak self] old, new in
            guard let self, (self.proxy.documentContextBeforeInput ?? "").hasSuffix(old) else { return }
            for _ in old { self.proxy.deleteBackward() }
            self.insert(new)
        }
        pad.onWordRead = { [weak self] in self?.haptic(.impact(.soft)) }
        pad.pause = options.handwritingPause
        pad.inkWidth = CGFloat(options.handwritingInkWidth)
        pad.inkColor = options.handwritingInk.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
        pad.onStepSize = { [weak self] step in
            guard let self else { return false }
            return self.setHandwritingSize(self.options.handwritingSize + step)
        }
        pad.onResetSize = { [weak self] in
            _ = self?.setHandwritingSize(1)
        }
        pad.onSpace = { [weak self] in self?.handwritingSpace() }
        // One tap, one word (Rooz, 2026-11-09); held, a word at a time after a moment.
        pad.onDeleteDown = { [weak self] in
            guard let self else { return }
            self.click(.delete)
            self.deleteWordBackward()
            self.repeatTimer?.invalidate()
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.repeatWords() }
            }
        }
        pad.onDeleteUp = { [weak self] in self?.backspaceUp() }
        pad.onReturn = { [weak self] in self?.insertReturn() }
        pad.onEmoji = { [weak self] in
            guard let self else { return }
            self.hideHandwriting(animated: false)
            self.emojiReturnsToHandwriting = true
            self.toggleEmoji()
        }
        pad.onClose = { [weak self] in self?.hideHandwriting(animated: true) }
        pad.onFeedback = { [weak self] in self?.haptic(.key) }
        pad.returnImage = returnKey.image
        pad.textBefore = { [weak self] in self?.proxy.documentContextBeforeInput ?? "" }
        pad.rank = { [weak self] texts in self?.rankHandwriting(texts) ?? texts }
        pad.showsGuide = options.handwritingGuide
        pad.showsStrip = options.handwritingStrip
        pad.guideLines = options.handwritingSize + 1
        view.addSubview(pad)
        handwritingPad = pad
        heightChanged()
        pad.alpha = 0
        UIView.animate(withDuration: 0.2) {
            pad.alpha = 1
            self.keysView.alpha = 0
        }
        pad.start()
    }

    func hideHandwriting(animated: Bool) {
        guard let pad = handwritingPad else { return }
        handwritingPad = nil
        heightChanged()
        // A delete held on the pad stops with it.
        backspaceUp()
        pad.commitPending()
        pad.stop()
        if animated {
            UIView.animate(withDuration: 0.2, animations: {
                pad.alpha = 0
                self.keysView.alpha = 1
            }, completion: { _ in pad.removeFromSuperview() })
        } else {
            keysView.alpha = 1
            pad.removeFromSuperview()
        }
        updateSuggestions()
    }

    /// The recognizer's readings in the order to offer them (Rooz, 2026-11-11): readings in the
    /// keyboard's language first, then words the keyboard knows, likelier after the word
    /// before, and words of the personal dictionary; otherwise the recognizer's own order.
    func rankHandwriting(_ texts: [String]) -> [String] {
        guard texts.count > 1 else { return texts }
        let english = isEnglish
        let personal = Set(dictionary.boostWords.map { Lexicon.shared.wordKey($0) })
        let context = typingContext(before: "", separated: true)
        func script(_ text: String) -> Bool? {  // true Latin, false Persian, nil neither
            var latin = false, persian = false
            for scalar in text.unicodeScalars {
                if ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) { latin = true }
                if (0x0600...0x06FF).contains(scalar.value) || (0xFB50...0xFEFF).contains(scalar.value) { persian = true }
            }
            return latin == persian ? nil : latin
        }
        let scored = texts.enumerated().map { index, text -> (text: String, score: Double) in
            var score = -0.6 * Double(index)
            let latin = script(text)
            if let latin { score += latin == english ? 3 : -3 }
            if let latin, !text.contains(" ") {
                let lexicon: Lexicon = latin ? .english : .shared
                if lexicon.isLoaded {
                    if let known = lexicon.wordScore(text, context: latin == english ? context : .none) {
                        score += min(3, max(0, 0.5 * (known - 3)))
                    } else if text.count > 1 {
                        score -= 1
                    }
                }
                if !latin, personal.contains(Lexicon.shared.wordKey(text)) { score += 2 }
            }
            return (text, score)
        }
        // A stable sort: equal scores keep the recognizer's order.
        return scored.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element.text)
    }
}
