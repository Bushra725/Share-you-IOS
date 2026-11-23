import Foundation
import FirebaseCore
import FirebaseAppCheck
import FirebaseCrashlytics
import FirebaseAnalytics

/// One place that starts Firebase. Called from `AppDelegate.didFinishLaunching`.
enum FirebaseBootstrap {
    static func configure() {
        // 1. App Check — must be installed before FirebaseApp.configure().
        //    Debug/Simulator: debug provider (register the token printed in the Xcode console
        //    under Firebase Console › App Check › Apps › Manage debug tokens).
        //    Release: App Attest (falls back to DeviceCheck on unsupported devices).
        AppCheck.setAppCheckProviderFactory(ShareYouAppCheckProviderFactory())

        // 2. Core (reads GoogleService-Info.plist from the app bundle).
        FirebaseApp.configure()

        // 3. Crashlytics — on in every build so crashes from TestFlight/App Store are reported.
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        Crashlytics.crashlytics().setCustomValue(AppConfig.version, forKey: "app_version")

        // 4. Analytics — no IDFA is read unless the user allows tracking (ATT).
        Analytics.setAnalyticsCollectionEnabled(true)
        AnrMonitor.shared.start()
    }
}

final class ShareYouAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG
        return AppCheckDebugProvider(app: app)
        #else
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        }
        return DeviceCheckProvider(app: app)
        #endif
    }
}
