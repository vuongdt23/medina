import SwiftUI
import MedinaCore

/// The course outline: a "Continue" header driven by progress, then the flat
/// depth-ordered outline (reusing CourseTree.outline) rendered as editorial
/// rows with completion dots, lesson lengths, and a now-playing indicator.
struct CourseOutline: View {
    @Bindable var model: LibraryModel
    let tree: TreeNode
    @Environment(\.colorScheme) private var scheme

    private var entries: [OutlineEntry] { CourseTree.outline(of: tree) }

    var body: some View {
        VStack(spacing: 0) {
            resumeHeader
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries) { entry in
                            OutlineRow(
                                entry: entry,
                                isSelected: entry.id == model.selectedItemID,
                                isPlaying: entry.item.id == model.lessonQueue?.current?.id,
                                progress: model.courseProgress.progress(for: entry.item.id),
                                durationSeconds: lessonDuration(entry.item.id)
                            )
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedItemID = entry.id }
                            .onTapGesture(count: 2) {
                                if entry.item.type == "lesson" { model.playLesson(entry.item) }
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: model.lessonQueue?.current?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .background(Theme.canvas(scheme))
    }

    /// The engine only knows the active lesson's duration; surface it so the
    /// now-playing row can show a length even before progress is persisted.
    private func lessonDuration(_ id: String) -> Double? {
        if model.lessonQueue?.current?.id == id, let d = model.playbackEngine?.duration, d > 0 { return d }
        if let d = model.courseProgress.progress(for: id)?.durationSeconds, d > 0 { return d }
        return nil
    }

    @ViewBuilder private var resumeHeader: some View {
        if model.progressEnabled, let target = model.resumeTarget {
            let p = model.courseProgress.progress(for: target.id)
            let started = (p?.positionSeconds ?? 0) > 1
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(started ? "Continue where you left off" : "Start learning")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(target.title)
                            .font(Theme.display(14, .semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { model.playLesson(target) } label: {
                        Label(started ? "Resume" : "Play", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                if model.courseProgress.totalCount > 0 {
                    HStack(spacing: 8) {
                        ProgressBar(fraction: model.courseProgress.fraction)
                        Text("\(Int(model.courseProgress.fraction * 100))%")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(Theme.card(scheme))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline(scheme)), alignment: .bottom)
        }
    }
}

struct OutlineRow: View {
    let entry: OutlineEntry
    let isSelected: Bool
    let isPlaying: Bool
    let progress: LessonProgress?
    let durationSeconds: Double?
    @Environment(\.colorScheme) private var scheme

    private var isLesson: Bool { entry.item.type == "lesson" }
    private var isSection: Bool { entry.item.type == "section" }

    var body: some View {
        HStack(spacing: 9) {
            Color.clear.frame(width: CGFloat(entry.depth) * 14)
            statusGlyph
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isPlaying ? Theme.accent : (isLesson ? .primary : .secondary))
                .frame(width: 16)
            Text(entry.item.title)
                .font(isSection ? Theme.display(12.5, .semibold) : .system(size: 12.5))
                .foregroundStyle(isSection ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else if isLesson, let label = durationSeconds.flatMap({ Duration.lessonLabel(seconds: $0) }) {
                Text(label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(isSelected ? Theme.accent.opacity(scheme == .dark ? 0.22 : 0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .help(entry.item.originalName ?? entry.item.title)
    }

    @ViewBuilder private var statusGlyph: some View {
        if isLesson {
            if progress?.isEffectivelyComplete == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.done)
            } else if let f = progress?.fraction, f > 0.01 {
                ProgressRing(fraction: f, size: 13, lineWidth: 2, showsLabel: false)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        } else {
            Color.clear.frame(width: 13, height: 13)
        }
    }

    private var icon: String {
        switch entry.item.type {
        case "lesson": return entry.item.mediaKind == "audio" ? "music.note" : "play.rectangle.fill"
        case "section": return "folder.fill"
        case "asset_directory": return "folder"
        case "subtitle": return "captions.bubble"
        default: return "doc.text"
        }
    }
}
