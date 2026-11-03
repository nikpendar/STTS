import Foundation
import WatchConnectivity

/// The link to the iPhone app (`WatchLink` there). A recording goes over in pieces of at most
/// `chunkSize` bytes with `sendMessage`, which wakes the iPhone app in the background; the text
/// comes back as a `result` message, or as user info when this app was closed in the meantime.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneLink()

    /// sendMessage payloads are limited (about 64 KB); AAC at 24 kbit/s is 3 KB a second.
    private let chunkSize = 48_000

    /// The text, or an error, for a recording id. Called on the main queue.
    var onResult: ((_ id: String, _ text: String?, _ error: String?) -> Void)?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isReachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    /// Sends a recording; returns once every piece arrived on the iPhone.
    func send(_ audio: Data, id: String) async throws {
        let session = WCSession.default
        guard session.activationState == .activated else { throw PhoneLinkError.notActivated }
        guard session.isReachable else { throw PhoneLinkError.unreachable }
        let count = max(1, (audio.count + chunkSize - 1) / chunkSize)
        for index in 0..<count {
            let start = index * chunkSize
            let piece = audio.subdata(in: start..<min(audio.count, start + chunkSize))
            let message: [String: Any] = ["kind": "chunk", "id": id, "index": index, "count": count, "data": piece]
            let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
                session.sendMessage(message, replyHandler: { continuation.resume(returning: $0) },
                                    errorHandler: { continuation.resume(throwing: $0) })
            }
            guard reply["ok"] as? Bool == true else { throw PhoneLinkError.rejected }
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliver(userInfo)
    }

    private func deliver(_ message: [String: Any]) {
        guard message["kind"] as? String == "result", let id = message["id"] as? String else { return }
        let text = message["text"] as? String
        let error = message["error"] as? String
        DispatchQueue.main.async { self.onResult?(id, text, error) }
    }
}

enum PhoneLinkError: LocalizedError {
    case notActivated, unreachable, rejected

    var errorDescription: String? {
        switch self {
        case .notActivated, .unreachable:
            return "آیفون در دسترس نیست. گوشی باید نزدیک ساعت باشد."
        case .rejected:
            return "آیفون صدا را نپذیرفت."
        }
    }
}
