import Foundation

/// What a keyboard sees of the document: the text before the cursor, the selection and the
/// text after it. Apps may cut both ends short.
struct DocumentContext {
    var before: String
    var selected: String
    var after: String
}

/// Notices how the user changes dictated text, by typing or by dictating over it, so the
/// corrected text can teach the model (`PersonalModel` in the app).
///
/// A keyboard only sees the text around the cursor, so each dictation is followed as a region:
/// its current text and the few characters before it, by which it is found again in the
/// document before every edit. An edit the keyboard makes changes the regions the cursor is
/// in. When a region cannot be found any more (the message was sent, the user moved to another
/// field) or the keyboard closes, its text is reported if it differs from the dictation but
/// still resembles it. Text is handled as Unicode scalars, since a zero-width non-joiner joins
/// the letter before it into one Character but is typed on its own.
struct EditTracker {
    enum Edit {
        /// Text typed on the keys.
        case type(String)
        /// Text of a new dictation. At the end of an earlier one it only counts as part of it
        /// after the user deleted that end, as when re-dictating a misheard last word.
        case dictate(String)
        case deleteBackward
    }

    private typealias Scalars = [Unicode.Scalar]

    private struct Region {
        let id: String
        let original: String
        /// The text just before the dictation when it started.
        let anchor: Scalars
        var text: Scalars
        /// Cursor position relative to the start of `text`, as the keyboard's own edits move it.
        var cursor: Int
        /// Earlier (text, cursor) states, to recognise a document that lags behind fast typing.
        var history: [(Scalars, Int)] = []
        /// Characters deleted from the end. Typing at the end refills them before it counts as
        /// new text after the dictation.
        var endDeficit = 0
    }

    private var regions: [Region] = []
    private var anchor: Scalars = []
    private static let maxRegions = 5
    private static let anchorLength = 16

    var isTracking: Bool { !regions.isEmpty }

    /// `prefix` is what the keyboard puts before the dictated text, such as a space.
    mutating func dictationStarted(_ context: DocumentContext, prefix: String) {
        anchor = Array((context.before + prefix).unicodeScalars.suffix(Self.anchorLength))
    }

    /// The final text is in the document and the cursor is at its end.
    mutating func dictationFinished(id: String, text: String) -> [Correction] {
        let scalars = Array(text.unicodeScalars)
        regions.append(Region(id: id, original: text, anchor: anchor, text: scalars, cursor: scalars.count))
        var finished: [Correction] = []
        while regions.count > Self.maxRegions {
            finished += Self.report(regions.removeFirst())
        }
        return finished
    }

    /// Call just before the keyboard changes the document.
    mutating func willEdit(_ edit: Edit, in context: DocumentContext) -> [Correction] {
        let visible = Self.visible(context)
        var kept: [Region] = []
        var finished: [Correction] = []
        for var region in regions {
            guard let selection = Self.locate(&region, visible: visible),
                  Self.apply(edit, to: &region, selection: selection, visible: visible) else {
                finished += Self.report(region)
                continue
            }
            kept.append(region)
        }
        regions = kept
        return finished
    }

    /// Call when the app reports a change of the text or the cursor.
    mutating func documentChanged(_ context: DocumentContext) -> [Correction] {
        let visible = Self.visible(context)
        var kept: [Region] = []
        var finished: [Correction] = []
        for var region in regions {
            if Self.locate(&region, visible: visible) == nil {
                finished += Self.report(region)
            } else {
                kept.append(region)
            }
        }
        regions = kept
        return finished
    }

    /// Reports every region, when the keyboard closes or the user has stopped editing.
    mutating func finishAll() -> [Correction] {
        defer { regions = [] }
        return regions.flatMap(Self.report)
    }

    // MARK: - Finding regions

    private struct Visible {
        let text: Scalars
        let cursor: Int
        let selection: Int
    }

    private static func visible(_ context: DocumentContext) -> Visible {
        let before = Array(context.before.unicodeScalars)
        let selected = Array(context.selected.unicodeScalars)
        return Visible(text: before + selected + Array(context.after.unicodeScalars),
                       cursor: before.count, selection: selected.count)
    }

    /// Finds the region in the document and updates its cursor. Returns the length of the
    /// selection (0 when the document lags behind the keyboard), or nil when the region is gone.
    private static func locate(_ region: inout Region, visible: Visible) -> Int? {
        // The region where the keyboard expects it, now or a few keystrokes ago.
        let versions = [(region.text, region.cursor)] + region.history.reversed()
        for (index, version) in versions.enumerated() {
            if starts(of: version.0, after: region.anchor, in: visible.text)
                .contains(where: { visible.cursor - $0 == version.1 }) {
                return index == 0 ? visible.selection : 0
            }
        }
        // The user moved the cursor.
        let candidates = starts(of: region.text, after: region.anchor, in: visible.text)
        guard let start = candidates.min(by: { abs(visible.cursor - $0) < abs(visible.cursor - $1) }) else { return nil }
        region.cursor = visible.cursor - start
        region.endDeficit = 0
        return visible.selection
    }

