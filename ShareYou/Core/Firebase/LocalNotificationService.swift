import Foundation
import UIKit
import UserNotifications

/// Local notifications (no server): received files, a paused transfer, a finished
/// conversion, and 24h / 72h reminders. The 72h delay is `reminder_inactive_hours`
/// in Remote Config, the same key Android uses.
@MainActor
final class LocalNotificationService {
    static let shared = LocalNotificationService()

    private enum ID {
        static let reminderFirst = "local.reminder.first"
        static let reminderSecond = "local.reminder.second"
        static let transferPaused = "local.transfer.paused"
        static let threadReceived = "received"
    }

    private let center = UNUserNotificationCenter.current()
    private var pending: [String: [String]] = [:]
    private var flushTask: Task<Void, Never>?

    private var inForeground: Bool { UIApplication.shared.applicationState == .active }

    func fileReceived(name: String, from sender: String) {
        guard !inForeground else { return }
        pending[sender, default: []].append(name)
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            flushReceived()
        }
    }

    private func flushReceived() {
        for (sender, names) in pending {
            let title = String(localized: "Files received from \(sender)")
            let body = names.count == 1
                ? names[0]
                : String(localized: "\(names.count) files saved in Files › Received")
            post(id: "local.received.\(sender)", title: title, body: body, route: "files",
                 thread: ID.threadReceived, analytics: "files_received")
        }
        pending.removeAll()
    }

    func taskFinished(_ title: String, body: String, route: String) {
        guard !inForeground else { return }
        post(id: "local.task.\(route)", title: title, body: body, route: route, analytics: "task_finished")
    }

    func appBackgroundedDuringTransfer() {
        post(id: ID.transferPaused,
             title: String(localized: "Transfer in progress"),
             body: String(localized: "Open Share you to keep sending. Transfers pause when the app is closed."),
             route: "receive", after: 3, analytics: "transfer_paused")
    }

    func cancelTransferWarning() {
        center.removePendingNotificationRequests(withIdentifiers: [ID.transferPaused])
        center.removeDeliveredNotifications(withIdentifiers: [ID.transferPaused])
    }

    /// Restarts the idle countdown. Called on launch, return to foreground, and when Remote Config updates.
    func rescheduleReminders() {
        center.removePendingNotificationRequests(withIdentifiers: [ID.reminderFirst, ID.reminderSecond])
        let rc = RemoteConfigService.shared
        guard rc.remindersEnabled, Prefs.shared.remindersOn, Prefs.shared.onboarded else { return }
        post(id: ID.reminderFirst,
             title: String(localized: "Share files in seconds"),
             body: String(localized: "Send photos, videos and music to any phone. No internet or cable needed."),
             route: "send", after: rc.reminderFirstHours * 3600, analytics: "reminder_first")
        post(id: ID.reminderSecond,
             title: String(localized: "Free up space on your iPhone"),
             body: String(localized: "Find duplicate photos and large videos with Clean."),
             route: "clean", after: rc.reminderSecondHours * 3600, analytics: "reminder_second")
    }

    private func post(id: String, title: String, body: String, route: String,
                      after seconds: TimeInterval = 1, thread: String? = nil, analytics: String) {
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["route": route, "source": "local", "id": id]
            if let thread { content.threadIdentifier = thread }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                AnalyticsService.log(.localNotificationScheduled, ["type": analytics])
            } catch {
                Log.e("Local notification failed", error)
            }
        }
    }
}
