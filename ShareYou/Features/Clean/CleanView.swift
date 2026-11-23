import SwiftUI
import Photos

struct CleanView: View {
    @StateObject private var cleaner = PhotoCleaner()
    @EnvironmentObject private var ads: AdsManager
    @EnvironmentObject private var store: StoreService
    @State private var section = 0
    @State private var showUnlock = false
    @State private var pendingSelect: (() -> Void)?
    @State private var confirm = false
    @State private var tick = 0
    private let storage = AppFiles.storage()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Storage used").font(.headline)
                    let frac = storage.total > 0 ? Double(storage.used) / Double(storage.total) : 0
                    ProgressView(value: frac).tint(frac > 0.85 ? .red : Brand.cyan3)
                    Text("\(FileUtils.formatSize(storage.used)) used of \(FileUtils.formatSize(storage.total))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Label("Clean junk", systemImage: "trash.slash")
                    Spacer()
                    Text(FileUtils.formatSize(cleaner.junkBytes)).foregroundStyle(.secondary)
                    Button("Clean") {
                        AnalyticsService.click("clean_junk", screen: "clean")
                        cleaner.cleanJunk(); ads.tryShow(.scanCleaned)
                    }
                        .buttonStyle(.bordered).disabled(cleaner.junkBytes == 0)
                }
            } footer: {
                Text("Junk is Share you's own cache and temporary files. iOS doesn't let apps clean other apps.")
            }

            switch cleaner.status {
            case .authorized, .limited:
                photosSection
            case .notDetermined:
                Section {
                    Button("Allow access") {
                        AnalyticsService.click("allow_photos", screen: "clean")
                        Task { await cleaner.requestAccess(); await cleaner.scan() }
                    }
                } footer: { Text("Find duplicate and similar photos, screenshots and large videos.") }
            default:
                Section {
                    Text("Photos access is off.")
                    Button("Open Settings") { UIHelpers.openSettings() }
                }
            }
        }
        .navigationTitle(Text("Clean"))
        .task {
            await cleaner.refreshJunk()
            if cleaner.status == .authorized || cleaner.status == .limited, !cleaner.scanned { await cleaner.scan() }
        }
        .onDisappear { ads.tryShow(.cleanExit) }
        .safeAreaInset(edge: .bottom) {
            if !cleaner.selected.isEmpty {
                Button(role: .destructive) { confirm = true } label: {
                    Text("Delete \(cleaner.selected.count) item(s) • \(FileUtils.formatSize(cleaner.selectedBytes))").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).padding().background(.bar)
            }
        }
        .confirmationDialog(Text("Delete \(cleaner.selected.count) item(s)?"), isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                AnalyticsService.click("delete_confirm", screen: "clean", [
                    "count": cleaner.selected.count,
                    "bytes": AnalyticsService.bytes(cleaner.selectedBytes)
                ])
                Task {
                    if await cleaner.deleteSelected() { ads.tryShow(.scanCleaned) }
                }
            }
        } message: {
            Text("They move to Recently Deleted in Photos for 30 days.")
        }
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(title: "Select all & Smart select",
                        message: "Pick every duplicate in one tap. Watch one short video to unlock it until midnight.",
                        icon: "wand.and.stars", perks: ["Smart select keeps the best photo", "Select all in one tap", "Lasts until midnight"]) {
                DayUnlock.grantCleanSelect()
                AnalyticsService.log(.featureUnlock, ["feature": "clean_select"])
                tick += 1
                pendingSelect?()
                pendingSelect = nil
            }
        }
    }

    @ViewBuilder private var photosSection: some View {
        Section {
            Picker("", selection: $section) {
                Text("Duplicates (\(cleaner.duplicates.count))").tag(0)
                Text("Similar (\(cleaner.similar.count))").tag(1)
                Text("Screenshots (\(cleaner.screenshots.count))").tag(2)
                Text("Large videos (\(cleaner.largeVideos.count))").tag(3)
            }
            .pickerStyle(.menu)
            .onChange(of: section) { value in
                let name = ["duplicates", "similar", "screenshots", "large_videos"][min(value, 3)]
                AnalyticsService.click("section", screen: "clean", ["section": name])
            }
            if cleaner.scanning {
                ProgressView(value: cleaner.progress) { Text("Scanning photos…") }
            } else {
                HStack {
                    if section <= 1 {
                        Button("Smart select") {
                            AnalyticsService.click("smart_select", screen: "clean")
                            gated { cleaner.smartSelect() }
                        }
                    }
                    Spacer()
                    Button("Select all") {
                        AnalyticsService.click("select_all", screen: "clean")
                        gated { cleaner.selectAll(currentAssets) }
                    }
                    UnlockPill(state: store.isPremium ? .premium : (DayUnlock.cleanSelect() ? .unlockedToday : .locked))
                }
                .buttonStyle(.borderless)
                .id(tick)
            }
        }
        Section {
            switch section {
            case 0, 1:
                let groups = section == 0 ? cleaner.duplicates : cleaner.similar
                if groups.isEmpty && !cleaner.scanning { EmptyStateView(icon: "checkmark.seal", title: "Nothing to clean") }
                ForEach(groups) { g in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(g.assets.enumerated()), id: \.element.localIdentifier) { idx, a in
                                selectableThumb(a, badge: idx == 0 ? String(localized: "KEEP") : nil)
                            }
                        }
                    }
                }
            case 2:
                grid(cleaner.screenshots)
            default:
                if cleaner.largeVideos.isEmpty && !cleaner.scanning { EmptyStateView(icon: "checkmark.seal", title: "No videos over 100 MB") }
                ForEach(cleaner.largeVideos) { item in
                    HStack {
                        selectableThumb(item.asset, badge: nil)
                        VStack(alignment: .leading) {
                            Text(FileUtils.formatSize(item.size)).font(.headline)
                            Text(FileUtils.formatDuration(item.asset.duration)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var currentAssets: [PHAsset] {
        switch section {
        case 0: return cleaner.duplicates.flatMap(\.assets)
        case 1: return cleaner.similar.flatMap(\.assets)
        case 2: return cleaner.screenshots
        default: return cleaner.largeVideos.map(\.asset)
        }
    }

    private func gated(_ action: @escaping () -> Void) {
        if DayUnlock.cleanSelect() { action() } else {
            AnalyticsService.click("unlock_clean", screen: "clean")
            pendingSelect = action
            showUnlock = true
        }
    }

    private func grid(_ assets: [PHAsset]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
            ForEach(assets, id: \.localIdentifier) { selectableThumb($0, badge: nil) }
        }
    }

    private func selectableThumb(_ a: PHAsset, badge: String?) -> some View {
        let on = cleaner.selected.contains(a.localIdentifier)
        return AssetThumb(asset: a, side: 96, showDuration: true)
            .overlay(alignment: .topTrailing) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Brand.cyan3 : .white).font(.title3).padding(4).shadow(radius: 2)
            }
            .overlay(alignment: .bottomLeading) {
                if let badge {
                    Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.green, in: Capsule()).foregroundStyle(.white).padding(4)
                }
            }
            .onTapGesture { cleaner.toggle(a) }
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}
