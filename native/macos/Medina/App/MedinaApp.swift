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
    var courseProgress: CourseProgress = .empty
    var progressEnabled = false
    var courseSearch = ""
    /// Which top-level screen is showing. The library grid is the anchor;
    /// opening a card pushes into a focused course workspace.
    enum Screen: Equatable { case library; case course(String) }
    var route: Screen = .library
    private var lastReportedAt: Date = .distantPast
    private var lastReportedLessonID: String?
    private var profileID: UUID = {
        let key = "medinaProfileID"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()
    private var client: MedinaAPIClient?
    var currentClient: MedinaAPIClient? { client }
    var profileIdentifier: String { profileID.uuidString }
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
            progressEnabled = info?.capabilities?["progress"] == true
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
            if let selectedCourseID {
                await loadTree(courseID: selectedCourseID, token: treeRequestToken)
                await loadProgress(courseID: selectedCourseID)
            }
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
        selectedItemID = lesson.id
        playbackEngine?.play()
        lastReportedLessonID = nil
        lastReportedAt = .distantPast
    }

    /// Plays a lesson identified by id within the current tree (used by Resume
    /// and the outline rows). No-op when the id is not a playable lesson.
    func playLesson(id: String) {
        guard let tree, let lesson = CourseTree.lessons(in: tree).first(where: { $0.id == id }) else { return }
        playLesson(lesson)
    }

    /// The lesson the "Continue" affordance should start, if any.
    var resumeTarget: TreeNode? {
        guard let tree else { return nil }
        return CourseTree.resumeTarget(in: tree, progress: courseProgress)
    }

    func playNext() {
        reportPlaybackProgress(force: true)
        guard var queue = lessonQueue, let lesson = queue.moveNext() else { return }
        lessonQueue = queue
        loadQueuedLesson(lesson)
    }

    func playPrevious() {
        reportPlaybackProgress(force: true)
        guard var queue = lessonQueue, let lesson = queue.movePrevious() else { return }
        lessonQueue = queue
        loadQueuedLesson(lesson)
    }

    func stopPlayback() {
        reportPlaybackProgress(force: true)
        playbackEngine?.shutdown()
        playbackEngine = nil
        lessonQueue = nil
    }

    private func advanceAfterNaturalEnd() {
        // A lesson that played to its end is complete regardless of the
        // position the player last reported.
        markCurrentLessonComplete()
        guard var queue = lessonQueue, let current = queue.current,
              let next = queue.naturalEOF(for: current.id, autoplay: true) else { return }
        lessonQueue = queue
        loadQueuedLesson(next)
    }

    /// Reports the active lesson's position to the server, throttled to roughly
    /// once every 5 seconds unless `force` (stop, track change) is set.
    func reportPlaybackProgress(force: Bool = false) {
        guard progressEnabled, let client, let engine = playbackEngine,
              let lesson = lessonQueue?.current else { return }
        let now = Date()
        let switched = lastReportedLessonID != lesson.id
        guard force || switched || now.timeIntervalSince(lastReportedAt) >= 5 else { return }
        lastReportedAt = now
        lastReportedLessonID = lesson.id
        let position = engine.currentTime
        let duration = engine.duration
        let complete = duration > 0 && position / duration >= 0.9
        var record = LessonProgress(itemId: lesson.id, positionSeconds: position,
                                    durationSeconds: duration, completed: complete)
        updateLocalProgress(record)
        Task { [profileIdentifier] in
            if let stored = try? await client.putLessonProgress(id: lesson.id, profileID: profileIdentifier, record) {
                record = stored
            }
        }
    }

    private func markCurrentLessonComplete() {
        guard progressEnabled, let client, let lesson = lessonQueue?.current else { return }
        let duration = playbackEngine?.duration ?? 0
        let record = LessonProgress(itemId: lesson.id, positionSeconds: duration,
                                    durationSeconds: duration, completed: true)
        updateLocalProgress(record)
        lastReportedLessonID = lesson.id
        Task { [profileIdentifier] in
            _ = try? await client.putLessonProgress(id: lesson.id, profileID: profileIdentifier, record)
        }
    }

    /// Optimistically folds a new record into the in-memory course progress so
    /// the outline and sidebar update immediately, before the server round-trip.
    private func updateLocalProgress(_ record: LessonProgress) {
        var next = courseProgress
        let wasComplete = next.lessons[record.itemId]?.isEffectivelyComplete ?? false
        next.lessons[record.itemId] = record
        if record.isEffectivelyComplete && !wasComplete {
            next.completedCount = min(next.totalCount == 0 ? next.completedCount + 1 : next.totalCount,
                                      next.completedCount + 1)
        }
        courseProgress = next
    }

    private func loadQueuedLesson(_ lesson: TreeNode) {
        guard let client, let stream = lesson.streamUrl else { return }
        playbackEngine?.load(url: client.resolve(stream), title: lesson.title)
        selectedItemID = lesson.id
        playbackEngine?.play()
        lastReportedLessonID = nil
        lastReportedAt = .distantPast
    }

    func selectCourse(_ course: Course) async {
        let token = UUID()
        treeRequestToken = token
        selectedCourseID = course.id
        UserDefaults.standard.set(course.id, forKey: "selectedCourseID")
        selectedItemID = nil
        courseProgress = .empty
        guard client != nil else {
            if let cached = cache?.load() { tree = cached.trees[course.id] }
            return
        }
        await loadTree(courseID: course.id, token: token)
        await loadProgress(courseID: course.id)
    }

    /// Pushes into the course focus screen and loads its content. Switching to
    /// a different course stops any playback bound to the previous course.
    func openCourse(_ course: Course) async {
        if selectedCourseID != course.id { stopPlayback() }
        route = .course(course.id)
        await selectCourse(course)
    }

    /// Returns to the library grid and stops playback — the player belongs to
    /// the course being left, so it must not carry over to another course.
    func backToLibrary() {
        stopPlayback()
        route = .library
    }

    /// Fetches aggregate course progress for the active profile. Progress is a
    /// best-effort overlay; failures never block browsing or playback.
    func loadProgress(courseID: String) async {
        guard progressEnabled, let client else { return }
        do {
            let incoming = try await client.courseProgress(courseID: courseID, profileID: profileIdentifier)
            guard selectedCourseID == courseID else { return }
            courseProgress = incoming
        } catch {
            // Keep whatever we had; progress is non-essential.
        }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.canvas(scheme).ignoresSafeArea()
            switch model.route {
            case .library:
                LibraryHome(model: model)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            case .course:
                CourseFocus(model: model)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .animation(.easeInOut(duration: 0.32), value: model.route)
        .task {
            if !model.showConnectionSheet { await model.connect() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.status?.state == "scanning" ? 1 : 10))
                await model.refresh()
            }
        }
        .sheet(isPresented: $model.showConnectionSheet) {
            ConnectionSetupView(model: model)
                .frame(width: 520, height: 440)
        }
        .alert("Medina", isPresented: Binding(get: { model.errorMessage != nil && !model.showConnectionSheet }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
