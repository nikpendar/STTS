import SwiftUI

@main
struct PersianSTTApp: App {
    var body: some Scene {
        WindowGroup {
            if let state = UserDefaults.standard.string(forKey: "keyboardPreview") {
                KeyboardPreview(state: state)
            } else {
                ContentView()
            }
        }
    }
}
