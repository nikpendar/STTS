import CoreText
import Foundation
import Network
import Security
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
    /// The app's session ended (timed out or stopped): the keyboard greys its mic.
    static let ended = "com.persianstt.ended"
    /// Keyboard starts and stops a recording; the app confirms with `recording`.
    static let start = "com.persianstt.start"
    /// As `start`, while the space bar is held: no stop after a silence, the keyboard ends it.
    static let startHeld = "com.persianstt.startHeld"
    static let recording = "com.persianstt.recording"
    static let stop = "com.persianstt.stop"
    /// Pauses a recording (no audio is kept) and resumes it; the keyboard no longer sends these.
    static let pause = "com.persianstt.pause"
    static let resume = "com.persianstt.resume"
    /// The app paused the recording itself: iOS took the microphone (a call, Siri, the system's
    /// own dictation). The keyboard ends the recording with what was said.
    static let interrupted = "com.persianstt.interrupted"
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
    /// Loudness of the microphone while recording, `levels` steps of 2 dB from -55 dB (silence)
    /// to loud speech.
    static let levels = 20
    static func level(_ step: Int) -> String { "com.persianstt.level.\(step)" }

    /// Prefixes that mark a served transcript as provisional or final. A fetch started for a
    /// partial result can arrive after the final one was published, so the keyboard goes by the prefix.
    static let partialPrefix = "P"
    /// Final transcript: "F" + dictation id + newline + text. The id lets the keyboard report
    /// the user's later edits of that text (`Correction`).
    static let finalPrefix = "F"
    /// Seconds still expected for the final transcription, for the keyboard's processing ring.
    static let estimatePrefix = "E"
    /// Separates the messages of one fetch; each starts with one of the prefixes above.
    static let separator: Character = "\u{1E}"
    /// Marks a pause inside a served transcript: the speech model writes it where the speaker
    /// paused (`ScribeStream`). The keyboard reads spoken commands by it (`VoiceCommands`) and
    /// shows it as a space.
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

    /// The keyboard opens the app: to start a session, and from its settings panel. Guideline
    /// 4.4.1 lets a keyboard open only Settings; on Rooz's decision (2026-10-27) it stays on in
    /// the App Store build too, and goes off here if App Review rejects it.
    static let keyboardOpensApp = true
    /// Opens the app and starts a keyboard session. It carries the bridge key: opened without
    /// it (by another app or a web page), the app only opens and voice typing stays off.
    static var sessionURL: URL {
        BridgeKey.refreshInKeyboard()
        return URL(string: "persianstt://session?k=\(BridgeKey.current)")!
    }
    /// Opens the app's settings from the keyboard's settings panel.
    static let settingsURL = URL(string: "persianstt://settings")!

    /// Posted by the keyboard each time it opens with Full Access, after it marks
    /// `fullAccessPasteboard`, so the app can tell the keyboard is added and allowed.
    static let fullAccess = "com.persianstt.fullAccess"
    /// Holds "on" once the keyboard has run with Full Access (only then can it write here).
    static let fullAccessPasteboard = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyboardState")

    /// Posts one of the names above, with the bridge key in it (`BridgeKey`).
    static func post(_ name: String) {
        BridgeKey.refreshInKeyboard()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(BridgeKey.keyed(name) as CFString), nil, nil, true)
    }
}

/// A random key the app makes once and leaves on a named pasteboard of the team, which only the
/// app and its keyboard (with Full Access) can read. Every Darwin notification name carries it,
/// and every loopback connection starts with it on its first line, so another app on the phone
/// can neither start a recording nor read the transcript (review, 2026-11-09).
enum BridgeKey {
    static let pasteboard = UIPasteboard.Name("ir.nikpendar.PersianSTT.bridgeKey")
    private static let defaultsKey = "bridgeKey"
    private static let type = "public.utf8-plain-text"
    /// Posted in-process when the keyboard learns a new key: its observers listen again under it.
    static let changed = Notification.Name("BridgeKeyChanged")
    private static let lock = NSLock()
    private static var cached: String?

    private static var inKeyboard: Bool { Bundle.main.bundlePath.hasSuffix(".appex") }

