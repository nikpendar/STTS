import AppIntents

/// Opens the app and starts a dictation that stops after a pause and copies the text
/// to the clipboard. Assign it to Back Tap, the Action Button or a Control Center control
/// through the Shortcuts app.
struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource = "دیکته‌ی فارسی"
    static var description = IntentDescription("صدا را ضبط می‌کند، به متن فارسی تبدیل می‌کند و در کلیپ‌بورد کپی می‌کند.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Transcriber.shared.requestQuickDictation()
        return .result()
    }
}

struct PersianSTTShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "دیکته با \(.applicationName)",
                "Dictate with \(.applicationName)",
            ],
            shortTitle: "دیکته‌ی فارسی",
            systemImageName: "mic.fill"
        )
    }
}
