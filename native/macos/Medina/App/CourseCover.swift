import SwiftUI
import MedinaCore

/// A library grid card with a server thumbnail when available and generated
/// artwork as its durable fallback. Hover lifts the card; the last-opened
/// course and per-course completion summary remain visible independently.
struct CourseCover: View {
    let course: Course
    let isLastOpened: Bool
    let progress: CourseProgressSummary?
    let client: MedinaAPIClient?
    var onOpen: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var gradient: [Color] { Theme.coverGradients[Theme.coverIndex(for: course.title)] }

    var body: some View {
        Button(action: onOpen) {
            card
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(CourseName.clean(course.title))
        .accessibilityHint("Open course")
        .accessibilityValue(progressLabel)
        .help(course.originalName ?? course.title)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                Text(CourseName.clean(course.title))
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                footer
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(isLastOpened ? Theme.accent.opacity(0.6) : Theme.hairline(scheme),
                        lineWidth: isLastOpened ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.08),
                radius: hovering ? 14 : 5, y: hovering ? 7 : 3)
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack {
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            // Subtle motif for depth.
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 108))
                .foregroundStyle(.white.opacity(0.07))
                .rotationEffect(.degrees(-8))
                .offset(x: 46, y: 24)
            Text(CourseName.monogram(course.title))
                .font(Theme.display(34, .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            ServerThumbnail(path: course.thumbnailUrl, client: client)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if let progress, progress.totalCount > 0 {
                VStack {
                    HStack {
                        Spacer()
                        ProgressRing(fraction: progress.fraction, size: 34, lineWidth: 3.5)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 118)
        .clipped()
    }

    private var progressLabel: String {
        guard let progress, progress.totalCount > 0 else {
            return isLastOpened ? "Last opened" : "Not started"
        }
        if progress.completedCount >= progress.totalCount { return "Complete" }
        if progress.completedCount == 0 { return "Not started, 0 of \(progress.totalCount) lessons" }
        return "\(progress.completedCount) of \(progress.totalCount) lessons complete"
    }

    @ViewBuilder private var footer: some View {
        if let progress, progress.totalCount > 0 {
            VStack(alignment: .leading, spacing: 5) {
                Text(progress.completedCount >= progress.totalCount
                     ? "Complete"
                     : progress.completedCount == 0
                        ? "Not started"
                        : "\(progress.completedCount) of \(progress.totalCount) lessons")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ProgressBar(fraction: progress.fraction)
            }
        } else {
            Text(isLastOpened ? "Last opened" : "Not started")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}
