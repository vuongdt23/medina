import Foundation

public struct Course: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public var originalName: String?
    public var position: Int?
}

public struct CoursePage: Decodable, Sendable {
    public var items: [Course]?
    public var nextCursor: String?
}

public struct APIErrorEnvelope: Decodable, Sendable {
    public struct Detail: Decodable, Sendable {
        public var code: String?
        public var message: String?
    }
    public var error: Detail?
}

public struct SystemInfo: Decodable, Sendable {
    public var name: String?
    public var version: String?
    public var apiVersion: String?
    public var capabilities: [String: Bool]?
}

public struct Library: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

/// Per-profile playback progress for a single lesson, as stored by the server.
public struct LessonProgress: Codable, Hashable, Sendable {
    public var itemId: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var completed: Bool
    public var updatedAt: String?

    public init(itemId: String, positionSeconds: Double = 0, durationSeconds: Double = 0,
                completed: Bool = false, updatedAt: String? = nil) {
        self.itemId = itemId
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.completed = completed
        self.updatedAt = updatedAt
    }

    /// Fraction watched in `0...1`, clamped; zero when the duration is unknown.
    public var fraction: Double {
        guard durationSeconds > 0 else { return completed ? 1 : 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }

    /// A lesson counts as finished when the server marked it complete or the
    /// viewer reached the last stretch of a lesson with a known duration.
    public var isEffectivelyComplete: Bool {
        completed || (durationSeconds > 0 && positionSeconds / durationSeconds >= 0.9)
    }
}

/// Aggregate course progress: a record per lesson that has any progress, plus
/// completion counts spanning every lesson in the course (including untouched).
public struct CourseProgress: Codable, Hashable, Sendable {
    public var lessons: [String: LessonProgress]
    public var completedCount: Int
    public var totalCount: Int

    public init(lessons: [String: LessonProgress] = [:], completedCount: Int = 0, totalCount: Int = 0) {
        self.lessons = lessons
        self.completedCount = completedCount
        self.totalCount = totalCount
    }

    public static let empty = CourseProgress()

    /// Completion fraction of the whole course in `0...1`.
    public var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }

    public func progress(for lessonID: String) -> LessonProgress? { lessons[lessonID] }
}

public struct IndexStatus: Decodable, Sendable {
    public var libraryId: String?
    public var state: String?
    public var itemCount: Int?
    public var progress: Progress?
    public var lastScanCompletedAt: String?
    public var lastScanError: String?

    public struct Progress: Decodable, Sendable {
        public var phase: String?
        public var entriesVisited: Int?
        public var currentDirectory: String?
        public var elapsedMs: Int?
    }
}

/// Recursive API tree DTO. Collection keys are optional because the Go API
/// omits empty typed collections and emits null for empty asset-directory children.
public struct TreeNode: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var title: String
    public var originalName: String?
    public var position: Int?
    public var mediaKind: String?
    public var mimeType: String?
    public var fileExtension: String?
    public var sizeBytes: Int64?
    public var streamUrl: String?
    public var contentUrl: String?
    public var children: [TreeNode]?
    public var sections: [TreeNode]?
    public var lessons: [TreeNode]?
    public var assets: [TreeNode]?
    public var subtitles: [TreeNode]?

    public init(id: String, type: String, title: String, originalName: String? = nil,
                position: Int? = nil, mediaKind: String? = nil, mimeType: String? = nil,
                extension fileExtension: String? = nil, sizeBytes: Int64? = nil, streamUrl: String? = nil,
                contentUrl: String? = nil, children: [TreeNode]? = nil,
                sections: [TreeNode]? = nil, lessons: [TreeNode]? = nil,
                assets: [TreeNode]? = nil, subtitles: [TreeNode]? = nil) {
        self.id = id; self.type = type; self.title = title; self.originalName = originalName
        self.position = position; self.mediaKind = mediaKind; self.mimeType = mimeType
        self.fileExtension = fileExtension; self.sizeBytes = sizeBytes; self.streamUrl = streamUrl
        self.contentUrl = contentUrl; self.children = children; self.sections = sections
        self.lessons = lessons; self.assets = assets; self.subtitles = subtitles
    }

    /// Navigable children share positions assigned before the server splits them
    /// into typed arrays. Attachments are deliberately excluded.
    public var orderedNavigableChildren: [TreeNode] {
        ((sections ?? []) + (lessons ?? []))
            .sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
    }

    public var allAssets: [TreeNode] {
        (assets ?? []) + (subtitles ?? [])
    }

    /// Assets that should be surfaced as browsable *resources* — everything in
    /// `assets` (files and `asset_directory` folders), excluding `subtitles`.
    /// Subtitles are side-loaded into playback, never shown as downloadable files.
    public var resourceAssets: [TreeNode] {
        (assets ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, originalName, position, mediaKind, mimeType, sizeBytes
        case streamUrl, contentUrl, children, sections, lessons, assets, subtitles
        case fileExtension = "extension"
    }
}

