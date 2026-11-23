import Foundation
import AVFoundation
import MediaPlayer
import UIKit

struct Track: Identifiable, Hashable {
    let url: URL
    let title: String
    let artist: String
    let duration: Double
    var id: URL { url }
}

/// Background music player (AVPlayer + lock-screen / Control Center controls), like Android's PlaybackService.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    enum RepeatMode { case off, all, one }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var visible: Bool { current != nil }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var commandsReady = false

    private init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.position = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.trackEnded()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.isPlaying = false; self?.updateNowPlaying() }
        }
    }

    func play(_ tracks: [Track], startAt: Int) {
        guard tracks.indices.contains(startAt) else { return }
        VideoController.shared.stop()
        queue = tracks
        index = startAt
        AnalyticsService.log(.musicPlay, ["queue_size": tracks.count])
        load()
        resume()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        activateSession()
        setupRemoteCommands()
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffle && queue.count > 1 {
            var n = index
            while n == index { n = Int.random(in: 0..<queue.count) }
            index = n
        } else {
            index = (index + 1) % queue.count
        }
        load()
        resume()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if position > 3 { seek(to: 0); return }
        index = (index - 1 + queue.count) % queue.count
        load()
        resume()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        position = seconds
        updateNowPlaying()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Stop & close player (the ✕ on the mini player).
    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        isPlaying = false
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AdsManager.shared.tryShow(.audioExit)
    }

    private func trackEnded() {
        switch repeatMode {
        case .one:
            seek(to: 0)
            player.play()
        case .all:
            next()
        case .off:
            if index < queue.count - 1 || shuffle { next() } else { pause(); seek(to: 0) }
        }
    }

    private func load() {
        guard let t = current else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: t.url))
        position = 0
        duration = t.duration
    }

    private func activateSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.e("Audio session failed", error)
        }
    }

    private func setupRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in Task { @MainActor in MusicController.shared.resume() }; return .success }
        c.pauseCommand.addTarget { _ in Task { @MainActor in MusicController.shared.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in MusicController.shared.toggle() }; return .success }
        c.nextTrackCommand.addTarget { _ in Task { @MainActor in MusicController.shared.next() }; return .success }
        c.previousTrackCommand.addTarget { _ in Task { @MainActor in MusicController.shared.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let pos = e.positionTime
            Task { @MainActor in MusicController.shared.seek(to: pos) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }
}

/// Finds playable music: audio files inside Share you + non-DRM songs from the Music library.
enum MusicLibrary {
    static func appTracks() async -> [Track] {
        let files = await FileScanner.allFiles().filter { $0.category == .music }
        var out: [Track] = []
        for f in files { out.append(await track(for: f.url)) }
        return out
    }

    static func track(for url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = String(localized: "Unknown artist")
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                if item.commonKey == .commonKeyTitle, let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                if item.commonKey == .commonKeyArtist, let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
            }
        }
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        return Track(url: url, title: title, artist: artist, duration: seconds.isFinite ? seconds : 0)
    }

    /// Songs synced to the iPhone's Music library (not Apple Music downloads, which are DRM-protected).
    static func libraryTracks() async -> [Track] {
        let status = await withCheckedContinuation { c in MPMediaLibrary.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { return [] }
        let songs = MPMediaQuery.songs().items ?? []
        return songs.compactMap { s in
            guard let url = s.assetURL, !s.hasProtectedAsset else { return nil }
            return Track(url: url, title: s.title ?? url.lastPathComponent, artist: s.artist ?? "", duration: s.playbackDuration)
        }
    }
}
