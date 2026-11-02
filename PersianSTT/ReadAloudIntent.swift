import AppIntents

/// Reads a text aloud in Persian without opening the app. Made for a Shortcuts personal
/// automation "When I receive a message": the automation passes the message and its sender.
/// `AudioPlaybackIntent` lets iOS start the audio while the app stays in the background.
struct ReadAloudIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "خواندن با کیلس"
    static var description = IntentDescription("متن را با صدای فارسی بلند می‌خواند، بدون باز کردن اپ. برای خواندن پیامک‌ها در اتوماسیون «وقتی پیامی دریافت می‌کنم».")
    static var openAppWhenRun = false

    @Parameter(title: "متن")
    var text: String

    @Parameter(title: "فرستنده")
    var sender: String?

    static var parameterSummary: some ParameterSummary {
        Summary("خواندن \(\.$text)") {
            \.$sender
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var spoken = text
        if let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            spoken = "پیام از \(sender). \(text)"
        }
        try Speaker.shared.speak(spoken)
        return .result()
    }
}
