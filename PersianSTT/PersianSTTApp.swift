import SwiftUI
import UIKit

/// The app's one window: the settings page (`ContentView`), or a test screen chosen by a
/// launch argument (`-keyboardTest`, `-keyboardPreview`) in the simulator workflows.
@main
struct PersianSTTApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            if TestHooks.bool("keyboardTest") {
                KeyboardTestView()
            } else if let state = TestHooks.string("keyboardPreview") {
                KeyboardPreview(state: state)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

/// Starts collecting crash reports (`CrashReports`) and listening for the watch app (`WatchLink`). The app is portrait only; the simulator
/// test (`-testLandscape 1`) also allows landscape to check the keyboard's landscape layout.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashReports.shared.start()
        // The key the keyboard needs to talk to the app (`BridgeKey`).
        BridgeKey.publish()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in BridgeKey.publish() }
        // The Apple Watch app sends recordings here, and may be what launched the app.
        WatchLink.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        TestHooks.bool("testLandscape") ? .landscapeRight : .portrait
    }
}

/// Launch arguments of the simulator workflows. Read only in the simulator: the app on a phone
/// ignores them, and the test screens are not built into it.
enum TestHooks {
    static func string(_ key: String) -> String? {
        #if targetEnvironment(simulator)
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }

    static func bool(_ key: String) -> Bool { string(key).map { $0 == "1" || $0 == "YES" || $0 == "true" } ?? false }
}
