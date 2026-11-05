import SwiftUI
import MedinaCore

/// The focused course workspace: a top bar with a Back-to-Library control and
/// the course title, over the structure outline beside the item inspector and
/// player. Playback keeps running if the user navigates back to the library.
struct CourseFocus: View {
    @Bindable var model: LibraryModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.hairline(scheme))
            content
        }
        .background(Theme.canvas(scheme))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.backToLibrary() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                    Text(model.libraries.first?.name ?? "Library").font(.system(size: 12.5, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Library (⌘[)")

            Divider().frame(height: 18)

            Text(model.tree?.title ?? "Loading…")
                .font(Theme.display(16, .bold))
                .lineLimit(1)

            Spacer()

            if let playing = model.lessonQueue?.current?.title {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    Text(playing).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Theme.card(scheme))
    }

    @ViewBuilder private var content: some View {
        if let tree = model.tree {
            HSplitView {
                CourseOutline(model: model, tree: tree)
                    .frame(minWidth: 320, idealWidth: 380)
                inspector(tree: tree)
                    .frame(minWidth: 360)
            }
        } else {
            ContentUnavailableView {
                Label("Preparing course…", systemImage: "books.vertical")
            } description: {
                Text("If this persists, the course may be empty or the server is unavailable.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func inspector(tree: TreeNode) -> some View {
        VStack(spacing: 0) {
            if let entry = CourseTree.outline(of: tree).first(where: { $0.id == model.selectedItemID }) {
                ItemDetail(
                    item: entry.item,
                    client: model.currentClient,
                    progress: model.courseProgress.progress(for: entry.item.id),
                    onPlay: { lesson in model.playLesson(lesson) }
                )
                .id(entry.id)
            } else {
                ContentUnavailableView("Choose a lesson or file",
                                       systemImage: "text.aligncenter",
                                       description: Text("Pick an item from the outline to read, preview, or play it."))
            }
            if let engine = model.playbackEngine {
                Divider()
                PlaybackPanel(
                    engine: engine,
                    lessonTitle: model.lessonQueue?.current?.title ?? engine.title,
                    upNextTitle: model.lessonQueue?.next?.title,
                    hasPrevious: model.lessonQueue?.previous != nil,
                    hasNext: model.lessonQueue?.next != nil,
                    onPrevious: { model.playPrevious() },
                    onNext: { model.playNext() },
                    onStop: { model.stopPlayback() },
                    onTick: { model.reportPlaybackProgress() }
                )
            }
        }
        .background(Theme.canvas(scheme))
    }
}
