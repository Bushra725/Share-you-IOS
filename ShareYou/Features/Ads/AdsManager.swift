import UIKit
import GoogleMobileAds
import UserMessagingPlatform
import AppTrackingTransparency

/// Ad unit ids from the xcconfig files (Debug = Google's test ids, Release = yours).
enum AdConfig {
    static var banner: String { AppConfig.info("SYAdBannerID") }
    static var interstitial: String { AppConfig.info("SYAdInterstitialID") }
    static var rewarded: String { AppConfig.info("SYAdRewardedID") }
    static var appOpen: String { AppConfig.info("SYAdAppOpenID") }
    static var native: String { AppConfig.info("SYAdNativeID") }

    /// Placeholder ids ("REPLACE_ME") are never requested.
    static func usable(_ id: String) -> Bool { id.hasPrefix("ca-app-pub-") && id.contains("/") }
}

/// AdMob with the same rules as the Android app (`Ads.kt`):
///  - UMP consent (GDPR) is gathered before any ad request; ATT is asked after consent, later, at a calm moment.
///  - Interstitials: never on app start; only after the first finished task in session 1; 60–90 s cooldown;
///    4–6 per session; at least 2 user actions between two; never during a transfer or while audio/video plays.
///  - App-open ad: cold start from the 2nd session (3–5 s splash wait), or when returning after 3+ minutes.
///  - Rewarded: unlocks a feature until midnight, or Premium for 24 h.
///  - Premium hides every ad.
@MainActor
final class AdsManager: NSObject, ObservableObject {
    static let shared = AdsManager()

    enum Place {
        case transferDone, groupDone, pcDone, convertDone, scanCleaned, cleanExit
        case fileOpen, videoExit, audioExit, historyExit
    }

    /// Holds the branded splash while a cold-start app-open ad is given a few seconds to load.
    @Published private(set) var splash = false
    @Published private(set) var canRequestAds = false
    @Published private(set) var privacyOptionsRequired = false

    private var sdkStarted = false
    private var interstitial: InterstitialAd?
    private var rewarded: RewardedAd?
    private var appOpen: AppOpenAd?
    private var loadingInterstitial = false
    private var loadingRewarded = false
    private var loadingAppOpen = false
    private var showingFullScreen = false
    private var lastShown: Date?
    private var cooldown: TimeInterval = 75
    private var interstitialsShown = 0
    private var sessionCap = 5
    private var actionsSinceAd = 0
    private var fileOpens = 0
    private var backgroundAt: Date?
    private var pendingInterstitial = false
    private var pendingAppOpen = false
    private var flushTimer: Timer?
    private var rewardCallback: (() -> Void)?
    private var rewardEarned = false

    private var prefs: Prefs { Prefs.shared }

    var adsOff: Bool {
        StoreService.shared.isPremium || !RemoteConfigService.shared.adsEnabled || !canRequestAds
    }

    // MARK: - Session & consent

    func startSession() {
        prefs.appSessions += 1
        interstitialsShown = 0
        actionsSinceAd = 0
        fileOpens = 0
        let rc = RemoteConfigService.shared
        sessionCap = rc.interstitialSessionCap > 0 ? rc.interstitialSessionCap : Int.random(in: 4...6)
        cooldown = rc.interstitialCooldown > 0 ? rc.interstitialCooldown : Double.random(in: 60...90)
        if prefs.appSessions >= 2 && !StoreService.shared.isPremium { splash = true }
    }

