import SwiftUI
import Combine
import MedinaCore
import MedinaPlayback

/// Adaptive shell: the inspector and outline keep their identity through live
/// resizing. The libmpv player remains model-owned.
struct CourseFocus: View {
    @Bindable var model: LibraryModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("workspaceSidebarWidth") private var preferredSidebarWidth = 360.0
    @AppStorage("workspaceFocusMode") private var focusMode = false
    @State private var layout: WorkspaceLayout = .standard
    @State private var measuredWindow = false
    @State private var compactContentOpen = false
    @State private var dragStartWidth: Double?
    @State private var focusSearchRequest = 0
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var sidebarVisible: Bool {
        layout == .compact ? compactContentOpen : !focusMode
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar
                Divider()
                if let tree = model.tree, tree.id == model.selectedCourseID {
                    workspace(tree: tree, size: geometry.size)
                } else if let loadingID = model.treeLoadingCourseID,
                          loadingID == model.selectedCourseID {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading \(model.courses.first(where: { $0.id == loadingID }).map { CourseName.clean($0.title) } ?? "course")…")
                            .font(.system(size: 14, weight: .medium))
                        Text("Preparing the course outline")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                } else {
                    ContentUnavailableView("Course unavailable", systemImage: "books.vertical",
                                           description: Text("The course outline could not be loaded."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in
                let next = WorkspaceLayout.resolve(width: width, previous: measuredWindow ? layout : nil)
                measuredWindow = true
                if next != layout { compactContentOpen = false }
                layout = next
            }
        }
        .background(Theme.canvas(scheme))
        .preferredColorScheme(focusMode && layout != .compact ? .dark : nil)
        .onChange(of: model.itemSelectionRevision) { _, _ in compactContentOpen = false }
        .onReceive(ticker) { _ in model.reportPlaybackProgress() }
        .onDisappear { model.reportPlaybackProgress(force: true) }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { model.backToLibrary() } label: {
                Label("Library", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Library (⌘[)")

            Text(model.tree.map { CourseName.clean($0.title) } ?? "Loading…")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.tree?.originalName ?? model.tree?.title ?? "")

            if let playing = model.lessonQueue?.current,
               model.selectedItemID != playing.id {
                Button { model.selectItem(id: playing.id) } label: {
                    Image(systemName: "play.rectangle")
                }
                .help("Return to playing lesson")
                .accessibilityLabel("Return to playing lesson")
            }

            Button {
                if layout == .compact { compactContentOpen = true }
                else { focusMode = false }
                focusSearchRequest += 1
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("Search course lessons (⌘F)")
            .accessibilityLabel("Search course lessons")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Open Medina settings")
            .accessibilityLabel("Settings")

            Button {
                if layout == .compact { compactContentOpen.toggle() }
                else { focusMode.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(sidebarVisible ? "Hide course content" : "Show course content")
            .accessibilityLabel(sidebarVisible ? "Hide course content" : "Show course content")

        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .tint(Theme.accent)
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.card(scheme))
    }

    private func workspace(tree: TreeNode, size: CGSize) -> some View {
        let width = layout.sidebarWidth(preferred: preferredSidebarWidth, available: size.width)
        let inline = sidebarVisible && layout != .compact
        return ZStack(alignment: .leading) {
            inspector(short: size.height < 540)
                .padding(.leading, inline ? width + 6 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!(layout == .compact && sidebarVisible))
                .disabled(layout == .compact && sidebarVisible)
                .accessibilityHidden(layout == .compact && sidebarVisible)

            // In compact mode the navigation is a drawer, or a full-content
            // view below 600pt. Never squeeze a sliver of video beside it.
            if layout == .compact && sidebarVisible && size.width >= 600 {
                Color.black.opacity(0.25)
                    .onTapGesture { compactContentOpen = false }
                    .accessibilityLabel("Dismiss course content")
            }

            HStack(spacing: 0) {
                CourseOutline(
                    model: model, tree: tree, short: size.height < 540,
                    focusSearchRequest: focusSearchRequest,
                    onDismiss: layout == .compact ? { compactContentOpen = false } : nil
                )
                .frame(width: width)
                if layout != .compact { resizeHandle(width: width) }
            }
            .frame(width: width + (layout == .compact ? 0 : 6))
            .frame(maxHeight: .infinity)
            .background(Theme.canvas(scheme))
            .offset(x: sidebarVisible ? 0 : -width - 6)
            .opacity(sidebarVisible ? 1 : 0)
            .allowsHitTesting(sidebarVisible)
            .disabled(!sidebarVisible)
            .accessibilityHidden(!sidebarVisible)
        }
        .clipped()
    }

    private func resizeHandle(width: Double) -> some View {
        Rectangle()
            .fill(Theme.hairline(scheme))
            .frame(width: 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = width }
                    preferredSidebarWidth = min(480, max(300, (dragStartWidth ?? width) + value.translation.width))
                }
                .onEnded { _ in dragStartWidth = nil })
            .accessibilityLabel("Course sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: preferredSidebarWidth = min(480, width + 20)
                case .decrement: preferredSidebarWidth = max(300, width - 20)
                @unknown default: break
                }
            }
            .help("Drag to resize course content")
    }

    @ViewBuilder private func inspector(short: Bool) -> some View {
        let selected = model.selectedAsset?.id == model.selectedItemID ? model.selectedAsset : nil
        if let selected, selected.type == "asset" {
            ItemDetail(item: selected, client: model.currentClient,
                       progress: model.courseProgress.progress(for: selected.id),
                       onPlay: { model.playLesson($0) })
                .id(selected.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let engine = model.playbackEngine {
            PlaybackPanel(
                engine: engine,
                lessonTitle: model.lessonQueue?.current?.title ?? engine.title,
                lessonContext: lessonContext(),
                upNextTitle: model.lessonQueue?.next?.title,
                hasPrevious: model.lessonQueue?.previous != nil,
                hasNext: model.lessonQueue?.next != nil,
                short: short,
                autoplay: Binding(get: { model.autoplayNext }, set: { model.autoplayNext = $0 }),
                onPrevious: { model.playPrevious() },
                onNext: { model.playNext() }
            )
        } else {
            ContentUnavailableView("Choose a lesson or file", systemImage: "play.rectangle",
                                   description: Text("Open course content to start learning."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func lessonContext() -> String {
        guard let queue = model.lessonQueue, !queue.lessons.isEmpty else { return "" }
        return "Lesson \(queue.currentIndex + 1) of \(queue.lessons.count)"
    }
}