    /// The key in use; empty in the keyboard until it has read one.
    static var current: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var key = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if key.isEmpty, !inKeyboard {
            var bytes = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
            }
            key = bytes.map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(key, forKey: defaultsKey)
        }
        cached = key
        return key
    }

    /// App side: leaves the key where the keyboard reads it. Called while the app is in front
    /// (a background app cannot write a pasteboard).
    static func publish() {
        guard !inKeyboard else { return }
        let key = current
        let board = UIPasteboard(name: pasteboard, create: true)
        if board?.string != key { board?.string = key }
    }

    /// Keyboard side: reads the key the app left, keeps a copy, and tells its observers when it
    /// changed. Cheap enough to call before each message the keyboard sends.
    static func refreshInKeyboard() {
        guard inKeyboard,
              let key = UIPasteboard(name: pasteboard, create: false)?.string,
              key.count == 32, key != current else { return }
        lock.lock()
        cached = key
        lock.unlock()
        UserDefaults.standard.set(key, forKey: defaultsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// A notification name with the key in it. `fullAccess` stays as it is: the keyboard posts it
    /// before it may have the key, and it only ticks the app's setup step.
    static func keyed(_ name: String) -> String {
        guard name != DictationBridge.fullAccess else { return name }
        let prefix = "com.persianstt."
        guard name.hasPrefix(prefix) else { return name }
        return prefix + current + "." + name.dropFirst(prefix.count)
    }

    /// True when a `sessionURL` carries this app's key.
    static func matches(_ url: URL) -> Bool {
        let key = current
        let given = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "k" }?.value
        return !key.isEmpty && given == key
    }

    /// The first line of each loopback connection.
    static var line: Data { Data((current + "\n").utf8) }

    /// Splits a received buffer at its first line: the rest when that line is the key, else nil.
    static func check(_ buffer: Data) -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let key = current
        guard !key.isEmpty, buffer[buffer.startIndex..<newline] == Data(key.utf8) else { return nil }
        return buffer[buffer.index(after: newline)...]
    }
}

/// Runs handlers on the main queue when Darwin notifications arrive.
/// Names are given plain; it listens under the keyed names (`BridgeKey`), and again under the
/// new ones when the keyboard learns a new key.
final class DarwinObserver {
    private var handlers: [String: () -> Void] = [:]
    /// Keyed name heard → plain name of its handler. Read on the notification's thread.
    private var plainNames: [String: String] = [:]
    private let lock = NSLock()
    private var keyChange: NSObjectProtocol?

    init() {
        keyChange = NotificationCenter.default.addObserver(forName: BridgeKey.changed, object: nil, queue: .main) { [weak self] _ in
            self?.listenAgain()
        }
    }

    func observe(_ name: String, handler: @escaping () -> Void) {
        handlers[name] = handler
        add(name)
    }

    private func add(_ name: String) {
        let keyed = BridgeKey.keyed(name)
        lock.lock()
        plainNames[keyed] = name
        lock.unlock()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let receiver = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                receiver.lock.lock()
                let plain = receiver.plainNames[name.rawValue as String]
                receiver.lock.unlock()
                guard let plain else { return }
                DispatchQueue.main.async { receiver.handlers[plain]?() }
            },
            keyed as CFString, nil, .deliverImmediately)
    }

    private func listenAgain() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque())
        lock.lock()
        plainNames = [:]
        lock.unlock()
        handlers.keys.forEach(add)
    }

    deinit {
        if let keyChange { NotificationCenter.default.removeObserver(keyChange) }
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

    /// Answers only a connection whose first line is the bridge key; anything else is dropped
    /// and the messages stay for the keyboard.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if buffer.contains(0x0A) {
                    guard BridgeKey.check(buffer) != nil else { connection.cancel(); return }
                    let reply = Data(self.pending.joined(separator: String(DictationBridge.separator)).utf8)
                    self.pending = []
                    connection.send(content: reply, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil || buffer.count > 256 {
                    connection.cancel()
                } else {
                    next()
                }
            }
        }
        next()
        queue.asyncAfter(deadline: .now() + 3) { if connection.state != .cancelled { connection.cancel() } }
    }
}

