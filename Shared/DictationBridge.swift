import Foundation

/// Messages between the keyboard extension and the app.
///
/// Darwin notifications carry no data, and a free Apple ID cannot use App Groups,
/// so the transcript itself travels on the general pasteboard.
enum DictationBridge {
    /// Keyboard asks whether a session is running; the app answers with `alive`.
    static let ping = "com.persianstt.ping"
    static let alive = "com.persianstt.alive"
    /// Keyboard starts and stops a recording; the app confirms with `recording`.
    static let start = "com.persianstt.start"
    static let recording = "com.persianstt.recording"
    static let stop = "com.persianstt.stop"
    /// Keyboard extension started; the app shows it so a keyboard that never launches is visible.
    static let launched = "com.persianstt.keyboardLaunched"
    /// Keyboard abandons the transcription in progress.
    static let cancel = "com.persianstt.cancel"
    /// App finished: the transcript is on the pasteboard (`done`), or nothing was recognized (`failed`).
    static let done = "com.persianstt.done"
    static let failed = "com.persianstt.failed"

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
