import SwiftUI
import AppKit
import MedinaCore

/// The course sidebar: a "Continue" header driven by progress and a segmented
/// structure bar, then collapsible sections. Lessons are the primary rows;
/// supporting files live in a collapsible "Resources" folder tree per section
/// and at course level. Subtitles are never shown here — they belong to playback.
struct CourseOutline: View {
    @Bindable var model: LibraryModel
    let tree: TreeNode
    @Environment(\.colorScheme) private var scheme

    @State private var expandedSections: Set<String> = []
    @State private var expandedResources: Set<String> = []
    @State private var seededForCourse: String?

    private var groups: [SectionGroup] { CourseTree.sectionGroups(of: tree, progress: model.courseProgress) }
    private var courseResources: [TreeNode] { CourseTree.courseResources(of: tree) }

    var body: some View {
        VStack(spacing: 0) {
            resumeHeader
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(groups) { group in
                            SectionBlock(
                                group: group,
                                depth: 0,
                                model: model,
                                expandedSections: $expandedSections,
                                expandedResources: $expandedResources
                            )
                        }
                        if !courseResources.isEmpty {
                            ResourceDisclosure(
                                id: "\(tree.id)#course-resources",
                                title: "Course resources",
                                resources: courseResources,
                                model: model,
                                isExpanded: expandedResources.contains("\(tree.id)#course-resources"),
                                onToggle: { toggle(&expandedResources, "\(tree.id)#course-resources") },
                                expandedResources: $expandedResources
                            )
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: model.lessonQueue?.current?.id) { _, id in
                    guard let id else { return }
                    expandSectionContaining(lessonID: id)
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas(scheme))
        .onAppear { seedExpansionIfNeeded() }
        .onChange(of: tree.id) { _, _ in seededForCourse = nil; seedExpansionIfNeeded() }
    }

    // MARK: Expansion state

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    /// On first display of a course, open the ancestor chain down to where the
    /// learner should continue (the resume target), so they land on it directly.
    private func seedExpansionIfNeeded() {
        guard seededForCourse != tree.id else { return }
        seededForCourse = tree.id
        if let target = model.resumeTarget {
            expandSectionContaining(lessonID: target.id)
        } else if let first = groups.first(where: { !$0.isSynthetic }) {
            expandedSections.insert(first.id)
        }
    }

    private func expandSectionContaining(lessonID: String) {
        // Expand every ancestor section of the playing lesson so it's visible.
        var toOpen: [String] = []
        func search(_ group: SectionGroup) -> Bool {
            var found = group.directLessons.contains(where: { $0.id == lessonID })
            for case .subsection(let sub) in group.children where search(sub) { found = true }
            if found, !group.isSynthetic { toOpen.append(group.id) }
            return found
        }
        for group in groups { _ = search(group) }
        guard !toOpen.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) { toOpen.forEach { expandedSections.insert($0) } }
    }

    // MARK: Resume header

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
                    SegmentedProgressBar(segments: segments)
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

    private var segments: [(weight: Int, fraction: Double, isComplete: Bool)] {
        groups.filter { $0.total > 0 }.map { (weight: $0.total, fraction: $0.fraction, isComplete: $0.isComplete) }
    }
}

// MARK: - Section block

/// A collapsible section: a header with status, title, count, and a play
/// button, revealing its ordered children (lesson rows and nested subsection
/// blocks) and a resources disclosure. Sections nest recursively.
struct SectionBlock: View {
    let group: SectionGroup
    let depth: Int
    @Bindable var model: LibraryModel
    @Binding var expandedSections: Set<String>
    @Binding var expandedResources: Set<String>
    @Environment(\.colorScheme) private var scheme

    /// First playable lesson in the whole subtree — what "play section" starts.
    private var firstLesson: TreeNode? { CourseTree.lessons(in: group.section).first }
    private var isExpanded: Bool { group.isSynthetic || expandedSections.contains(group.id) }
    private var resourcesID: String { "\(group.id)#resources" }

    var body: some View {
        VStack(spacing: 0) {
            if !group.isSynthetic { header }
            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(group.children) { child in
                        switch child {
                        case .lesson(let lesson):
                            lessonRow(lesson)
                        case .subsection(let sub):
                            SectionBlock(
                                group: sub,
                                depth: depth + 1,
                                model: model,
                                expandedSections: $expandedSections,
                                expandedResources: $expandedResources
                            )
                            .padding(.top, 2)
                        }
                    }
                    if !group.resources.isEmpty {
                        ResourceDisclosure(
                            id: resourcesID,
                            title: "Resources",
                            resources: group.resources,
                            model: model,
                            isExpanded: expandedResources.contains(resourcesID),
                            onToggle: { toggle(&expandedResources, resourcesID) },
                            expandedResources: $expandedResources
                        )
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, group.isSynthetic ? 0 : 6)
                .padding(.top, group.isSynthetic ? 0 : 2)
            }
        }
        .background(
            group.isSynthetic ? Color.clear
                : Theme.card(scheme).opacity(scheme == .dark ? 0.5 : 0.7),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func lessonRow(_ lesson: TreeNode) -> some View {
        LessonRow(
            lesson: lesson,
            isSelected: lesson.id == model.selectedItemID,
            isPlaying: lesson.id == model.lessonQueue?.current?.id,
            progress: model.courseProgress.progress(for: lesson.id),
            durationSeconds: lessonDuration(lesson.id)
        )
        .id(lesson.id)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedItemID = lesson.id
            model.playLesson(lesson)
        }
    }

