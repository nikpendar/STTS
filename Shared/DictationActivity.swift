import ActivityKit
import AppIntents
import Foundation

/// The Live Activity of a dictation started without the app on screen (Siri, the Control Center
/// button, the home screen widget): live text, the voice level and pause and end buttons on the
/// lock screen. Built into the app, which runs the dictation (`BackgroundDictation`), and into
/// the widget extension (KeylessWidgets), which draws it.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case listening, paused, transcribing, done, failed
        }

        var phase: Phase = .listening
        /// The text so far, or the final text.
        var text = ""
        /// The last voice levels, 0...1, oldest first, for the bars.
        var levels: [Double] = []
        /// Since when the recording runs, for the timer; paused time is left out.
        var started = Date()
        /// After the end: "copied" or "saved", shown under the text.
        var note = ""
    }
}

/// Starts a dictation with the app in the background, also with the iPhone locked: Siri
/// ("Keyless dictation"), the Control Center or lock screen button and the home screen widget.
/// The text is saved in the app's history and comes back as the result, so a shortcut can copy
/// it, send it or add it to a note. A second run while one is recording ends it.
/// On iOS 17 it is a plain intent, without the right to record in the background.
struct KeylessDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "دیکته با کیلس"
    static let description = IntentDescription("بدون باز کردن برنامه، حتی با گوشی قفل، صدا را ضبط و به متن فارسی تبدیل می‌کند و متن را برمی‌گرداند.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        #if WIDGET_EXTENSION
        return .result(value: "", dialog: "")
        #else
        let text = await BackgroundDictation.shared.run()
        return .result(value: text, dialog: IntentDialog(stringLiteral: text.isEmpty ? "متنی نوشته نشد." : text))
        #endif
    }
}

/// iOS 18: lets the intent start a recording with the app in the background or the iPhone
/// locked, as long as it shows a Live Activity.
@available(iOS 18.0, *)
extension KeylessDictationIntent: AudioRecordingIntent {}

/// The Live Activity's pause and resume button.
struct PauseDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "مکث دیکته"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        BackgroundDictation.shared.togglePause()
        #endif
        return .result()
    }
}

/// The Live Activity's end button: the recording stops and the text is written.
struct EndDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "پایان دیکته"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        BackgroundDictation.shared.end()
        #endif
        return .result()
    }
}

/// Opens the app and starts a dictation that stops after a pause and copies the text to the
/// clipboard (the iPhone must be unlocked). Also the "dictate and copy" control.
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "دیکته‌ی فارسی و کپی"
    static let description = IntentDescription("برنامه را باز می‌کند، صدا را ضبط می‌کند، به متن فارسی تبدیل می‌کند و در کلیپ‌بورد کپی می‌کند.")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        Transcriber.shared.requestQuickDictation()
        #endif
        return .result()
    }
}