public struct OutlineEntry: Identifiable, Sendable {
    public let item: TreeNode
    public let depth: Int
    public var id: String { item.id }
}

/// One section's content, grouped for the sectioned sidebar. Sections nest:
/// a group holds its ordered children (direct lessons and subsection groups),
/// its own resource files/folders, and completion counts over the whole subtree.
public struct SectionGroup: Identifiable, Sendable {
    /// An ordered child of a section: either a playable lesson or a subsection.
    public enum Child: Identifiable, Sendable {
        case lesson(TreeNode)
        case subsection(SectionGroup)
        public var id: String {
            switch self {
            case .lesson(let node): return node.id
            case .subsection(let group): return group.id
            }
        }
    }

    public let section: TreeNode
    /// Ordered children (direct lessons interleaved with subsections by position).
    public let children: [Child]
    public let resources: [TreeNode]
    public let completed: Int
    public let total: Int
    /// Synthetic groups (loose lessons directly under the course root) have no
    /// real section node and render without a collapsible header.
    public let isSynthetic: Bool

    public var id: String { section.id }
    public var isComplete: Bool { total > 0 && completed >= total }
    public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }

    /// Direct lessons only (not recursing into subsections) — used for the
    /// section's own play button and now-playing containment checks.
    public var directLessons: [TreeNode] {
        children.compactMap { if case .lesson(let n) = $0 { return n } else { return nil } }
    }

    public init(section: TreeNode, children: [Child], resources: [TreeNode],
                completed: Int, total: Int, isSynthetic: Bool = false) {
        self.section = section
        self.children = children
        self.resources = resources
        self.completed = completed
        self.total = total
        self.isSynthetic = isSynthetic
    }
}

public enum CourseTree {
    /// Depth-first lesson order shared by the outline and playback queue.
    public static func lessons(in root: TreeNode) -> [TreeNode] {
        var result: [TreeNode] = []
        func visit(_ node: TreeNode) {
            for child in node.orderedNavigableChildren {
                if child.type == "lesson" { result.append(child) }
                else if child.type == "section" { visit(child) }
            }
        }
        visit(root)
        return result
    }

    public static func outline(of root: TreeNode) -> [OutlineEntry] {
        var result: [OutlineEntry] = []
        func appendAssets(_ node: TreeNode, depth: Int) {
            for asset in node.allAssets.sorted(by: { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }) {
                result.append(OutlineEntry(item: asset, depth: depth))
                appendAssets(asset, depth: depth + 1)
            }
            for child in (node.children ?? []).sorted(by: { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }) {
                result.append(OutlineEntry(item: child, depth: depth))
                appendAssets(child, depth: depth + 1)
            }
        }
        func visit(_ node: TreeNode, depth: Int) {
            for child in node.orderedNavigableChildren {
                result.append(OutlineEntry(item: child, depth: depth))
                if child.type == "section" { visit(child, depth: depth + 1) }
                else if child.type == "lesson" { appendAssets(child, depth: depth + 1) }
            }
            appendAssets(node, depth: depth)
        }
        visit(root, depth: 0)
        return result
    }

    /// Groups the course into sections for the sectioned sidebar. Sections nest
    /// recursively; lessons that sit directly under the root (no enclosing
    /// section) are collected into a single leading synthetic group.
    public static func sectionGroups(of root: TreeNode, progress: CourseProgress) -> [SectionGroup] {
        var groups: [SectionGroup] = []
        var looseLessons: [TreeNode] = []
        for child in root.orderedNavigableChildren {
            switch child.type {
            case "lesson":
                looseLessons.append(child)
            case "section":
                groups.append(makeSectionGroup(child, progress: progress))
            default:
                break
            }
        }
        if !looseLessons.isEmpty {
            let completed = looseLessons.filter {
                progress.progress(for: $0.id)?.isEffectivelyComplete ?? false
            }.count
            let synthetic = TreeNode(id: "\(root.id)#loose", type: "section", title: root.title)
            groups.insert(SectionGroup(section: synthetic,
                                       children: looseLessons.map { .lesson($0) }, resources: [],
                                       completed: completed, total: looseLessons.count,
                                       isSynthetic: true), at: 0)
        }
        return groups
    }

