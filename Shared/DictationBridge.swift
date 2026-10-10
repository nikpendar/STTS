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
    /// App started the final pass; an estimate of how long it takes is on `transcriptPort`.
    static let progress = "com.persianstt.progress"
    /// App finished: the transcript is ready on `transcriptPort` (`done`), or nothing was recognized (`failed`).
    static let done = "com.persianstt.done"
    static let failed = "com.persianstt.failed"

    /// Prefixes that mark a served transcript as provisional or final. A fetch started for a
    /// partial result can arrive after the final one was published, so the keyboard goes by the prefix.
    static let partialPrefix = "P"
    /// Final transcript: "F" + dictation id + newline + text. The id lets the keyboard report
    /// the user's later edits of that text (`Correction`).
    static let finalPrefix = "F"
    /// Estimated seconds for the final pass, for the keyboard's progress ring.
    static let estimatePrefix = "E"

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

/// App side: hands the latest transcript to the next connection on 127.0.0.1, then forgets it.
final class TranscriptServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TranscriptServer")
    private var listener: NWListener?
    private var pending: Data?

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
            pending = nil
        }
    }

    func publish(_ text: String) {
        queue.async { [self] in pending = Data(text.utf8) }
    }

    private func serve(_ connection: NWConnection) {
        let data = pending ?? Data()
        pending = nil
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

/// Key background and outline colors, chosen in the app and applied by the keyboard.
/// The app writes them to a named pasteboard (shared by apps of the same team, and written while
/// the app is in the foreground); the keyboard reads it with Full Access and keeps a copy.
struct KeyStyle: Codable, Equatable {
    struct RGBA: Codable, Equatable {
        var r, g, b, a: Double
        var color: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    }

    var fill: RGBA
    var stroke: RGBA
    /// Letter and symbol colour; nil follows the system (black in light mode, white in dark).
    var text: RGBA?

    var textColor: UIColor { text?.color ?? .label }

    static let standard = KeyStyle(fill: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.18),
                                   stroke: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.45),
                                   text: nil)
    private static let pasteboardName = UIPasteboard.Name("ir.nikpendar.PersianSTT.keyStyle")
    private static let pasteboardType = "public.json"
    static let defaultsKey = "keyStyle"

    /// App side: saves the style and hands it to the keyboard.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        UIPasteboard(name: Self.pasteboardName, create: true)?.setData(data, forPasteboardType: Self.pasteboardType)
    }

    /// Keyboard side: the app's latest style, else the last one seen, else the standard style.
    static func load() -> KeyStyle {
        if let data = UIPasteboard(name: pasteboardName, create: false)?.data(forPasteboardType: pasteboardType),
           let style = try? JSONDecoder().decode(KeyStyle.self, from: data) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
            return style
        }
        return saved
    }

    /// The style stored in this process's own defaults.
    static var saved: KeyStyle {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(KeyStyle.self, from: $0) } ?? standard
    }
}
