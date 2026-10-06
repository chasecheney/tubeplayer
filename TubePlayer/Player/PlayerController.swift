import Foundation
import Observation
import UIKit
import VLCKit

/// What to play: a streamed page or a downloaded file, each with an optional separate audio track.
struct PlaybackSource: Equatable {
    var videoURL: URL
    var audioURL: URL?
    var headers: [String: String] = [:]
    var startPosition: Double = 0

    init?(media: ExtractedMedia) {
        guard let v = media.video?.url.flatMap(URL.init(string:)) else { return nil }
        videoURL = v
        audioURL = media.audio?.url.flatMap(URL.init(string:))
        headers = media.video?.httpHeaders ?? [:]
    }

    init?(video: Video) {
        guard let v = video.videoURL else { return nil }
        videoURL = v
        audioURL = video.audioURL
        startPosition = video.lastPosition
    }
}

/// A thin, version-tolerant wrapper around VLCMediaPlayer.
@MainActor
@Observable
final class PlayerController {
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var loops = false

    @ObservationIgnored let player = VLCMediaPlayer()
    @ObservationIgnored let drawable = UIView()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var source: PlaybackSource?
    @ObservationIgnored private var didSeekToStart = false
    @ObservationIgnored private var userPaused = false

    init() {
        drawable.backgroundColor = .black
        player.drawable = drawable
    }

    func load(_ source: PlaybackSource, autoplay: Bool = true) {
        guard source != self.source else {
            if autoplay { play() }
            return
        }
        self.source = source
        didSeekToStart = source.startPosition < 3
        isBuffering = true
        currentTime = 0
        duration = 0

        let media: VLCMedia? = VLCMedia(url: source.videoURL)
        guard let media else { return }
        if let agent = source.headers["User-Agent"] {
            media.addOption(":http-user-agent=\(agent)")
        }
        if let referer = source.headers["Referer"] {
            media.addOption(":http-referrer=\(referer)")
        }
        media.addOption(":network-caching=1500")
        if loops {
            media.addOption(":input-repeat=65535")
        }
        player.media = media
        if let audio = source.audioURL {
            _ = player.addPlaybackSlave(audio, type: .audio, enforce: true)
        }
        startTimer()
        if autoplay { play() }
    }

    func play() {
        userPaused = false
        player.play()
    }

    func pause() {
        userPaused = true
        player.pause()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player.stop()
        isPlaying = false
        source = nil
    }

    /// Seeks to a fraction (0...1) of the duration.
    func seek(toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        player.position = type(of: player.position).init(clamped)
        currentTime = clamped * duration
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        seek(toFraction: seconds / duration)
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let playing = player.isPlaying
        let time = Double(player.time.intValue) / 1000
        let length = Double(player.media?.length.intValue ?? 0) / 1000

        if length > 0 { duration = length }
        isBuffering = !playing && !userPaused && time == currentTime
        if playing && !isPlaying { isBuffering = false }
        isPlaying = playing
        currentTime = max(time, 0)

        if !didSeekToStart, playing, duration > 0, let start = source?.startPosition {
            didSeekToStart = true
            if start < duration - 5 { seek(to: start) }
        }
    }
}