    /// UMP consent first (shows Google's form only where required, e.g. EEA/UK), then the Mobile Ads SDK.
    func gatherConsentAndStart() async {
        let params = RequestParameters()
        #if DEBUG
        let debug = DebugSettings()
        // Uncomment to test the GDPR form outside the EEA:
        // debug.geography = .EEA
        params.debugSettings = debug
        #endif
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: params)
            try await ConsentForm.loadAndPresentIfRequired(from: UIHelpers.topViewController())
        } catch {
            Log.d("Consent: \(error.localizedDescription)")
        }
        canRequestAds = ConsentInformation.shared.canRequestAds
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        startSDKIfAllowed()
        if prefs.appSessions >= 2 { maybeAskTracking(after: 2) }
    }

    /// Settings › Privacy choices (required by UMP when `privacyOptionsRequired`).
    func showPrivacyOptions() async {
        do {
            try await ConsentForm.presentPrivacyOptionsForm(from: UIHelpers.topViewController())
        } catch {
            Log.d("Privacy options: \(error.localizedDescription)")
        }
        canRequestAds = ConsentInformation.shared.canRequestAds
    }

    private func startSDKIfAllowed() {
        guard canRequestAds, !sdkStarted else {
            if !canRequestAds { splash = false }
            return
        }
        sdkStarted = true
        MobileAds.shared.start(completionHandler: nil)
        preloadInterstitial()
        prepareRewarded()
        if !adsOff { loadAppOpen() } else { splash = false }
    }

    /// App Tracking Transparency, asked once, after consent, never on the first screen of the first launch.
    func maybeAskTracking(after seconds: Double = 1.5) {
        guard !prefs.attAsked, ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard UIApplication.shared.applicationState == .active, !showingFullScreen, !splash else { return }
            prefs.attAsked = true
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
    }

    // MARK: - App lifecycle

    func appEnteredBackground() { backgroundAt = Date() }

    func appBecameActive() {
        defer { backgroundAt = nil }
        guard let away = backgroundAt.map({ Date().timeIntervalSince($0) }) else { return }
        if away >= 180 && !adsOff {
            pendingAppOpen = true
            if appOpen != nil { showAppOpen(ignoreCooldown: true) } else { loadAppOpen() }
        } else {
            flushPending()
        }
    }

    /// A navigation counts as a user action. Two are required between interstitials.
    func noteAction() { actionsSinceAd += 1 }

    /// The first finished task of session 1 is what allows interstitials to start.
    func markTaskDone() {
        let first = !prefs.firstTaskDone
        prefs.firstTaskDone = true
        if first { maybeAskTracking(after: 3) }
    }

    // MARK: - Cold-start splash with app-open ad

    func runColdSplash() async {
        guard splash else { return }
        if adsOff || prefs.appSessions < 2 { splash = false; return }
        let wait = Double.random(in: 3...5)
        let start = Date()
        while Date().timeIntervalSince(start) < wait {
            if appOpen != nil && !blockedNow() && canRequestAds { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        splash = false
        if appOpen != nil && !blockedNow() && !adsOff { showAppOpen(ignoreCooldown: true) } else { loadAppOpen() }
    }

    // MARK: - Interstitials

    func tryShow(_ place: Place, count: Int = 1) {
        guard placeReady(place, count: count) else { return }
        pendingInterstitial = true
        showInterstitialNow()
    }

    private func placeReady(_ place: Place, count: Int) -> Bool {
        let n = max(1, count)
        switch place {
        case .fileOpen:
            let crossed = fileOpens / 4 != (fileOpens + n) / 4
            fileOpens += n
            return crossed
        default:
            return true
        }
    }

    private func gatesOK() -> Bool {
        if adsOff || showingFullScreen || splash { return false }
        if interstitialsShown >= sessionCap { return false }
        if interstitialsShown > 0 && actionsSinceAd < 2 { return false }
        if prefs.appSessions <= 1 && !prefs.firstTaskDone { return false }
        if let lastShown, Date().timeIntervalSince(lastShown) < cooldown { return false }
        if blockedNow() { return false }
        return true
    }

    private func showInterstitialNow() {
        guard pendingInterstitial else { return }
        if adsOff || interstitialsShown >= sessionCap { pendingInterstitial = false; return }
        guard gatesOK() else { preloadInterstitial(); scheduleFlush(); return }
        guard let ad = interstitial, let vc = UIHelpers.topViewController() else { preloadInterstitial(); return }
        interstitial = nil
        pendingInterstitial = false
        pendingAppOpen = false
        showingFullScreen = true
        lastShown = Date()
        interstitialsShown += 1
        actionsSinceAd = 0
        cooldown = RemoteConfigService.shared.interstitialCooldown > 0 ? RemoteConfigService.shared.interstitialCooldown : Double.random(in: 60...90)
        ad.fullScreenContentDelegate = self
        ad.present(from: vc)
    }

    private func preloadInterstitial() {
        guard sdkStarted, !adsOff, interstitial == nil, !loadingInterstitial, AdConfig.usable(AdConfig.interstitial) else { return }
        loadingInterstitial = true
        InterstitialAd.load(with: AdConfig.interstitial, request: Request()) { [weak self] ad, error in
            Task { @MainActor in
                guard let self else { return }
                self.loadingInterstitial = false
                if let ad { self.interstitial = ad; self.flushPending() }
                else { Log.d("Interstitial failed: \(error?.localizedDescription ?? "")") }
            }
        }
    }

    // MARK: - Pending flush

    /// No full-screen ad during a transfer or while audio or video is playing.
    private func blockedNow() -> Bool {
        TransferManager.shared.hasActiveWork || MusicController.shared.isPlaying || VideoController.shared.isPlaying
            || PcShare.shared.running
    }

    private func scheduleFlush() {
        let delay: TimeInterval
        if blockedNow() { delay = 2 }
        else if let lastShown, Date().timeIntervalSince(lastShown) < cooldown {
            delay = min(90, cooldown - Date().timeIntervalSince(lastShown) + 0.25)
        } else { delay = 1.5 }
        flushTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.adsOff { self.pendingInterstitial = false; self.pendingAppOpen = false; return }
                self.flushPending()
                if self.pendingInterstitial || self.pendingAppOpen { self.scheduleFlush() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        flushTimer = t
    }

    private func flushPending() {
        guard !adsOff, !showingFullScreen, !splash, UIApplication.shared.applicationState == .active else { return }
        if pendingAppOpen && appOpen != nil && !blockedNow() {
            showAppOpen(ignoreCooldown: true)
            return
        }
        if pendingInterstitial && !blockedNow() { showInterstitialNow() }
    }

    // MARK: - App open

    private func loadAppOpen() {
        guard sdkStarted, !adsOff, appOpen == nil, !loadingAppOpen, AdConfig.usable(AdConfig.appOpen) else { return }
        loadingAppOpen = true
        AppOpenAd.load(with: AdConfig.appOpen, request: Request()) { [weak self] ad, _ in
            Task { @MainActor in
                guard let self else { return }
                self.loadingAppOpen = false
                self.appOpen = ad
                if ad != nil && self.pendingAppOpen { self.flushPending() }
            }
        }
    }

    private func showAppOpen(ignoreCooldown: Bool) {
        guard !adsOff else { return }
        if showingFullScreen || splash || blockedNow() {
            pendingAppOpen = true
            scheduleFlush()
            return
        }
        guard let ad = appOpen, let vc = UIHelpers.topViewController() else { pendingAppOpen = true; loadAppOpen(); return }
        if !ignoreCooldown, let lastShown, Date().timeIntervalSince(lastShown) < cooldown {
            pendingAppOpen = true
            scheduleFlush()
            return
        }
        appOpen = nil
        pendingAppOpen = false
        showingFullScreen = true
        lastShown = Date()
        ad.fullScreenContentDelegate = self
        ad.present(from: vc)
    }

    // MARK: - Rewarded

    func prepareRewarded() {
        guard sdkStarted, rewarded == nil, !loadingRewarded, AdConfig.usable(AdConfig.rewarded) else { return }
        loadingRewarded = true
        RewardedAd.load(with: AdConfig.rewarded, request: Request()) { [weak self] ad, error in
            Task { @MainActor in
                guard let self else { return }
                self.loadingRewarded = false
                self.rewarded = ad
                if ad == nil { Log.d("Rewarded failed: \(error?.localizedDescription ?? "")") }
            }
        }
    }

    /// Plays a rewarded ad. `onReward` only runs after the viewer has earned the reward.
    func showRewarded(onReward: @escaping () -> Void, onUnavailable: @escaping (String) -> Void) {
        guard canRequestAds else {
            onUnavailable(String(localized: "Ads are turned off by your privacy choices. Get Premium to unlock everything."))
            return
        }
        guard NetworkMonitor.shared.isOnline else {
            onUnavailable(String(localized: "The reward video needs internet. Connect to Wi-Fi or mobile data, then try again."))
            return
        }
        guard let ad = rewarded, let vc = UIHelpers.topViewController() else {
            prepareRewarded()
            onUnavailable(String(localized: "The reward video is not ready yet. Stay on a network with internet and try again."))
            return
        }
        rewarded = nil
        rewardEarned = false
        rewardCallback = onReward
        showingFullScreen = true
        ad.fullScreenContentDelegate = self
        ad.present(from: vc) { [weak self] in
            Task { @MainActor in self?.rewardEarned = true }
        }
    }

    fileprivate func fullScreenDismissed() {
        showingFullScreen = false
        if rewardEarned, let cb = rewardCallback {
            AnalyticsService.log(.rewardEarned)
            cb()
        }
        rewardEarned = false
        rewardCallback = nil
        preloadInterstitial()
        prepareRewarded()
        loadAppOpen()
        flushPending()
    }
}

extension AdsManager: FullScreenContentDelegate {
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.fullScreenDismissed() }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            self.showingFullScreen = false
            self.rewardCallback = nil
            self.preloadInterstitial()
            self.prepareRewarded()
        }
    }
}
