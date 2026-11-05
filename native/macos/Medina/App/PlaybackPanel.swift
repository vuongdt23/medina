import SwiftUI
import AVKit
import MedinaPlayback

/// The playback surface: native AVKit video, lesson title, an "up next" hint,
/// transport + audio/subtitle/speed menus, and keyboard shortcuts. A periodic
/// tick drives server-side progress reporting while playing.
struct PlaybackPanel: View {
    let engine: AVPlaybackEngine
    let lessonTitle: String
    let upNextTitle: String?
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onStop: () -> Void
    let onTick: () -> Void

    @Environment(\.colorScheme) private var scheme
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            NativeAVPlayerView(player: engine.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Video player: \(lessonTitle)")

            // Lesson-level controls only. Scrubbing, play/pause, volume and
            // fullscreen come from AVKit's native inline controls on the video.
            HStack(alignment: .center, spacing: 12) {
                Button(action: onPrevious) { Image(systemName: "backward.end.fill") }
                    .disabled(!hasPrevious).help("Previous lesson")
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                VStack(alignment: .leading, spacing: 2) {
                    Text(lessonTitle)
                        .font(Theme.display(14, .semibold)).lineLimit(1)
                    if let upNextTitle {
                        Text("Up next · \(upNextTitle)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !engine.audioOptions.isEmpty {
                    Menu("Audio") {
                        ForEach(Array(engine.audioOptions.enumerated()), id: \.offset) { index, title in
                            Button(title) { engine.selectAudioTrack(index) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                if !engine.subtitleOptions.isEmpty {
                    Menu("Subtitles") {
                        Button("Off") { engine.selectSubtitleTrack(nil) }
                        ForEach(Array(engine.subtitleOptions.enumerated()), id: \.offset) { index, title in
                            Button(title) { engine.selectSubtitleTrack(index) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Menu("Speed") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed, format: .number)×") { engine.setSpeed(Float(speed)) }
                    }
                }.menuStyle(.borderlessButton).fixedSize()

                Button(action: onNext) { Image(systemName: "forward.end.fill") }
                    .disabled(!hasNext).help("Next lesson")
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button(action: onStop) { Image(systemName: "xmark") }
                    .help("Close player")
            }
            .buttonStyle(.borderless)
            .tint(Theme.accent)
            .font(.system(size: 12))

            if case .failed(let message) = engine.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card(scheme))
        .onReceive(ticker) { _ in onTick() }
        .onDisappear { onTick() }
    }
}

struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
