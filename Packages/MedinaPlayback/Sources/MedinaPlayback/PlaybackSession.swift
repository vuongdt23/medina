import Foundation
import Observation
import SwiftUI
import SwiftVLC

public enum AVPlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

public struct PlaybackSubtitle: Sendable, Hashable {
    public let url: URL
    public let filename: String
    public init(url: URL, filename: String) {
        let component = filename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        self.url = url
        self.filename = component.isEmpty || component == "." || component == ".." ? "subtitle.srt" : component
    }
}

public struct PlaybackTrack: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let language: String?
    public init(id: String, title: String, language: String? = nil) {
        self.id = id; self.title = title; self.language = language
    }
}

/// SwiftVLC playback engine used by every Medina lesson.
@MainActor
@Observable
public final class VLCPlaybackEngine {
    /// When `MEDINA_VLC_VERBOSE` is set, every player is backed by a verbose
    /// libVLC instance so decoder/vout/demux errors surface through
    /// `onDiagnostic`. Default playback uses the shared quiet instance and
    /// pays none of libVLC's logging cost.
    static let verboseInstance: VLCInstance? =
        ProcessInfo.processInfo.environment["MEDINA_VLC_VERBOSE"] != nil
        ? (try? VLCInstance(arguments: VLCInstance.defaultArguments + ["--verbose=2"]))
        : nil

    public let player: Player = verboseInstance.map { Player(instance: $0) } ?? Player()
    @ObservationIgnored private var vlcLogTask: Task<Void, Never>?
    public private(set) var title = ""
    public private(set) var errorMessage: String?
    public private(set) var completed = false
    public private(set) var subtitleTracks: [Track] = []
    public private(set) var audioTracks: [Track] = []
    public private(set) var requestedResumeTime: Double = 0
    public var onNaturalEnd: (() -> Void)?
    public var onTracksChanged: (() -> Void)?
    public var onDiagnostic: ((Bool, String) -> Void)?

    @ObservationIgnored private var outcomeTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var subtitleDirectories: [URL] = []
    @ObservationIgnored private var activeGeneration: PlaybackGeneration?
    private var completedTime: Double?
    private var completedDuration: Double?