    /// Builds one section group, recursing into subsections and preserving the
    /// position-ordered interleaving of direct lessons and subsections. Counts
    /// span the whole subtree; resources are this section's own files plus those
    /// attached to its direct lessons (subsections carry their own).
    private static func makeSectionGroup(_ section: TreeNode, progress: CourseProgress) -> SectionGroup {
        var children: [SectionGroup.Child] = []
        var resources = section.resourceAssets
        for child in section.orderedNavigableChildren {
            switch child.type {
            case "lesson":
                children.append(.lesson(child))
                resources.append(contentsOf: child.resourceAssets)
            case "section":
                children.append(.subsection(makeSectionGroup(child, progress: progress)))
            default:
                break
            }
        }
        let allLessons = lessons(in: section)
        let completed = allLessons.filter {
            progress.progress(for: $0.id)?.isEffectivelyComplete ?? false
        }.count
        return SectionGroup(section: section, children: children, resources: resources,
                            completed: completed, total: allLessons.count)
    }

    /// Course-level resource files/folders attached directly to the root.
    public static func courseResources(of root: TreeNode) -> [TreeNode] {
        root.resourceAssets
    }

    /// Number of leaf files beneath a resource node (folders recurse into
    /// `children`; a plain asset counts as one). Subtitles are never resources.
    public static func resourceFileCount(of node: TreeNode) -> Int {
        guard node.type == "asset_directory" else { return 1 }
        return (node.children ?? []).reduce(0) { $0 + resourceFileCount(of: $1) }
    }

    /// Total bytes beneath a resource node, summing known `sizeBytes`.
    public static func totalSize(of node: TreeNode) -> Int64 {
        if node.type == "asset_directory" {
            return (node.children ?? []).reduce(0) { $0 + totalSize(of: $1) }
        }
        return node.sizeBytes ?? 0
    }

    /// The lesson to resume: the most recently updated lesson that is not yet
    /// effectively complete. Falls back to the first lesson when everything is
    /// complete. Returns nil only for a course with no lessons.
    public static func resumeTarget(in root: TreeNode, progress: CourseProgress) -> TreeNode? {
        let ordered = lessons(in: root)
        guard !ordered.isEmpty else { return nil }
        let incomplete = ordered.filter { !(progress.progress(for: $0.id)?.isEffectivelyComplete ?? false) }
        if incomplete.isEmpty { return ordered.first }
        // Prefer the most recently touched incomplete lesson; updatedAt is an
        // ISO-8601 string, so lexical ordering matches chronological ordering.
        let touched = incomplete
            .compactMap { lesson -> (TreeNode, String)? in
                guard let stamp = progress.progress(for: lesson.id)?.updatedAt else { return nil }
                return (lesson, stamp)
            }
            .max { $0.1 < $1.1 }
        return touched?.0 ?? incomplete.first
    }

    /// During initial enumeration, canonical sections can temporarily move from
    /// `sections` to `assets` as asset_directory nodes. Retain their last good
    /// tree and suppress that provisional duplicate until scan completion.
    public static func preservingCanonicalSections(old: TreeNode, new: TreeNode, scanInProgress: Bool) -> TreeNode {
        guard scanInProgress else { return new }
        var result = new
        let previousSections = Dictionary(uniqueKeysWithValues: (old.sections ?? []).map { ($0.id, $0) })
        var incomingSections = new.sections ?? []
        var incomingAssets = new.assets ?? []
        for previous in previousSections.values {
            if let index = incomingSections.firstIndex(where: { $0.id == previous.id }) {
                incomingSections[index] = preservingCanonicalSections(old: previous, new: incomingSections[index], scanInProgress: true)
            } else if incomingAssets.contains(where: { $0.id == previous.id && $0.type == "asset_directory" }) {
                incomingSections.append(previous)
                incomingAssets.removeAll { $0.id == previous.id }
            }
        }
        result.sections = incomingSections.sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
        result.assets = incomingAssets
        return result
    }
}

