import Foundation
import FirebaseRemoteConfig

/// Remote Config with safe in-app defaults. Keys:
///  - force_update_version (String, e.g. "1.2.0"): versions below it must update.
///  - ads_enabled (Bool): global kill switch for ads.
///  - interstitial_cooldown_sec (Number): minimum seconds between interstitials (default 60–90 random).
///  - interstitial_session_cap (Number): max interstitials per session (default 4–6 random).
@MainActor
final class RemoteConfigService: ObservableObject {
    static let shared = RemoteConfigService()

    @Published private(set) var forceUpdateVersion = "0.0.0"
    @Published private(set) var adsEnabled = true
    @Published private(set) var interstitialCooldown: Double = 0
    @Published private(set) var interstitialSessionCap = 0

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
            "interstitial_cooldown_sec": 0 as NSNumber,
            "interstitial_session_cap": 0 as NSNumber
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
        interstitialCooldown = rc.configValue(forKey: "interstitial_cooldown_sec").numberValue.doubleValue
        interstitialSessionCap = rc.configValue(forKey: "interstitial_session_cap").numberValue.intValue
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
