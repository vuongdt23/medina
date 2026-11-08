import AppKit
import CMpvShim
import CMpvSystem
import Foundation
import Observation
import SwiftUI

public enum AVPlaybackState: Equatable, Sendable {
    case idle, loading, ready, playing, paused, ended
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
        self.id = id
        self.title = title
        self.language = language
    }
}

private final class MpvPrewarmPool: @unchecked Sendable {
    private struct Prepared {
        let handle: OpaquePointer
        let readAheadBytes: Int
    }
    private let lock = NSLock()
    private var prepared: Prepared?

    func take(readAheadBytes: Int) -> OpaquePointer? {
        lock.lock()
        let entry = prepared
        prepared = nil
        lock.unlock()
        guard let entry else { return nil }
        guard entry.readAheadBytes == readAheadBytes else {
            mpv_terminate_destroy(entry.handle)
            return nil
        }
        return entry.handle
    }

    func store(_ handle: OpaquePointer, readAheadBytes: Int) {
        lock.lock()
        let previous = prepared
        prepared = Prepared(handle: handle, readAheadBytes: readAheadBytes)
        lock.unlock()
        if let previous { mpv_terminate_destroy(previous.handle) }
    }
}

private let mpvPrewarmPool = MpvPrewarmPool()

private func mpvOptions(readAheadBytes: Int) -> [(String, String)] {
    let bytes = min(1 << 30, max(16 << 20, readAheadBytes))
    return [
        ("config", "no"), ("terminal", "no"), ("msg-level", "all=warn"),
        ("vo", "libmpv"), ("osc", "no"), ("input-default-bindings", "no"),
        ("cache", "yes"), ("cache-secs", "60"), ("network-timeout", "20"),
        ("hwdec", "auto-safe"), ("demuxer-max-bytes", String(bytes)),
        ("demuxer-max-back-bytes", String(min(bytes, 256 << 20)))
    ]
}

/// Owns Medina's single libmpv client. All control/property operations are
/// serialized on the main actor; libmpv itself is thread-safe for these calls.
@MainActor
@Observable
public final class MpvPlaybackEngine {
    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var renderOpenGLContext: NSOpenGLContext?
    private var refreshTask: Task<Void, Never>?
    private var pendingResume: Double = 0
    private var pendingSubtitles: [PlaybackSubtitle] = []
    private var didAttachSubtitles = false
    private var loadBeganAt = Date.distantPast
    private var didReportFileLoaded = false
    private var didReportPlaybackRestart = false
    private var didReportFirstFrame = false
    private var didReportEnd = false
    private var didApplyResume = false
    private var expectedURL: String?
    private var lastPause: Bool?
    private var lastPosition = 0.0
    private var lastDuration: Double?
    private var isSeekableValue = false
    private var volumeValue: Float = 1
    private var mutedValue = false
    private var speedValue: Float = 1
    public private(set) var title = ""
    public private(set) var errorMessage: String?
    public private(set) var audioTracks: [PlaybackTrack] = []
    public private(set) var subtitleTracks: [PlaybackTrack] = []
    public private(set) var bufferedRanges: [ClosedRange<Double>] = []
    public private(set) var initializationDurationMilliseconds = 0.0
    public private(set) var usedPrewarmedClient = false
    public var onNaturalEnd: (() -> Void)?
    public var onTracksChanged: (() -> Void)?
    public var onDiagnostic: ((Bool, String) -> Void)?

    public init(prefetchBufferBytes: Int = 1 << 30) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let normalizedReadAhead = min(1 << 30, max(16 << 20, prefetchBufferBytes))
        let prewarmed = mpvPrewarmPool.take(readAheadBytes: normalizedReadAhead)
        guard let handle = prewarmed ?? mpv_create() else {
            errorMessage = "Could not create the libmpv playback client."
            return
        }
        self.handle = handle
        usedPrewarmedClient = prewarmed != nil
        if prewarmed == nil {
            for (name, value) in mpvOptions(readAheadBytes: normalizedReadAhead) {
                let result = name.withCString { key in value.withCString { mpv_set_option_string(handle, key, $0) } }
                if result < 0 { onDiagnostic?(false, "libmpv option \(name) rejected: error \(result)") }
            }
            let initialized = mpv_initialize(handle)
            guard initialized >= 0 else {
                errorMessage = "libmpv could not initialize: \(String(cString: mpv_error_string(initialized)))"
                mpv_terminate_destroy(handle)
                self.handle = nil
                return
            }
        }
        medina_mpv_enable_timing_events(handle)
        initializationDurationMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public static func naturalEndTimelineIsConsistent(time: Duration, duration: Duration?) -> Bool {
        let elapsed = durationSeconds(time)
        guard let duration else { return elapsed > 0.5 }
        let length = durationSeconds(duration)
        guard length > 0 else { return true }
        return elapsed >= length - max(0.5, min(2.0, length * 0.02))
    }

