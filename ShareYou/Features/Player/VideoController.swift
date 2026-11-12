import SwiftUI
import AVKit
import Photos

/// Video playback state, shared with the ads rules (no full-screen ad while a video plays).
@MainActor
final class VideoController: NSObject, ObservableObject {
    static let shared = VideoController()

    @Published private(set) var isPlaying = false
    @Published var presented: VideoSource?

    let player = AVPlayer()
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
        MusicController.shared.pause()
        presented = source
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
    let source: VideoController.VideoSource
    @EnvironmentObject private var video: VideoController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlayerControllerView(player: video.player, allowPiP: DayUnlock.player())
            .ignoresSafeArea()
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(Text("Close"))
                .padding()
            }
            .task {
                OrientationLock.allowLandscape(true)
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
