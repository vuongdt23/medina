import SwiftUI
import AppKit
import MedinaCore

/// The course sidebar: a Continue card before playback, then styled collapsible
/// sections and a single course-progress footer. Lessons are the primary rows;
/// supporting files live in a collapsible "Resources" folder tree per section
/// and at course level. Subtitles are never shown here — they belong to playback.
struct CourseOutline: View {
    @Bindable var model: LibraryModel
    let tree: TreeNode
    var short = false
    var focusSearchRequest = 0
    var onDismiss: (() -> Void)? = nil
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @AppStorage("compactLessonRows") private var compactRows = false
    @State private var search = ""
    @State private var jumpRequest = 0

    @State private var expandedSections: Set<String> = []
    @State private var expandedResources: Set<String> = []
    @State private var seededForCourse: String?

    private var groups: [SectionGroup] { CourseTree.sectionGroups(of: tree, progress: model.courseProgress) }
    private var courseResources: [TreeNode] { CourseTree.courseResources(of: tree) }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader
            if !short { resumeHeader }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                SectionBlock(
                                    group: group,
                                    depth: 0,
                                    number: groups.prefix(index).filter { !$0.isSynthetic }.count + 1,
                                    model: model,
                                    expandedSections: $expandedSections,
                                    expandedResources: $expandedResources
                                )
                            }
                        } else {
                            searchResults
                        }
                        if search.isEmpty && !courseResources.isEmpty {
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
                }
                .onChange(of: jumpRequest) { _, _ in
                    guard let id = model.lessonQueue?.current?.id else { return }
                    search = ""
                    expandSectionContaining(lessonID: id)
                    Task { @MainActor in
                        // Let the cleared search and expanded sections lay out.
                        await Task.yield()
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            progressFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas(scheme))
        .onAppear { seedExpansionIfNeeded() }
        .onChange(of: tree.id) { _, _ in seededForCourse = nil; search = ""; seedExpansionIfNeeded() }
        .onChange(of: focusSearchRequest) { _, _ in searchFocused = true }
    }

    // MARK: Navigation and search

    private var navigationHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Course content").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { jumpRequest += 1 } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.borderless)
                .disabled(model.lessonQueue?.current == nil)
                .help("Jump to playing lesson")
                .accessibilityLabel("Jump to playing lesson")
                Menu {
                    Toggle("Compact lesson rows", isOn: $compactRows)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Outline density")
                .accessibilityLabel("Outline density")
                if let onDismiss {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search lessons or sections", text: $search)
                    .focused($searchFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear lesson search")
                }
            }
            .padding(9)
            .background(Theme.hairline(scheme), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(Theme.card(scheme))
    }

    @ViewBuilder private var searchResults: some View {
        let results = LessonSearch.results(in: tree, query: search)
        if results.isEmpty {
            Text("No matching lessons")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
        ForEach(results) { result in
            Button {
                if model.lessonQueue?.current?.id != result.id { model.playLesson(result.lesson) }
                model.selectItem(id: result.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if !result.sectionPath.isEmpty {
                        Text(result.sectionPath)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(2).padding(.horizontal, 9)
                    }
                    LessonRow(lesson: result.lesson,
                              isSelected: result.id == model.selectedItemID,
                              isPlaying: result.id == model.lessonQueue?.current?.id,
                              progress: model.courseProgress.progress(for: result.id),
                              durationSeconds: model.courseProgress.progress(for: result.id)?.durationSeconds)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var progressFooter: some View {
        if model.progressEnabled, model.courseProgress.totalCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Course progress")
                    Spacer()
                    Text("\(model.courseProgress.completedCount)/\(model.courseProgress.totalCount) · \(Int(model.courseProgress.fraction * 100))%")
                        .monospacedDigit()
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressBar(fraction: model.courseProgress.fraction)
            }
            .padding(14)
            .background(Theme.card(scheme))
        }
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
        if model.playbackEngine == nil, model.progressEnabled, let target = model.resumeTarget {
            let p = model.courseProgress.progress(for: target.id)
            let started = (p?.positionSeconds ?? 0) > 1
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(started ? "Continue where you left off" : "Start learning")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(target.title)
                            .font(.system(size: 14, weight: .semibold))
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
            }
            .padding(14)
            .background(Theme.card(scheme))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline(scheme)), alignment: .bottom)
        }
    }
}

// MARK: - Section block

