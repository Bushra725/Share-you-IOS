import SwiftUI

struct RootView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var remoteConfig: RemoteConfigService
    @EnvironmentObject private var video: VideoController
    /// First-launch branded splash (same ~1.8s hold as Android).
    @State private var introSplash = true

    var body: some View {
        ZStack {
            TabView(selection: $router.tab) {
                tab(path: $router.homePath) { HomeView() }
                    .tabItem { Label("Home", systemImage: "house.fill") }.tag(AppTab.home)
                tab(path: $router.filesPath) { FilesView() }
                    .tabItem { Label("Files", systemImage: "folder.fill") }.tag(AppTab.files)
                tab(path: $router.playerPath) { PlayerTabView() }
                    .tabItem { Label("Player", systemImage: "play.circle.fill") }.tag(AppTab.player)
                tab(path: $router.toolsPath) { ToolsView() }
                    .tabItem { Label("Tools", systemImage: "square.grid.2x2.fill") }.tag(AppTab.tools)
                tab(path: $router.mePath) { MeView() }
                    .tabItem { Label("Me", systemImage: "person.fill") }.tag(AppTab.me)
            }
            .tint(Brand.cyanInk)

            if let toast = router.toast {
                VStack { Spacer(); ToastView(text: toast) }
                    .animation(.spring(), value: router.toast)
                    .allowsHitTesting(false)
            }
            if introSplash || ads.splash {
                SplashView()
                    .transition(.opacity)
                    .task(id: ads.splash) {
                        if ads.splash { await ads.runColdSplash() }
                    }
            }
            if remoteConfig.updateRequired {
                ForceUpdateView()
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.25)) { introSplash = false }
        }
        .preferredColorScheme(prefs.colorScheme)
        .sheet(isPresented: $router.showPaywall) { PaywallView() }
        .fullScreenCover(item: $video.presented) { src in VideoPlayerScreen(source: src) }
        .fullScreenCover(isPresented: Binding(get: { !prefs.onboarded }, set: { prefs.onboarded = !$0 })) {
            OnboardingView()
        }
        .onChange(of: router.homePath.count) { _ in ads.noteAction() }
        .onChange(of: router.filesPath.count) { _ in ads.noteAction() }
        .onChange(of: router.toolsPath.count) { count in
            ads.noteAction()
            // Left Safebox (or any tools push) — always re-lock.
            if count == 0 { Vault.shared.lock() }
        }
        .onChange(of: router.mePath.count) { _ in ads.noteAction() }
        .onChange(of: router.tab) { _ in
            ads.noteAction()
            // Tab switch keeps Tools' NavigationStack alive; force lock so reopen asks again.
            Vault.shared.lock()
        }
    }

    private func tab<Content: View>(path: Binding<NavigationPath>, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: path) {
            root()
                .navigationDestination(for: Route.self) { route in destination(route) }
        }
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .send: SendView()
        case .receive(let group): ReceiveView(group: group)
        case .group: GroupShareView()
        case .connect(let group): ConnectView(group: group)
        case .pc: PcShareView()
        case .history: HistoryView()
        case .settings: SettingsView()
        case .account: AccountView()
        case .about: AboutView()
        case .safebox: SafeboxView()
        case .converter: ConverterView()
        case .clean: CleanView()
        case .category(let c): CategoryFilesView(category: c)
        case .browser(let url): FolderBrowserView(folder: url)
        case .largeFiles: LargeFilesView()
        case .music: PlayerTabView()
        case .videos: CategoryFilesView(category: .videos)
        }
    }
}

struct ForceUpdateView: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            VStack(spacing: 16) {
                BrandIconBox(systemName: "arrow.down.app.fill", size: 72)
                Text("Update required").font(.title2.bold())
                Text("A newer version of \(AppConfig.appName) is needed to keep sharing. It only takes a moment.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button {
                    if let url = AppConfig.appStoreURL { openURL(url) }
                } label: { Text("Update").frame(maxWidth: .infinity) }
                .buttonStyle(BrandButtonStyle())
            }
            .padding(32)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var prefs: Prefs
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("AppLogo").resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.top, 40).accessibilityHidden(true)
                Text("Welcome to \(AppConfig.appName)").font(.title.bold()).multilineTextAlignment(.center)
                Text("Send photos, videos, music and any file to Android phones, iPhones and computers — fast, and without internet.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick your avatar").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(0..<Prefs.avatars.count, id: \.self) { i in
                            Button { prefs.avatar = i } label: {
                                Text(Prefs.avatars[i]).font(.largeTitle)
                                    .frame(width: 48, height: 48)
                                    .background(Circle().fill(prefs.avatar == i ? Brand.cyan3.opacity(0.3) : Color.clear))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(prefs.avatar == i ? .isSelected : [])
                        }
                    }
                    Text("Your name on other devices").font(.headline).padding(.top, 8)
                    TextField("Device name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { name = prefs.deviceName }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("We only ask for a permission when you use the feature that needs it.", systemImage: "hand.raised.fill")
                    Label("Files go straight from phone to phone. Nothing is uploaded.", systemImage: "lock.fill")
                }
                .font(.footnote).foregroundStyle(.secondary)
                Button {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { prefs.deviceName = String(trimmed.prefix(24)) }
                    prefs.onboarded = true
                } label: { Text("Get started").frame(maxWidth: .infinity) }
                .buttonStyle(BrandButtonStyle())
            }
            .padding(24)
        }
        .interactiveDismissDisabled()
    }
}
