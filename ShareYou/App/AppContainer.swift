import SwiftUI

/// Builds and owns every long-lived service (simple constructor-based dependency injection).
/// Views receive these through `@EnvironmentObject`; non-view code gets them passed in or uses `.shared`.
@MainActor
final class AppContainer: ObservableObject {
    let prefs = Prefs.shared
    let router = Router.shared
    let history = HistoryStore.shared
    let network = NetworkMonitor.shared
    let remoteConfig = RemoteConfigService.shared
    let auth = AuthService.shared
    let store = StoreService.shared
    let ads = AdsManager.shared
    let transfer = TransferManager.shared
    let pc = PcShare.shared
    let music = MusicController.shared
    let video = VideoController.shared
    let vault = Vault.shared
    let selection = SelectionStore.shared

    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        network.start()
        AppFiles.prepareFolders()
        store.start()
        auth.start()
        ads.startSession()
        await remoteConfig.fetch()
        await ads.gatherConsentAndStart()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            ads.appBecameActive()
            store.refreshEntitlements()
        case .background:
            ads.appEnteredBackground()
            vault.lock()
            video.appEnteredBackground()
        default:
            break
        }
    }
}
