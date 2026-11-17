import Foundation
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "notes")

/// A piece of a note's dictation: where it is in the note's audio, what the model heard and
/// what went into the note. Kept so the piece can be heard again and its text corrected.
struct NoteSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The audio file in the note's folder.
    var audio: String
    var start: Double
    var end: Double
    /// The model's words (pause marks removed): what training compares the correction with.
    var raw: String
    /// The text as it went into the note (numbers, personal dictionary, Persian spelling).
    var text: String
    var corrected = false

    var duration: Double { end - start }
}

/// A note: plain text, kept on this iPhone only. Tags are the #words in the text.
struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var body = ""
    var created = Date()
    var modified = Date()
    var pinned = false
    var folder: String?
    var segments: [NoteSegment] = []
    /// Audio files of the note's recordings and transcribed files, in its folder.
    var audioFiles: [String] = []
    /// The audio file a transcribed file came from (its name), shown in the note.
    var source: String?

    /// A title the user gave the note (the list's menu); without one the first line is the title.
    var customTitle: String?

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let line = body.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) } ?? L("یادداشت بدون متن", "Empty note")
    }

    var hasCustomTitle: Bool { !(customTitle ?? "").isEmpty }

    /// The text after the title line (or from the start, under a title of its own), for the list.
    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst(hasCustomTitle ? 0 : 1).prefix(2).joined(separator: " ")
    }

    var tags: [String] { PersianText.hashtags(in: body) }
    var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && audioFiles.isEmpty }
}

