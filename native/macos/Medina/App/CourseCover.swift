import SwiftUI
import MedinaCore

/// A library grid card: a generated gradient cover with a monogram, the course
/// title, and (once the course has been opened) a progress ring. Hover lifts
/// the card; the last-opened course is highlighted.
struct CourseCover: View {
    let course: Course
    let isLastOpened: Bool
    let progress: CourseProgress?
    var onOpen: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var gradient: [Color] { Theme.coverGradients[Theme.coverIndex(for: course.title)] }

    var body: some View {
        Button(action: onOpen) {
            card
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityLabel(course.title)
        .accessibilityHint("Open course")
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

    @ViewBuilder private var footer: some View {
        if let progress, progress.totalCount > 0 {
            Text("\(progress.completedCount)/\(progress.totalCount) lessons · \(Int(progress.fraction * 100))%")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Text(isLastOpened ? "Last opened" : "Course")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

/// Helpers to make noisy scene-release course names presentable.
enum CourseName {
    /// Strips leading source tags like "[WebToolTip.com]" and "Udemy -" so the
    /// human title reads cleanly on cards.
    static func clean(_ raw: String) -> String {
        var s = raw
        // Drop a leading bracketed tag, e.g. "[FreeCourseSite.com] ".
        if let close = s.firstIndex(of: "]"), s.first == "[" {
            s = String(s[s.index(after: close)...])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["Udemy -", "Udemy–", "Udemy", "[Udemy]"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        return s.isEmpty ? raw : s
    }

    /// Up to two initials from the cleaned title for the cover monogram.
    static func monogram(_ raw: String) -> String {
        let words = clean(raw)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        let initials = words.prefix(2).compactMap { $0.first }.map(String.init)
        let joined = initials.joined().uppercased()
        return joined.isEmpty ? "•" : joined
    }
}
