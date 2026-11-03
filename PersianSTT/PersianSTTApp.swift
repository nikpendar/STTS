import SwiftUI
import UIKit
import UserNotifications

/// The app's one window: the settings page (`ContentView`), or a test screen chosen by a
/// launch argument (`-keyboardTest`, `-keyboardPreview`) in the simulator workflows.
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

/// Starts collecting crash reports (`CrashReports`) and listening for the watch app (`WatchLink`). The app is portrait only; the simulator
/// test (`-testLandscape 1`) also allows landscape to check the keyboard's landscape layout.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashReports.shared.start()
        // The Apple Watch app sends recordings here, and may be what launched the app.
        WatchLink.shared.start()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// A tap on the notification of a dictation made with the iPhone locked or the app in the
    /// background copies its text: the app is on screen then, so the clipboard takes it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let text = response.notification.request.content.userInfo[BackgroundDictation.notificationTextKey] as? String {
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UserDefaults.standard.bool(forKey: "testLandscape") ? .landscapeRight : .portrait
    }
}
