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

    public func resolve(_ serverPath: String) -> URL {
        URL(string: serverPath, relativeTo: profile.origin)!.absoluteURL
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            throw MedinaAPIError.httpStatus(http.statusCode, envelope?.error?.message ?? String(data: data.prefix(2048), encoding: .utf8) ?? "Request failed")
        }
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
