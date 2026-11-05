import SwiftUI
import AVKit
import MedinaPlayback

/// AVKit owns media controls. Medina adds only course-level navigation and
/// auto-advance, styled as lesson context rather than a second transport bar.
struct PlaybackPanel: View {
    let engine: AVPlaybackEngine
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

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || short
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    NativeAVPlayerView(player: engine.player)
                        .accessibilityLabel("Video player: \(lessonTitle)")
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
        }
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
