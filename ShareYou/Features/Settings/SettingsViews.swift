import SwiftUI
import StoreKit
import AuthenticationServices

struct SettingsView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var router: Router
    @StateObject private var push = PushService.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            if !store.isPremium {
                Section { PremiumBanner { router.paywall() } }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            Section("Appearance") {
                Picker("Appearance", selection: $prefs.themeMode) {
                    Text("Follow system").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                Button { UIHelpers.openSettings() } label: {
                    LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "")
                }
                .foregroundStyle(.primary)
            }
            Section {
                Toggle("Group relay", isOn: $prefs.groupRelay)
                Toggle("Keep screen on while sharing", isOn: $prefs.keepScreenOn)
                Toggle("Save received photos & videos to Photos", isOn: $prefs.saveToPhotos)
            } header: { Text("Transfer") } footer: {
                Text("Host forwards every file to all members. Received files are saved in Files › On My iPhone › Share you › Received.")
            }
            Section("Permissions") {
                Button { UIHelpers.openSettings() } label: { Label("App permissions", systemImage: "hand.raised.fill") }
                if push.authorization == .notDetermined {
                    Button { Task { await push.requestPermission() } } label: { Label("Turn on notifications", systemImage: "bell.badge") }
                } else {
                    LabeledContent { Text(push.authorization == .authorized ? "On" : "Off") } label: { Label("Notifications", systemImage: "bell") }
                }
                if ads.privacyOptionsRequired {
                    Button { Task { await ads.showPrivacyOptions() } } label: { Label("Ad privacy choices", systemImage: "shield.lefthalf.filled") }
                }
            }
            Section {
                Button("Clear transfer history", role: .destructive) { confirmClear = true }
            } footer: { Text("Only the list is cleared. Your received files stay on the device.") }
            Section {
                NavigationLink(value: Route.about) { Label("About", systemImage: "info.circle") }
            }
            #if DEBUG
            Section("Debug") {
                Toggle("Unlock Premium (debug)", isOn: Binding(get: { prefs.premiumDebug }, set: { store.setDebugPremium($0) }))
                Button("Test crash (Crashlytics)", role: .destructive) { CrashReporter.testCrash() }
                Button("Reset ad session counters") { prefs.appSessions = 0; prefs.firstTaskDone = false }
            }
            #endif
        }
        .navigationTitle(Text("Settings"))
        .task { await push.refreshStatus() }
        .confirmationDialog(Text("Clear transfer history"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { history.clear() }
        }
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var showMail = false
    @State private var showShare = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image("AppLogo").resizable().frame(width: 84, height: 84).clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                    Text(AppConfig.appName).font(.title2.bold())
                    Text("Version \(AppConfig.version) (\(AppConfig.build))").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Button { openURL(AppConfig.privacyPolicyURL) } label: { Label("Privacy policy", systemImage: "hand.raised") }
                Button { openURL(AppConfig.termsURL) } label: { Label("Terms of Use", systemImage: "doc.text") }
                if let email = AppConfig.supportEmail {
                    Button {
                        if MailComposer.canSend { showMail = true }
                        else if let url = URL(string: "mailto:\(email)") { openURL(url) }
                    } label: { Label("Contact us", systemImage: "envelope") }
                }
                Button {
                    if let url = AppConfig.writeReviewURL { openURL(url) } else { requestReview() }
                } label: { Label("Rate us", systemImage: "star") }
                Button { showShare = true } label: { Label("Share app", systemImage: "square.and.arrow.up") }
                if let more = AppConfig.moreAppsURL {
                    Button { openURL(more) } label: { Label("More apps", systemImage: "square.grid.2x2") }
                }
            }
            .foregroundStyle(.primary)
            Section {
                Text("Transfers go directly between devices over your Wi-Fi or the other phone's hotspot. Files are never uploaded to a server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("About"))
        .sheet(isPresented: $showMail) {
            MailComposer(recipient: AppConfig.supportEmail ?? "",
                         subject: "\(AppConfig.appName) \(AppConfig.version) (iOS)",
                         body: "\n\n—\n\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion), app \(AppConfig.version) (\(AppConfig.build))")
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [String(localized: "Send files fast without internet with \(AppConfig.appName)"),
                               AppConfig.appStoreURL ?? AppConfig.privacyPolicyURL])
        }
    }
}

/// Sign in (optional) / account management with in-app deletion.
struct AccountView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.colorScheme) private var scheme
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let a = auth.account {
                Section {
                    LabeledContent("Name", value: a.name ?? "—")
                    LabeledContent("Email", value: a.email ?? "—")
                    LabeledContent("Signed in with", value: a.providers.map { $0 == "apple.com" ? "Apple" : $0 == "google.com" ? "Google" : $0 }.joined(separator: ", "))
                } footer: { Text("Your profile and transfer totals are synced to your account. Files are never uploaded.") }
                Section {
                    Button("Sign out") { auth.signOut() }
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in (optional)").font(.headline)
                        Text("Keep your profile and stats across devices. Everything else works without an account.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    OfflineBanner()
                    SignInWithAppleButtonView()
                        .frame(height: 50)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    Button { Task { await auth.signInWithGoogle() } } label: {
                        HStack {
                            Image(systemName: "g.circle.fill").font(.title2)
                            Text("Sign in with Google").font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(scheme == .dark ? .black : .white)
                        .background(scheme == .dark ? Color.white : Color.black, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            if auth.busy { ProgressView() }
            if let error = auth.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(auth.account == nil ? Text("Sign in") : Text("Account"))
        .disabled(auth.busy)
        .confirmationDialog(Text("Delete your account?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { _ = await auth.deleteAccount() } }
        } message: {
            Text("Your account and its synced data are deleted. Files on this iPhone stay.")
        }
    }
}

struct SignInWithAppleButtonView: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            auth.prepareAppleRequest(request)
        } onCompletion: { result in
            Task { await auth.handleApple(result) }
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
    }
}
