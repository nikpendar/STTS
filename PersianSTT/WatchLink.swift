import Foundation
import UIKit
import WatchConnectivity
import os

private let log = Logger(subsystem: "ir.nikpendar.PersianSTT", category: "watch")

/// The Apple Watch app's speech recogniser. The watch records (AAC, 16 kHz mono) and sends the
/// recording here in pieces with `sendMessage`, which wakes this app in the background; the
/// recording is transcribed with the same model as the keyboard and the text goes back to the
/// watch. Nothing leaves the two devices.
///
/// Messages (all dictionaries, see `WatchMessage` in KeylessWatch/PhoneLink.swift):
/// - watch to phone: `kind = chunk`, `id`, `index`, `count`, `data`; the reply only says it arrived.
/// - phone to watch: `kind = result`, `id`, and `text` or `error`. Sent with `sendMessage` while
///   the watch app is open, otherwise with `transferUserInfo`, which waits for it to open.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    /// Recordings still arriving, by id. Only touched on `queue`.
    private var pending: [String: [Int: Data]] = [:]
    private let queue = DispatchQueue(label: "ir.nikpendar.PersianSTT.watch")

    /// Starts listening for the watch; called at every launch, including background launches
    /// by the watch.
    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if let error {
            log.error("watch session: \(error.localizedDescription, privacy: .public)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: listen to the new one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["kind"] as? String == "chunk",
              let id = message["id"] as? String,
              let index = message["index"] as? Int,
              let count = message["count"] as? Int, count > 0, count <= 64,
              let data = message["data"] as? Data
        else {
            replyHandler(["ok": false])
            return
        }
        replyHandler(["ok": true])
        queue.async {
            var parts = self.pending[id] ?? [:]
            parts[index] = data
            guard parts.count == count else {
                self.pending[id] = parts
                return
            }
            self.pending[id] = nil
            let audio = (0..<count).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
            Task { await self.transcribe(id: id, audio: audio) }
        }
    }

    // MARK: - Transcription

    private func transcribe(id: String, audio: Data) async {
        // Background launches have about 30 s; ask for the rest of the time iOS allows.
        let background = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "watch dictation")
        }
        defer {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(background) }
        }
        let started = Date()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(id).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            // The keyboard's dictation and this one share the model's stream.
            if await MainActor.run(body: { KeyboardSession.shared.isCapturing }) {
                return send(id: id, error: "کیبورد کیلس روی گوشی در حال دیکته است.")
            }
            guard let engine = await Transcriber.shared.readyEngine() else {
                return send(id: id, error: "مدل گفتار روی گوشی نصب نیست. اپ کیلس را روی گوشی باز کنید.")
            }
            try audio.write(to: url)
            let samples = try AudioLoader.loadSamples(url: url)
            let raw = try await engine.transcribe(samples)
            let text = DictationBridge.removingPauseMarks(raw).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                return send(id: id, error: "صدایی شنیده نشد.")
            }
            // As in the keyboard: punctuation from the app, then numbers, ZWNJ and the personal dictionary.
            let options = KeyboardOptions.load()
            let dictionary = PersonalDictionary.saved
            let punctuated = options.autoPunctuation
                ? AutoPunctuation.shared.punctuate(text, quiet: dictionary.symbolWords)
                : text
            let written = VoiceCommands.process(punctuated, punctuation: false, commands: false,
                                                zwnj: options.autoZWNJ, dictionary: dictionary).text
            log.info("watch dictation: \(Double(samples.count) / AudioLoader.sampleRate, format: .fixed(precision: 1)) s of audio in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
            send(id: id, text: written)
        } catch {
            log.error("watch dictation failed: \(error.localizedDescription, privacy: .public)")
            send(id: id, error: "تبدیل به متن ناموفق بود.")
        }
    }

    private func send(id: String, text: String? = nil, error: String? = nil) {
        var reply: [String: Any] = ["kind": "result", "id": id]
        if let text { reply["text"] = text }
        if let error { reply["error"] = error }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(reply, replyHandler: nil) { _ in
                session.transferUserInfo(reply)
            }
        } else {
            session.transferUserInfo(reply)
        }
    }
}