/// Keyboard side: reads the transcript the app is serving. Needs Full Access.
enum TranscriptClient {
    static func fetch(completion: @escaping (String?) -> Void) {
        BridgeKey.refreshInKeyboard()
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
            case .ready:
                connection.send(content: BridgeKey.line, completion: .contentProcessed { _ in })
                receive()
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
        guard let json = try? JSONEncoder().encode(self) else { return }
        BridgeKey.refreshInKeyboard()
        let data = BridgeKey.line + json
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
                    // Only a connection that starts with the bridge key is taken.
                    if let json = BridgeKey.check(buffer),
                       let correction = try? JSONDecoder().decode(Correction.self, from: json) {
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

/// Saving in the app hands the setting to the keyboard on its named pasteboard; the keyboard
/// keeps the last copy it read.
extension SharedSetting {
    private static var pasteboardType: String { "public.json" }

    /// Saves the setting and hands it to the other side: the app's settings pages, or the
    /// keyboard's settings panel (`KeyboardOptions`), which the app reads back with `load()`.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UIPasteboard(name: Self.pasteboardName, create: true)?.setData(data, forPasteboardType: Self.pasteboardType)
    }

    /// The latest setting on the pasteboard, else the last one seen, else the standard one.
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

/// The keyboard's look, set in the app: key fill, outline and letter colours, the background
/// colour or picture, and the letter size.
struct KeyStyle: SharedSetting, Equatable {
    struct RGBA: Codable, Equatable {
        var r, g, b, a: Double
        var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    }

    var fill: RGBA
    var stroke: RGBA
    /// Letter and symbol colour, always opaque; nil follows the system (black in light mode, white in dark).
    var text: RGBA?
    /// The whole keyboard's background, always opaque; nil leaves the system's own.
    var background: RGBA?
    /// A picture behind the keys instead of the colour (`KeyboardBackground`): a preset's id or
    /// the user's photo.
    var backgroundImage: String?
    /// Point size of the letters and digits on the keys; nil is the standard 23.
    var letterSize: Double?

    static let standardLetterSize = 23.0

    var textColor: UIColor { text.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? .label }
    var backgroundColor: UIColor? { background.map { UIColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) } }
    /// Keys with neither a fill nor an outline that can be seen.
    var keysAreClear: Bool { fill.a < 0.03 && stroke.a < 0.03 }

    static let standard = KeyStyle(fill: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.18),
                                   stroke: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.45),
                                   text: nil, background: nil)
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyStyle")
    static let defaultsKey = "keyStyle"
}

/// The personal dictionary is edited in the app and read by the keyboard like the settings.
extension PersonalDictionary: SharedSetting {
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.personalDictionary")
    static let defaultsKey = "personalDictionary"
}

/// Typed shortcuts («آدف» → the shop's address), set in the app on their own page and used by
/// the keyboard only when typing; dictation uses the personal dictionary instead.
struct TypedShortcuts: SharedSetting, Equatable {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// What is typed: one word.
        var shortcut: String
        /// What it becomes.
        var text: String
    }

    var entries: [Entry] = []

    static let standard = TypedShortcuts()
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.typedShortcuts")
    static let defaultsKey = "typedShortcuts"

    /// The shortcuts by `PersonalDictionary.key`, one-word ones only.
    var byKey: [String: String] {
        var found: [String: String] = [:]
        for entry in entries {
            let typed = entry.shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = PersonalDictionary.key(typed)
            guard !key.isEmpty, !text.isEmpty, !typed.contains(" "), key != PersonalDictionary.key(text) else { continue }
            found[key] = text
        }
        return found
    }
}

