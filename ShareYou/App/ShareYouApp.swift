import SwiftUI
import GoogleSignIn

@main
struct ShareYouApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// Dependency container. Every service is created once here and injected into the view tree.
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container.prefs)
                .environmentObject(container.router)
                .environmentObject(container.history)
                .environmentObject(container.network)
                .environmentObject(container.remoteConfig)
                .environmentObject(container.auth)
                .environmentObject(container.store)
                .environmentObject(container.ads)
                .environmentObject(container.transfer)
                .environmentObject(container.pc)
                .environmentObject(container.music)
                .environmentObject(container.video)
                .environmentObject(container.vault)
                .environmentObject(container.selection)
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    container.router.handleIncoming(url: url)
                }
                .task { await container.start() }
        }
        .onChange(of: scenePhase) { phase in
            container.scenePhaseChanged(phase)
        }
    }
}
