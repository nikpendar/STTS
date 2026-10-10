import CoreText
import Foundation
import Network
import UIKit

/// Messages between the keyboard extension and the app.
///
/// Darwin notifications carry no data, a free Apple ID cannot use App Groups, and a
/// background app cannot write the general pasteboard, so the transcript itself is served
/// over a loopback TCP socket (`TranscriptServer` in the app, `TranscriptClient` in the keyboard).
enum DictationBridge {
    /// Keyboard asks whether a session is running; the app answers with `alive`.
    static let ping = "com.persianstt.ping"
    static let alive = "com.persianstt.alive"
    /// Keyboard starts and stops a recording; the app confirms with `recording`.
    static let start = "com.persianstt.start"
    static let recording = "com.persianstt.recording"
    static let stop = "com.persianstt.stop"
    /// Keyboard abandons the transcription in progress.
    static let cancel = "com.persianstt.cancel"
    /// App has a provisional transcript of the recording so far on `transcriptPort`.
    static let partial = "com.persianstt.partial"
    /// App has a new time estimate on `transcriptPort`, for a live pass or the final transcription.
    static let progress = "com.persianstt.progress"
    /// App finished: the transcript is ready on `transcriptPort` (`done`), or nothing was recognized (`failed`).
    static let done = "com.persianstt.done"
    static let failed = "com.persianstt.failed"
    /// App ended the recording by itself: after the speaker stopped talking (`stopped`, the
    /// transcription follows as after `stop`), or because nobody spoke (`idle`, nothing follows).
    static let stopped = "com.persianstt.stopped"
    static let idle = "com.persianstt.idle"
    /// Loudness of the microphone while recording, `levels` steps from silence to loud speech.
    static let levels = 10
    static func level(_ step: Int) -> String { "com.persianstt.level.\(step)" }

    /// Prefixes that mark a served transcript as provisional or final. A fetch started for a
    /// partial result can arrive after the final one was published, so the keyboard goes by the prefix.
    static let partialPrefix = "P"
    /// Final transcript: "F" + dictation id + newline + text. The id lets the keyboard report
    /// the user's later edits of that text (`Correction`).
    static let finalPrefix = "F"
    /// Seconds still expected for the final transcription, for the keyboard's processing ring.
    static let estimatePrefix = "E"
    /// Seconds still expected for the live pass in progress, for the keyboard's live text ring.
    static let livePrefix = "L"
    /// Separates the messages of one fetch; each starts with one of the prefixes above.
    static let separator: Character = "\u{1E}"
    /// Marks a pause inside a served transcript: between whisper's segments and between the
    /// pieces of a live transcription, which are cut where the speaker paused. The keyboard
    /// reads spoken commands by it (`VoiceCommands`) and shows it as a space.
    static let pauseMark: Character = "\u{E000}"

    static func removingPauseMarks(_ text: String) -> String {
        text.split(separator: pauseMark, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Loopback port the app serves the latest transcript on.
    static let transcriptPort: NWEndpoint.Port = 47_861
    /// Loopback port the keyboard sends corrections to.
    static let correctionPort: NWEndpoint.Port = 47_862

    /// Opens the app and starts a keyboard session.
    static let sessionURL = URL(string: "persianstt://session")!
    /// Opens the app from the keyboard's settings key.
    static let settingsURL = URL(string: "persianstt://settings")!

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Runs handlers on the main queue when Darwin notifications arrive.
final class DarwinObserver {
    private var handlers: [String: () -> Void] = [:]

    func observe(_ name: String, handler: @escaping () -> Void) {
        handlers[name] = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let receiver = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                let key = name.rawValue as String
                DispatchQueue.main.async { receiver.handlers[key]?() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
    }
}

/// App side: hands the messages published since the last connection on 127.0.0.1 to the next
/// one, then forgets them. Of each kind (first character) only the newest is kept.
final class TranscriptServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TranscriptServer")
    private var listener: NWListener?
    private var pending: [String] = []

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: DictationBridge.transcriptPort)
            guard let listener = try? NWListener(using: parameters) else { return }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.stop() }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            pending = []
        }
    }

    /// Drops messages left from an earlier dictation.
    func clear() {
        queue.async { [self] in pending = [] }
    }

    func publish(_ text: String) {
        queue.async { [self] in
            pending.removeAll { $0.first == text.first }
            pending.append(text)
        }
    }

    private func serve(_ connection: NWConnection) {
        let data = Data(pending.joined(separator: String(DictationBridge.separator)).utf8)
        pending = []
        connection.start(queue: queue)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Keyboard side: reads the transcript the app is serving. Needs Full Access.
enum TranscriptClient {
    static func fetch(completion: @escaping (String?) -> Void) {
        let connection = NWConnection(host: "127.0.0.1", port: DictationBridge.transcriptPort, using: .tcp)
        // One serial queue for the connection and the timeout, so `finished` is never raced.
        let queue = DispatchQueue(label: "TranscriptClient")
        var buffer = Data()
        var finished = false
        func finish(_ text: String?) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { completion(text) }
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if isComplete {
                    finish(String(data: buffer, encoding: .utf8))
                } else if error != nil {
                    finish(nil)
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: receive()
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

/// The user's edit of a dictated text, sent by the keyboard so the app can upload the
/// recording with the corrected text for training (`PersonalModel`).
struct Correction: Codable {
    let id: String
    let original: String
    let corrected: String

    /// Keyboard side: sends the correction to the app over 127.0.0.1. Needs Full Access.
    func send() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: DictationBridge.correctionPort, using: .tcp)
        let queue = DispatchQueue(label: "Correction")
        connection.start(queue: queue)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }
}

/// App side: receives corrections from the keyboard.
final class CorrectionServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CorrectionServer")
    private var listener: NWListener?
    private let handler: (Correction) -> Void

    /// `handler` runs on the main queue.
    init(handler: @escaping (Correction) -> Void) {
        self.handler = handler
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: DictationBridge.correctionPort)
            guard let listener = try? NWListener(using: parameters) else { return }
            listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.stop() }
            }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func receive(_ connection: NWConnection) {
        var buffer = Data()
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if isComplete || error != nil || buffer.count > 1 << 20 {
                    connection.cancel()
                    if let correction = try? JSONDecoder().decode(Correction.self, from: buffer) {
                        DispatchQueue.main.async { self?.handler(correction) }
                    }
                } else {
                    next()
                }
            }
        }
        connection.start(queue: queue)
        next()
    }
}