public struct LessonQueue: Sendable {
    public let lessons: [TreeNode]
    public private(set) var currentIndex: Int
    private var advancedAtEOF = Set<String>()

    public init(lessons: [TreeNode], startingAt lessonID: String? = nil) {
        self.lessons = lessons
        self.currentIndex = lessonID.flatMap { id in lessons.firstIndex(where: { $0.id == id }) } ?? 0
    }

    public var current: TreeNode? { lessons.indices.contains(currentIndex) ? lessons[currentIndex] : nil }
    public var previous: TreeNode? { currentIndex > 0 && lessons.indices.contains(currentIndex) ? lessons[currentIndex - 1] : nil }
    public var next: TreeNode? { currentIndex + 1 < lessons.count ? lessons[currentIndex + 1] : nil }

    @discardableResult public mutating func movePrevious() -> TreeNode? {
        guard previous != nil else { return nil }
        currentIndex -= 1
        return current
    }

    @discardableResult public mutating func moveNext() -> TreeNode? {
        guard next != nil else { return nil }
        currentIndex += 1
        return current
    }

    /// Advances once for the active entry on natural EOF only. Repeated or late
    /// EOF events cannot skip a lesson; manual stop/failure never calls this.
    @discardableResult public mutating func naturalEOF(for lessonID: String, autoplay: Bool) -> TreeNode? {
        guard current?.id == lessonID, advancedAtEOF.insert(lessonID).inserted, autoplay else { return nil }
        return moveNext()
    }
}

public struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var origin: URL
    public var libraryID: String?

    public init(id: UUID = UUID(), name: String = "Medina Server", origin: URL = URL(string: "http://127.0.0.1:17843")!, libraryID: String? = nil) {
        self.id = id; self.name = name; self.origin = origin; self.libraryID = libraryID
    }

    public static func normalizedOrigin(_ raw: String) throws -> URL {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw MedinaAPIError.invalidOrigin
        }
        var normalized = components
        normalized.path = ""
        guard let url = normalized.url else { throw MedinaAPIError.invalidOrigin }
        return url
    }
}

public enum MedinaAPIError: Error, LocalizedError, Sendable {
    case invalidOrigin
    case invalidResponse
    case httpStatus(Int, String)
    case incompatibleAPI(String)
    case noLibrary

    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "Enter an HTTP or HTTPS server origin without a path, query, or fragment."
        case .invalidResponse: return "The server returned an invalid response."
        case .httpStatus(let status, let message): return "HTTP \(status): \(message)"
        case .incompatibleAPI(let version): return "Unsupported Medina API version: \(version)"
        case .noLibrary: return "The server has no configured library."
        }
    }
}

