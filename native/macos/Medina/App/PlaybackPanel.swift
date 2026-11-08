import SwiftUI
import AppKit
import MedinaPlayback

/// Medina adds lesson navigation and auto-advance plus libmpv on-screen controls.
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
    @State private var mpvControlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var scrubPosition: Double?
    @State private var isScrubbing = false
    @State private var hoverTime: Double?
    @State private var showPlaybackOptions = false
    @State private var feedbackTitle: String?
    @State private var feedbackSymbol: String?
    @State private var feedbackTask: Task<Void, Never>?
    @State private var isPointerOverVideo = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || short
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    PlaybackVideoSurface(session: engine)
                        .accessibilityLabel("Video player: \(lessonTitle)")
                    if mpvControlsVisible {
                        mpvControls(compact: compact)
                            .transition(.opacity)
                    }
                    if engine.state == .loading {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.regular).tint(.white)
                            Text("Opening lesson…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(18)
                        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                    }
                    if let feedbackTitle, let feedbackSymbol {
                        transientFeedback(symbol: feedbackSymbol, title: feedbackTitle)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                            .zIndex(2)
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
                .onContinuousHover(perform: handleVideoHover)

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
            .onChange(of: engine.state) { _, state in
                if state == .playing { scheduleMpvControlsHide() }
                else { revealMpvControls() }
            }
            .onChange(of: engine.isSeekable) { _, seekable in
                if !seekable { updateSeekPreview(nil) }
            }
            .onChange(of: showPlaybackOptions) { _, isPresented in
                if isPresented { revealMpvControls() }
                else { scheduleMpvControlsHide(after: isPointerOverVideo ? .seconds(3) : .milliseconds(450)) }
            }
            .onChange(of: engine.seekPreview.sourceRevision) { _, _ in
                scrubPosition = nil
                isScrubbing = false
                hoverTime = nil
            }
            .onAppear { scheduleMpvControlsHide() }
            .onDisappear {
                hideControlsTask?.cancel()
                feedbackTask?.cancel()
                showPlaybackOptions = false
                engine.seekPreview.dismiss()
                hoverTime = nil
                scrubPosition = nil
                isScrubbing = false
            }
        }
    }

    private func handleVideoHover(_ phase: HoverPhase) {
        switch phase {
        case .active:
            isPointerOverVideo = true
            revealMpvControls()
        case .ended:
            isPointerOverVideo = false
            if !isScrubbing {
                hoverTime = nil
                engine.seekPreview.dismiss()
            }
            scheduleMpvControlsHide(after: .milliseconds(450))
        @unknown default:
            break
        }
    }

    /// Keep the playback surface unobstructed. Show on-screen controls on movement and
    /// hide them shortly after playback resumes.
    private func revealMpvControls() {
        hideControlsTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { mpvControlsVisible = true }
        if engine.state == .playing { scheduleMpvControlsHide() }
    }

    private func scheduleMpvControlsHide(after delay: Duration = .seconds(3)) {
        hideControlsTask?.cancel()
        guard engine.state == .playing else {
            mpvControlsVisible = true
            return
        }
        guard !isScrubbing, hoverTime == nil, !showPlaybackOptions else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, engine.state == .playing,
                  !isScrubbing, hoverTime == nil, !showPlaybackOptions else { return }
            withAnimation(.easeOut(duration: 0.2)) { mpvControlsVisible = false }
        }
    }

    private func toggleFullscreen() {
        // `keyWindow` can be nil while a borderless SwiftUI control is active;
        // fall back to the app's main content window rather than doing nothing.
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    private func mpvControls(compact: Bool) -> some View {
        VStack(spacing: 0) {
            overlayHeader(compact: compact)
                .padding(.horizontal, 26)
                .padding(.top, 20)
            Spacer(minLength: 24)
            VStack(spacing: 8) {
                SeekSlider(value: playbackPosition, duration: engine.duration,
                           enabled: engine.isSeekable && (engine.knownDuration ?? 0) > 0,
                           bufferedRanges: engine.bufferedRanges,
                           onHover: updateSeekPreview,
                           onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        revealMpvControls()
                    } else if let target = scrubPosition {
                        // Keep libmpv's serialized seek queue free of drag samples.
                        engine.seek(to: target)
                        scrubPosition = nil
                        scheduleMpvControlsHide()
                    }
                })
                .frame(height: 26)
                .overlay(alignment: .topLeading) { seekPreviewBubble }
                transportBar(compact: compact)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.72), location: 0),
                .init(color: .black.opacity(0.18), location: 0.22),
                .init(color: .clear, location: 0.48),
                .init(color: .black.opacity(0.18), location: 0.72),
                .init(color: .black.opacity(0.88), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .font(.system(size: 13, weight: .medium))
    }

    private func overlayHeader(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lessonContext.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.25)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                Text(lessonTitle)
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .help(lessonTitle)
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
            Spacer(minLength: 8)
            if !compact, let upNextTitle {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("UP NEXT")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.62))
                    Text(upNextTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14)))
                .frame(maxWidth: 230, alignment: .trailing)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
        }
    }

    private func transportBar(compact: Bool) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: compact ? 9 : 12) {
                skipButton(-10)
                playPauseButton
                skipButton(10)
                Text(timeText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize()
                    .padding(.leading, compact ? 2 : 8)
            }
            Spacer(minLength: 8)
            if !compact {
                playbackOptionsButton(compact: compact)
                muteButton
                volumeSlider(width: 104)
            } else {
                playbackOptionsButton(compact: compact)
            }
            fullscreenButton
        }
        .frame(maxWidth: .infinity)
    }

    private var playbackPosition: Binding<Double> {
        Binding(
            get: {
                let upperBound = max(engine.duration, 1)
                return min(upperBound, max(0, scrubPosition ?? engine.currentTime))
            },
            set: { target in
                if isScrubbing { scrubPosition = target }
                else { engine.seek(to: target) } // Native keyboard/accessibility adjustment.
            }
        )
    }

    private func updateSeekPreview(_ time: Double?) {
        guard let time, engine.isSeekable, let duration = engine.knownDuration, duration > 0 else {
            hoverTime = nil
            engine.seekPreview.dismiss()
            scheduleMpvControlsHide()
            return
        }
        let target = min(max(0, duration.nextDown), max(0, time))
        hoverTime = target
        engine.seekPreview.request(at: target)
        revealMpvControls()
    }

    private var seekPreviewBubble: some View {
        GeometryReader { geometry in
            if let hoverTime {
                let width = min(220, geometry.size.width)
                let x = min(max(0, geometry.size.width - width),
                            max(0, geometry.size.width * hoverTime / max(engine.duration, 1) - width / 2))
                let image = engine.seekPreview.imageData.flatMap { NSImage(data: $0) }
                VStack(spacing: 6) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: max(1, width - 12), height: 112)
                    } else {
                        VStack(spacing: 8) {
                            if engine.seekPreview.lastError == nil {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Loading preview…")
                            } else {
                                Image(systemName: "photo")
                                Text("Preview unavailable")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: max(1, width - 12), height: 112)
                    }
                    Text(timeLabel(hoverTime))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 16)
                }
                .padding(6)
                .frame(width: width)
                .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2)))
                .offset(x: x, y: -154)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func skipButton(_ seconds: Double) -> some View {
        Button {
            engine.skip(by: seconds)
            showFeedback(symbol: seconds < 0 ? "gobackward.10" : "goforward.10",
                         title: "\(seconds < 0 ? "−" : "+")10 seconds")
        } label: {
            Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
        .disabled(!engine.isSeekable)
        .opacity(engine.isSeekable ? 1 : 0.45)
        .help(seconds < 0 ? "Back 10 seconds" : "Forward 10 seconds")
    }

    private var playPauseButton: some View {
        let isPlaying = engine.state == .playing
        return Button {
            if isPlaying { engine.pause() } else { engine.play() }
            showFeedback(symbol: isPlaying ? "pause.fill" : "play.fill",
                         title: isPlaying ? "Paused" : "Playing")
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Theme.accent, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .shadow(color: Theme.accent.opacity(0.32), radius: 12, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .help(isPlaying ? "Pause" : "Play")
    }

    private func playbackOptionsButton(compact: Bool) -> some View {
        Button {
            showPlaybackOptions.toggle()
            revealMpvControls()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.white.opacity(showPlaybackOptions ? 0.2 : 0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback settings")
        .help("Playback settings")
        .popover(isPresented: $showPlaybackOptions, arrowEdge: .bottom) {
            playbackOptionsPopover(compact: compact)
        }
    }

    private func playbackOptionsPopover(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Playback settings", systemImage: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("SPEED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0], id: \.self) { rate in
                        let selected = abs(engine.playbackSpeed - Float(rate)) < 0.01
                        Button {
                            engine.setSpeed(Float(rate))
                            showFeedback(symbol: "speedometer", title: "\(String(format: "%.2g", rate))× speed")
                        } label: {
                            Text("\(rate, specifier: "%.2g")×")
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .foregroundStyle(selected ? Theme.accent : .primary)
                                .background(selected ? Theme.accent.opacity(0.13) : Color.primary.opacity(0.045),
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            if !engine.audioTracks.isEmpty {
                Menu {
                    ForEach(engine.audioTracks) { track in
                        Button(track.title) { engine.selectAudioTrack(id: track.id) }
                    }
                } label: {
                    settingsMenuRow(symbol: "waveform", title: "Audio track")
                }
                .menuStyle(.borderlessButton)
            }
            Menu {
                Button("Off") { engine.selectSubtitleTrack(id: nil) }
                ForEach(engine.subtitleTracks) { track in
                    Button(track.title) { engine.selectSubtitleTrack(id: track.id) }
                }
            } label: {
                settingsMenuRow(symbol: "captions.bubble", title: "Subtitles")
            }
            .menuStyle(.borderlessButton)
            if compact {
                Divider()
                HStack(spacing: 10) {
                    muteButton
                    Slider(value: Binding(get: { Double(engine.volume) },
                                          set: { engine.setVolume(Float($0)) }), in: 0...1)
                        .tint(Theme.accent)
                        .accessibilityLabel("Volume")
                    Text("\(Int(engine.volume * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(16)
        .frame(width: 276)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func settingsMenuRow(symbol: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
            Text(title)
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var muteButton: some View {
        Button {
            engine.toggleMute()
            showFeedback(symbol: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         title: engine.isMuted ? "Muted" : "Sound on")
        } label: {
            Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(engine.isMuted ? "Unmute" : "Mute")
        .help(engine.isMuted ? "Unmute" : "Mute")
    }

    private func volumeSlider(width: CGFloat) -> some View {
        Slider(value: Binding(get: { Double(engine.volume) }, set: { engine.setVolume(Float($0)) }), in: 0...1)
            .tint(Theme.accent)
            .frame(width: width)
            .accessibilityLabel("Volume")
    }

    private var fullscreenButton: some View {
        Button(action: toggleFullscreen) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enter or exit fullscreen")
        .help("Enter or exit fullscreen")
    }

    private func transientFeedback(symbol: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 28)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.black.opacity(0.66), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        .allowsHitTesting(false)
    }

    private func showFeedback(symbol: String, title: String) {
        feedbackTask?.cancel()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
            feedbackSymbol = symbol
            feedbackTitle = title
        }
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                feedbackSymbol = nil
                feedbackTitle = nil
            }
        }
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