    public init() {
        if let instance = Self.verboseInstance {
            let stream = instance.logStream(minimumLevel: .debug)
            vlcLogTask = Task { [weak self] in
                for await entry in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.onDiagnostic?(false, "libVLC [\(entry.level)] [\(entry.module ?? "?")] \(entry.message)")
                }
            }
        }
    }

    public var state: AVPlaybackState {
        if completed { return .ended }
        if let errorMessage { return .failed(errorMessage) }
        switch player.state {
        case .idle: return .idle
        case .opening, .buffering: return .loading
        case .playing: return .playing
        case .paused: return .paused
        case .stopped, .stopping: return .ready
        case .error: return .failed(errorMessage ?? "VLC could not play this lesson.")
        }
    }

    public var currentTime: Double {
        if let completedTime { return completedTime }
        return durationSeconds(player.currentTime)
    }
    public var duration: Double {
        if completed { return completedDuration ?? 0 }
        guard let duration = player.duration else { return 0 }
        return durationSeconds(duration)
    }
    public var knownDuration: Double? {
        if completed { return completedDuration }
        guard let duration = player.duration else { return nil }
        return durationSeconds(duration)
    }
    public var playbackSpeed: Float { player.rate }
    public var isSeekable: Bool { player.isSeekable }
    public var volume: Float { player.volume }
    public var isMuted: Bool { player.isMuted }

    public func load(url: URL, title: String, subtitles: [PlaybackSubtitle], resumeAt: Double = 0) {
        cancelSessionTasks()
        activeGeneration = nil
        self.title = title
        errorMessage = nil
        completed = false
        completedTime = nil
        subtitleTracks = []
        audioTracks = []
        requestedResumeTime = max(0, resumeAt)

        // Subscribe before play so even an immediate terminal event is observed.
        let outcomes = player.terminalOutcomes
        let statuses = player.playbackStatus
        do {
            let media = try Media(url: url)
            // Our server streams ordinary HTTP files. A modest prebuffer keeps
            // libVLC from immediately starving when the initial connection is
            // slower than the media bitrate, while still allowing range seeks.
            // VLC refills this entire buffer after every seek, so an oversized
            // value turns each scrub/skip into a multi-second stall. 1500ms
            // gives a Tailscale/WAN link enough headroom against latency jitter
            // without punishing seeks.
            media.addOption(":network-caching=1500")
            for subtitle in subtitles {
                do { try media.addSlave(from: subtitle.url, type: .subtitle) }
                catch { /* A missing or unsupported sidecar must not block the lesson. */ }
            }
            try player.play(media)
            let generation = player.generation
            activeGeneration = generation
            outcomeTask = Task { [weak self] in
                for await outcome in outcomes {
                    guard let self, !Task.isCancelled else { return }
                    guard outcome.generation == self.activeGeneration else { continue }
                    switch outcome.cause {
                    case .naturalEnd:
                        guard Self.naturalEndTimelineIsConsistent(
                            time: outcome.finalTimeline.time,
                            duration: outcome.finalTimeline.duration
                        ) else {
                            self.onDiagnostic?(true, "Ignored inconsistent natural-end timeline \(outcome.finalTimeline.time) / \(String(describing: outcome.finalTimeline.duration)) at \(outcome.generation)")
                            continue
                        }
                        self.onDiagnostic?(false, "Natural end \(outcome.generation), timeline \(outcome.finalTimeline.time) / \(outcome.finalTimeline.duration.map { String(describing: $0) } ?? "unknown")")
                        self.completedTime = durationSeconds(outcome.finalTimeline.time)
                        self.completedDuration = outcome.finalTimeline.duration.map(durationSeconds)
                        self.completed = true
                        self.onNaturalEnd?()
                    case .failure:
                        self.onDiagnostic?(false, "VLC terminal failure \(outcome.generation): \(outcome.cause)")
                        self.errorMessage = "VLC reported a playback failure. Check the media source or try the native player."
                    case .requestedStop, .replacement, .cancellation, .unknownNativeStop:
                        self.onDiagnostic?(true, "Ignored VLC terminal outcome \(outcome.cause) for \(outcome.generation)")
                    }
                }
            }
            statusTask = Task { [weak self, player] in
                for await status in statuses {
                    guard let self, !Task.isCancelled else { return }
                    // VideoView can cause SwiftVLC to recast its native player
                    // once the AppKit drawable attaches. That preserves the
                    // same media but advances its generation; retain the new
                    // identity so terminal and seek events are not attributed
                    // to the retired, zero-length rendering session.
                    guard let active = self.activeGeneration, status.generation >= active else { continue }
                    if status.generation > active {
                        self.activeGeneration = status.generation
                        self.onDiagnostic?(true, "VLC adopted drawable playback session \(status.generation)")
                    }
                    player.refreshTracks()
                    self.audioTracks = player.audioTracks
                    self.subtitleTracks = player.subtitleTracks
                    self.onTracksChanged?()
                    if status.state == .error {
                        self.errorMessage = "VLC could not open this lesson. Check the connection or try the native player."
                    }
                }
            }
            let events = player.events(policy: .unbounded) { event in
                switch event {
                case .tracksChanged, .mediaChanged: true
                default: false
                }
            }
            eventTask = Task { [weak self, player] in
                for await _ in events {
                    guard let self, !Task.isCancelled else { return }
                    guard self.activeGeneration == generation else { continue }
                    player.refreshTracks()
                    self.audioTracks = player.audioTracks
                    self.subtitleTracks = player.subtitleTracks
                    self.onTracksChanged?()
                }
            }
            if !subtitles.isEmpty {
                subtitleFallbackTask = Task { [weak self] in
                    await self?.attachCachedSubtitleFallback(subtitles, generation: generation)
                }
            }
            if resumeAt > 0 { resumeTask = Task { [weak self] in await self?.resume(to: resumeAt, generation: generation) } }
        } catch {
            player.stop()
            errorMessage = error.localizedDescription
        }
    }

    static func naturalEndTimelineIsConsistent(time: Duration, duration: Duration?) -> Bool {
        let elapsed = durationSeconds(time)
        guard let duration else { return elapsed > 0.5 }
        let length = durationSeconds(duration)
        guard length > 0 else { return true }
        let tolerance = max(0.5, min(2.0, length * 0.02))
        return elapsed >= length - tolerance
    }

    private func attachCachedSubtitleFallback(_ subtitles: [PlaybackSubtitle], generation: PlaybackGeneration) async {
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, activeGeneration == generation, player.subtitleTracks.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MedinaSubtitles-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return }
        subtitleDirectories.append(directory)
        var cached: [(PlaybackSubtitle, URL)] = []
        for subtitle in subtitles {
            guard !Task.isCancelled, activeGeneration == generation else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: subtitle.url)
                guard !Task.isCancelled, activeGeneration == generation else { return }
                let destination = directory.appendingPathComponent(subtitle.filename)
                try data.write(to: destination, options: .atomic)
                cached.append((subtitle, destination))
            } catch { continue }
        }
        let pairedIndexes = Set(cached.filter { $0.0.filename.lowercased().hasSuffix(".idx") }
            .map { URL(fileURLWithPath: $0.0.filename).deletingPathExtension().lastPathComponent.lowercased() })
        for (subtitle, localURL) in cached {
            guard activeGeneration == generation else { return }
            let ext = URL(fileURLWithPath: subtitle.filename).pathExtension.lowercased()
            let stem = URL(fileURLWithPath: subtitle.filename).deletingPathExtension().lastPathComponent.lowercased()
            if ext == "sub", pairedIndexes.contains(stem) { continue }
            do { try player.addExternalTrack(from: localURL, type: .subtitle, select: false) }
            catch { continue }
        }
        guard activeGeneration == generation else { return }
        player.refreshTracks()
        subtitleTracks = player.subtitleTracks
    }

    private func resume(to seconds: Double, generation: PlaybackGeneration) async {
        for _ in 0..<200 {
            guard !Task.isCancelled, activeGeneration == generation else { return }
            if player.isSeekable {
                let target = duration > 0 ? min(seconds, duration) : seconds
                await seek(to: target, generation: generation)
                requestedResumeTime = 0
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func play() {
        completed = false
        completedTime = nil
        completedDuration = nil
        do {
            try player.play()
            activeGeneration = player.generation
        } catch { errorMessage = error.localizedDescription }
    }
    public func pause() { player.pause() }
    public func togglePlayback() {
        if player.isPlaybackRequestedActive { pause() } else { play() }
    }
    public func seek(to seconds: Double) {
        Task { await seek(to: seconds, generation: activeGeneration) }
    }
    private func seek(to seconds: Double, generation: PlaybackGeneration?) async {
        guard let generation, activeGeneration == generation, player.isSeekable, seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        do {
            // A fast (keyframe) seek lands near the target without decoding every
            // intermediate frame. Scrubbing to a rough position does not need
            // frame-exact precision, and a precise seek here stalls playback.
            let request = try player.requestSeek(to: .seconds(target), fast: true)
            _ = await request.outcome
            guard activeGeneration == generation else { return }
        } catch {
            errorMessage = "The seek could not be completed: \(error.localizedDescription)"
        }
    }
    public func skip(by offset: Double) {
        guard offset.isFinite else { return }
        Task { await skip(by: offset, generation: activeGeneration) }
    }
    private func skip(by offset: Double, generation: PlaybackGeneration?) async {
        guard let generation, activeGeneration == generation, player.isSeekable else { return }
        onDiagnostic?(true, "Relative seek \(offset)s from \(player.currentTime) at \(generation)")
        do {
            let request = try player.requestSeek(by: .seconds(offset), fast: true)
            let outcome = await request.outcome
            guard activeGeneration == generation else { return }
            onDiagnostic?(true, "Relative seek \(offset)s resolved as \(outcome) at \(player.currentTime)")
            if outcome == .rejected || outcome == .timedOut {
                errorMessage = "The skip seek did not complete (\(outcome))."
            }
        } catch {
            errorMessage = "The skip seek could not be completed: \(error.localizedDescription)"
        }
    }
    public func setSpeed(_ value: Float) {
        let speed = min(4, max(0.25, value))
        do { try player.setPlaybackRate(PlaybackRate(speed)) } catch { errorMessage = error.localizedDescription }
    }
    public func setVolume(_ value: Float) {
        do { try player.setAudioVolume(Volume(min(1, max(0, value)))) } catch { errorMessage = error.localizedDescription }
    }
    public func toggleMute() { player.isMuted.toggle() }
    public func selectAudioTrack(id: String?) { player.selectedAudioTrack = id.flatMap { id in audioTracks.first { $0.id == id } } }
    public func selectSubtitleTrack(id: String?) { player.selectedSubtitleTrack = id.flatMap { id in subtitleTracks.first { $0.id == id } } }

    public func shutdown() async {
        activeGeneration = nil
        cancelSessionTasks()
        vlcLogTask?.cancel(); vlcLogTask = nil
        await player.shutdown()
        for directory in subtitleDirectories { try? FileManager.default.removeItem(at: directory) }
        subtitleDirectories.removeAll()
    }

    private func cancelSessionTasks() {
        outcomeTask?.cancel(); outcomeTask = nil
        statusTask?.cancel(); statusTask = nil
        subtitleFallbackTask?.cancel(); subtitleFallbackTask = nil
        resumeTask?.cancel(); resumeTask = nil
        eventTask?.cancel(); eventTask = nil
    }
}

/// The app's single VLC playback session.
@MainActor
@Observable
public final class PlaybackSession {
    public private(set) var vlcEngine: VLCPlaybackEngine?
    public private(set) var title = ""
    public var onNaturalEnd: (() -> Void)? {
        didSet { vlcEngine?.onNaturalEnd = onNaturalEnd }
    }
    public var onDiagnostic: ((Bool, String) -> Void)? {
        didSet { vlcEngine?.onDiagnostic = onDiagnostic }
    }
    private var speedPreference: Float = 1
    private var volumePreference: Float = 1
    private var mutePreference = false
    private var preferredAudioLanguage: String?
    private var preferredSubtitleLanguage: String?
    private var subtitlePreferenceWasSet = false

    public init() {}

    /// Starts libVLC's one-time plugin and decoder initialization off the UI
    /// path. Call this as the application launches, before a lesson is opened.
    public static func prewarmVLC() {
        VLCInstance.prewarmShared(priority: .userInitiated)
    }

    public var state: AVPlaybackState { vlcEngine?.state ?? .idle }
    public var currentTime: Double { vlcEngine?.currentTime ?? 0 }
    public var duration: Double { vlcEngine?.duration ?? 0 }
    public var knownDuration: Double? { vlcEngine?.knownDuration }
    public var isSeekable: Bool { vlcEngine?.isSeekable ?? false }
    public var playbackSpeed: Float { vlcEngine?.playbackSpeed ?? speedPreference }
    public var volume: Float { vlcEngine?.volume ?? volumePreference }
    public var isMuted: Bool { vlcEngine?.isMuted ?? mutePreference }
    public var audioTracks: [PlaybackTrack] {
        (vlcEngine?.audioTracks ?? []).map { PlaybackTrack(id: $0.id, title: $0.name, language: $0.language) }
    }
    public var subtitleTracks: [PlaybackTrack] {
        (vlcEngine?.subtitleTracks ?? []).map { PlaybackTrack(id: $0.id, title: $0.name, language: $0.language) }
    }

    public func load(url: URL, title: String, subtitles: [PlaybackSubtitle] = [], resumeAt: Double = 0) {
        self.title = title
        let engine = ensureVLC()
        engine.load(url: url, title: title, subtitles: subtitles, resumeAt: resumeAt)
        engine.setSpeed(speedPreference)
        engine.setVolume(volumePreference)
        if engine.isMuted != mutePreference { engine.toggleMute() }
    }

    public func play() { vlcEngine?.play() }
    public func pause() { vlcEngine?.pause() }
    public func togglePlayback() { vlcEngine?.togglePlayback() }
    public func seek(to seconds: Double) { vlcEngine?.seek(to: seconds) }
    public func skip(by seconds: Double) { vlcEngine?.skip(by: seconds) }
    public func setSpeed(_ speed: Float) {
        guard speed.isFinite else { return }
        speedPreference = min(4, max(0.25, speed))
        vlcEngine?.setSpeed(speedPreference)
    }
    public func setVolume(_ volume: Float) {
        volumePreference = min(1, max(0, volume))
        vlcEngine?.setVolume(volumePreference)
    }
    public func toggleMute() {
        mutePreference.toggle()
        vlcEngine?.toggleMute()
    }
    public func selectAudioTrack(id: String?) {
        let track = id.flatMap { id in vlcEngine?.audioTracks.first { $0.id == id } }
        preferredAudioLanguage = track?.language
        vlcEngine?.selectAudioTrack(id: id)
    }
    public func selectSubtitleTrack(id: String?) {
        subtitlePreferenceWasSet = true
        let track = id.flatMap { id in vlcEngine?.subtitleTracks.first { $0.id == id } }
        preferredSubtitleLanguage = track?.language
        vlcEngine?.selectSubtitleTrack(id: id)
    }
    public func shutdown() async {
        if let vlcEngine { await vlcEngine.shutdown() }
        vlcEngine = nil
    }
    private func ensureVLC() -> VLCPlaybackEngine {
        if let vlcEngine { return vlcEngine }
        let engine = VLCPlaybackEngine()
        engine.onNaturalEnd = onNaturalEnd
        engine.onDiagnostic = onDiagnostic
        engine.onTracksChanged = { [weak self, weak engine] in
            guard let self, let engine, self.vlcEngine === engine else { return }
            if let language = self.preferredAudioLanguage,
               let track = engine.audioTracks.first(where: { $0.language?.caseInsensitiveCompare(language) == .orderedSame }),
               engine.player.selectedAudioTrack?.id != track.id {
                engine.selectAudioTrack(id: track.id)
            }
            if let language = self.preferredSubtitleLanguage,
               let track = engine.subtitleTracks.first(where: { $0.language?.caseInsensitiveCompare(language) == .orderedSame }),
               engine.player.selectedSubtitleTrack?.id != track.id {
                engine.selectSubtitleTrack(id: track.id)
            } else if self.subtitlePreferenceWasSet && self.preferredSubtitleLanguage == nil,
                      engine.player.selectedSubtitleTrack != nil {
                engine.selectSubtitleTrack(id: nil)
            }
        }
        vlcEngine = engine
        return engine
    }
}

/// The one stable rendering surface owned by the package.
public struct PlaybackVideoSurface: View {
    @Bindable private var session: PlaybackSession
    public init(session: PlaybackSession) { self.session = session }
    public var body: some View {
        Group {
            if let player = session.vlcEngine?.player {
                // NSViewRepresentable has no useful intrinsic aspect ratio. Supply
                // one explicitly so SwiftUI never collapses VLC's drawable to a
                // thin strip (especially while a window enters fullscreen).
                VideoView(player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black
            }
        }
    }
}

func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
