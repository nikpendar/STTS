import SwiftUI

/// Keyless on Apple Watch: a microphone for the iPhone app. The watch records, the iPhone turns
/// the speech into Persian text offline (`WatchLink` in the iOS app), and the text comes back
/// here to be sent with the share sheet (Messages, Mail, ...).
@main
struct KeylessWatchApp: App {
    @StateObject private var dictation = WatchDictation.shared

    var body: some Scene {
        WindowGroup {
            DictationView()
                .environmentObject(dictation)
                // The complication opens keylesswatch://record: start recording right away.
                .onOpenURL { url in
                    if url.host == "record" { dictation.startFromComplication() }
                }
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
