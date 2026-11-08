import SwiftUI
import MedinaCore

/// The redesigned Library homepage keeps discovery, resuming, and course
/// browsing in one stable vertical hierarchy. Non-empty search replaces the
/// shelves with grouped global results while preserving the top bar.
struct LibraryHome: View {
    @Bindable var model: LibraryModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    private var query: String {
        model.courseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline(scheme))
            pageBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas(scheme))
        .task(id: model.courseSearch) {
            await model.performLibrarySearch(model.courseSearch)
        }
        .onExitCommand {
            if !model.courseSearch.isEmpty {
                model.courseSearch = ""
                searchFocused = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.libraries.first?.name ?? "Library")
                        .font(Theme.display(22, .bold))
                        .lineLimit(1)
                    Text("\(model.courses.count) courses")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                connectionControls
            }
            searchField
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(Theme.card(scheme))
        .accessibilityElement(children: .contain)
    }

    private var connectionControls: some View {
        HStack(spacing: 11) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Medina settings")
            .accessibilityLabel("Settings")

            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? Theme.done : Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    Text(model.connectionMessage)
                    Text(isConnected ? "Connected" : "Offline")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if model.status?.state == "scanning" {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server status")
            .accessibilityValue(model.connectionMessage)
            .help(model.connectionMessage)

            Button { model.showConnectionSheet = true } label: {
                Image(systemName: "server.rack")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Server settings")
            .accessibilityLabel("Server settings")

            Button { Task { await model.rescan() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rescan library")
            .accessibilityLabel("Rescan library")
        }
    }

    private var isConnected: Bool {
        model.errorMessage == nil && model.connectionMessage.hasPrefix("Connected")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search courses, lessons, sections, and resources", text: $model.courseSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onSubmit {
                    if let first = model.searchResults.first {
                        Task { await model.openSearchResult(first) }
                    }
                }
            if model.searchIsLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Searching")
            }
            if !model.courseSearch.isEmpty {
                Button {
                    model.courseSearch = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear library search")
            } else {
                Text("⌘F")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.hairline(scheme), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.canvas(scheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline(scheme)))
        .frame(maxWidth: 620, alignment: .leading)
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    // MARK: Body

    @ViewBuilder private var pageBody: some View {
        if query.isEmpty {
            browsingBody
        } else {
            searchBody
        }
    }

    private var browsingBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if model.recentIsLoading && model.recentItems.isEmpty {
                    continueSkeleton
                } else if !model.recentItems.isEmpty {
                    continueWatching
                }
                courseCatalog
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.browse")
    }

    private var continueSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Continue Watching", subtitle: "Loading recent lessons…")
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .fill(Theme.card(scheme))
                        .frame(width: 270, height: 150)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading Continue Watching")
        }
    }

    private var continueWatching: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Continue Watching", subtitle: model.recentMessage)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(model.recentItems) { item in
                        ContinueWatchingCard(item: item, client: model.currentClient) {
                            Task { await model.openRecent(item) }
                        }
                    }
                }
                .padding(.bottom, 5)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("library.continue-watching")
    }

    @ViewBuilder private var courseCatalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("All Courses", subtitle: "\(model.courses.count) available")
                .accessibilityAddTraits(.isHeader)
            if model.courses.isEmpty {
                ContentUnavailableView("No courses indexed yet", systemImage: "tray",
                                       description: Text("Connect to a server with indexed course content, or rescan the library."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 54)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 18)], spacing: 18) {
                    ForEach(Array(model.courses.enumerated()), id: \.element.id) { index, course in
                        CourseCover(
                            course: course,
                            isLastOpened: course.id == model.selectedCourseID,
                            progress: course.progress,
                            client: model.currentClient,
                            onOpen: { Task { await model.openCourse(course) } }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(Double(min(index, 10)) * 0.015),
                                   value: model.courses.count)
                    }
                }
            }
        }
        .accessibilityIdentifier("library.all-courses")
    }

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.display(18, .bold))
            Spacer()
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: Search

    private var searchBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Search Results").font(Theme.display(20, .bold))
                        Text(resultSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.searchUsesLocalFallback {
                        Chip("Course titles only", systemImage: "wifi.slash", tint: .orange)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if let message = model.searchMessage {
                    Label(message, systemImage: model.searchUsesLocalFallback ? "exclamationmark.triangle" : "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10))
                }

                if model.searchResults.isEmpty && !model.searchIsLoading {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                           description: Text("Try a different title, lesson, section, or resource name."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 34)
                } else {
                    ForEach(searchGroups, id: \.type) { group in
                        SearchResultGroup(type: group.type, items: group.items,
                                          client: model.currentClient) { result in
                            Task { await model.openSearchResult(result) }
                        }
                    }
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.search-results")
    }

    private var resultSummary: String {
        let count = model.searchResults.count
        if model.searchIsLoading && count > 0 { return "Refreshing \(count) results for “\(query)”…" }
        if model.searchIsLoading { return "Searching for “\(query)”…" }
        return "\(count) \(count == 1 ? "result" : "results") for “\(query)”"
    }

    private var searchGroups: [(type: String, items: [SearchResult])] {
        let known = ["course", "lesson", "section"]
        var groups = known.compactMap { type -> (type: String, items: [SearchResult])? in
            let items = model.searchResults.filter { $0.type == type }
            return items.isEmpty ? nil : (type, items)
        }
        let resources = model.searchResults.filter { $0.type == "asset" || $0.type == "asset_directory" }
        if !resources.isEmpty { groups.append(("asset", resources)) }
        return groups
    }
}

private struct ContinueWatchingCard: View {
    let item: RecentProgressItem
    let client: MedinaAPIClient?
    let onResume: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: onResume) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(colors: Theme.coverGradients[Theme.coverIndex(for: item.coursePath)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white.opacity(0.75))
                    ServerThumbnail(path: item.thumbnailUrl, client: client)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .frame(height: 88)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(item.coursePath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressBar(fraction: item.fraction)
                    HStack {
                        Text("Resume")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                        Text(timeLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(11)
            }
            .frame(width: 270)
            .background(Theme.card(scheme))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.hairline(scheme)))
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.07), radius: hovering ? 10 : 4, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Resume \(item.title)")
        .accessibilityValue("\(Int(item.fraction * 100)) percent complete, \(item.coursePath)")
    }

    private var timeLabel: String {
        let elapsed = Duration.lessonLabel(seconds: item.positionSeconds) ?? "0:00"
        guard let total = Duration.lessonLabel(seconds: item.durationSeconds) else { return elapsed }
        return "\(elapsed) / \(total)"
    }
}

