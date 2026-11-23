import Foundation
import SwiftUI
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

    static func setKey(_ key: String, _ value: Any) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    /// Settings › Debug › "Test crash". Run the app WITHOUT the debugger attached
    /// (stop in Xcode, open from the home screen), tap it, then reopen the app to upload the report.
    static func testCrash() -> Never {
        fatalError("Crash was triggered")
    }
}

/// Firebase Analytics events. `first_open` and `session_start` are collected by the SDK.
/// Every custom name matches the product event list and stays within GA4's 40-character limit.
enum AnalyticsService {
    /// Screen currently on screen, attached to background events and ANR reports.
    static var currentScreen = "splash"
    private static var backgroundAt: Date?

    enum Event: String {
        case tutorialComplete = "tutorial_complete"
        case settingsChange = "settings_change"
        case share = "share"
        case rateApp = "rate_app"
        case contactUs = "contact_us"
        case attResult = "att_result"
        case forceUpdateShown = "force_update_shown"
        case deepLinkOpen = "deep_link_open"
        case fileSharedIn = "file_shared_in"
        case appForeground = "app_foreground"
        case appBackground = "app_background"
        case filesSelected = "files_selected"
        case fileLimitHit = "file_limit_hit"
        case permissionResult = "permission_result"
        case qrScanned = "qr_scanned"
        case connectAttempt = "connect_attempt"
        case connectSuccess = "connect_success"
        case connectFailed = "connect_failed"
        case sendStart = "send_start"
        case receiveStart = "receive_start"
        case networkHintShown = "network_hint_shown"
        case groupCreate = "group_create"
        case groupJoin = "group_join"
        case featureUnlock = "feature_unlock"
        case disconnect = "disconnect"
        case fileOpen = "file_open"
        case fileSent = "file_sent"
        case fileReceived = "file_received"
        case transferDone = "transfer_done"
        case transferFailed = "transfer_failed"
        case pcStart = "pc_start"
        case pcUpload = "pc_upload"
        case pcDownload = "pc_download"
        case fileImport = "file_import"
        case fileShare = "file_share"
        case fileDelete = "file_delete"
        case musicPlay = "music_play"
        case videoPlay = "video_play"
        case convertStart = "convert_start"
        case convertDone = "convert_done"
        case convertFailed = "convert_failed"
        case vaultSetup = "vault_setup"
        case vaultUnlock = "vault_unlock"
        case vaultAdd = "vault_add"
        case vaultRestore = "vault_restore"
        case junkClean = "junk_clean"
        case cleanScan = "clean_scan"
        case cleanDelete = "clean_delete"
        case paywallView = "paywall_view"
        case beginCheckout = "begin_checkout"
        case purchase = "purchase"
        case purchaseFailed = "purchase_failed"
        case restorePurchases = "restore_purchases"
        case adShow = "ad_show"
        case adReward = "ad_reward"
        case consentResult = "consent_result"
        case login = "login"
        case signUp = "sign_up"
        case logout = "logout"
        case deleteAccount = "delete_account"
        case notificationOpen = "notification_open_app"
        case notificationPermission = "notification_permission"
        case localNotificationScheduled = "local_notification_scheduled"
        case appNotResponding = "app_not_responding"
    }

    static func log(_ event: Event, _ params: [String: Any] = [:]) {
        log(event.rawValue, params)
    }

    static func log(_ name: String, _ params: [String: Any] = [:]) {
        Analytics.logEvent(String(name.prefix(40)), parameters: params.isEmpty ? nil : params)
    }

    /// Firebase recommended `screen_view`.
    static func screen(_ name: String) {
        let clean = String(name.prefix(100))
        currentScreen = clean
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: clean,
            AnalyticsParameterScreenClass: clean
        ])
        CrashReporter.setKey("screen", clean)
        AnrMonitor.shared.currentScreen = clean
    }

    /// `ui_click` with `screen_name` and `button_id`, plus any extra parameters.
    static func click(_ button: String, screen: String? = nil, _ extra: [String: Any] = [:]) {
        var params = extra
        params["screen_name"] = screen ?? currentScreen
        params["button_id"] = String(button.prefix(40))
        log("ui_click", params)
    }

    static func foreground() {
        let away = backgroundAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        if backgroundAt != nil { log(.appForeground, ["seconds_away": max(0, away)]) }
        backgroundAt = nil
    }

    static func background() {
        backgroundAt = Date()
        log(.appBackground, ["screen_name": currentScreen])
    }

    static func logAdImpression(value: Double, currency: String, format: String, unitID: String) {
        Analytics.logEvent(AnalyticsEventAdImpression, parameters: [
            AnalyticsParameterAdPlatform: "AdMob",
            AnalyticsParameterAdSource: "AdMob",
            AnalyticsParameterAdFormat: format,
            AnalyticsParameterAdUnitName: unitID,
            AnalyticsParameterValue: value,
            AnalyticsParameterCurrency: currency
        ])
    }

    static func logPurchase(productID: String, value: Double, currency: String, transactionID: String) {
        Analytics.logEvent(AnalyticsEventPurchase, parameters: [
            AnalyticsParameterTransactionID: transactionID,
            AnalyticsParameterValue: value,
            AnalyticsParameterCurrency: currency,
            AnalyticsParameterItems: [[
                AnalyticsParameterItemID: productID,
                AnalyticsParameterItemName: productID,
                AnalyticsParameterQuantity: 1
            ]]
        ])
    }

    /// Whole bytes, clamped so the value fits a Firebase number parameter.
    static func bytes(_ n: Int64) -> Int { Int(min(max(n, 0), Int64(Int.max))) }
}

extension View {
    /// Logs a `screen_view` each time this screen appears.
    func trackScreen(_ name: String) -> some View {
        onAppear { AnalyticsService.screen(name) }
    }
}
