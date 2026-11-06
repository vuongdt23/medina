import SwiftUI
import AppKit
import MedinaPlayback

/// Medina adds lesson navigation and auto-advance plus VLC on-screen controls.
struct PlaybackPanel: View {
    let engine: PlaybackSession
    let lessonTitle: String
    let lessonContext: String
    let upNextTitle: String?
    let hasPrevious: Bool
    let hasNext: Bool
    let short: Bool
    @Binding var autoplay: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var vlcControlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var scrubPosition: Double?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || short
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    PlaybackVideoSurface(session: engine)
                        .accessibilityLabel("Video player: \(lessonTitle)")
                    if vlcControlsVisible {
                        vlcControls(compact: compact)
                            .transition(.opacity)
                    }
                    if case .failed(let message) = engine.state {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle").font(.title)
                            Text("Unable to play this lesson").font(.headline)
                            Text(message).font(.callout).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .padding(24)
                        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        .padding(20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                    HStack(alignment: .center, spacing: 28) {
                        lessonHeading
                        if !compact { lessonNavigation(compact: false) }
                    }
                    if compact { lessonNavigation(compact: true) }
                    if !compact, let upNextTitle {
                        HStack(spacing: 8) {
                            Text("UP NEXT")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(Theme.accent)
                            Text(upNextTitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, compact ? 18 : 28)
                .padding(.vertical, short ? 12 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [Theme.card(scheme), Theme.canvas(scheme)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.hairline(scheme)).frame(height: 1)
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { revealVLCControls() }
            }
            .onChange(of: engine.state) { _, state in
                if state == .playing { scheduleVLCControlsHide() }
                else { revealVLCControls() }
            }
            .onAppear { scheduleVLCControlsHide() }
            .onDisappear { hideControlsTask?.cancel() }
        }
    }

    /// VLC's drawable needs mouse input to remain unobstructed. Match the
    /// native-player convention: show the on-screen controls on movement and
    /// hide them shortly after playback resumes.
    private func revealVLCControls() {
        hideControlsTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { vlcControlsVisible = true }
        if engine.state == .playing { scheduleVLCControlsHide() }
    }

    private func scheduleVLCControlsHide() {
        hideControlsTask?.cancel()
        guard engine.state == .playing else {
            vlcControlsVisible = true
            return
        }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, engine.state == .playing else { return }
            withAnimation(.easeOut(duration: 0.2)) { vlcControlsVisible = false }
        }
    }

    private func toggleFullscreen() {
        // `keyWindow` can be nil while a borderless SwiftUI control is active;
        // fall back to the app's main content window rather than doing nothing.
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    private func vlcControls(compact: Bool) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    bufferHealthTrack
                    Slider(value: playbackPosition, in: 0...max(engine.duration, 1), onEditingChanged: { editing in
                        if !editing, let target = scrubPosition {
                            // Submitting every drag sample overwhelms libVLC's
                            // serialized seek queue and can leave it at EOF. Keep
                            // the thumb responsive locally, then make one exact
                            // seek when the user releases it.
                            engine.seek(to: target)
                            scrubPosition = nil
                        }
                    })
                        .disabled(!engine.isSeekable || (engine.knownDuration ?? 0) <= 0)
                        .accessibilityLabel("Playback position")
                }
                if compact {
                    compactVLCTransport
                } else {
                    regularVLCTransport
                }
            }
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, 10)
            .frame(maxWidth: compact ? 680 : 960)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .font(.system(size: 13, weight: .semibold))
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    private var playbackPosition: Binding<Double> {
        Binding(
            get: {
                let upperBound = max(engine.duration, 1)
                return min(upperBound, max(0, scrubPosition ?? engine.currentTime))
            },
            set: { scrubPosition = $0 }
        )
    }

    /// A thin bar under the scrubber showing libVLC's read-ahead cache health:
    /// a lighter segment extends ahead of the playhead by the cache fill
    /// fraction of the remaining timeline. This is buffer *health*, not an
    /// absolute buffered-to position (libVLC does not expose that).
    private var bufferHealthTrack: some View {
        GeometryReader { geo in
            let total = max(engine.duration, 1)
            let played = min(1, max(0, (scrubPosition ?? engine.currentTime) / total))
            let remaining = max(0, 1 - played)
            let aheadFraction = remaining * engine.bufferFill
            let width = geo.size.width
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: width * aheadFraction, height: 3)
                .offset(x: width * played)
                .animation(.easeOut(duration: 0.3), value: aheadFraction)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(height: 3)
        .opacity(engine.state == .playing || engine.state == .loading ? 1 : 0)
    }

    private var compactVLCTransport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                skipButton(-10)
                playPauseButton
                skipButton(10)
                Text(timeText).font(.system(.caption, design: .monospaced))
                Spacer(minLength: 0)
                fullscreenButton
            }
            HStack(spacing: 14) {
                speedMenu
                tracksMenu
                muteButton
                volumeSlider(width: 76)
            }
        }
    }

    private var regularVLCTransport: some View {
        HStack(spacing: 14) {
            skipButton(-10)
            playPauseButton
            skipButton(10)
            Text(timeText).font(.system(.caption, design: .monospaced))
            Spacer(minLength: 8)
            speedMenu
            if !engine.audioTracks.isEmpty { audioMenu }
            subtitlesMenu
            muteButton
            volumeSlider(width: 86)
            fullscreenButton
        }
    }

    private func skipButton(_ seconds: Double) -> some View {
        Button { engine.skip(by: seconds) } label: {
            Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
        }
        .accessibilityLabel(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
        .disabled(!engine.isSeekable)
        .help(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
    }

    private var playPauseButton: some View {
        Button { engine.togglePlayback() } label: {
            Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
        }
        .accessibilityLabel(engine.state == .playing ? "Pause" : "Play")
        .help(engine.state == .playing ? "Pause" : "Play")
    }

    private var speedMenu: some View {
        Menu("\(engine.playbackSpeed, specifier: "%.2g")×") {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { rate in
                Button("\(rate, specifier: "%.2g")×") { engine.setSpeed(Float(rate)) }
            }
        }
        .help("Playback speed")
    }

    private var tracksMenu: some View {
        Menu {
            if !engine.audioTracks.isEmpty { audioMenu }
            subtitlesMenu
        } label: {
            Image(systemName: "captions.bubble")
        }
        .help("Audio and subtitle tracks")
    }

    private var audioMenu: some View {
        Menu("Audio") {
            ForEach(engine.audioTracks) { track in
                Button(track.title) { engine.selectAudioTrack(id: track.id) }
            }
        }
    }

    private var subtitlesMenu: some View {
        Menu("Subtitles") {
            Button("Off") { engine.selectSubtitleTrack(id: nil) }
            ForEach(engine.subtitleTracks) { track in
                Button(track.title) { engine.selectSubtitleTrack(id: track.id) }
            }
        }
    }

    private var muteButton: some View {
        Button { engine.toggleMute() } label: {
            Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .accessibilityLabel("Mute or unmute")
        .help("Mute or unmute")
    }

    private func volumeSlider(width: CGFloat) -> some View {
        Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.setVolume(Float($0)) }), in: 0...1)
            .frame(width: width)
            .accessibilityLabel("Volume")
    }

    private var fullscreenButton: some View {
        Button(action: toggleFullscreen) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .accessibilityLabel("Enter or exit fullscreen")
        .help("Enter or exit fullscreen")
    }

    private var timeText: String {
        "\(timeLabel(engine.currentTime)) / \(engine.knownDuration.map(timeLabel) ?? "--:--")"
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private var lessonHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !short {
                HStack(spacing: 8) {
                    Capsule().fill(engine.state == .ended ? Theme.done : Theme.accent)
                        .frame(width: 16, height: 3)
                    Text(engine.state == .ended ? "COMPLETED" : "NOW LEARNING")
                        .font(.system(size: 10, weight: .bold)).tracking(1.2)
                        .foregroundStyle(engine.state == .ended ? Theme.done : Theme.accent)
                    Text("· \(lessonContext)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(lessonTitle)
                .font(.system(size: short ? 17 : 21, weight: .semibold))
                .lineLimit(short ? 1 : 2)
                .help(lessonTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lessonNavigation(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline(scheme)))
            }
            .buttonStyle(.plain)
            .disabled(!hasPrevious)
            .opacity(hasPrevious ? 1 : 0.4)
            .help("Previous lesson (⌘←)")
            .accessibilityLabel("Previous lesson")
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button(action: onNext) {
                HStack(spacing: 9) {
                    Text("Next lesson").font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .foregroundStyle(hasNext ? Theme.accent : .secondary)
                .background(Theme.accent.opacity(hasNext ? (scheme == .dark ? 0.16 : 0.09) : 0.03),
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent.opacity(hasNext ? 0.2 : 0.06)))
            }
            .buttonStyle(.plain)
            .disabled(!hasNext)
            .help("Next lesson (⌘→)")
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Spacer(minLength: 8)
            Toggle("Auto-next", isOn: $autoplay)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .tint(Theme.accent)
                .fixedSize()
                .help("Automatically start the next lesson when this one ends")
                .accessibilityLabel("Automatically play next lesson")
        }
        .fixedSize(horizontal: !compact, vertical: true)
    }
}