private struct SearchResultGroup: View {
    let type: String
    let items: [SearchResult]
    let client: MedinaAPIClient?
    let onOpen: (SearchResult) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.display(16, .bold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, result in
                    SearchResultRow(result: result, client: client, onOpen: { onOpen(result) })
                    if index < items.count - 1 { Divider().padding(.leading, 66) }
                }
            }
            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.hairline(scheme)))
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch type {
        case "course": return "Courses"
        case "lesson": return "Lessons"
        case "section": return "Sections"
        default: return "Resources"
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let client: MedinaAPIClient?
    let onOpen: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.coverGradients[Theme.coverIndex(for: result.coursePath)].first?.opacity(0.7) ?? Theme.accent)
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                    ServerThumbnail(path: result.thumbnailUrl, client: client)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .frame(width: 46, height: 46)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(result.type.capitalized)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .textCase(.uppercase)
                        Text(result.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(result.coursePath)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(hovering ? Theme.cardSelected(scheme).opacity(0.55) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(result.type.capitalized), \(result.title)")
        .accessibilityValue(result.coursePath)
        .accessibilityHint("Open result")
    }

    private var symbol: String {
        switch result.type {
        case "course": return "books.vertical.fill"
        case "lesson": return "play.fill"
        case "section": return "text.book.closed.fill"
        default: return "doc.fill"
        }
    }
}
