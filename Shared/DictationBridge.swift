import Foundation
import Network

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
    /// App finished: the transcript is ready on `transcriptPort` (`done`), or nothing was recognized (`failed`).
    static let done = "com.persianstt.done"
    static let failed = "com.persianstt.failed"

    /// Loopback port the app serves the latest transcript on.
    static let transcriptPort: NWEndpoint.Port = 47_861

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