/// The notes, one folder each under Application Support/Notes (note.json and its audio).
/// Saving waits half a second after the last change, off the main thread.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []

    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Notes", isDirectory: true)
    }()

    private let queue = DispatchQueue(label: "ir.nikpendar.PersianSTT.notes", qos: .utility)
    private var saves: [UUID: Task<Void, Never>] = [:]

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        let folders = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        notes = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("note.json")) else { return nil }
            return try? decoder.decode(Note.self, from: data)
        }
        log.info("loaded \(self.notes.count) notes")
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    /// Pinned first, then the most recently changed.
    var sorted: [Note] {
        notes.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.modified > b.modified }
    }

    var folders: [String] {
        Array(Set(notes.compactMap(\.folder))).sorted()
    }

    var tags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for note in sorted { for tag in note.tags where seen.insert(PersianText.searchKey(tag)).inserted { out.append(tag) } }
        return out
    }

    @discardableResult
    func create(body: String = "", folder: String? = nil) -> Note {
        let note = Note(body: body, folder: folder)
        notes.append(note)
        save(note, now: true)
        return note
    }

    /// Changes a note through `change`; `touch` moves it up the list as just edited.
    func update(_ id: UUID, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[i]
        change(&note)
        guard note != notes[i] else { return }
        if touch { note.modified = Date() }
        notes[i] = note
        save(note)
    }

    func delete(_ id: UUID) {
        saves[id]?.cancel()
        saves[id] = nil
        notes.removeAll { $0.id == id }
        let folder = folder(of: id)
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Notes that can go into another one: not recording, not being transcribed.
    func isBusy(_ id: UUID) -> Bool {
        NoteRecorder.shared.isRecording(id) || FileTranscriber.shared.job?.noteID == id
    }

    /// Puts `sources` into note `id`, oldest first after its own text, a blank line between
    /// them; their audio and dictated pieces move with them, and the sources are deleted.
    func merge(_ sources: [UUID], into id: UUID) {
        let fm = FileManager.default
        let others = sources.filter { $0 != id && !isBusy($0) }.compactMap(note).sorted { $0.created < $1.created }
        guard note(id) != nil, !others.isEmpty else { return }
        try? fm.createDirectory(at: folder(of: id), withIntermediateDirectories: true)
        for other in others {
            for file in other.audioFiles {
                try? fm.moveItem(at: audioURL(other.id, file), to: audioURL(id, file))
            }
        }
        update(id) { note in
            for other in others {
                let text = other.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let own = note.body.trimmingCharacters(in: .newlines)
                    note.body = own.isEmpty ? text : own + "\n\n" + text
                }
                note.segments += other.segments
                note.audioFiles += other.audioFiles
                if note.folder == nil { note.folder = other.folder }
                note.created = min(note.created, other.created)
            }
        }
        save(note(id)!, now: true)
        for other in others { delete(other.id) }
    }

    /// Deletes a note left empty (no text, no audio), as Notes does when one leaves it.
    func deleteIfEmpty(_ id: UUID) {
        guard let note = note(id), note.isEmpty, !NoteRecorder.shared.isRecording(id), FileTranscriber.shared.job?.noteID != id else { return }
        delete(id)
    }

    nonisolated func folder(of id: UUID) -> URL {
        Self.directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated func audioURL(_ id: UUID, _ file: String) -> URL {
        folder(of: id).appendingPathComponent(file)
    }

    /// A new audio file name in the note's folder (the folder is created).
    func newAudioFile(for id: UUID) -> String {
        try? FileManager.default.createDirectory(at: folder(of: id), withIntermediateDirectories: true)
        let name = "audio-\(Int(Date().timeIntervalSince1970 * 1000)).m4a"
        update(id, touch: false) { $0.audioFiles.append(name) }
        return name
    }

    /// Saves every pending change now (the app goes to the background).
    func flush() {
        for (id, task) in saves {
            task.cancel()
            if let note = note(id) { write(note) }
        }
        saves = [:]
    }

    private func save(_ note: Note, now: Bool = false) {
        saves[note.id]?.cancel()
        if now {
            saves[note.id] = nil
            write(note)
            return
        }
        let id = note.id
        saves[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let note = self.note(id) else { return }
            self.saves[id] = nil
            self.write(note)
        }
    }

    private func write(_ note: Note) {
        let folder = folder(of: note.id)
        guard let data = try? JSONEncoder().encode(note) else { return }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("note.json"), options: .atomic)
            } catch {
                log.error("cannot save note: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Dates

    /// «۲۴ آبان ۱۴۰۵، ۲۲:۵۵» (Persian calendar) in Persian; Gregorian in English. Today shows the
    /// time alone, this week the weekday.
    static func dateText(_ date: Date, full: Bool = false) -> String {
        var calendar = Calendar(identifier: AppLanguage.english ? .gregorian : .persian)
        calendar.locale = AppLanguage.locale
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = AppLanguage.locale
        if full {
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyyHHmm")
        } else if calendar.isDateInToday(date) {
            formatter.setLocalizedDateFormatFromTemplate("HHmm")
        } else if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 6 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        }
        return formatter.string(from: date)
    }
}

/// Settings of the notes page.
enum NotesSettings {
    /// Digits of dictated text in notes: Persian (the model's, by default) or Latin.
    static let latinDigitsKey = "notesLatinDigits"
    static var latinDigits: Bool { UserDefaults.standard.bool(forKey: latinDigitsKey) }
    /// The Persian voice reads notes aloud (`PersianSpeech`), in builds that have it. Part of
    /// the notes plan Rooz approved on 2026-11-15, although the «خواندن متن» page itself stays
    /// hidden (2026-11-04); false hides the button.
    static let readsAloud = true
}

/// The model's words for one piece of a note, written as the note keeps them: numbers in
/// digits, the personal dictionary's spellings, Persian letters and ZWNJ, digits as chosen.
struct NoteTextWriter {
    private let dictionary = PersonalDictionary.saved
    private let latin = NotesSettings.latinDigits

    func write(_ words: String) -> String {
        var text = SpokenNumbers.digits(in: words)
        text = dictionary.applied(to: text)
        text = PersianText.normalized(text)
        return latin ? PersianText.latinDigits(text) : text
    }
}