/// The font of the settings page and the keys: a TTF or OTF file that the IPA build puts in a
/// Fonts folder inside the app and the keyboard (see build.yml), else the system font. Glyphs
/// the font lacks, such as Latin letters in a Persian-only font, come from the system font.
enum AppFont {
    /// PostScript name of the bundled font, registered on first use.
    static let name: String? = {
        let urls = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "Fonts") ?? []
        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            if let name = descriptors.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }) {
                return name
            }
        }
        return nil
    }()

    static func font(ofSize size: CGFloat) -> UIFont {
        name.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }
}

/// Settings chosen in the app and applied by the keyboard. A free Apple ID has no App Groups,
/// so the app writes them to a named pasteboard (shared by apps of the same team, and written
/// while the app is in the foreground); the keyboard reads it with Full Access and keeps a copy
/// in its own defaults.
protocol SharedSetting: Codable {
    static var pasteboardName: UIPasteboard.Name { get }
    static var defaultsKey: String { get }
    static var standard: Self { get }
}

extension SharedSetting {
    private static var pasteboardType: String { "public.json" }

    /// App side: saves the setting and hands it to the keyboard.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UIPasteboard(name: Self.pasteboardName, create: true)?.setData(data, forPasteboardType: Self.pasteboardType)
    }

    /// Keyboard side: the app's latest setting, else the last one seen, else the standard one.
    static func load() -> Self {
        if let data = UIPasteboard(name: pasteboardName, create: false)?.data(forPasteboardType: pasteboardType),
           let value = try? JSONDecoder().decode(Self.self, from: data) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            return value
        }
        return saved
    }

    /// The setting stored in this process's own defaults.
    static var saved: Self {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? standard
    }
}

/// Key background and outline colors.
struct KeyStyle: SharedSetting, Equatable {
    struct RGBA: Codable, Equatable {
        var r, g, b, a: Double
        var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    }

    var fill: RGBA
    var stroke: RGBA
    /// Letter and symbol colour, always opaque; nil follows the system (black in light mode, white in dark).
    var text: RGBA?

    var textColor: UIColor { text.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? .label }

    static let standard = KeyStyle(fill: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.18),
                                   stroke: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.45),
                                   text: nil)
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyStyle")
    static let defaultsKey = "keyStyle"
}

/// Keyboard features that can be turned off in the app.
struct KeyboardOptions: SharedSetting, Equatable {
    /// Suggest the next word after a space.
    var predictNextWord = true
    /// Offer the listed word a typed one is probably a misspelling of.
    var correctTypos = true
    /// Spoken «نقطه», «ویرگول», «خط بعد»… become punctuation.
    var voicePunctuation = true
    /// «پاک کن», «همه رو پاک کن» and «برگردون», said on their own, edit the text.
    var voiceCommands = true

    static let standard = KeyboardOptions()
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyboardOptions")
    static let defaultsKey = "keyboardOptions"

    init() {}

    /// Options added later are on when an older copy lacks them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        predictNextWord = try container.decodeIfPresent(Bool.self, forKey: .predictNextWord) ?? true
        correctTypos = try container.decodeIfPresent(Bool.self, forKey: .correctTypos) ?? true
        voicePunctuation = try container.decodeIfPresent(Bool.self, forKey: .voicePunctuation) ?? true
        voiceCommands = try container.decodeIfPresent(Bool.self, forKey: .voiceCommands) ?? true
    }
}