    public var state: AVPlaybackState {
        guard handle != nil else { return .failed(errorMessage ?? "libmpv is unavailable.") }
        if let errorMessage { return .failed(errorMessage) }
        if boolProperty("eof-reached"), let handle, let expectedURL,
           expectedURL.withCString({ medina_mpv_path_matches(handle, $0) }) != 0 {
            if !didReportEnd {
                didReportEnd = true
                onNaturalEnd?()
            }
            return .ended
        }
        guard boolProperty("idle-active") == false else { return title.isEmpty ? .idle : .loading }
        guard let paused = lastPause else { return .loading }
        return paused ? .paused : .playing
    }
    public var currentTime: Double { max(0, lastPosition) }
    public var duration: Double { lastDuration ?? 0 }
    public var knownDuration: Double? { lastDuration }
    public var isSeekable: Bool { isSeekableValue }
    public var playbackSpeed: Float { speedValue }
    public var volume: Float { volumeValue }
    public var isMuted: Bool { mutedValue }
    /// Fraction of the timeline covered by cached, seekable ranges.
    public var bufferFill: Double {
        guard let duration = lastDuration, duration > 0 else { return 0 }
        let seconds = bufferedRanges.reduce(0.0) { $0 + $1.upperBound - $1.lowerBound }
        return min(1, max(0, seconds / duration))
    }

