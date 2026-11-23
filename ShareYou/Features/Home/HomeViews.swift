import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var selection: SelectionStore
    @State private var preview: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                VStack(spacing: 16) {
                    if !store.isPremium {
                        NativeAdCard()
                        PremiumBanner {
                            AnalyticsService.click("premium_banner", screen: "home")
                            router.paywall(source: "home_banner")
                        }
                    }
                    SectionCard {
                        Text("Quick tools").font(.headline).padding(.bottom, 8)
                        TileGrid(items: [
                            ToolItem(icon: "desktopcomputer", title: "Connect PC", color: Brand.catApps) { AnalyticsService.click("tool_connect_pc", screen: "home"); router.push(.pc) },
                            ToolItem(icon: "person.3.fill", title: "Group share", color: Brand.catVideo) { AnalyticsService.click("tool_group_share", screen: "home"); router.push(.group) },
                            ToolItem(icon: "lock.fill", title: "Safebox", color: Brand.catSafe) { AnalyticsService.click("tool_safebox", screen: "home"); router.push(.safebox) },
                            ToolItem(icon: "arrow.triangle.2.circlepath", title: "Converter", color: Brand.catDocs) { AnalyticsService.click("tool_converter", screen: "home"); router.push(.converter) },
                            ToolItem(icon: "sparkles", title: "Clean", color: Brand.catPink) { AnalyticsService.click("tool_clean", screen: "home"); router.push(.clean) },
                            ToolItem(icon: "music.note", title: "Music", color: Brand.catMusic) { AnalyticsService.click("tool_music", screen: "home"); router.tab = .player },
                            ToolItem(icon: "film.fill", title: "Videos", color: Brand.catVideo) { AnalyticsService.click("tool_videos", screen: "home"); router.push(.category(.videos)) },
                            ToolItem(icon: "clock.arrow.circlepath", title: "History", color: Brand.catDownload) { AnalyticsService.click("tool_history", screen: "home"); router.push(.history) }
                        ])
                    }
                    StorageCard { AnalyticsService.click("storage_card", screen: "home"); router.tab = .files }
                    AdBanner()
                    recent
                }
                .padding()
            }
        }
        .background(Brand.background)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $preview) { url in QuickLookView(urls: [url]).ignoresSafeArea() }
    }

    private var hero: some View {
        VStack(spacing: 22) {
            HStack(spacing: 12) {
                AvatarBubble(index: prefs.avatar, size: 44, ring: true)
                Text(AppConfig.appName).font(.title2.weight(.heavy)).foregroundStyle(Brand.navy)
                Spacer()
                Button {
                    AnalyticsService.click("scan_qr", screen: "home")
                    router.push(.connect(group: false))
                } label: {
                    Image(systemName: "qrcode.viewfinder").font(.title3).foregroundStyle(Brand.navy)
                        .frame(width: 42, height: 42).background(Color.white.opacity(0.35), in: Circle())
                }
                .accessibilityLabel(Text("Scan QR code"))
            }
            HStack {
                Spacer()
                bigAction("Send", icon: "arrow.up") {
                    AnalyticsService.click("send", screen: "home")
                    selection.clear(); router.push(.send)
                }
                Spacer()
                bigAction("Receive", icon: "arrow.down") {
                    AnalyticsService.click("receive", screen: "home")
                    router.push(.receive(group: false))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 24)
        .background(Brand.gradient.clipShape(BottomRoundedShape(radius: 32)))
    }

    private func bigAction(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle().fill(Color.white).frame(width: 92, height: 92)
                    .overlay(Circle().fill(Brand.gradient).frame(width: 72, height: 72)
                        .overlay(Image(systemName: icon).font(.system(size: 32, weight: .bold)).foregroundStyle(Brand.navy)))
                Text(title).font(.headline).foregroundStyle(Brand.navy)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        SectionCard {
            HStack {
                Text("Recently received").font(.headline)
                Spacer()
                Button("History") { AnalyticsService.click("recent_history", screen: "home"); router.push(.history) }
            }
            let items = history.entries.filter { !$0.sent }.prefix(5)
            if items.isEmpty {
                Text("Files you receive will show up here.").foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ForEach(Array(items)) { e in
                    Button {
                        AnalyticsService.click("recent_file", screen: "home", ["category": e.mime.split(separator: "/").first.map(String.init) ?? "other"])
                        AnalyticsService.log(.fileOpen, ["category": e.mime.split(separator: "/").first.map(String.init) ?? "other"])
                        if let u = e.url { preview = u }
                    } label: {
                        HStack(spacing: 12) {
                            FileThumb(url: e.url, name: e.name)
                            VStack(alignment: .leading) {
                                Text(e.name).lineLimit(1).foregroundStyle(.primary)
                                Text("\(FileUtils.formatSize(e.size)) • \(e.peer)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Tools

struct ToolsView: View {
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var selection: SelectionStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !store.isPremium {
                    PremiumBanner {
                        AnalyticsService.click("premium_banner", screen: "tools")
                        router.paywall(source: "tools")
                    }
                }
                section("Transfer", [
                    ToolItem(icon: "arrow.up", title: "Send", color: Brand.catApps) {
                        AnalyticsService.click("tool_send", screen: "tools")
                        selection.clear(); router.push(.send)
                    },
                    ToolItem(icon: "arrow.down", title: "Receive", color: Brand.catPhoto) {
                        AnalyticsService.click("tool_receive", screen: "tools")
                        router.push(.receive(group: false))
                    },
                    ToolItem(icon: "person.3.fill", title: "Group share", color: Brand.catVideo) { AnalyticsService.click("tool_group_share", screen: "tools"); router.push(.group) },
                    ToolItem(icon: "desktopcomputer", title: "Connect PC", color: Brand.catApps) { AnalyticsService.click("tool_connect_pc", screen: "tools"); router.push(.pc) },
                    ToolItem(icon: "clock.arrow.circlepath", title: "History", color: Brand.catDocs) { AnalyticsService.click("tool_history", screen: "tools"); router.push(.history) }
                ])
                section("Media", [
                    ToolItem(icon: "music.note", title: "Music", color: Brand.catPink) { AnalyticsService.click("tool_music", screen: "tools"); router.tab = .player },
                    ToolItem(icon: "film.fill", title: "Videos", color: Brand.catVideo) { AnalyticsService.click("tool_videos", screen: "tools"); router.push(.category(.videos)) },
                    ToolItem(icon: "arrow.triangle.2.circlepath", title: "Converter", color: Brand.catDocs) { AnalyticsService.click("tool_converter", screen: "tools"); router.push(.converter) }
                ])
                section("Files", [
                    ToolItem(icon: "folder.fill", title: "Browse", color: Brand.catCyan) { AnalyticsService.click("tool_browse", screen: "tools"); router.push(.browser(AppFiles.documents)) },
                    ToolItem(icon: "sparkles", title: "Clean", color: Brand.catPdf) { AnalyticsService.click("tool_clean", screen: "tools"); router.push(.clean) },
                    ToolItem(icon: "lock.fill", title: "Safebox", color: Brand.catSafe) { AnalyticsService.click("tool_safebox", screen: "tools"); router.push(.safebox) },
                    ToolItem(icon: "externaldrive.fill", title: "Large files", color: Brand.catDownload) { AnalyticsService.click("tool_large_files", screen: "tools"); router.push(.largeFiles) }
                ])
                AdBanner()
            }
            .padding()
        }
        .background(Brand.background)
        .navigationTitle(Text("Tools"))
    }

    private func section(_ title: LocalizedStringKey, _ items: [ToolItem]) -> some View {
        SectionCard {
            Text(title).font(.headline).padding(.bottom, 6)
            TileGrid(items: items)
        }
    }
}

// MARK: - Me

struct MeView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var store: StoreService
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var auth: AuthService
    @State private var editing = false
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Button {
                        AnalyticsService.click("change_avatar", screen: "me")
                        prefs.avatar = (prefs.avatar + 1) % Prefs.avatars.count
                    } label: {
                        AvatarBubble(index: prefs.avatar, size: 72, ring: true)
                    }
                    .accessibilityLabel(Text("Change avatar"))
                    VStack(alignment: .leading) {
                        Text(prefs.deviceName).font(.title3.bold()).foregroundStyle(Brand.navy).lineLimit(1)
                        (store.isPremium ? Text("⭐ Premium") : Text("Free")).font(.caption).foregroundStyle(Brand.navy.opacity(0.8))
                        if let a = auth.account {
                            Text(a.email ?? a.name ?? "").font(.caption).foregroundStyle(Brand.navy.opacity(0.8))
                        }
                    }
                    Spacer()
                    Button {
                        AnalyticsService.click("edit_name", screen: "me")
                        name = prefs.deviceName; editing = true
                    } label: { Image(systemName: "pencil").foregroundStyle(Brand.navy).padding(8) }
                        .accessibilityLabel(Text("Edit name"))
                }
                .padding(24)
                .padding(.top, 40)
                .background(Brand.gradient)

                VStack(spacing: 16) {
                    if !store.isPremium {
                        PremiumBanner {
                            AnalyticsService.click("premium", screen: "me")
                            router.paywall(source: "me")
                        }
                    }
                    SectionCard {
                        HStack {
                            stat("Sent", FileUtils.formatSize(history.sentBytes), history.sentCount)
                            stat("Received", FileUtils.formatSize(history.receivedBytes), history.receivedCount)
                        }
                    }
                    SectionCard(padding: 4) {
                        row("crown.fill", "Share you Premium", store.isPremium ? store.statusLabel : nil) {
                            AnalyticsService.click("premium", screen: "me"); router.paywall(source: "me")
                        }
                        Divider()
                        row("person.crop.circle", auth.account == nil ? "Sign in" : "Account", nil) {
                            AnalyticsService.click("account", screen: "me"); router.push(.account)
                        }
                        Divider()
                        row("clock.arrow.circlepath", "Transfer history", nil) {
                            AnalyticsService.click("transfer_history", screen: "me"); router.push(.history)
                        }
                        Divider()
                        row("lock.fill", "Safebox", nil) { AnalyticsService.click("safebox", screen: "me"); router.push(.safebox) }
                        Divider()
                        row("gearshape.fill", "Settings", nil) { AnalyticsService.click("settings", screen: "me"); router.push(.settings) }
                        Divider()
                        row("info.circle.fill", "About", "\(AppConfig.appName) \(AppConfig.version)") {
                            AnalyticsService.click("about", screen: "me"); router.push(.about)
                        }
                    }
                }
                .padding()
            }
        }
        .background(Brand.background)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .alert(Text("Device name"), isPresented: $editing) {
            TextField("Device name", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { prefs.deviceName = String(trimmed.prefix(24)) }
                Task { await FirestoreService.shared.upsertProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Other phones see this name when you share.")
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String, _ count: Int) -> some View {
        VStack {
            Text(value).font(.title3.bold()).foregroundStyle(Brand.cyanInk)
            Text(label).font(.subheadline)
            Text("\(count) files").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ icon: String, _ title: LocalizedStringKey, _ subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Brand.cyan3).frame(width: 28)
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var ads: AdsManager
    @State private var preview: URL?
    @State private var filter = 0
    @State private var looked = false

    var body: some View {
        List {
            Picker("", selection: $filter) {
                Text("All").tag(0)
                Text("Sent").tag(1)
                Text("Received").tag(2)
            }
            .pickerStyle(.segmented)
            .onChange(of: filter) { value in
                let name = value == 1 ? "sent" : value == 2 ? "received" : "all"
                AnalyticsService.click("filter", screen: "history", ["value": name])
            }
            let list = history.entries.filter { filter == 0 || (filter == 1 ? $0.sent : !$0.sent) }
            if list.isEmpty { EmptyStateView(icon: "clock", title: "No transfers yet") }
            ForEach(list) { e in
                HStack(spacing: 12) {
                    FileThumb(url: e.url, name: e.name)
                    VStack(alignment: .leading) {
                        Text(e.name).lineLimit(1)
                        Text("\(FileUtils.formatSize(e.size)) • \(e.peer) • \(e.time.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: e.sent ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(e.sent ? Brand.catApps : Brand.catPhoto)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    AnalyticsService.click("open_entry", screen: "history")
                    if let u = e.url { preview = u; looked = true }
                }
            }
        }
        .navigationTitle(Text("Transfer history"))
        .fullScreenCover(item: $preview) { url in QuickLookView(urls: [url]).ignoresSafeArea() }
        .onDisappear { if looked { ads.tryShow(.historyExit) } }
    }
}
