import SwiftUI
import UIKit

@main
struct PersianSTTApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

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

/// The app is portrait only; the simulator test (`-testLandscape 1`) also allows landscape
/// to check the keyboard's landscape layout.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UserDefaults.standard.bool(forKey: "testLandscape") ? .landscapeRight : .portrait
    }
}
