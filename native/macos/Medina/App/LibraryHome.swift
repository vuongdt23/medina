import SwiftUI
import MedinaCore

/// The home screen: a searchable, full-width grid of course cards over a
/// header carrying the library identity, search, and connection controls.
struct LibraryHome: View {
    @Bindable var model: LibraryModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool

    private var filtered: [Course] {
        let q = model.courseSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.courses }
        return model.courses.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline(scheme))
            grid
        }
        .background(Theme.canvas(scheme))
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 22)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.libraries.first?.name ?? "Library")
                        .font(Theme.display(22, .bold))
                    Text("\(model.courses.count) courses")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                connectionControls
            }
            searchField
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
        .background(Theme.card(scheme))
    }

    private var connectionControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.errorMessage == nil && model.connectionMessage.hasPrefix("Connected") ? Theme.done : Color.orange)
                    .frame(width: 7, height: 7)
                Text(model.connectionMessage)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                if model.status?.state == "scanning" { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            Button { model.showConnectionSheet = true } label: {
                Image(systemName: "server.rack")
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Server settings")
            Button { Task { await model.rescan() } } label: {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Rescan library")
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search courses", text: $model.courseSearch)
                .textFieldStyle(.plain).font(.system(size: 13.5))
                .focused($searchFocused)
            if !model.courseSearch.isEmpty {
                Button { model.courseSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Theme.canvas(scheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline(scheme)))
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        )
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.courses.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(model.courses.isEmpty ? "No courses indexed yet." : "No courses match “\(model.courseSearch)”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)],
                          spacing: 18) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, course in
                        CourseCover(
                            course: course,
                            isLastOpened: course.id == model.selectedCourseID,
                            progress: course.id == model.selectedCourseID ? model.courseProgress : nil,
                            onOpen: { Task { await model.openCourse(course) } }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .animation(.easeOut(duration: 0.28).delay(Double(min(index, 16)) * 0.02),
                                   value: filtered.count)
                    }
                }
                .padding(22)
            }
        }
    }
}
