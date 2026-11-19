import Foundation
import AdjustSdk

/// Adjust attribution + events for Share you iOS.
/// Tokens come from Info.plist (xcconfig). Dashboard values are the defaults below.
enum AdjustService {
    private static var started = false

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static var appToken: String {
        let t = info("SYAdjustAppToken")
        return t.isEmpty ? "3xsqwfivifi8" : t
    }

    /// Event token for `start_trial`.
    private static var startTrialToken: String {
        let t = info("SYAdjustEventStartTrial")
        return t.isEmpty ? "8vleqp" : t
    }

    /// Event token for `ad_revenue_adjust`.
    private static var adRevenueToken: String {
        let t = info("SYAdjustEventAdRevenue")
        return t.isEmpty ? "h09t4e" : t
    }

    /// Call once from `AppDelegate` right after Firebase bootstrap.
    static func configure() {
        guard !started else { return }
        guard !appToken.isEmpty else { return }
        started = true

        #if DEBUG
        let environment = ADJEnvironmentSandbox
        let logLevel = ADJLogLevel.verbose
        #else
        let environment = ADJEnvironmentProduction
        let logLevel = ADJLogLevel.info
        #endif

        guard let config = ADJConfig(appToken: appToken, environment: environment) else { return }
        config.logLevel = logLevel
        Adjust.initSdk(config)
        Log.d("Adjust SDK started (\(environment))")
    }

    /// Rewarded 24h Premium unlock (`start_trial` → `8vleqp`). Same as Android/Flutter.
    static func trackStartTrial(rewardType: String = "premium_24h") {
        guard let event = ADJEvent(eventToken: startTrialToken) else { return }
        event.addCallbackParameter(rewardType, forKey: "reward_type")
        Adjust.trackEvent(event)
        Log.d("Adjust start_trial reward_type=\(rewardType)")
    }

    /// AdMob paid impression (`ad_revenue_adjust` → `h09t4e`).
    /// `value` is in currency units (not micros).
    static func trackAdRevenue(
        valueMicros: Int64,
        currency: String,
        adUnitID: String? = nil,
        format: String? = nil
    ) {
        let value = Double(valueMicros) / 1_000_000.0
        let code = currency.isEmpty ? "USD" : currency

        if value > 0, let revenue = ADJAdRevenue(source: "admob_sdk") {
            revenue.setRevenue(value, currency: code)
            if let adUnitID, !adUnitID.isEmpty { revenue.setAdRevenueUnit(adUnitID) }
            if let format, !format.isEmpty { revenue.setAdRevenuePlacement(format) }
            Adjust.trackAdRevenue(revenue)
        }

        guard let event = ADJEvent(eventToken: adRevenueToken) else { return }
        if value > 0 {
            event.setRevenue(value, currency: code)
        }
        if let format, !format.isEmpty {
            event.addCallbackParameter(format, forKey: "ad_format")
        }
        if let adUnitID, !adUnitID.isEmpty {
            event.addCallbackParameter(adUnitID, forKey: "ad_unit")
        }
        Adjust.trackEvent(event)
        Log.d("Adjust ad_revenue_adjust value=\(value) \(code)")
    }
}
