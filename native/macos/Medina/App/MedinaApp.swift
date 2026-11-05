import AVKit
import SwiftUI
import MedinaCore
import MedinaPlayback

@main
struct MedinaApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryWindow()
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
@Observable
final class LibraryModel {
    var origin = UserDefaults.standard.string(forKey: "serverOrigin") ?? "http://127.0.0.1:17843"
    var connectionMessage = "Not connected"
    var showConnectionSheet = !UserDefaults.standard.bool(forKey: "hasConnectedSuccessfully")
    var errorMessage: String?
    var info: SystemInfo?
    var libraries: [Library] = []
    var courses: [Course] = []
    var selectedCourseID: String? = UserDefaults.standard.string(forKey: "selectedCourseID")
    var tree: TreeNode?
    var selectedItemID: String?
    var status: IndexStatus?
    var playbackEngine: AVPlaybackEngine?
    var lessonQueue: LessonQueue?
    var isWorking = false
    private var profileID: UUID = {
        let key = "medinaProfileID"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()
    private var client: MedinaAPIClient?
    private var cache: LibraryCache?
    private var treeRequestToken = UUID()
    private var connectionToken = UUID()

    func connect() async {
        let token = UUID()
        connectionToken = token
        isWorking = true
        defer { isWorking = false }
        do {
            let normalized = try ServerProfile.normalizedOrigin(origin)
            origin = normalized.absoluteString
            UserDefaults.standard.set(origin, forKey: "serverOrigin")
            if UserDefaults.standard.string(forKey: "profileOrigin") != origin {
                profileID = UUID()
                UserDefaults.standard.set(profileID.uuidString, forKey: "medinaProfileID")
                UserDefaults.standard.set(origin, forKey: "profileOrigin")
            }
            let profile = ServerProfile(id: profileID, origin: normalized)
            let cache = LibraryCache(profileID: profileID)
            self.cache = cache
            if let snapshot = cache.load() {
                libraries = snapshot.libraries
                courses = snapshot.courses
                if let selectedCourseID { tree = snapshot.trees[selectedCourseID] }
            }
            let api = MedinaAPIClient(profile: profile)
            try await api.health()
            guard connectionToken == token else { return }
            info = try await api.systemInfo()
            guard connectionToken == token else { return }
            libraries = try await api.libraries()
            guard connectionToken == token else { return }
            guard let library = libraries.first else { throw MedinaAPIError.noLibrary }
            self.client = api
            self.status = try? await api.indexStatus()
            courses = try await api.courses(libraryID: library.id)
            guard connectionToken == token else { return }
            connectionMessage = "Connected · API \(info?.apiVersion ?? "?")"
            UserDefaults.standard.set(true, forKey: "hasConnectedSuccessfully")
            errorMessage = nil
            showConnectionSheet = false
            persistCache()
            if let selectedCourseID { await loadTree(courseID: selectedCourseID, token: treeRequestToken) }
        } catch {
            guard connectionToken == token else { return }
            connectionMessage = "Connection failed"
            showConnectionSheet = true
            errorMessage = error.localizedDescription
            if let cached = cache?.load() {
                libraries = cached.libraries
                courses = cached.courses
                if let selectedCourseID { tree = cached.trees[selectedCourseID] }
            }
        }
    }

    func playLesson(_ lesson: TreeNode) {
        guard lesson.type == "lesson", let client, let stream = lesson.streamUrl else { return }
        let lessons = tree.map { CourseTree.lessons(in: $0) } ?? [lesson]
        lessonQueue = LessonQueue(lessons: lessons, startingAt: lesson.id)
        if playbackEngine == nil {
            let engine = AVPlaybackEngine()
            engine.onNaturalEnd = { [weak self] in self?.advanceAfterNaturalEnd() }
            playbackEngine = engine
        }
        playbackEngine?.load(url: client.resolve(stream), title: lesson.title)
    }

    func playNext() {
        guard var queue = lessonQueue, let lesson = queue.moveNext() else { return }
        lessonQueue = queue
        loadQueuedLesson(lesson)
    }

    func playPrevious() {
        guard var queue = lessonQueue, let lesson = queue.movePrevious() else { return }
        lessonQueue = queue
        loadQueuedLesson(lesson)
    }

    func stopPlayback() {
        playbackEngine?.shutdown()
        playbackEngine = nil
        lessonQueue = nil
    }

    private func advanceAfterNaturalEnd() {
        guard var queue = lessonQueue, let current = queue.current,
              let next = queue.naturalEOF(for: current.id, autoplay: true) else { return }
        lessonQueue = queue
        loadQueuedLesson(next)
    }

    private func loadQueuedLesson(_ lesson: TreeNode) {
        guard let client, let stream = lesson.streamUrl else { return }
        playbackEngine?.load(url: client.resolve(stream), title: lesson.title)
    }

    func selectCourse(_ course: Course) async {
        let token = UUID()
        treeRequestToken = token
        selectedCourseID = course.id
        UserDefaults.standard.set(course.id, forKey: "selectedCourseID")
        selectedItemID = nil
        guard client != nil else {
            if let cached = cache?.load() { tree = cached.trees[course.id] }
            return
        }
        await loadTree(courseID: course.id, token: token)
    }

    private func loadTree(courseID: String, token: UUID) async {
        guard let client else { return }
        do {
            let incoming = try await client.tree(courseID: courseID)
            guard treeRequestToken == token, selectedCourseID == courseID else { return }
            if let current = tree, current.id == incoming.id {
                tree = CourseTree.preservingCanonicalSections(old: current, new: incoming, scanInProgress: status?.state == "scanning")
            } else { tree = incoming }
            errorMessage = nil
            persistCache()
        } catch {
            guard treeRequestToken == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard let client else { await connect(); return }
        do {
            let previousState = status?.state
            let updatedStatus = try await client.indexStatus()
            status = updatedStatus
            if let library = libraries.first {
                courses = try await client.courses(libraryID: library.id)
            }
            let refreshTree = updatedStatus.state == "scanning" || (previousState == "scanning" && updatedStatus.state != "scanning")
            if refreshTree, let selectedCourseID {
                await loadTree(courseID: selectedCourseID, token: treeRequestToken)
            }
            persistCache()
        } catch { errorMessage = error.localizedDescription }
    }

    func rescan() async {
        guard let client else { return }
        do { try await client.startScan(); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    private func persistCache() {
        guard let cache else { return }
        cache.save(LibrarySnapshot(savedAt: Date(), libraries: libraries, courses: courses,
                                   trees: tree.map { [$0.id: $0] } ?? [:]))
    }
}

struct LibraryWindow: View {
    @State private var model = LibraryModel()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label(model.connectionMessage, systemImage: model.errorMessage == nil ? "network" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Server…") { model.showConnectionSheet = true }
                    Button { Task { await model.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Rescan library")
                }.padding(.horizontal, 12).padding(.bottom, 8)
                List(model.courses, selection: Binding(get: { model.selectedCourseID }, set: { id in
                    guard let item = model.courses.first(where: { $0.id == id }) else { return }
                    Task { await model.selectCourse(item) }
                })) { course in
                    Text(course.title).tag(course.id as String?)
                }
                if let status = model.status {
                    HStack {
                        Text(status.state ?? "unknown")
                        if status.state == "scanning" { ProgressView().controlSize(.small) }
                        Spacer()
                        Text("\(status.itemCount ?? 0) indexed")
                    }.font(.caption).foregroundStyle(.secondary).padding(10)
                }
            }
            .navigationTitle(model.libraries.first?.name ?? "Library")
            .task {
                if !model.showConnectionSheet { await model.connect() }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(model.status?.state == "scanning" ? 1 : 10))
                    await model.refresh()
                }
            }
        } detail: {
            detail
        }
        .sheet(isPresented: $model.showConnectionSheet) {
            ConnectionSetupView(model: model)
                .frame(width: 520, height: 440)
        }
        .alert("Medina", isPresented: Binding(get: { model.errorMessage != nil && !model.showConnectionSheet }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var detail: some View {
        if let tree = model.tree {
            HSplitView {
                List(CourseTree.outline(of: tree), selection: $model.selectedItemID) { entry in
                    OutlineRow(entry: entry)
                        .tag(entry.id as String?)
                }
                .frame(minWidth: 300)
                VStack(spacing: 0) {
                    if let entry = CourseTree.outline(of: tree).first(where: { $0.id == model.selectedItemID }) {
                        ItemDetails(item: entry.item) { lesson in model.playLesson(lesson) }
                    } else {
                        ContentUnavailableView("Choose a lesson or file", systemImage: "rectangle.split.3x1")
                    }
                    if let engine = model.playbackEngine {
                        Divider()
                        PlaybackPanel(
                            engine: engine,
                            lessonTitle: model.lessonQueue?.current?.title ?? engine.title,
                            hasPrevious: model.lessonQueue?.previous != nil,
                            hasNext: model.lessonQueue?.next != nil,
                            onPrevious: { model.playPrevious() },
                            onNext: { model.playNext() },
                            onStop: { model.stopPlayback() }
                        )
                    }
                }
                .frame(minWidth: 340)
            }
            .navigationTitle(tree.title)
        } else {
            ContentUnavailableView("Connect to a Medina server", systemImage: "server.rack",
                                   description: Text("Enter the address of your self-hosted Medina server."))
        }
    }
}

struct ConnectionSetupView: View {
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to Medina").font(.title2).bold()
                    Text("Enter the address of your self-hosted server.").foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Server address").font(.headline)
                TextField("http://127.0.0.1:17843", text: $model.origin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { Task { await model.connect() } }
                Text("Use the server’s origin only (for example, http://192.168.1.20:17843). Medina connects directly; it does not install or start the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Testing connection…").foregroundStyle(.secondary)
                }
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if model.connectionMessage.hasPrefix("Connected"), let info = model.info {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.connectionMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Medina \(info.version ?? "") · API \(info.apiVersion ?? "?")").font(.caption).foregroundStyle(.secondary)
                    if let capabilities = info.capabilities {
                        Text(capabilitySummary(capabilities)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
            HStack {
                Button("Continue Offline") {
                    model.showConnectionSheet = false
                    dismiss()
                }
                .help("Browse any previously cached library metadata")
                Spacer()
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isWorking)
            }
        }
        .padding(28)
        .background(.regularMaterial)
    }

    private func capabilitySummary(_ capabilities: [String: Bool]) -> String {
        let supported = capabilities.filter(\.value).keys.sorted()
        return supported.isEmpty ? "No optional capabilities reported" : "Available: " + supported.joined(separator: ", ")
    }
}

struct OutlineRow: View {
    let entry: OutlineEntry
    var body: some View {
        Label {
            Text(entry.item.title).lineLimit(1)
        } icon: {
            Image(systemName: icon).foregroundStyle(entry.item.type == "lesson" ? .primary : .secondary)
        }
        .padding(.leading, CGFloat(entry.depth) * 12)
        .help(entry.item.originalName ?? entry.item.title)
    }
    private var icon: String {
        switch entry.item.type {
        case "lesson": return entry.item.mediaKind == "audio" ? "music.note" : "play.rectangle"
        case "section": return "folder"
        case "asset_directory": return "folder"
        case "subtitle": return "captions.bubble"
        default: return "doc"
        }
    }
}

struct PlaybackPanel: View {
    let engine: AVPlaybackEngine
    let lessonTitle: String
    let hasPrevious: Bool
    let hasNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            NativeAVPlayerView(player: engine.player)
                .frame(minHeight: 210, idealHeight: 260)
                .accessibilityLabel("Video player: \(lessonTitle)")
            HStack(spacing: 12) {
                Button(action: onPrevious) { Image(systemName: "backward.end.fill") }
                    .disabled(!hasPrevious).help("Previous lesson")
                Text(lessonTitle).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if !engine.audioOptions.isEmpty {
                    Menu("Audio") {
                        ForEach(Array(engine.audioOptions.enumerated()), id: \.offset) { index, title in
                            Button(title) { engine.selectAudioTrack(index) }
                        }
                    }
                }
                if !engine.subtitleOptions.isEmpty {
                    Menu("Subtitles") {
                        Button("Off") { engine.selectSubtitleTrack(nil) }
                        ForEach(Array(engine.subtitleOptions.enumerated()), id: \.offset) { index, title in
                            Button(title) { engine.selectSubtitleTrack(index) }
                        }
                    }
                }
                Menu("Speed") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed, format: .number)×") { engine.setSpeed(Float(speed)) }
                    }
                }
                Button(action: onNext) { Image(systemName: "forward.end.fill") }
                    .disabled(!hasNext).help("Next lesson")
                Button(action: onStop) { Image(systemName: "xmark") }
                    .help("Stop playback")
            }
            if case .failed(let message) = engine.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}

struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = AVLayerVideoGravity.resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct ItemDetails: View {
    let item: TreeNode
    var onPlay: (TreeNode) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(item.type.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: item.type == "lesson" ? "play.rectangle" : "doc")
                .font(.caption).foregroundStyle(.secondary)
            Text(item.title).font(.title2).bold()
            if let name = item.originalName { Text(name).font(.callout).foregroundStyle(.secondary) }
            if let size = item.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption) }
            if item.type == "lesson" {
                Button {
                    onPlay(item)
                } label: {
                    Label("Play from beginning", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else if let url = item.contentUrl {
                Text(url).font(.caption.monospaced()).textSelection(.enabled)
            }
            Spacer()
        }.padding(24).frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
    }
}