/// Section cards carry hierarchy and progress, not another set of play controls.
/// Nested sections use a lighter treatment instead of stacking cards in cards.
struct SectionBlock: View {
    let group: SectionGroup
    let depth: Int
    var number: Int? = nil
    @Bindable var model: LibraryModel
    @Binding var expandedSections: Set<String>
    @Binding var expandedResources: Set<String>
    @Environment(\.colorScheme) private var scheme

    @State private var isHovering = false
    private var containsCurrentLesson: Bool {
        guard let id = model.lessonQueue?.current?.id else { return false }
        return CourseTree.lessons(in: group.section).contains { $0.id == id }
    }
    private var sectionLabel: String {
        if depth > 0 { return "SUBSECTION" }
        return number.map { String(format: "SECTION %02d", $0) } ?? "SECTION"
    }
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
                .padding(.horizontal, group.isSynthetic ? 0 : 8)
                .padding(.bottom, group.isSynthetic ? 0 : 8)
                .overlay(alignment: .leading) {
                    if depth > 0 {
                        Rectangle().fill(Theme.hairline(scheme))
                            .frame(width: 1).padding(.leading, 3)
                    }
                }
            }
        }
        .background {
            if !group.isSynthetic && depth == 0 {
                RoundedRectangle(cornerRadius: 12)
                    .fill(containsCurrentLesson ? Theme.cardSelected(scheme) : Theme.card(scheme))
            }
        }
        .overlay {
            if !group.isSynthetic && depth == 0 {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(containsCurrentLesson ? Theme.accent.opacity(0.22) : Theme.hairline(scheme))
            }
        }
    }

    private func lessonRow(_ lesson: TreeNode) -> some View {
        Button {
            if model.lessonQueue?.current?.id != lesson.id { model.playLesson(lesson) }
            model.selectItem(id: lesson.id)
        } label: {
            LessonRow(
                lesson: lesson,
                isSelected: lesson.id == model.selectedItemID,
                isPlaying: lesson.id == model.lessonQueue?.current?.id,
                progress: model.courseProgress.progress(for: lesson.id),
                durationSeconds: lessonDuration(lesson.id)
            )
        }
        .buttonStyle(.plain)
        .id(lesson.id)
    }

    private var header: some View {
        Button { toggle(&expandedSections, group.id) } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(sectionLabel)
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(containsCurrentLesson ? Theme.accent : .secondary)
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            if group.isComplete {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            }
                            Text("\(group.completed)/\(group.total)").monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(group.isComplete ? Theme.done : .secondary)
                    }
                    Text(group.section.title)
                        .font(.system(size: depth > 0 ? 13 : 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DisclosureChevron(isOpen: isExpanded, size: 11)
            }
            .padding(.vertical, depth > 0 ? 10 : 14)
            .padding(.horizontal, 13)
            .background(isHovering ? Theme.hairline(scheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(group.section.title)
        .accessibilityValue("\(group.completed) of \(group.total) lessons completed, \(isExpanded ? "expanded" : "collapsed")")
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
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
    @AppStorage("compactLessonRows") private var compactRows = false

    var body: some View {
        HStack(spacing: 10) {
            statusGlyph.frame(width: 18)
            Text(lesson.title)
                .font(.system(size: 14, weight: isPlaying ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(compactRows ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let label = durationSeconds.flatMap({ Duration.lessonLabel(seconds: $0) }) {
                Text(label)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, compactRows ? 6 : 10).padding(.horizontal, 10)
        .frame(minHeight: compactRows ? 32 : 44)
        .background(isSelected ? Theme.cardSelected(scheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if isPlaying {
                Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isPlaying ? "Current lesson" : (progress?.isEffectivelyComplete == true ? "Completed" : ""))
        .help(lesson.originalName ?? lesson.title)
    }

    @ViewBuilder private var statusGlyph: some View {
        if isPlaying {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
        } else if progress?.isEffectivelyComplete == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14)).foregroundStyle(Theme.done)
        } else if let f = progress?.fraction, f > 0.01 {
            ProgressRing(fraction: f, size: 15, lineWidth: 2, showsLabel: false)
        } else {
            Image(systemName: lesson.mediaKind == "audio" ? "music.note" : "play.rectangle")
                .font(.system(size: 14)).foregroundStyle(.secondary)
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
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
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
                        Text(node.title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(2)
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
            Text(node.title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(2)
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
        .onTapGesture { model.selectItem(id: node.id) }
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