    public func load(url: URL, title: String, subtitles: [PlaybackSubtitle], resumeAt: Double = 0) {
        guard let handle else { errorMessage = "libmpv is unavailable."; return }
        self.title = title
        errorMessage = nil
        pendingResume = max(0, resumeAt)
        didApplyResume = pendingResume == 0
        pendingSubtitles = subtitles
        didAttachSubtitles = subtitles.isEmpty
        expectedURL = url.absoluteString
        _ = medina_mpv_poll_timing_events(handle)
        loadBeganAt = Date()
        didReportFileLoaded = false
        didReportPlaybackRestart = false
        didReportFirstFrame = false
        didReportEnd = false
        lastPosition = 0
        lastDuration = nil
        isSeekableValue = false
        audioTracks = []
        subtitleTracks = []
        bufferedRanges = []
        let commandStartedAt = ProcessInfo.processInfo.systemUptime
        let result = url.absoluteString.withCString { medina_mpv_load(handle, $0) }
        guard result >= 0 else { fail("Unable to open this lesson: \(mpvError(result))"); return }
        setProperty("pause", flag: 0)
        let sourceKind = ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? "network" : "local/other"
        let enqueueMilliseconds = (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
        onDiagnostic?(false, "libmpv accepted \(sourceKind) load request in \(Int(enqueueMilliseconds)) ms")
        refresh()
    }

    public func play() {
        if state == .ended { seek(to: 0) }
        setProperty("pause", flag: 0)
    }
    public func pause() { setProperty("pause", flag: 1) }
    public func togglePlayback() { setProperty("pause", flag: state == .playing ? 1 : 0) }
    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        command(["seek", String(max(0, seconds)), "absolute+exact"])
    }
    public func skip(by seconds: Double) {
        guard seconds.isFinite else { return }
        command(["seek", String(seconds), "relative+exact"])
    }
    public func setSpeed(_ speed: Float) {
        guard speed.isFinite else { return }
        speedValue = min(4, max(0.25, speed))
        setProperty("speed", number: Double(speedValue))
    }
    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        volumeValue = min(1, max(0, volume))
        setProperty("volume", number: Double(volumeValue * 100))
    }
    public func toggleMute() {
        mutedValue.toggle()
        setProperty("mute", flag: mutedValue ? 1 : 0)
    }
    public func selectAudioTrack(id: String?) { setTrack("aid", id: id) }
    public func selectSubtitleTrack(id: String?) { setTrack("sid", id: id) }

    public func shutdown() async {
        refreshTask?.cancel()
        refreshTask = nil
        bufferedRanges = []
        if let renderContext {
            renderOpenGLContext?.makeCurrentContext()
            medina_mpv_render_free(renderContext)
            self.renderContext = nil
            renderOpenGLContext = nil
        }
        if let handle {
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
    }

    fileprivate func attachRenderer(context: NSOpenGLContext?) -> Bool {
        guard let handle, let context else { return false }
        if renderContext != nil, renderOpenGLContext === context { return true }
        if let renderContext {
            renderOpenGLContext?.makeCurrentContext()
            medina_mpv_render_free(renderContext)
            self.renderContext = nil
            renderOpenGLContext = nil
        }
        context.makeCurrentContext()
        guard let renderer = medina_mpv_render_create(handle) else {
            fail("Could not initialize libmpv's OpenGL renderer.")
            return false
        }
        renderContext = renderer
        renderOpenGLContext = context
        return true
    }

    fileprivate func draw(width: Int, height: Int) {
        guard attachRenderer(context: NSOpenGLContext.current), let renderContext else { return }
        let hasNewFrame = medina_mpv_render_draw(renderContext, Int32(width), Int32(height)) != 0
        if hasNewFrame, didReportFileLoaded, !didReportFirstFrame {
            didReportFirstFrame = true
            let milliseconds = Int(Date().timeIntervalSince(loadBeganAt) * 1_000)
            onDiagnostic?(false, "First video frame rendered in \(milliseconds) ms after load request")
        }
    }

    fileprivate func reportSwap() {
        guard let renderContext else { return }
        medina_mpv_render_report_swap(renderContext)
    }

    private func refresh() {
        guard let handle else { return }
        let timingEvents = medina_mpv_poll_timing_events(handle)
        if timingEvents & Int32(MEDINA_MPV_EVENT_FILE_LOADED) != 0, !didReportFileLoaded {
            didReportFileLoaded = true
            let milliseconds = Int(Date().timeIntervalSince(loadBeganAt) * 1_000)
            onDiagnostic?(false, "Media input opened in \(milliseconds) ms")
        }
        if timingEvents & Int32(MEDINA_MPV_EVENT_PLAYBACK_RESTART) != 0, !didReportPlaybackRestart {
            didReportPlaybackRestart = true
            let milliseconds = Int(Date().timeIntervalSince(loadBeganAt) * 1_000)
            onDiagnostic?(false, "Playback started in \(milliseconds) ms after load request")
        }
        let idle = boolProperty("idle-active")
        if idle {
            if !title.isEmpty, Date().timeIntervalSince(loadBeganAt) > 30, errorMessage == nil {
                fail("libmpv could not open this lesson. Check the media source or connection.")
            }
            return
        }
        if !didAttachSubtitles, let expectedURL,
           expectedURL.withCString({ medina_mpv_path_matches(handle, $0) }) != 0 {
            didAttachSubtitles = true
            for subtitle in pendingSubtitles {
                let result = subtitle.url.absoluteString.withCString { urlPointer in
                    subtitle.filename.withCString { namePointer in medina_mpv_add_subtitle(handle, urlPointer, namePointer) }
                }
                if result < 0 { onDiagnostic?(true, "Could not attach subtitle \(subtitle.filename): \(mpvError(result))") }
            }
        }
        if let position = numberProperty("time-pos"), position.isFinite { lastPosition = max(0, position) }
        lastDuration = numberProperty("duration").flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let ranges = readBufferedRanges(handle)
        let normalizedRanges = Self.normalizedBufferedRanges(ranges, duration: lastDuration)
        if normalizedRanges != bufferedRanges { bufferedRanges = normalizedRanges }
        lastPause = boolProperty("pause")
        isSeekableValue = boolProperty("seekable")
        volumeValue = Float((numberProperty("volume") ?? 100) / 100)
        mutedValue = boolProperty("mute")
        speedValue = Float(numberProperty("speed") ?? 1)
        if !didApplyResume, lastDuration != nil, !boolProperty("seeking") {
            didApplyResume = true
            seek(to: pendingResume)
        }
        refreshTracks()
    }

    private func readBufferedRanges(_ handle: OpaquePointer) -> [Double] {
        let capacity = 128
        var values = [Double](repeating: 0, count: capacity * 2)
        let count = values.withUnsafeMutableBufferPointer { buffer in
            medina_mpv_get_buffered_ranges(handle, buffer.baseAddress, Int32(capacity))
        }
        guard count > 0 else { return [] }
        return Array(values.prefix(Int(count) * 2))
    }

    static func normalizedBufferedRanges(_ values: [Double], duration: Double?) -> [ClosedRange<Double>] {
        guard values.count >= 2 else { return [] }
        let limit = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .greatestFiniteMagnitude
        var ranges: [ClosedRange<Double>] = []
        for index in stride(from: 0, to: values.count - 1, by: 2) {
            let rawStart = values[index]
            let rawEnd = values[index + 1]
            guard rawStart.isFinite, rawEnd.isFinite else { continue }
            let start = max(0, rawStart)
            let end = min(limit, rawEnd)
            guard end > start else { continue }
            ranges.append(start...end)
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.05 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func refreshTracks() {
        guard let handle else { return }
        var newAudio: [PlaybackTrack] = []
        var newSubtitles: [PlaybackTrack] = []
        for index in 0..<medina_mpv_get_track_count(handle) {
            var id = [CChar](repeating: 0, count: 32)
            var type = [CChar](repeating: 0, count: 32)
            var title = [CChar](repeating: 0, count: 256)
            var language = [CChar](repeating: 0, count: 64)
            var selected: Int32 = 0
            let ok = medina_mpv_get_track(handle, Int32(index), &id, 32, &type, 32,
                                          &title, 256, &language, 64, &selected)
            guard ok != 0 else { continue }
            let trackType = decodeCString(type)
            let track = PlaybackTrack(id: decodeCString(id),
                                      title: title[0] == 0 ? "\(trackType.capitalized) \(index + 1)" : decodeCString(title),
                                      language: language[0] == 0 ? nil : decodeCString(language))
            if trackType == "audio" { newAudio.append(track) }
            if trackType == "sub" { newSubtitles.append(track) }
        }
        if audioTracks != newAudio || subtitleTracks != newSubtitles {
            audioTracks = newAudio
            subtitleTracks = newSubtitles
            onTracksChanged?()
        }
    }

    private func setTrack(_ property: String, id: String?) {
        guard let handle else { return }
        let value = id ?? "no"
        let result = property.withCString { key in value.withCString { mpv_set_property_string(handle, key, $0) } }
        if result < 0 { onDiagnostic?(true, "Could not select \(property) \(value): \(mpvError(result))") }
    }
    private func command(_ arguments: [String]) {
        guard let handle else { return }
        let result = arguments.withCStringArray { mpv_command(handle, $0) }
        if result < 0 { onDiagnostic?(true, "libmpv command failed: \(mpvError(result))") }
    }
    private func setOption(_ name: String, value: String) {
        guard let handle else { return }
        let result = name.withCString { key in value.withCString { mpv_set_property_string(handle, key, $0) } }
        if result < 0 { onDiagnostic?(true, "libmpv property \(name) could not be set: \(mpvError(result))") }
    }
    private func setProperty(_ name: String, flag: Int32) {
        guard let handle else { return }
        var value = flag
        let result = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_FLAG, &value) }
        if result < 0 { onDiagnostic?(true, "libmpv property \(name) could not be set: \(mpvError(result))") }
    }
    private func setProperty(_ name: String, number: Double) {
        guard let handle else { return }
        var value = number
        let result = name.withCString { mpv_set_property(handle, $0, MPV_FORMAT_DOUBLE, &value) }
        if result < 0 { onDiagnostic?(true, "libmpv property \(name) could not be set: \(mpvError(result))") }
    }
    private func numberProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        let result = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &value) }
        return result < 0 ? nil : value
    }
    private func boolProperty(_ name: String) -> Bool {
        guard let handle else { return false }
        var value: Int32 = 0
        let result = name.withCString { mpv_get_property(handle, $0, MPV_FORMAT_FLAG, &value) }
        return result >= 0 && value != 0
    }
    private func fail(_ message: String) {
        errorMessage = message
        onDiagnostic?(false, message)
    }
    private func mpvError(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }
}

