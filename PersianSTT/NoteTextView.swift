import SwiftUI
import UIKit

/// Drives the note's text view from outside: dictated text going in at the cursor (live text
/// in grey, replaced by the final text of each piece) and the sentence being read aloud.
@MainActor
final class NoteEditorController: ObservableObject {
    fileprivate weak var textView: NoteUITextView?
    /// Where the live text is while a piece is spoken.
    private var live: NSRange?
    /// Where the next piece goes.
    private var insertion = 0
    private var highlighted: NSRange?
    /// Called with the whole text after a change made here.
    var onChange: (String) -> Void = { _ in }

    /// The user is typing in the note (for the Done button).
    @Published fileprivate(set) var focused = false

    func beginDictation() {
        guard let textView else { return }
        let length = (textView.text as NSString).length
        insertion = textView.isFirstResponder ? min(textView.selectedRange.location, length) : length
        textView.resignFirstResponder()
        textView.isEditable = false
        live = nil
    }

    func showPartial(_ text: String) {
        guard let textView else { return }
        if text.isEmpty {
            removeLive()
            return
        }
        let piece = spaced(text, at: live?.location ?? insertion, replacing: live?.length ?? 0)
        let range = live ?? NSRange(location: insertion, length: 0)
        let attributed = NSAttributedString(string: piece, attributes: textView.attributes(color: .secondaryLabel))
        textView.textStorage.replaceCharacters(in: range, with: attributed)
        live = NSRange(location: range.location, length: (piece as NSString).length)
        textView.scrollRangeToVisible(live!)
    }

    func commit(_ text: String) {
        guard let textView else { return }
        let range = live ?? NSRange(location: insertion, length: 0)
        let piece = spaced(text, at: range.location, replacing: range.length)
        textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: piece, attributes: textView.attributes()))
        live = nil
        insertion = range.location + (piece as NSString).length
        textView.applyDirections(around: NSRange(location: range.location, length: (piece as NSString).length))
        textView.scrollRangeToVisible(NSRange(location: insertion, length: 0))
        onChange(textView.text)
    }

    func endDictation() {
        removeLive()
        guard let textView else { return }
        textView.isEditable = true
        textView.selectedRange = NSRange(location: min(insertion, (textView.text as NSString).length), length: 0)
    }

    /// Highlights the sentence being read (nil clears it).
    func highlight(_ range: NSRange?) {
        guard let textView else { return }
        let length = textView.textStorage.length
        if let old = highlighted, NSMaxRange(old) <= length {
            textView.textStorage.removeAttribute(.backgroundColor, range: old)
        }
        highlighted = nil
        guard let range, NSMaxRange(range) <= length else { return }
        textView.textStorage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: range)
        highlighted = range
        textView.scrollRangeToVisible(range)
    }

    /// Replaces the whole text (the «یکسان‌سازی» and digits commands), keeping the cursor.
    func replaceAll(_ text: String) {
        guard let textView else { return }
        let selection = textView.selectedRange
        textView.setNote(text)
        textView.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        onChange(text)
    }

    private func removeLive() {
        guard let textView, let live else { return }
        textView.textStorage.replaceCharacters(in: live, with: "")
        self.live = nil
    }

    /// `text` with a space before it after a word, and after it before one.
    private func spaced(_ text: String, at location: Int, replacing length: Int) -> String {
        guard let textView else { return text }
        let ns = textView.text as NSString
        var out = text
        if location > 0, let before = Unicode.Scalar(ns.character(at: location - 1)),
           !CharacterSet.whitespacesAndNewlines.contains(before) {
            out = " " + out
        }
        let after = location + length
        if after < ns.length, let next = Unicode.Scalar(ns.character(at: after)),
           !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains(next) {
            out += " "
        }
        return out
    }
}

/// The text view: each paragraph reads from the side of its own language (`PersianText
/// .isRightToLeft`), Arabic letters typed or pasted become Persian ones, and pasted text gets
/// Persian ZWNJ and spacing (`PersianText.normalized`).
final class NoteUITextView: UITextView {
    var defaultRTL = !AppLanguage.english
    var bodyFont: UIFont = AppFont.font(ofSize: 19)

    func attributes(color: UIColor = .label) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: color]
    }

    func setNote(_ text: String) {
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes()))
        applyDirections(around: NSRange(location: 0, length: textStorage.length))
    }

    /// Sets each paragraph touching `range` right to left or left to right by its letters.
    func applyDirections(around range: NSRange) {
        let ns = textStorage.string as NSString
        guard ns.length > 0 else {
            typingAttributes[.paragraphStyle] = Self.style(rtl: defaultRTL)
            return
        }
        let start = min(range.location, ns.length)
        var paragraph = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, ns.length - start)))
        let end = NSMaxRange(paragraph)
        var location = paragraph.location
        textStorage.beginEditing()
        while location < end {
            paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let rtl = PersianText.isRightToLeft(Substring(ns.substring(with: paragraph)), defaultRTL: defaultRTL)
            textStorage.addAttribute(.paragraphStyle, value: Self.style(rtl: rtl), range: paragraph)
            location = NSMaxRange(paragraph)
            if paragraph.length == 0 { break }
        }
        textStorage.endEditing()
        let caret = min(selectedRange.location, ns.length)
        let current = ns.paragraphRange(for: NSRange(location: caret, length: 0))
        let rtl = PersianText.isRightToLeft(Substring(ns.substring(with: current)), defaultRTL: defaultRTL)
        typingAttributes = attributes().merging([.paragraphStyle: Self.style(rtl: rtl)]) { $1 }
    }

    static func style(rtl: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.alignment = .natural
        style.lineSpacing = 6
        style.paragraphSpacing = 8
        return style
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return super.paste(sender) }
        let normalized = PersianText.normalized(text)
        guard let range = selectedTextRange else { return }
        replace(range, withText: normalized)
    }
}

struct NoteTextView: UIViewRepresentable {
    let text: String
    let controller: NoteEditorController
    var editable = true
    let onChange: (String) -> Void

    func makeUIView(context: Context) -> NoteUITextView {
        let view = NoteUITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = view.bodyFont
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 80, right: 12)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.setNote(text)
        controller.textView = view
        controller.onChange = onChange
        return view
    }

    func updateUIView(_ view: NoteUITextView, context: Context) {
        controller.textView = view
        controller.onChange = onChange
        // A change from outside (a transcribed file adding text): the view follows unless
        // the user is typing or dictating into it.
        if view.text != text, view.isEditable, view.markedTextRange == nil, !view.isFirstResponder {
            let selection = view.selectedRange
            view.setNote(text)
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: NoteTextView
        private var edited = NSRange(location: 0, length: 0)

        init(_ parent: NoteTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            edited = NSRange(location: range.location, length: (text as NSString).length)
            // Arabic ي ك and digits from other keyboards, written the Persian way.
            let unified = PersianText.unifyingLetters(text)
            guard unified != text, let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return true }
            textView.replace(textRange, withText: unified)
            return false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.controller.focused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.controller.focused = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? NoteUITextView else { return }
            if view.markedTextRange == nil { view.applyDirections(around: edited) }
            parent.onChange(view.text)
        }
    }
}