    private var header: some View {
        Button { toggle(&expandedSections, group.id) } label: {
            HStack(spacing: 8) {
                DisclosureChevron(isOpen: isExpanded)
                statusDot
                Text(group.section.title)
                    .font(Theme.display(depth > 0 ? 12 : 13, .semibold))
                    .foregroundStyle(group.isComplete ? .secondary : (depth > 0 ? .secondary : .primary))
                    .strikethrough(group.isComplete, color: .secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if group.isComplete {
                    Text("DONE")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.done)
                }
                Text("\(group.completed)/\(group.total)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if firstLesson != nil {
                    Button {
                        if let first = firstLesson { model.playLesson(first) }
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Play this section")
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
        }
    }

    @ViewBuilder private var statusDot: some View {
        if group.isComplete {
            Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(Theme.done)
        } else if group.completed > 0 {
            Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
        } else {
            Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func lessonDuration(_ id: String) -> Double? {
        if model.lessonQueue?.current?.id == id, let d = model.playbackEngine?.duration, d > 0 { return d }
        if let d = model.courseProgress.progress(for: id)?.durationSeconds, d > 0 { return d }
        return nil
    }
}

// MARK: - Lesson row

struct LessonRow: View {
    let lesson: TreeNode
    let isSelected: Bool
    let isPlaying: Bool
    let progress: LessonProgress?
    let durationSeconds: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 9) {
            statusGlyph
            Image(systemName: lesson.mediaKind == "audio" ? "music.note" : "play.rectangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isPlaying ? Theme.accent : .primary)
                .frame(width: 16)
            Text(lesson.title)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else if let label = durationSeconds.flatMap({ Duration.lessonLabel(seconds: $0) }) {
                Text(label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(isSelected ? Theme.accent.opacity(scheme == .dark ? 0.22 : 0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .help(lesson.originalName ?? lesson.title)
    }

    @ViewBuilder private var statusGlyph: some View {
        if progress?.isEffectivelyComplete == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.done)
        } else if let f = progress?.fraction, f > 0.01 {
            ProgressRing(fraction: f, size: 13, lineWidth: 2, showsLabel: false)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Resource disclosure + tree

/// A collapsible "Resources" group holding a recursive folder/file tree.
struct ResourceDisclosure: View {
    let id: String
    let title: String
    let resources: [TreeNode]
    @Bindable var model: LibraryModel
    let isExpanded: Bool
    let onToggle: () -> Void
    @Binding var expandedResources: Set<String>
    @Environment(\.colorScheme) private var scheme

    private var fileCount: Int { resources.reduce(0) { $0 + CourseTree.resourceFileCount(of: $1) } }

    var body: some View {
        VStack(spacing: 1) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    DisclosureChevron(isOpen: isExpanded)
                    Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 5).padding(.horizontal, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ResourceTree(nodes: resources, depth: 0, model: model, expandedResources: $expandedResources)
            }
        }
    }
}

/// Recursively renders resource folders (expandable, ZIP-downloadable) and
/// files (selectable, with inline quick actions).
struct ResourceTree: View {
    let nodes: [TreeNode]
    let depth: Int
    @Bindable var model: LibraryModel
    @Binding var expandedResources: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            if node.type == "asset_directory" {
                ResourceFolderRow(node: node, depth: depth, model: model, expandedResources: $expandedResources)
            } else {
                ResourceFileRow(node: node, depth: depth, model: model)
            }
        }
    }
}

struct ResourceFolderRow: View {
    let node: TreeNode
    let depth: Int
    @Bindable var model: LibraryModel
    @Binding var expandedResources: Set<String>
    @Environment(\.colorScheme) private var scheme
    @State private var isWorking = false

    private var isOpen: Bool { expandedResources.contains(node.id) }
    private var children: [TreeNode] {
        (node.children ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
    }
    private var fileCount: Int { CourseTree.resourceFileCount(of: node) }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Color.clear.frame(width: CGFloat(depth) * 14)
                Button {
                    if isOpen { expandedResources.remove(node.id) } else { expandedResources.insert(node.id) }
                } label: {
                    HStack(spacing: 8) {
                        DisclosureChevron(isOpen: isOpen, size: 9)
                        Image(systemName: isOpen ? "folder.fill" : "folder")
                            .font(.system(size: 12)).foregroundStyle(Theme.accentSoft).frame(width: 16)
                        Text(node.title).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(fileCount)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await downloadZip() } } label: {
                    if isWorking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.down.circle").font(.system(size: 12)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isWorking || model.currentClient == nil)
                .help("Download folder as ZIP")
            }
            .padding(.vertical, 4).padding(.horizontal, 9)
            if isOpen {
                ResourceTree(nodes: children, depth: depth + 1, model: model, expandedResources: $expandedResources)
            }
        }
    }

    @MainActor private func downloadZip() async {
        guard let client = model.currentClient else { return }
        isWorking = true
        defer { isWorking = false }
        try? await AssetActions.download(node, client: client)
    }
}

struct ResourceFileRow: View {
    let node: TreeNode
    let depth: Int
    @Bindable var model: LibraryModel
    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false
    @State private var isWorking = false

    private var isSelected: Bool { node.id == model.selectedItemID }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            FileTypeIcon(fileExtension: node.fileExtension, name: node.originalName ?? node.title)
            Text(node.title).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 6)
            if isHovering {
                Button { Task { await download() } } label: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isWorking || model.currentClient == nil)
                .help("Download")
            } else if let size = node.sizeBytes {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if isWorking { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 4).padding(.horizontal, 9)
        .background(isSelected ? Theme.accent.opacity(scheme == .dark ? 0.2 : 0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedItemID = node.id }
        .onHover { isHovering = $0 }
        .help(node.originalName ?? node.title)
    }

    @MainActor private func download() async {
        guard let client = model.currentClient else { return }
        isWorking = true
        defer { isWorking = false }
        try? await AssetActions.download(node, client: client)
    }
}