@MainActor
@Observable
public final class PlaybackSession {
    public private(set) var mpvEngine: MpvPlaybackEngine?
    public let seekPreview = SeekPreviewController()
    public private(set) var title = ""
    public var onNaturalEnd: (() -> Void)? { didSet { mpvEngine?.onNaturalEnd = onNaturalEnd } }
    public var onDiagnostic: ((Bool, String) -> Void)? {
        didSet { mpvEngine?.onDiagnostic = onDiagnostic; seekPreview.onDiagnostic = onDiagnostic }
    }
    private var speedPreference: Float = 1
    private var volumePreference: Float = 1
    private var mutePreference = false
    private var preferredAudioLanguage: String?
    private var preferredSubtitleLanguage: String?
    private var subtitlePreferenceWasSet = false

    public init() {}
    public static func prewarmMpv(prefetchBufferBytes: Int = 1 << 30) {
        let readAheadBytes = min(1 << 30, max(16 << 20, prefetchBufferBytes))
        Task.detached(priority: .userInitiated) {
            guard let handle = mpv_create() else { return }
            for (name, value) in mpvOptions(readAheadBytes: readAheadBytes) {
                let result = name.withCString { key in value.withCString { mpv_set_option_string(handle, key, $0) } }
                guard result >= 0 else { mpv_terminate_destroy(handle); return }
            }
            guard mpv_initialize(handle) >= 0 else { mpv_terminate_destroy(handle); return }
            mpvPrewarmPool.store(handle, readAheadBytes: readAheadBytes)
        }
    }
    public var state: AVPlaybackState { mpvEngine?.state ?? .idle }
    public var currentTime: Double { mpvEngine?.currentTime ?? 0 }
    public var duration: Double { mpvEngine?.duration ?? 0 }
    public var knownDuration: Double? { mpvEngine?.knownDuration }
    public var isSeekable: Bool { mpvEngine?.isSeekable ?? false }
    public var bufferedRanges: [ClosedRange<Double>] { mpvEngine?.bufferedRanges ?? [] }
    public var bufferFill: Double { mpvEngine?.bufferFill ?? 0 }
    public var playbackSpeed: Float { mpvEngine?.playbackSpeed ?? speedPreference }
    public var volume: Float { mpvEngine?.volume ?? volumePreference }
    public var isMuted: Bool { mpvEngine?.isMuted ?? mutePreference }
    public var audioTracks: [PlaybackTrack] { mpvEngine?.audioTracks ?? [] }
    public var subtitleTracks: [PlaybackTrack] { mpvEngine?.subtitleTracks ?? [] }

