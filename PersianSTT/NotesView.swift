import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The notes: a list with search that ignores Persian spelling variants, filters by folder
/// and #tag, pinned notes first, dates in the Persian calendar; a new note by typing, by
/// voice, or from an audio file (also shared from Telegram or WhatsApp).
struct NotesListView: View {
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var files = FileTranscriber.shared
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var open: OpenNote?
    @State private var importing = false
    @AppStorage(NotesSettings.latinDigitsKey) private var latinDigits = false
    /// A note to open when the page appears (an audio file shared to the app).
    @Binding var opening: UUID?

    /// The note pushed by code (a new note, a shared file), and whether dictation starts at once.
    struct OpenNote: Hashable, Identifiable {
        let id: UUID
        var dictate = false
    }

    enum Filter: Hashable {
        case all
        case pinned
        case folder(String)
        case tag(String)
    }

    var body: some View {
        List {
            if let job = files.job {
                Section { TranscriptionBanner(job: job) }
            }
            if let message = files.message {
                Section {
                    Text(message).font(.app(.footnote)).foregroundStyle(.secondary)
                }
            }
            if store.notes.isEmpty {
                emptyState
            } else {
                filters
                ForEach(visible) { note in
                    NavigationLink { NoteEditorView(id: note.id) } label: { NoteRow(note: note) }
                        .swipeActions(edge: .leading) {
                            Button {
                                store.update(note.id, touch: false) { $0.pinned.toggle() }
                            } label: {
                                Label(note.pinned ? L("برداشتن سنجاق", "Unpin") : L("سنجاق", "Pin"),
                                      systemImage: note.pinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(note.id) } label: {
                                Label(L("حذف", "Delete"), systemImage: "trash")
                            }
                        }
                        .contextMenu { NoteMenu(note: note) }
                }
            }
        }
        .searchable(text: $query, prompt: L("جستجو در یادداشت‌ها", "Search notes"))
        .navigationTitle(L("یادداشت‌ها", "Notes"))
        .navigationBarTitleDisplayMode(.large)
        .toolbarRole(.editor)
        .navigationDestination(item: $open) { item in
            NoteEditorView(id: item.id, dictateOnOpen: item.dictate)
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Menu {
                    Button { importing = true } label: {
                        Label(L("تبدیل فایل صوتی به متن", "Transcribe an Audio File"), systemImage: "waveform.badge.plus")
                    }
                    Picker(selection: $latinDigits) {
                        Text(L("فارسی (۱۲۳)", "Persian (۱۲۳)")).tag(false)
                        Text(L("لاتین (123)", "Latin (123)")).tag(true)
                    } label: {
                        Label(L("ارقام متن گفتاری", "Digits in Dictated Text"), systemImage: "textformat.123")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Spacer()
                Text(countText).font(.app(.caption)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    open = OpenNote(id: store.create(folder: currentFolder).id, dictate: true)
                } label: {
                    Image(systemName: "mic.fill")
                }
                .accessibilityLabel(L("یادداشت صوتی", "Voice Note"))
                Button {
                    open = OpenNote(id: store.create(folder: currentFolder).id)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel(L("یادداشت تازه", "New Note"))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.audioTypes) { result in
            if case .success(let url) = result, let id = files.transcribe(url) { open = OpenNote(id: id) }
        }
        .onAppear(perform: openPending)
        .onChange(of: opening) { _, _ in openPending() }
        .font(.app(.body))
    }

    private func openPending() {
        guard let id = opening else { return }
        opening = nil
        open = OpenNote(id: id)
    }

    private var currentFolder: String? {
        if case .folder(let name) = filter { return name }
        return nil
    }

    private var countText: String {
        let count = store.notes.count.formatted(.number.locale(AppLanguage.locale))
        return L("\(count) یادداشت", "\(count) notes")
    }

    private var visible: [Note] {
        store.sorted.filter { note in
            switch filter {
            case .all: break
            case .pinned: if !note.pinned { return false }
            case .folder(let name): if note.folder != name { return false }
            case .tag(let tag):
                let key = PersianText.searchKey(tag)
                if !note.tags.contains(where: { PersianText.searchKey($0) == key }) { return false }
            }
            return PersianText.matches(note.body + "\n" + (note.folder ?? ""), query: query)
        }
    }

    @ViewBuilder private var filters: some View {
        let folders = store.folders
        let tags = store.tags
        if !folders.isEmpty || !tags.isEmpty || store.notes.contains(where: \.pinned) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(L("همه", "All"), .all)
                    if store.notes.contains(where: \.pinned) { chip(L("سنجاق‌شده", "Pinned"), .pinned, symbol: "pin.fill") }
                    ForEach(folders, id: \.self) { chip($0, .folder($0), symbol: "folder") }
                    ForEach(tags, id: \.self) { chip("#" + $0, .tag($0)) }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private func chip(_ title: String, _ value: Filter, symbol: String? = nil) -> some View {
        Button {
            filter = filter == value ? .all : value
        } label: {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).font(.app(.subheadline))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(filter == value ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(filter == value ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "note.text").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(L("هنوز یادداشتی نیست", "No notes yet")).font(.app(.headline))
                Text(L("با دکمه‌ی میکروفون حرف بزنید تا یادداشت نوشته شود، یا یک ویس تلگرام یا واتس‌اپ را با «اشتراک‌گذاری» به آواک بفرستید.",
                       "Tap the microphone and speak to write a note, or share a Telegram or WhatsApp voice message to Avak."))
                    .font(.app(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
        .listRowBackground(Color.clear)
    }

    static var audioTypes: [UTType] {
        [.audio, UTType(FileTranscriber.ogg), UTType(FileTranscriber.opus), UTType(filenameExtension: "ogg"),
         UTType(filenameExtension: "opus"), UTType(filenameExtension: "oga")].compactMap { $0 }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.orange) }
                Text(note.title).font(.app(.headline)).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(NotesStore.dateText(note.modified)).foregroundStyle(.secondary)
                Text(note.preview.isEmpty ? " " : note.preview).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.app(.subheadline))
            if note.folder != nil || !note.audioFiles.isEmpty {
                HStack(spacing: 10) {
                    if let folder = note.folder { Label(folder, systemImage: "folder") }
                    if !note.audioFiles.isEmpty { Label(L("صدا", "Audio"), systemImage: "waveform") }
                }
                .font(.app(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pin, folder and delete, for the list and the editor.
private struct NoteMenu: View {
    let note: Note
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        Button {
            store.update(note.id, touch: false) { $0.pinned.toggle() }
        } label: {
            Label(note.pinned ? L("برداشتن سنجاق", "Unpin") : L("سنجاق کردن", "Pin"), systemImage: note.pinned ? "pin.slash" : "pin")
        }
        FolderMenu(note: note)
        Button(role: .destructive) { store.delete(note.id) } label: {
            Label(L("حذف یادداشت", "Delete Note"), systemImage: "trash")
        }
    }
}

private struct FolderMenu: View {
    let note: Note
    @ObservedObject private var store = NotesStore.shared

    var body: some View {
        Menu {
            Button { NewFolderPrompt.ask(for: note.id) } label: {
                Label(L("پوشه‌ی تازه…", "New Folder…"), systemImage: "folder.badge.plus")
            }
            ForEach(store.folders, id: \.self) { folder in
                Button {
                    store.update(note.id, touch: false) { $0.folder = folder }
                } label: {
                    if note.folder == folder { Label(folder, systemImage: "checkmark") } else { Text(folder) }
                }
            }
            if note.folder != nil {
                Button { store.update(note.id, touch: false) { $0.folder = nil } } label: {
                    Label(L("بیرون از پوشه", "No Folder"), systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label(L("پوشه", "Folder"), systemImage: "folder")
        }
    }
}

/// A folder name asked in an alert (menus cannot hold a text field).
enum NewFolderPrompt {
    @MainActor static func ask(for id: UUID) {
        let alert = UIAlertController(title: L("پوشه‌ی تازه", "New Folder"), message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = L("نام پوشه", "Folder name") }
        alert.addAction(UIAlertAction(title: L("انصراف", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("ساختن", "Create"), style: .default) { _ in
            let name = PersianText.unifyingLetters(alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            NotesStore.shared.update(id, touch: false) { $0.folder = name }
        })
        UIApplication.shared.topController?.present(alert, animated: true)
    }
}

extension UIApplication {
    var topController: UIViewController? {
        var top = connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

private struct TranscriptionBanner: View {
    let job: FileTranscriber.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.tint)
                Text(job.waiting ? L("منتظر خاموش شدن تایپ صوتی…", "Waiting for voice typing to turn off…")
                                 : L("در حال تبدیل «\(job.name)»", "Transcribing “\(job.name)”"))
                    .font(.app(.subheadline)).lineLimit(1)
                Spacer()
                Button(L("لغو", "Cancel")) { FileTranscriber.shared.cancel() }.font(.app(.subheadline))
            }
            ProgressView(value: job.progress)
            Text(L("تا پایان تبدیل، آواک را باز نگه دارید.", "Keep Avak open until it is done."))
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Editor

/// One note: Persian-aware text editing, long dictation at the cursor with pause and resume,
/// reading aloud with the sentence highlighted, the dictated pieces to hear and correct, and
/// sharing as text, PDF or audio.
struct NoteEditorView: View {
    let id: UUID
    var dictateOnOpen = false
    @ObservedObject private var store = NotesStore.shared
    @ObservedObject private var recorder = NoteRecorder.shared
    @ObservedObject private var files = FileTranscriber.shared
    @ObservedObject private var speech = PersianSpeech.shared
    @StateObject private var controller = NoteEditorController()
    @State private var showingPieces = false
    @State private var sharing: [URL]?
    @State private var started = false
    @Environment(\.dismiss) private var dismiss

    private var note: Note? { store.note(id) }
    private var recordingHere: Bool { recorder.isRecording(id) }

    var body: some View {
        VStack(spacing: 0) {
            if let note {
                header(note)
                NoteTextView(text: note.body, controller: controller) { text in
                    store.update(id) { $0.body = text }
                }
            } else {
                Spacer()
            }
            bottomBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let note {
                    if controller.focused {
                        Button(L("تمام", "Done")) { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    }
                    shareMenu(note)
                    moreMenu(note)
                }
            }
        }
        .sheet(isPresented: $showingPieces) {
            NavigationStack { PiecesView(id: id) }
                .environment(\.layoutDirection, AppLanguage.english ? .leftToRight : .rightToLeft)
        }
        .sheet(item: Binding(get: { sharing.map(SharedFiles.init) }, set: { if $0 == nil { sharing = nil } })) { files in
            ShareSheet(items: files.urls)
        }
        .onChange(of: speech.spokenRange) { _, range in controller.highlight(range) }
        .onAppear {
            let editor = controller
            recorder.onPartial = { [weak editor] text in editor?.showPartial(text) }
            recorder.onPiece = { [weak editor] segment in editor?.commit(segment.text) }
            if dictateOnOpen, !started {
                started = true
                Task { await startDictation() }
            }
        }
        .onDisappear {
            if recordingHere { recorder.stop() }
            recorder.onPiece = nil
            recorder.onPartial = { _ in }
            speech.stop()
            store.deleteIfEmpty(id)
        }
        .font(.app(.body))
    }

    private func header(_ note: Note) -> some View {
        HStack(spacing: 8) {
            Text(NotesStore.dateText(note.modified, full: true))
            if let folder = note.folder { Label(folder, systemImage: "folder").labelStyle(.titleAndIcon) }
            if let source = note.source { Label(source, systemImage: "waveform").lineLimit(1) }
            Spacer()
        }
        .font(.app(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 6) {
            if let message = recorder.message ?? files.message {
                Text(message).font(.app(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let job = files.job, job.noteID == id {
                TranscriptionBanner(job: job).padding(.horizontal)
            }
            HStack(spacing: 20) {
                if recordingHere {
                    Text(Self.clock(recorder.seconds)).font(.app(.body).monospacedDigit()).frame(minWidth: 64)
                    Button {
                        recorder.isPaused ? recorder.resume() : recorder.pause()
                    } label: {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.title2).frame(width: 52, height: 52)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                    .accessibilityLabel(recorder.isPaused ? L("ادامه", "Resume") : L("مکث", "Pause"))
                    Button {
                        recorder.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title2).foregroundStyle(.white).frame(width: 64, height: 64)
                            .background(Color.red, in: Circle())
                            .overlay(Circle().stroke(Color.red.opacity(0.3), lineWidth: CGFloat(4 + min(1, recorder.level * 25) * 10)))
                    }
                    .accessibilityLabel(L("پایان ضبط", "Stop Recording"))
                } else {
                    if NotesSettings.readsAloud, PersianSpeech.directory != nil {
                        Button {
                            if speech.isSpeaking { speech.stop() } else if let note { speech.speak(note.body, highlighting: true) }
                        } label: {
                            Image(systemName: speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
                                .font(.title2).frame(width: 52, height: 52)
                        }
                        .disabled(note?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        .accessibilityLabel(speech.isSpeaking ? L("توقف خواندن", "Stop Reading") : L("بلندخوانی", "Read Aloud"))
                    }
                    Button {
                        Task { await startDictation() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.title).foregroundStyle(.white).frame(width: 64, height: 64)
                            .background(Color.accentColor, in: Circle())
                    }
                    .disabled(files.job != nil)
                    .accessibilityLabel(L("ضبط", "Record"))
                    if !(note?.segments.isEmpty ?? true) {
                        Button { showingPieces = true } label: {
                            Image(systemName: "text.badge.checkmark").font(.title2).frame(width: 52, height: 52)
                        }
                        .accessibilityLabel(L("تکه‌های گفتار", "Dictated Pieces"))
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onChange(of: recorder.noteID) { old, new in
            if old == id, new == nil { controller.endDictation() }
        }
    }

    private func startDictation() async {
        speech.stop()
        controller.beginDictation()
        if await !recorder.start(note: id) { controller.endDictation() }
    }

    private func shareMenu(_ note: Note) -> some View {
        Menu {
            Button { sharing = [NoteExport.text(note)].compactMap { $0 } } label: {
                Label(L("متن", "Text"), systemImage: "doc.plaintext")
            }
            Button { sharing = [NoteExport.pdf(note)].compactMap { $0 } } label: {
                Label("PDF", systemImage: "doc.richtext")
            }
            if !note.audioFiles.isEmpty {
                Button { sharing = note.audioFiles.map { store.audioURL(id, $0) } } label: {
                    Label(L("صدای یادداشت", "Note Audio"), systemImage: "waveform")
                }
            }
            Button { UIPasteboard.general.string = note.body } label: {
                Label(L("کپی متن", "Copy Text"), systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(note.body.isEmpty && note.audioFiles.isEmpty)
    }

    private func moreMenu(_ note: Note) -> some View {
        Menu {
            Button {
                controller.replaceAll(PersianText.normalized(note.body))
            } label: {
                Label(L("یکسان‌سازی حروف و نیم‌فاصله", "Fix Letters and ZWNJ"), systemImage: "wand.and.stars")
            }
            Menu {
                Button(L("فارسی (۱۲۳)", "Persian (۱۲۳)")) { controller.replaceAll(PersianText.persianDigits(note.body)) }
                Button(L("لاتین (123)", "Latin (123)")) { controller.replaceAll(PersianText.latinDigits(note.body)) }
            } label: {
                Label(L("تبدیل ارقام", "Convert Digits"), systemImage: "textformat.123")
            }
            Divider()
            Button {
                store.update(id, touch: false) { $0.pinned.toggle() }
            } label: {
                Label(note.pinned ? L("برداشتن سنجاق", "Unpin") : L("سنجاق کردن", "Pin"), systemImage: note.pinned ? "pin.slash" : "pin")
            }
            FolderMenu(note: note)
            Button(role: .destructive) {
                if recordingHere { recorder.stop() }
                speech.stop()
                store.delete(id)
                dismiss()
            } label: {
                Label(L("حذف یادداشت", "Delete Note"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(recordingHere)
    }

    /// ۱۲:۰۵ (Persian digits in Persian).
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        let text = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        return AppLanguage.english ? text : PersianText.persianDigits(text)
    }
}

private struct SharedFiles: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined() }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Pieces

/// The note's dictated pieces: hear each one again and correct its text. A correction
/// changes the note, teaches the personal dictionary, and with «یادگیری از اصلاح‌ها» on goes
/// to training with the piece's audio.
private struct PiecesView: View {
    let id: UUID
    @ObservedObject private var store = NotesStore.shared
    @StateObject private var player = PiecePlayer()
    @State private var editing: NoteSegment?
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(store.note(id)?.segments ?? []) { segment in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            player.toggle(segment, url: store.audioURL(id, segment.audio))
                        } label: {
                            Image(systemName: player.playing == segment.id ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment.text).font(.app(.body))
                            HStack(spacing: 6) {
                                Text(NoteEditorView.clock(segment.start))
                                if segment.corrected { Label(L("اصلاح شد", "Corrected"), systemImage: "checkmark") }
                            }
                            .font(.app(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = segment.text
                        editing = segment
                    }
                }
            } footer: {
                Text(L("روی هر تکه بزنید تا متنش را درست کنید. اصلاح‌ها به واژه‌نامه‌ی شخصی کمک می‌کنند و اگر «یادگیری از اصلاح‌ها» روشن باشد، برای بهتر شدن مدل فرستاده می‌شوند.",
                       "Tap a piece to correct its text. Corrections help the personal dictionary and, with Learning from Corrections on, are sent to improve the model."))
                    .font(.app(.footnote))
            }
        }
        .navigationTitle(L("تکه‌های گفتار", "Dictated Pieces"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("تمام", "Done")) { dismiss() } }
        }
        .sheet(item: $editing) { segment in
            NavigationStack {
                Form {
                    Section {
                        TextField("", text: $draft, axis: .vertical)
                            .lineLimit(3...10)
                            .font(.app(.body))
                    } footer: {
                        Text(L("شنیده‌شده: \(segment.text)", "Heard: \(segment.text)")).font(.app(.footnote))
                    }
                }
                .navigationTitle(L("اصلاح متن", "Correct Text"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("انصراف", "Cancel")) { editing = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("ذخیره", "Save")) {
                            store.correct(segment, in: id, to: PersianText.normalized(draft))
                            editing = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium])
            .environment(\.layoutDirection, AppLanguage.english ? .leftToRight : .rightToLeft)
        }
        .onDisappear { player.stop() }
        .font(.app(.body))
    }
}

/// Plays one piece of a note's audio.
@MainActor
private final class PiecePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing: UUID?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ segment: NoteSegment, url: URL) {
        if playing == segment.id { return stop() }
        stop()
        guard !NoteRecorder.shared.isRecording, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        PersianSpeech.shared.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.delegate = self
        player.currentTime = max(0, segment.start - 0.15)
        player.play()
        self.player = player
        playing = segment.id
        timer = Timer.scheduledTimer(withTimeInterval: max(0.3, segment.duration + 0.3), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        if playing != nil, !KeyboardSession.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Export

/// A note as a file to share: plain text, or a PDF set in the app font, each paragraph from
/// the side of its language.
enum NoteExport {
    static func text(_ note: Note) -> URL? {
        let url = file(note, ext: "txt")
        do { try note.body.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }

    @MainActor static func pdf(_ note: Note) -> URL? {
        let rtlDefault = !AppLanguage.english
        let body = NSMutableAttributedString()
        let titleFont = AppFont.font(ofSize: 20)
        let textFont = AppFont.font(ofSize: 13)
        let small = AppFont.font(ofSize: 10)
        func add(_ text: String, font: UIFont, color: UIColor = .black, rtl: Bool? = nil) {
            for paragraph in text.components(separatedBy: "\n") {
                let style = NSMutableParagraphStyle()
                let isRTL = rtl ?? PersianText.isRightToLeft(Substring(paragraph), defaultRTL: rtlDefault)
                style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
                style.alignment = isRTL ? .right : .left
                style.lineSpacing = 4
                style.paragraphSpacing = 6
                body.append(NSAttributedString(string: paragraph + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
            }
        }
        add(note.title, font: titleFont)
        add(NotesStore.dateText(note.modified, full: true), font: small, color: .darkGray, rtl: rtlDefault)
        add("", font: small)
        add(note.body, font: textFont)

        let formatter = UISimpleTextPrintFormatter(attributedText: body)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)   // A4
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 48, dy: 56), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, [kCGPDFContextCreator as String: "Avak"])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        let url = file(note, ext: "pdf")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// A temporary file named after the note's title.
    private static func file(_ note: Note, ext: String) -> URL {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n")
        var name = String(note.title.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "note" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(note.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(String(name.prefix(60))).appendingPathExtension(ext)
    }
}
