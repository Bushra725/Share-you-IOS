import SwiftUI
import AVKit
import Photos

/// Video playback state, shared with the ads rules (no full-screen ad while a video plays).
@MainActor
final class VideoController: NSObject, ObservableObject {
    static let shared = VideoController()

    @Published private(set) var isPlaying = false
    @Published var presented: VideoSource?
    @Published private(set) var current: VideoSource?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    let player = AVPlayer()
    private var queue: [VideoSource] = []
    private var index = 0
    private var rateObserver: NSKeyValueObservation?

    enum VideoSource: Identifiable, Equatable {
        case file(URL)
        case asset(String) // PHAsset local identifier
        var id: String {
            switch self {
            case .file(let u): return u.absoluteString
            case .asset(let id): return id
            }
        }
    }

    private override init() {
        super.init()
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func open(_ source: VideoSource) {
        openQueue([source], startAt: 0)
    }

    func openQueue(_ items: [VideoSource], startAt: Int) {
        guard items.indices.contains(startAt) else { return }
        MusicController.shared.pause()
        queue = items
        index = startAt
        current = items[startAt]
        refreshStepFlags()
        if presented == nil { presented = items[startAt] }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        let nextIndex = index + delta
        guard queue.indices.contains(nextIndex) else { return }
        index = nextIndex
        current = queue[nextIndex]
        refreshStepFlags()
    }

    private func refreshStepFlags() {
        canGoBack = index > 0
        canGoForward = index + 1 < queue.count
    }

    func load(_ source: VideoSource) async {
        switch source {
        case .file(let url):
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        case .asset(let id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            let item: AVPlayerItem? = await withCheckedContinuation { c in
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in c.resume(returning: item) }
            }
            player.replaceCurrentItem(with: item)
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        current = nil
        canGoBack = false
        canGoForward = false
        presented = nil
    }

    /// Without the Background/PiP unlock, video pauses when the app leaves the screen (Android behaviour).
    func appEnteredBackground() {
        if !DayUnlock.player() { player.pause() }
    }

    func closed() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        OrientationLock.allowLandscape(false)
        AdsManager.shared.tryShow(.videoExit)
    }
}

/// Full-screen system player: speed menu (0.5×–2×), AirPlay, scrubbing, Picture in Picture (when unlocked).
struct VideoPlayerScreen: View {
    @EnvironmentObject private var video: VideoController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlayerControllerView(player: video.player, allowPiP: DayUnlock.player())
            .ignoresSafeArea()
            .background(Color.black)
            .overlay(alignment: .top) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(Text("Close"))
                    Spacer(minLength: 8)
                    Button { video.previous() } label: {
                        Image(systemName: "backward.fill").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(!video.canGoBack)
                    .accessibilityLabel(Text("Previous"))
                    Button { video.next() } label: {
                        Image(systemName: "forward.fill").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(!video.canGoForward)
                    .accessibilityLabel(Text("Next"))
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .task {
                OrientationLock.allowLandscape(true)
            }
            .task(id: video.current?.id) {
                guard let source = video.current else { return }
                await video.load(source)
            }
            .onDisappear { video.closed() }
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowPiP: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = allowPiP
        vc.canStartPictureInPictureAutomaticallyFromInline = allowPiP
        vc.speeds = [AVPlaybackSpeed(rate: 0.5, localizedName: "0.5×"),
                     AVPlaybackSpeed(rate: 0.75, localizedName: "0.75×"),
                     AVPlaybackSpeed(rate: 1.0, localizedName: "1×"),
                     AVPlaybackSpeed(rate: 1.25, localizedName: "1.25×"),
                     AVPlaybackSpeed(rate: 1.5, localizedName: "1.5×"),
                     AVPlaybackSpeed(rate: 2.0, localizedName: "2×")]
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.allowsPictureInPicturePlayback = allowPiP
    }
}
