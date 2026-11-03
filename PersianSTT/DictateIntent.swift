import AppIntents

/// Lists the dictation shortcuts in the Shortcuts app and Siri. Siri has no Persian, so the
/// phrases Siri hears are English; the Persian ones are for the Shortcuts app's search.
/// - "Keyless dictation": records in the background, also with the iPhone locked
///   (`KeylessDictationIntent`, iOS 18 and later).
/// - "Dictate with Keyless": opens the app and copies the text (`DictateIntent`).
struct PersianSTTShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        if #available(iOS 18.0, *) {
            AppShortcut(
                intent: KeylessDictationIntent(),
                phrases: [
                    "\(.applicationName) dictation",
                    "Start \(.applicationName) dictation",
                    "دیکته با \(.applicationName) در پس‌زمینه",
                ],
                shortTitle: "دیکته با کیلس",
                systemImageName: "waveform.badge.mic"
            )
        }
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "دیکته با \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "دیکته و کپی",
            systemImageName: "mic.fill"
        )
    }
}