public final class MedinaAPIClient: Sendable {
    public let profile: ServerProfile
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(profile: ServerProfile, session: URLSession = .shared) {
        self.profile = profile
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func health() async throws {
        struct Health: Decodable { var status: String }
        let value: Health = try await get("/api/v1/health")
        guard value.status == "ok" else { throw MedinaAPIError.invalidResponse }
    }

    public func systemInfo() async throws -> SystemInfo {
        let value: SystemInfo = try await get("/api/v1/system/info")
        guard let version = value.apiVersion, version.split(separator: ".").first == "1" else {
            throw MedinaAPIError.incompatibleAPI(value.apiVersion ?? "missing")
        }
        return value
    }

    public func libraries() async throws -> [Library] { try await get("/api/v1/libraries") }
    public func indexStatus() async throws -> IndexStatus { try await get("/api/v1/index/status") }

    public func courses(libraryID: String) async throws -> [Course] {
        var cursor: String?
        var seen = Set<String>()
        var all: [Course] = []
        repeat {
            var components = URLComponents(url: endpoint("/api/v1/libraries/\(pathSegment(libraryID))/courses"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: CoursePage = try await request(components.url!)
            all.append(contentsOf: page.items ?? [])
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw MedinaAPIError.invalidResponse }
        } while cursor != nil
        return all
    }

    public func tree(courseID: String) async throws -> TreeNode {
        try await get("/api/v1/courses/\(pathSegment(courseID))/tree")
    }

    /// Reads aggregate course progress for a client profile. Progress is
    /// scoped by the opaque `X-Medina-Profile` identifier; the server has no
    /// accounts and treats each profile independently.
    public func courseProgress(courseID: String, profileID: String) async throws -> CourseProgress {
        var request = URLRequest(url: endpoint("/api/v1/courses/\(pathSegment(courseID))/progress"))
        request.timeoutInterval = 10
        request.setValue(profileID, forHTTPHeaderField: "X-Medina-Profile")
        return try await send(request)
    }

    /// Stores playback progress for a lesson and returns the persisted record.
    @discardableResult
    public func putLessonProgress(id: String, profileID: String, _ body: LessonProgress) async throws -> LessonProgress {
        var request = URLRequest(url: endpoint("/api/v1/lessons/\(pathSegment(id))/progress"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.setValue(profileID, forHTTPHeaderField: "X-Medina-Profile")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Payload: Encodable { var positionSeconds: Double; var durationSeconds: Double; var completed: Bool }
        request.httpBody = try JSONEncoder().encode(Payload(positionSeconds: body.positionSeconds,
                                                            durationSeconds: body.durationSeconds,
                                                            completed: body.completed))
        return try await send(request)
    }

    public func resolve(_ serverPath: String) -> URL {
        URL(string: serverPath, relativeTo: profile.origin)!.absoluteURL
    }

    public func assetPreviewURL(id: String) -> URL {
        endpoint("/api/v1/assets/\(pathSegment(id))/preview")
    }

    public func assetDownloadURL(id: String) -> URL {
        endpoint("/api/v1/assets/\(pathSegment(id))/download")
    }

    public func assetArchiveURL(id: String) -> URL {
        endpoint("/api/v1/assets/\(pathSegment(id))/archive.zip")
    }

    public func assetContentURL(id: String) -> URL {
        endpoint("/api/v1/assets/\(pathSegment(id))/content")
    }

    public func previewAsset(id: String) async throws -> Data {
        var request = URLRequest(url: assetPreviewURL(id: id))
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw httpStatusError(http.statusCode, data: data) }
        return data
    }

    /// Fetches an asset's raw bytes from the content endpoint (which serves any
    /// asset, including HTML/SVG that `preview` rejects with 415), returning the
    /// bytes and the server's resolved MIME type when present.
    public func fetchContent(id: String) async throws -> (data: Data, mimeType: String?) {
        var request = URLRequest(url: assetContentURL(id: id))
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw httpStatusError(http.statusCode, data: data) }
        let mime = (http.value(forHTTPHeaderField: "Content-Type"))
            .flatMap { $0.split(separator: ";", maxSplits: 1).first.map(String.init) }?
            .trimmingCharacters(in: .whitespaces)
        return (data, mime)
    }

    /// Streams an asset or archive to a user-selected URL without holding the
    /// complete download in memory.
    public func download(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
            throw httpStatusError(http.statusCode, data: data)
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: temporaryURL, to: destination)
    }

    private func httpStatusError(_ status: Int, data: Data) -> MedinaAPIError {
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
        let message = envelope?.error?.message ?? String(data: data.prefix(2048), encoding: .utf8) ?? "Request failed"
        return .httpStatus(status, message)
    }

    public func startScan() async throws {
        let url = endpoint("/api/v1/index/scan")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard http.statusCode == 202 || http.statusCode == 409 else {
            throw MedinaAPIError.httpStatus(http.statusCode, "Could not start scan")
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T { try await request(endpoint(path)) }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url); request.timeoutInterval = 10
        return try await send(request)
    }

    /// Performs a prepared request and decodes the JSON body, applying the
    /// shared status-code and decoding-error handling used across the client.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw httpStatusError(http.statusCode, data: data) }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw MedinaAPIError.invalidResponse }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: profile.origin)!.absoluteURL
    }

    private func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

}

/// A replaceable, profile-scoped JSON cache. Cache failures are non-fatal to browsing.
public struct LibrarySnapshot: Codable, Sendable {
    public var savedAt: Date
    public var libraries: [Library]
    public var courses: [Course]
    public var trees: [String: TreeNode]

    public init(savedAt: Date = Date(), libraries: [Library], courses: [Course], trees: [String: TreeNode]) {
        self.savedAt = savedAt
        self.libraries = libraries
        self.courses = courses
        self.trees = trees
    }
}

public struct LibraryCache: Sendable {
    private let fileURL: URL
    public init(profileID: UUID, fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        fileURL = base.appendingPathComponent("Medina", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
            .appendingPathComponent("library-v1.json")
    }
    public func load() -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
    }
    public func save(_ snapshot: LibrarySnapshot) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch { /* A disposable local metadata cache must never block the UI. */ }
    }
}
