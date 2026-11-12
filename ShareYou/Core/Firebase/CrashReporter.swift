import Foundation
import FirebaseCrashlytics
import FirebaseAnalytics

/// Thin wrapper so feature code does not import Firebase directly.
enum CrashReporter {
    static func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    static func record(_ error: Error) {
        Crashlytics.crashlytics().record(error: error)
    }

    static func setUser(_ id: String?) {
        Crashlytics.crashlytics().setUserID(id ?? "")
        Analytics.setUserID(id)
    }

    /// Settings › Debug › "Test crash". Run the app WITHOUT the debugger attached
    /// (stop in Xcode, open from the home screen), tap it, then reopen the app to upload the report.
    static func testCrash() -> Never {
        fatalError("Crash was triggered")
    }
}

/// Analytics events used across the app. Event names stay ≤ 40 chars, snake_case.
enum AnalyticsService {
    enum Event: String {
        case transferDone = "transfer_done"
        case groupStarted = "group_started"
        case pcConnected = "pc_connected"
        case convertDone = "convert_done"
        case vaultAdded = "vault_added"
        case cleanDone = "clean_done"
        case paywallShown = "paywall_shown"
        case purchase = "premium_purchase"
        case rewardEarned = "reward_earned"
        case signIn = "sign_in"
    }

    static func log(_ event: Event, _ params: [String: Any]? = nil) {
        Analytics.logEvent(event.rawValue, parameters: params)
    }

    static func screen(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [AnalyticsParameterScreenName: name])
    }
}
