import SwiftUI
import Photos

struct PlayerTabView: View {
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Music").tag(0)
                Text("Videos").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            if tab == 0 { MusicListView() } else { VideoLibraryView() }
        }
        .navigationTitle(Text("Player"))
        .background(Brand.background)
        .trackScreen("player")
        .onChange(of: tab) { value in
            AnalyticsService.click(value == 0 ? "tab_music" : "tab_videos", screen: "player")
        }
    }
}

// MARK: - Music

struct MusicListView: View {
    @EnvironmentObject private var music: MusicController
    @State private var appTracks: [Track] = []
    @State private var libraryTracks: [Track] = []
    @State private var loading = true
    @State private var search = ""

    private var all: [Track] { appTracks + libraryTracks }
    private var filtered: [Track] {
        search.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if loading { ProgressView() }
            if !loading && all.isEmpty {
                EmptyStateView(icon: "music.note", title: "No music yet",
                               message: "Songs you receive, and songs synced to this iPhone's Music library, show up here.")
                    .listRowBackground(Color.clear)
            }
            if !filtered.isEmpty {
                Button {
                    AnalyticsService.click("shuffle_all", screen: "player")
                    music.shuffle = true
                    music.play(filtered, startAt: Int.random(in: 0..<filtered.count))
                } label: { Label("Shuffle all", systemImage: "shuffle") }
            }
            ForEach(Array(filtered.enumerated()), id: \.element.id) { i, t in
                Button {
                    AnalyticsService.click("play_song", screen: "player")
                    music.play(filtered, startAt: i)
                } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(Brand.catMusic.opacity(0.15)).frame(width: 44, height: 44)
                            .overlay(Image(systemName: music.current == t && music.isPlaying ? "waveform" : "music.note").foregroundStyle(Brand.catMusic))
                        VStack(alignment: .leading) {
                            Text(t.title).lineLimit(1).foregroundStyle(.primary)
                            Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(FileUtils.formatDuration(t.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { PlayerSearchBar(text: $search) }
        .onChange(of: search) { q in
            if q.count == 1 { AnalyticsService.click("search", screen: "player") }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        appTracks = await MusicLibrary.appTracks()
        libraryTracks = await MusicLibrary.libraryTracks()
        loading = false
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var music: MusicController
    @State private var showNowPlaying = false

    var body: some View {
        if let t = music.current {
            HStack(spacing: 12) {
                Image(systemName: "music.note").foregroundStyle(Brand.navy)
                    .frame(width: 36, height: 36).background(Brand.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 0) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    AnalyticsService.click("play_pause", screen: "mini_player", ["state": music.isPlaying ? "pause" : "play"])
                    music.toggle()
                } label: { Image(systemName: music.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                    .accessibilityLabel(music.isPlaying ? Text("Pause") : Text("Play"))
                Button {
                    AnalyticsService.click("next", screen: "mini_player")
                    music.next()
                } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel(Text("Next"))
                Button {
                    AnalyticsService.click("close_player", screen: "mini_player")
                    music.close()
                } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(Text("Stop & close player"))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                AnalyticsService.click("open_now_playing", screen: "mini_player")
                showNowPlaying = true
            }
            .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var music: MusicController
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
            Text("Now playing").font(.subheadline).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 28).fill(Brand.gradient)
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "music.note").font(.system(size: 96)).foregroundStyle(Brand.navy))
                .padding(.horizontal, 32)
            VStack(spacing: 4) {
                Text(music.current?.title ?? "").font(.title3.bold()).lineLimit(2).multilineTextAlignment(.center)
                Text(music.current?.artist ?? "").foregroundStyle(.secondary)
            }
            VStack {
                Slider(value: Binding(get: { scrubbing ?? music.position }, set: { scrubbing = $0 }),
                       in: 0...max(music.duration, 1)) { editing in
                    if !editing, let s = scrubbing {
                        AnalyticsService.click("seek", screen: "now_playing")
                        music.seek(to: s); scrubbing = nil
                    }
                }
                .tint(Brand.cyan3)
                HStack {
                    Text(FileUtils.formatDuration(scrubbing ?? music.position))
                    Spacer()
                    Text(FileUtils.formatDuration(music.duration))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            HStack(spacing: 0) {
                Button {
                    AnalyticsService.click("shuffle", screen: "now_playing")
                    music.shuffle.toggle()
                } label: { Image(systemName: "shuffle").foregroundStyle(music.shuffle ? Brand.cyan3 : .secondary) }
                    .accessibilityLabel(Text("Shuffle"))
                    .frame(maxWidth: .infinity)
                Button {
                    AnalyticsService.click("previous", screen: "now_playing")
                    music.previous()
                } label: { Image(systemName: "backward.fill").font(.title2) }
                    .accessibilityLabel(Text("Previous"))
                    .frame(maxWidth: .infinity)
                Button {
                    AnalyticsService.click("play_pause", screen: "now_playing")
                    music.toggle()
                } label: {
                    Image(systemName: music.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56))
                }
                .accessibilityLabel(music.isPlaying ? Text("Pause") : Text("Play"))
                .frame(maxWidth: .infinity)
                Button {
                    AnalyticsService.click("next", screen: "now_playing")
                    music.next()
                } label: { Image(systemName: "forward.fill").font(.title2) }
                    .accessibilityLabel(Text("Next"))
                    .frame(maxWidth: .infinity)
                Button {
                    AnalyticsService.click("repeat", screen: "now_playing")
                    music.cycleRepeat()
                } label: {
                    Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(music.repeatMode == .off ? .secondary : Brand.cyan3)
                }
                .accessibilityLabel(Text("Repeat"))
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            Button(role: .destructive) {
                AnalyticsService.click("stop_close_player", screen: "now_playing")
                music.close(); dismiss()
            } label: { Label("Stop & close player", systemImage: "xmark.circle") }
            Spacer()
        }
        .padding()
        .presentationDragIndicator(.hidden)
        .trackScreen("now_playing")
    }
}

// MARK: - Videos

struct VideoLibraryView: View {
    @EnvironmentObject private var video: VideoController
    @EnvironmentObject private var store: StoreService
    @State private var assets: [PHAsset] = []
    @State private var files: [LocalFile] = []
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var showUnlock = false
    @State private var tick = 0
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pipCard
                if !filteredFiles.isEmpty {
                    Text("Share you files").font(.headline).padding(.horizontal)
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(filteredFiles) { f in
                            Button {
                                AnalyticsService.click("play_video", screen: "player", ["source": "files"])
                                let queue = filteredFiles.map { VideoController.VideoSource.file($0.url) }
                                video.openQueue(queue, startAt: queue.firstIndex(of: .file(f.url)) ?? 0)
                            } label: {
                                FileThumb(url: f.url, name: f.name, size: 110)
                                    .overlay(alignment: .bottomLeading) { Text(f.name).font(.caption2).lineLimit(1).padding(4).background(.ultraThinMaterial) }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                Text("On this iPhone").font(.headline).padding(.horizontal)
                switch status {
                case .authorized, .limited:
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(assets, id: \.localIdentifier) { a in
                            Button {
                                AnalyticsService.click("play_video", screen: "player", ["source": "photos"])
                                let queue = assets.map { VideoController.VideoSource.asset($0.localIdentifier) }
                                video.openQueue(queue, startAt: queue.firstIndex(of: .asset(a.localIdentifier)) ?? 0)
                            } label: { AssetThumb(asset: a, side: 110, showDuration: true) }
                        }
                    }
                    .padding(.horizontal, 4)
                case .notDetermined:
                    Button("Show videos from Photos") {
                        AnalyticsService.click("allow_photos", screen: "player")
                        Task {
                            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                            loadAssets()
                        }
                    }
                    .buttonStyle(.borderedProminent).padding(.horizontal)
                default:
                    VStack(alignment: .leading) {
                        Text("Photos access is off. Allow it in Settings to play videos from your library.").foregroundStyle(.secondary)
                        Button("Open Settings") { UIHelpers.openSettings() }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0) { PlayerSearchBar(text: $search) }
        .onChange(of: search) { q in
            if q.count == 1 { AnalyticsService.click("search", screen: "player") }
        }
        .task {
            files = await FileScanner.allFiles().filter { $0.category == .videos }
            loadAssets()
        }
        .sheet(isPresented: $showUnlock) {
            UnlockSheet(title: "Background play & Picture in Picture",
                        message: "Keep videos playing in a floating window while you use other apps.",
                        icon: "pip.fill",
                        perks: ["Picture in Picture", "Lasts until midnight"]) {
                DayUnlock.grantPlayer()
                AnalyticsService.log(.featureUnlock, ["feature": "player_pip"])
                tick += 1
            }
        }
    }

    private var pipCard: some View {
        let unlocked = DayUnlock.player()
        return HStack {
            Image(systemName: "pip.fill").foregroundStyle(Brand.cyan3)
            Text("Picture in Picture").font(.subheadline)
            Spacer()
            UnlockPill(state: store.isPremium ? .premium : (unlocked ? .unlockedToday : .locked))
        }
        .padding(12)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .onTapGesture {
            if !unlocked {
                AnalyticsService.click("unlock_pip", screen: "player")
                showUnlock = true
            }
        }
        .id(tick)
    }

    private var filteredFiles: [LocalFile] {
        search.isEmpty ? files : files.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func loadAssets() {
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 600
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var list: [PHAsset] = []
        result.enumerateObjects { a, _, _ in list.append(a) }
        assets = list
    }
}

struct PlayerSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(10)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Thumbnail for a Photos asset.
struct AssetThumb: View {
    let asset: PHAsset
    var side: CGFloat = 100
    var showDuration = false
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color.gray.opacity(0.2))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            if showDuration && asset.mediaType == .video {
                Text(FileUtils.formatDuration(asset.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    .padding(3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)).padding(4)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityLabel(Text(asset.mediaType == .video ? "Video" : "Photo"))
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            let size = CGSize(width: side * 2, height: side * 2)
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, _ in
                if let img { Task { @MainActor in image = img } }
            }
        }
    }
}