    public func load(url: URL, title: String, subtitles: [PlaybackSubtitle] = [], resumeAt: Double = 0, prefetchBufferBytes: Int = 1 << 30) {
        self.title = title
        seekPreview.load(url: url)
        let engine = ensureMpv(prefetchBufferBytes: prefetchBufferBytes)
        engine.load(url: url, title: title, subtitles: subtitles, resumeAt: resumeAt)
        engine.setSpeed(speedPreference)
        engine.setVolume(volumePreference)
        if engine.isMuted != mutePreference { engine.toggleMute() }
    }
    public func play() { mpvEngine?.play() }
    public func pause() { mpvEngine?.pause() }
    public func togglePlayback() { mpvEngine?.togglePlayback() }
    public func seek(to seconds: Double) { mpvEngine?.seek(to: seconds) }
    public func skip(by seconds: Double) { mpvEngine?.skip(by: seconds) }
    public func setSpeed(_ speed: Float) {
        guard speed.isFinite else { return }
        speedPreference = min(4, max(0.25, speed))
        mpvEngine?.setSpeed(speedPreference)
    }
    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        volumePreference = min(1, max(0, volume))
        mpvEngine?.setVolume(volumePreference)
    }
    public func toggleMute() { mutePreference.toggle(); mpvEngine?.toggleMute() }
    public func selectAudioTrack(id: String?) {
        preferredAudioLanguage = id.flatMap { id in audioTracks.first { $0.id == id }?.language }
        mpvEngine?.selectAudioTrack(id: id)
    }
    public func selectSubtitleTrack(id: String?) {
        subtitlePreferenceWasSet = true
        preferredSubtitleLanguage = id.flatMap { id in subtitleTracks.first { $0.id == id }?.language }
        mpvEngine?.selectSubtitleTrack(id: id)
    }
    public func shutdown() async {
        seekPreview.unload()
        if let mpvEngine { await mpvEngine.shutdown() }
        mpvEngine = nil
    }
    private func ensureMpv(prefetchBufferBytes: Int) -> MpvPlaybackEngine {
        if let mpvEngine { return mpvEngine }
        let engine = MpvPlaybackEngine(prefetchBufferBytes: prefetchBufferBytes)
        engine.onNaturalEnd = onNaturalEnd
        engine.onDiagnostic = onDiagnostic
        onDiagnostic?(false, engine.usedPrewarmedClient
            ? "Using preinitialized libmpv client (attach time \(Int(engine.initializationDurationMilliseconds)) ms)"
            : "libmpv client initialized in \(Int(engine.initializationDurationMilliseconds)) ms")
        engine.onTracksChanged = { [weak self, weak engine] in
            guard let self, let engine, self.mpvEngine === engine else { return }
            if let language = self.preferredAudioLanguage,
               let track = engine.audioTracks.first(where: { $0.language?.caseInsensitiveCompare(language) == .orderedSame }) {
                engine.selectAudioTrack(id: track.id)
            }
            if let language = self.preferredSubtitleLanguage,
               let track = engine.subtitleTracks.first(where: { $0.language?.caseInsensitiveCompare(language) == .orderedSame }) {
                engine.selectSubtitleTrack(id: track.id)
            } else if self.subtitlePreferenceWasSet && self.preferredSubtitleLanguage == nil {
                engine.selectSubtitleTrack(id: nil)
            }
        }
        mpvEngine = engine
        return engine
    }
}

