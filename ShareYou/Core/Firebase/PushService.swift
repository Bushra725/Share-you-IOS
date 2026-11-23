import UIKit
import UserNotifications
import FirebaseMessaging

/// Firebase Cloud Messaging: APNs registration, FCM token, topic subscription, notification taps.
/// The permission prompt is NOT shown at launch; it is asked after the first finished transfer
/// (or from Settings), with a short explanation first.
@MainActor
final class PushService: NSObject, ObservableObject {
    static let shared = PushService()
    static let topicUpdates = "shareyou_updates"

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    func attach(application: UIApplication) {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        // Registering for remote notifications does not show a prompt.
        application.registerForRemoteNotifications()
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
    }

    /// Shows the system prompt once. Returns true when notifications are allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        Prefs.shared.pushAsked = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            await refreshStatus()
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            AnalyticsService.log(.notificationPermission, ["granted": granted ? 1 : 0])
            return granted
        } catch {
            Log.e("Notification permission failed", error)
            return false
        }
    }

    /// Called after a successful transfer: the first time only, ask nicely.
    func askAfterFirstTaskIfNeeded() {
        guard !Prefs.shared.pushAsked else { return }
        Task {
            await refreshStatus()
            guard authorization == .notDetermined else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await requestPermission()
        }
    }

    fileprivate func handleToken(_ token: String) {
        Prefs.shared.fcmToken = token
        Log.d("FCM token ready (\(token.prefix(12))…)")
        Messaging.messaging().subscribe(toTopic: PushService.topicUpdates) { error in
            if let error { Log.e("Topic subscribe failed", error) }
        }
        Task { await FirestoreService.shared.saveFCMToken(token) }
    }
}

extension PushService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        Task { @MainActor in self.handleToken(fcmToken) }
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let route = info["route"] as? String
        await MainActor.run {
            Messaging.messaging().appDidReceiveMessage(info)
            let local = !(response.notification.request.trigger is UNPushNotificationTrigger)
            AnalyticsService.log(.notificationOpen, ["source": local ? "local" : "push", "route": route ?? ""])
            if let route { Router.shared.openDeepLink(route) }
        }
    }
}
