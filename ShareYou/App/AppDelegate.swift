import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn

/// UIKit app delegate, attached to SwiftUI with `@UIApplicationDelegateAdaptor`.
/// Firebase must be configured here, before any view touches a Firebase API.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // App Check provider must be set BEFORE FirebaseApp.configure().
        FirebaseBootstrap.configure()

        PushService.shared.attach(application: application)
        return true
    }

    // MARK: - Remote notifications (APNs → FCM)

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.e("APNs registration failed", error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Messaging.messaging().appDidReceiveMessage(userInfo)
        completionHandler(.noData)
    }

    // MARK: - URLs (Google Sign-In redirect)

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    // MARK: - Orientation (portrait app, the video player may rotate)

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// The app is portrait-only on iPhone. The full-screen video player unlocks landscape while it is open.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    static func allowLandscape(_ allow: Bool) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        mask = allow ? .allButUpsideDown : .portrait
        if !allow, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            if #available(iOS 16.0, *) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