public struct PlaybackVideoSurface: View {
    @Bindable private var session: PlaybackSession
    public init(session: PlaybackSession) { self.session = session }
    public var body: some View {
        MpvVideoRepresentable(session: session)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

private struct MpvVideoRepresentable: NSViewRepresentable {
    let session: PlaybackSession
    func makeNSView(context: Context) -> MpvOpenGLView { MpvOpenGLView(session: session)! }
    func updateNSView(_ nsView: MpvOpenGLView, context: Context) { nsView.needsDisplay = true }
}

@MainActor
private final class MpvOpenGLView: NSOpenGLView {
    private let session: PlaybackSession
    private var refreshTimer: Timer?
    init?(session: PlaybackSession) {
        self.session = session
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile), NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated), 0
        ]
        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attributes) else { return nil }
        super.init(frame: .zero, pixelFormat: pixelFormat)
        wantsBestResolutionOpenGLSurface = true
    }
    required init?(coder: NSCoder) { nil }
    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        _ = session.mpvEngine?.attachRenderer(context: openGLContext)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = self.session.state
                guard state == .playing || state == .loading else { return }
                self.needsDisplay = true
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        let scale = window?.backingScaleFactor ?? 1
        session.mpvEngine?.draw(width: Int(bounds.width * scale), height: Int(bounds.height * scale))
        context.flushBuffer()
        session.mpvEngine?.reportSwap()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}

private extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
        var storage: [UnsafePointer<CChar>?] = []
        func nest(_ index: Int, _ continuation: () throws -> R) rethrows -> R {
            guard index < count else { return try continuation() }
            return try self[index].withCString { pointer in
                storage.append(pointer)
                defer { storage.removeLast() }
                return try nest(index + 1, continuation)
            }
        }
        return try nest(0) { try storage.withUnsafeMutableBufferPointer { try body($0.baseAddress!) } }
    }
}

private func decodeCString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
