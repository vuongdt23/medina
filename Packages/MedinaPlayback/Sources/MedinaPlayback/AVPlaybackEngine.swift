import AVFoundation
import AVKit
import Foundation
import Observation

public enum AVPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

/// Native AVPlayer-backed playback for macOS-supported media. URLs stream
/// directly from Medina; the app does not download or transcode lesson media.
@MainActor
@Observable
public final class AVPlaybackEngine {
    public let player: AVPlayer
    public private(set) var state: AVPlaybackState = .idle
    public private(set) var title = ""
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var playbackSpeed: Float = 1
    public private(set) var audioOptions: [String] = []
    public private(set) var subtitleOptions: [String] = []
    public private(set) var selectedAudioIndex: Int?
    public private(set) var selectedSubtitleIndex: Int?
    public var onNaturalEnd: (() -> Void)?

    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var subtitleGroup: AVMediaSelectionGroup?

    public init(player: AVPlayer = AVPlayer()) {
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.updateTime(time) }
        }
    }

    public func load(url: URL, title: String) {
        stop()
        self.title = title
        currentTime = 0
        duration = 0
        state = .loading
        audioOptions = []
        subtitleOptions = []
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil

        let item = AVPlayerItem(url: url)
        currentItem = item
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.state = .ready
                    let value = CMTimeGetSeconds(item.duration)
                    self.duration = value.isFinite ? value : 0
                    self.loadMediaOptions(for: item)
                case .failed:
                    self.state = .failed(item.error?.localizedDescription ?? "The media could not be played.")
                case .unknown:
                    self.state = .loading
                @unknown default:
                    self.state = .failed("The media player reported an unknown state.")
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItem === item else { return }
                self.state = .ended
                self.onNaturalEnd?()
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        state = .loading
    }

    public func play() {
        player.play()
        if currentItem != nil { state = .playing }
    }

    public func pause() {
        player.pause()
        if currentItem != nil { state = .paused }
    }

    public func togglePlayback() {
        player.rate == 0 ? play() : pause()
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func setSpeed(_ speed: Float) {
        guard speed.isFinite else { return }
        let bounded = min(2.5, max(0.5, speed))
        playbackSpeed = bounded
        player.defaultRate = bounded
        if player.rate != 0 { player.rate = bounded }
    }

    public func replay() {
        guard let item = currentItem else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self, self.currentItem === item else { return }
                self.play()
            }
        }
    }

    public func setVolume(_ volume: Float) {
        player.volume = min(1, max(0, volume))
    }

    public func selectAudioTrack(_ index: Int?) {
        guard let item = currentItem, let audioGroup else { return }
        let option = index.flatMap { audioGroup.options.indices.contains($0) ? audioGroup.options[$0] : nil }
        item.select(option, in: audioGroup)
        selectedAudioIndex = index
    }

    public func selectSubtitleTrack(_ index: Int?) {
        guard let item = currentItem, let subtitleGroup else { return }
        let option = index.flatMap { subtitleGroup.options.indices.contains($0) ? subtitleGroup.options[$0] : nil }
        item.select(option, in: subtitleGroup)
        selectedSubtitleIndex = index
    }

    public func stop() {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemStatusObservation = nil
        currentItem = nil
        audioGroup = nil
        subtitleGroup = nil
        player.replaceCurrentItem(with: nil)
        if state != .idle { state = .idle }
    }

    public func shutdown() {
        stop()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func updateTime(_ time: CMTime) {
        let value = CMTimeGetSeconds(time)
        if value.isFinite { currentTime = value }
        if let item = currentItem {
            let length = CMTimeGetSeconds(item.duration)
            if length.isFinite { duration = length }
            if player.rate > 0 && (state == .ready || state == .paused || state == .ended) { state = .playing }
            else if player.rate == 0 && state == .playing { state = .paused }
            if player.rate > 0 && playbackSpeed != player.rate { playbackSpeed = player.rate }
        }
    }

    private func loadMediaOptions(for item: AVPlayerItem) {
        Task {
            do {
                audioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
                audioOptions = audioGroup?.options.map(\.displayName) ?? []
                selectedAudioIndex = audioGroup?.options.firstIndex {
                    item.currentMediaSelection.selectedMediaOption(in: audioGroup!) == $0
                }
            } catch { audioOptions = [] }
            do {
                subtitleGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
                subtitleOptions = subtitleGroup?.options.map(\.displayName) ?? []
                selectedSubtitleIndex = subtitleGroup?.options.firstIndex {
                    item.currentMediaSelection.selectedMediaOption(in: subtitleGroup!) == $0
                }
            } catch { subtitleOptions = [] }
        }
    }
}