/// Keyboard features that can be turned off in the app.
struct KeyboardOptions: SharedSetting, Equatable {
    /// The row of suggestions above the keys; off, the keys move up under a thin margin.
    var suggestionBar = true
    /// Suggest the next word after a space.
    var predictNextWord = true
    /// Offer the listed word a typed one is probably a misspelling of.
    var correctTypos = true
    /// Each pressed key shows its letter enlarged above it.
    var keyPreview = true
    /// Letters drawn raised off the keys, shifting as the phone tilts (Rooz, 2026-11-05).
    var tiltLetters = true
    /// Two spaces in a row type a full stop, three a comma.
    var doubleSpacePunctuation = true
    /// A row of digits above the letters.
    var numberRow = false
    /// Small digits on the top row's letters (ض 1 … ج 0), held to type them; replaces the number row.
    var digitsOnLetters = false
    /// A space after a word the list writes with ZWNJ puts it in (میخوام, کتاب ها).
    var autoZWNJ = true
    /// TapMap: touches between keys go to the key the user's habits and the word make likelier.
    var learnTouches = true
    /// Raised by the app to make the keyboard forget the touches it learned.
    var touchResets = 0
    /// The system keyboard's clicks: one for characters, one for backspace, one for the other keys.
    var keySounds = true
    /// Taptic feedback: keys, corrected words, emoji categories, holds and menus.
    var haptics = true
    /// How soon a handwritten word is read once the pen lifts: 0 slowest … 1 fastest
    /// (Rooz, 2026-11-08: write on without stopping; a slider in the app's handwriting page).
    var handwritingSpeed = 1.0
    /// The pen's width in points.
    var handwritingInkWidth = 4.0
    /// The pen's colour; nil follows the keyboard's letter colour.
    var handwritingInk: KeyStyle.RGBA?
    /// Written words slide aside like paper under the pen and fade once it rests; off, each
    /// word fades as soon as it is read (Rooz, 2026-11-09).
    var handwritingSlide = true
    /// A faint guide line across the handwriting paper, in the letters' colour (Rooz, 2026-11-11).
    var handwritingGuide = true
    /// A strip at the paper's outer edge that sends the word aside when tapped (Rooz, 2026-11-11).
    var handwritingStrip = true
    /// The handwriting pad's size: 0 small, 1 medium, 2 large (Rooz, 2026-11-09).
    var handwritingSize = 1
    static let handwritingSizeNames = ["کوچک", "متوسط", "بزرگ"]

    /// The pause after the last stroke that ends a handwritten word: 1.0 s slowest, 0.3 s fastest.
    var handwritingPause: TimeInterval { 1.0 - 0.7 * max(0, min(1, handwritingSpeed)) }
    static let handwritingSpeedNames = ["آرام", "متوسط", "سریع"]
    static let handwritingWidths = 2.0...10.0

    static let standard = KeyboardOptions()
    static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyboardOptions")
    static let defaultsKey = "keyboardOptions"

    init() {}

    /// Options added later take their default when an older copy lacks them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        suggestionBar = try container.decodeIfPresent(Bool.self, forKey: .suggestionBar) ?? true
        predictNextWord = try container.decodeIfPresent(Bool.self, forKey: .predictNextWord) ?? true
        correctTypos = try container.decodeIfPresent(Bool.self, forKey: .correctTypos) ?? true
        keyPreview = try container.decodeIfPresent(Bool.self, forKey: .keyPreview) ?? true
        tiltLetters = try container.decodeIfPresent(Bool.self, forKey: .tiltLetters) ?? true
        doubleSpacePunctuation = try container.decodeIfPresent(Bool.self, forKey: .doubleSpacePunctuation) ?? true
        numberRow = try container.decodeIfPresent(Bool.self, forKey: .numberRow) ?? false
        digitsOnLetters = try container.decodeIfPresent(Bool.self, forKey: .digitsOnLetters) ?? false
        autoZWNJ = try container.decodeIfPresent(Bool.self, forKey: .autoZWNJ) ?? true
        learnTouches = try container.decodeIfPresent(Bool.self, forKey: .learnTouches) ?? true
        touchResets = try container.decodeIfPresent(Int.self, forKey: .touchResets) ?? 0
        keySounds = try container.decodeIfPresent(Bool.self, forKey: .keySounds) ?? true
        haptics = try container.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        // Older copies kept three steps (0, 1, 2, fast by default); fast stays fast.
        handwritingSpeed = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .handwritingSpeed) ?? 1))
        handwritingInkWidth = try container.decodeIfPresent(Double.self, forKey: .handwritingInkWidth) ?? 4
        handwritingInk = try container.decodeIfPresent(KeyStyle.RGBA.self, forKey: .handwritingInk)
        handwritingSlide = try container.decodeIfPresent(Bool.self, forKey: .handwritingSlide) ?? true
        handwritingSize = try container.decodeIfPresent(Int.self, forKey: .handwritingSize) ?? 1
        handwritingGuide = try container.decodeIfPresent(Bool.self, forKey: .handwritingGuide) ?? true
        handwritingStrip = try container.decodeIfPresent(Bool.self, forKey: .handwritingStrip) ?? true
    }
}
