import Foundation
import FirebaseRemoteConfig

/// Remote Config with safe in-app defaults. Interstitial keys match Android so one
/// Firebase template controls both apps:
///  - ads_enabled, interstitial_ads_enabled
///  - interstitial_cooldown_ms (Android). `interstitial_cooldown_sec` is still read if ms is 0.
///  - interstitial_session_cap
///  - reminders_enabled, reminder_first_hours, reminder_inactive_hours
@MainActor
final class RemoteConfigService: ObservableObject {
    static let shared = RemoteConfigService()

    @Published private(set) var forceUpdateVersion = "0.0.0"
    @Published private(set) var adsEnabled = true
    @Published private(set) var interstitialEnabled = true
    /// Seconds between two interstitial ads. Comes from `interstitial_cooldown_ms`.
    @Published private(set) var interstitialCooldown: Double = 75
    @Published private(set) var interstitialSessionCap = 5
    @Published private(set) var remindersEnabled = true
    @Published private(set) var reminderFirstHours: Double = 24
    @Published private(set) var reminderSecondHours: Double = 72

    private lazy var rc: RemoteConfig = {
        let rc = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3600
        #endif
        rc.configSettings = settings
        rc.setDefaults([
            "force_update_version": "0.0.0" as NSString,
            "ads_enabled": true as NSNumber,
            "interstitial_ads_enabled": true as NSNumber,
            "interstitial_cooldown_ms": 75_000 as NSNumber,
            "interstitial_cooldown_sec": 0 as NSNumber,
            "interstitial_session_cap": 5 as NSNumber,
            "reminders_enabled": true as NSNumber,
            "reminder_first_hours": 24 as NSNumber,
            "reminder_inactive_hours": 72 as NSNumber
        ])
        return rc
    }()

    var updateRequired: Bool {
        Self.compare(AppConfig.version, forceUpdateVersion) == .orderedAscending
    }

    func fetch() async {
        apply() // defaults / last activated values first
        do {
            _ = try await rc.fetchAndActivate()
            apply()
        } catch {
            Log.d("Remote Config fetch failed: \(error.localizedDescription)")
        }
    }

    private func apply() {
        let version: String? = rc.configValue(forKey: "force_update_version").stringValue
        forceUpdateVersion = version ?? "0.0.0"
        adsEnabled = rc.configValue(forKey: "ads_enabled").boolValue
        interstitialEnabled = adsEnabled && rc.configValue(forKey: "interstitial_ads_enabled").boolValue
        let ms = rc.configValue(forKey: "interstitial_cooldown_ms").numberValue.doubleValue
        let sec = rc.configValue(forKey: "interstitial_cooldown_sec").numberValue.doubleValue
        let raw = ms > 0 ? ms / 1000 : sec
        interstitialCooldown = raw > 0 ? min(600, max(5, raw)) : 75
        interstitialSessionCap = rc.configValue(forKey: "interstitial_session_cap").numberValue.intValue
        remindersEnabled = rc.configValue(forKey: "reminders_enabled").boolValue
        reminderFirstHours = max(1, rc.configValue(forKey: "reminder_first_hours").numberValue.doubleValue)
        reminderSecondHours = max(1, rc.configValue(forKey: "reminder_inactive_hours").numberValue.doubleValue)
        AdsManager.shared.applyRemoteLimits()
        LocalNotificationService.shared.rescheduleReminders()
    }

    /// Numeric "1.2.10" style comparison.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}
