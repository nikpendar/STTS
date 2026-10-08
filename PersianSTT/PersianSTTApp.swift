import SwiftUI

@main
struct PersianSTTApp: App {
    var body: some Scene {
        WindowGroup {
            if UserDefaults.standard.bool(forKey: "keyboardTest") {
                KeyboardTestView()
            } else if let state = UserDefaults.standard.string(forKey: "keyboardPreview") {
                KeyboardPreview(state: state)
            } else {
                ContentView()
            }
        }
    }
}