    /// Positions in `visible` where `text` follows `anchor`. An empty anchor means the start of
    /// the document or of a paragraph; an anchor cut off by the start of the visible text matches
    /// by its remaining end.
    private static func starts(of text: Scalars, after anchor: Scalars, in visible: Scalars) -> [Int] {
        guard visible.count >= text.count else { return [] }
        return (0...(visible.count - text.count)).filter { i in
            let anchorMatches: Bool
            if anchor.isEmpty {
                anchorMatches = i == 0 || visible[i - 1] == "\n"
            } else if i < anchor.count {
                anchorMatches = visible[0..<i].elementsEqual(anchor.suffix(i))
            } else {
                anchorMatches = visible[(i - anchor.count)..<i].elementsEqual(anchor)
            }
            return anchorMatches && visible[i..<(i + text.count)].elementsEqual(text)
        }
    }

    // MARK: - Applying edits

    /// Applies an edit made at the cursor (replacing `selection` characters after it). Returns
    /// false when it changes the region in a way that cannot be followed.
    private static func apply(_ edit: Edit, to region: inout Region, selection: Int, visible: Visible) -> Bool {
        region.history.append((region.text, region.cursor))
        if region.history.count > 3 { region.history.removeFirst() }
        let inserted: Scalars
        switch edit {
        case .type(let text), .dictate(let text): inserted = Array(text.unicodeScalars)
        case .deleteBackward: inserted = []
        }
        let start = region.cursor
        let count = region.text.count

        if selection > 0 {
            let end = start + selection
            if start >= 0 && end <= count {
                region.text.replaceSubrange(start..<end, with: inserted)
                region.cursor = start + inserted.count
            } else if end <= 0 {
                region.cursor = end
            } else if start >= count {
                region.cursor = start + inserted.count
            } else {
                return false
            }
            return true
        }

        switch edit {
        case .type, .dictate:
            var extendsLastWord = false
            if case .type = edit, let last = region.text.last, let first = inserted.first {
                extendsLastWord = !isSpace(last) && !isSpace(first)
            }
            if start >= 0 && (start < count || start == count && (region.endDeficit > 0 || extendsLastWord)) {
                if start == count { region.endDeficit = max(0, region.endDeficit - inserted.count) }
                region.text.insert(contentsOf: inserted, at: start)
                region.cursor = start + inserted.count
            } else if start >= count {
                region.cursor = start + inserted.count
            }
        case .deleteBackward:
            if start >= 1 && start <= count {
                let removed = min(start, lastCharacterLength(region.text[0..<start]))
                region.text.removeSubrange((start - removed)..<start)
                region.cursor = start - removed
                if start == count { region.endDeficit += removed }
            } else if start > count {
                // After the region: the document says how long the deleted character is.
                let cursor = visible.cursor
                region.cursor = start - (cursor > 0 ? lastCharacterLength(visible.text[0..<cursor]) : 1)
            }
        }
        return true
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Scalars in the last Character, which is what backspace deletes.
    private static func lastCharacterLength(_ scalars: ArraySlice<Unicode.Scalar>) -> Int {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.suffix(16))
        return max(1, String(view).last?.unicodeScalars.count ?? 1)
    }

    // MARK: - Reporting

    private static func report(_ region: Region) -> [Correction] {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: region.text)
        let corrected = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
        let original = region.original.trimmingCharacters(in: .whitespacesAndNewlines)
        // Text that no longer resembles the dictation was rewritten, not corrected; added
        // punctuation alone teaches the model nothing about the words.
        guard !corrected.isEmpty, words(corrected) != words(original),
              corrected.count <= 2 * original.count + 20,
              similarity(Array(original), Array(corrected)) >= 0.5 else { return [] }
        return [Correction(id: region.id, original: original, corrected: corrected)]
    }

    private static func words(_ text: String) -> String {
        text.components(separatedBy: .punctuationCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 1 minus the edit distance divided by the longer length.
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        guard longest <= 4000 else { return 0 }
        var previous = Array(0...b.count)
        for i in a.indices {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices {
                current[j + 1] = a[i] == b[j] ? previous[j] : 1 + min(previous[j], previous[j + 1], current[j])
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(longest)
    }
}
