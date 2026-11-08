import Foundation

public struct CourseProgressSummary: Codable, Hashable, Sendable {
    public var completedCount: Int
    public var totalCount: Int
    public var percent: Int

    public init(completedCount: Int = 0, totalCount: Int = 0, percent: Int = 0) {
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.percent = percent
    }

    public var fraction: Double {
        if totalCount > 0 {
            return min(1, max(0, Double(completedCount) / Double(totalCount)))
        }
        return min(1, max(0, Double(percent) / 100))
    }
}

public struct Course: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public var originalName: String?
    public var position: Int?
    public var thumbnailUrl: String?
    public var progress: CourseProgressSummary?

    public init(id: String, title: String, originalName: String? = nil, position: Int? = nil,
                thumbnailUrl: String? = nil, progress: CourseProgressSummary? = nil) {
        self.id = id
        self.title = title
        self.originalName = originalName
        self.position = position
        self.thumbnailUrl = thumbnailUrl
        self.progress = progress
    }
}

public struct CoursePage: Decodable, Sendable {
    public var items: [Course]?
    public var nextCursor: String?
}

public struct SearchResponse: Decodable, Sendable {
    public var query: String
    public var items: [SearchResult]
}

public struct SearchResult: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var title: String
    public var originalName: String?
    public var courseId: String
    public var coursePath: String
    public var streamUrl: String?
    public var thumbnailUrl: String?

    public init(id: String, type: String, title: String, originalName: String? = nil,
                courseId: String, coursePath: String, streamUrl: String? = nil,
                thumbnailUrl: String? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.originalName = originalName
        self.courseId = courseId
        self.coursePath = coursePath
        self.streamUrl = streamUrl
        self.thumbnailUrl = thumbnailUrl
    }
}

public struct RecentProgressResponse: Decodable, Sendable {
    public var items: [RecentProgressItem]
}

public struct RecentProgressItem: Codable, Identifiable, Hashable, Sendable {
    public var itemId: String
    public var title: String
    public var courseId: String
    public var coursePath: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var completed: Bool
    public var updatedAt: String?
    public var streamUrl: String?
    public var thumbnailUrl: String?

    public var id: String { itemId }

    public var fraction: Double {
        guard durationSeconds > 0 else { return completed ? 1 : 0 }
        return min(1, max(0, positionSeconds / durationSeconds))
    }
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
        completed || (durationSeconds > 0 && positionSeconds / durationSeconds >= 0.95)
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
    public var durationSeconds: Double?
    public var streamUrl: String?
    public var contentUrl: String?
    public var thumbnailUrl: String?
    public var children: [TreeNode]?
    public var sections: [TreeNode]?
    public var lessons: [TreeNode]?
    public var assets: [TreeNode]?
    public var subtitles: [TreeNode]?

    public init(id: String, type: String, title: String, originalName: String? = nil,
                position: Int? = nil, mediaKind: String? = nil, mimeType: String? = nil,
                extension fileExtension: String? = nil, sizeBytes: Int64? = nil,
                durationSeconds: Double? = nil, streamUrl: String? = nil,
                contentUrl: String? = nil, thumbnailUrl: String? = nil,
                children: [TreeNode]? = nil,
                sections: [TreeNode]? = nil, lessons: [TreeNode]? = nil,
                assets: [TreeNode]? = nil, subtitles: [TreeNode]? = nil) {
        self.id = id; self.type = type; self.title = title; self.originalName = originalName
        self.position = position; self.mediaKind = mediaKind; self.mimeType = mimeType
        self.fileExtension = fileExtension; self.sizeBytes = sizeBytes; self.durationSeconds = durationSeconds
        self.streamUrl = streamUrl
        self.contentUrl = contentUrl
        self.thumbnailUrl = thumbnailUrl
        self.children = children; self.sections = sections
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
        case id, type, title, originalName, position, mediaKind, mimeType, sizeBytes, durationSeconds
        case streamUrl, contentUrl, thumbnailUrl, children, sections, lessons, assets, subtitles
        case fileExtension = "extension"
    }
}

public struct OutlineEntry: Identifiable, Sendable {
    public let item: TreeNode
    public let depth: Int
    public var id: String { item.id }
}

/// Helpers to make noisy scene-release course names presentable and to detect
/// redundant wrapper subdirectories that mirror the course title.
public enum CourseName {
    private static let providerPrefixes = [
        "udemy -", "udemy–", "udemy —", "udemy:", "[udemy]", "udemy",
    ]

    private static let genericWrapperTokens: Set<String> = [
        "course", "courses", "content", "coursecontent",
        "videos", "video", "lectures", "lessons", "main", "files", "coursefiles",
    ]

    /// Strips leading/trailing source tags like `[FreeCourseSite.com]` and
    /// provider prefixes like `Udemy -` so human titles read cleanly.
    public static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.first == "[", let close = s.firstIndex(of: "]") {
            s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var strippedPrefix = true
        while strippedPrefix {
            strippedPrefix = false
            let lower = s.lowercased()
            for prefix in providerPrefixes where lower.hasPrefix(prefix) {
                let candidate = String(s.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:\t"))
                if !candidate.isEmpty {
                    s = candidate
                    strippedPrefix = true
                    break
                }
            }
        }
        while s.last == "]", let open = s.lastIndex(of: "["), open > s.startIndex {
            let candidate = String(s[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                s = candidate
            } else {
                break
            }
        }
        return s.isEmpty ? raw : s
    }

    /// Up to two initials from the cleaned title for the cover monogram.
    public static func monogram(_ raw: String) -> String {
        let words = clean(raw)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        let initials = words.prefix(2).compactMap { $0.first }.map(String.init)
        let joined = initials.joined().uppercased()
        return joined.isEmpty ? "•" : joined
    }

    /// True when `raw` starts with a numeric index prefix (e.g. `01 - Intro`,
    /// `02. Overview`, `001_Welcome`).
    public static func hasLeadingIndex(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isNumber else { return false }
        let afterDigits = trimmed.drop(while: { $0.isNumber })
        guard let sep = afterDigits.first else { return false }
        return sep == " " || sep == "-" || sep == "_" || sep == "." || sep == ")"
    }

    /// True when `candidate` is a wrapper directory name that repeats or slugs
    /// the course title (e.g. `data-engineering-essentials-hands-on-sql-python-and-spark`
    /// under `[FreeCourseSite.com] Udemy - Data Engineering Essentials Hands-on - SQL, Python, and Spark`)
    /// or uses a generic container name like `Course Content` / `Videos`.
    public static func isWrapperDirectoryName(_ candidate: String, forCourse courseTitle: String) -> Bool {
        if hasLeadingIndex(candidate) { return false }
        let candidateWords = normalizedTokens(of: clean(candidate))
        guard !candidateWords.isEmpty else { return false }
        let candidateJoined = candidateWords.joined()
        if genericWrapperTokens.contains(candidateJoined) {
            return true
        }
        let courseWords = normalizedTokens(of: clean(courseTitle))
        let rawCourseWords = normalizedTokens(of: courseTitle)
        guard !courseWords.isEmpty else { return false }
        let courseJoined = courseWords.joined()
        let rawJoined = rawCourseWords.joined()
        if candidateJoined == courseJoined || candidateJoined == rawJoined {
            return true
        }
        if candidateWords.count >= 2 && courseWords.count >= 2 {
            if courseWords.starts(with: candidateWords) || candidateWords.starts(with: courseWords) {
                return true
            }
            if candidateJoined.count >= 10 && (courseJoined.contains(candidateJoined) || candidateJoined.contains(courseJoined)) {
                return true
            }
        }
        return false
    }

    private static func normalizedTokens(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
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

    /// Checks current-lesson containment without flattening or sorting the tree.
    public func containsLesson(id: String) -> Bool {
        children.contains { child in
            switch child {
            case .lesson(let lesson): return lesson.id == id
            case .subsection(let group): return group.containsLesson(id: id)
            }
        }
    }
}

public enum CourseTree {
    /// Many production course directories have an outer release/archive folder
    /// whose only navigable child is the true course directory (for example,
    /// `[FreeCourseSite.com] Udemy - Foo/foo/01 - Intro/...`), often alongside
    /// loose `.url`/readme files at the outer root. Collapse that redundant
    /// wrapper chain so its child sections become the top-level course sections
    /// and its course-level files surface in Course resources.
    public static func effectiveRoot(of root: TreeNode) -> TreeNode {
        guard root.type == "course" else { return root }
        let courseTitle = root.originalName ?? root.title
        var current = root
        while let unwrapped = unwrapSingleWrapperSection(of: current, courseTitle: courseTitle) {
            current = unwrapped
        }
        return current
    }

    private static func unwrapSingleWrapperSection(of current: TreeNode, courseTitle: String) -> TreeNode? {
        guard (current.lessons ?? []).isEmpty,
              let sections = current.sections,
              sections.count == 1,
              let onlySection = sections.first,
              shouldUnwrapRootSection(onlySection, courseTitle: courseTitle) else {
            return nil
        }
        var promoted = current
        promoted.sections = onlySection.sections
        promoted.lessons = onlySection.lessons
        let mergedAssets = (onlySection.resourceAssets + current.resourceAssets).enumerated().map { index, item -> TreeNode in
            var copy = item
            copy.position = index
            return copy
        }
        promoted.assets = mergedAssets.isEmpty ? nil : mergedAssets
        let mergedSubtitles = (onlySection.subtitles ?? []) + (current.subtitles ?? [])
        promoted.subtitles = mergedSubtitles.isEmpty ? nil : mergedSubtitles
        return promoted
    }

    private static func shouldUnwrapRootSection(_ onlySection: TreeNode, courseTitle: String) -> Bool {
        let childSections = onlySection.sections ?? []
        let directLessons = onlySection.lessons ?? []
        let candidateName = onlySection.originalName ?? onlySection.title

        // 1. A single child directory that holds no direct lessons and fans out
        //    into multiple sections is a pure wrapper directory.
        if directLessons.isEmpty && childSections.count > 1 {
            return true
        }

        // 2. A chain of single-child wrapper directories (e.g. double-extracted
        //    archives) that eventually unwraps.
        if directLessons.isEmpty && childSections.count == 1,
           let nested = childSections.first,
           shouldUnwrapRootSection(nested, courseTitle: courseTitle) {
            return true
        }

        // 3. A single child directory whose name mirrors the course title (e.g.
        //    `data-engineering-essentials-...` inside `[FreeCourseSite.com] Udemy - Data Engineering...`)
        //    or is a generic wrapper name (`Course Content`, `Videos`, etc.).
        if (!childSections.isEmpty || !directLessons.isEmpty)
            && CourseName.isWrapperDirectoryName(candidateName, forCourse: courseTitle) {
            return true
        }

        // 4. An unnumbered single child directory wrapping multiple numbered
        //    section folders, even if a loose intro/trailer video sits beside them.
        if childSections.count > 1
            && !CourseName.hasLeadingIndex(candidateName)
            && childSections.filter({ CourseName.hasLeadingIndex($0.originalName ?? $0.title) }).count >= 2 {
            return true
        }

        return false
    }

    /// Finds any indexed tree node, including nested resource folders.
    public static func item(id: String, in root: TreeNode) -> TreeNode? {
        if root.id == id { return root }
        let collections = [root.sections, root.lessons, root.assets, root.subtitles, root.children]
        for collection in collections {
            for child in collection ?? [] {
                if let match = item(id: id, in: child) { return match }
            }
        }
        return nil
    }

    /// Depth-first lesson order shared by the outline and playback queue.
    public static func lessons(in root: TreeNode) -> [TreeNode] {
        let root = effectiveRoot(of: root)
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
        let root = effectiveRoot(of: root)
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
        let root = effectiveRoot(of: root)
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
            let synthetic = TreeNode(id: "\(root.id)#loose", type: "section", title: CourseName.clean(root.title))
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
        var completed = 0
        var total = 0
        for child in section.orderedNavigableChildren {
            switch child.type {
            case "lesson":
                children.append(.lesson(child))
                resources.append(contentsOf: child.resourceAssets)
                total += 1
                if progress.progress(for: child.id)?.isEffectivelyComplete == true { completed += 1 }
            case "section":
                let subsection = makeSectionGroup(child, progress: progress)
                completed += subsection.completed
                total += subsection.total
                children.append(.subsection(subsection))
            default:
                break
            }
        }
        return SectionGroup(section: section, children: children, resources: resources,
                            completed: completed, total: total)
    }

    /// Course-level resource files/folders attached directly to the root.
    public static func courseResources(of root: TreeNode) -> [TreeNode] {
        effectiveRoot(of: root).resourceAssets
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

    public func courses(libraryID: String, profileID: String? = nil) async throws -> [Course] {
        var cursor: String?
        var seen = Set<String>()
        var all: [Course] = []
        repeat {
            var components = URLComponents(url: endpoint("/api/v1/libraries/\(pathSegment(libraryID))/courses"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 10
            if let profileID, !profileID.isEmpty {
                request.setValue(profileID, forHTTPHeaderField: "X-Medina-Profile")
            }
            let page: CoursePage = try await send(request)
            all.append(contentsOf: page.items ?? [])
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw MedinaAPIError.invalidResponse }
        } while cursor != nil
        return all
    }

    public func search(query: String, type: String? = nil, limit: Int = 50) async throws -> SearchResponse {
        var components = URLComponents(url: endpoint("/api/v1/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
        ]
        if let type, !type.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "type", value: type))
        }
        return try await request(components.url!)
    }

    public func recentProgress(profileID: String, limit: Int = 20,
                               includeCompleted: Bool = false) async throws -> [RecentProgressItem] {
        var components = URLComponents(url: endpoint("/api/v1/progress/recent"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
            URLQueryItem(name: "includeCompleted", value: includeCompleted ? "true" : "false"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue(profileID, forHTTPHeaderField: "X-Medina-Profile")
        let response: RecentProgressResponse = try await send(request)
        return response.items
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

    /// `completed` is deliberately optional. Routine playback writes omit the
    /// field so a sticky server-side completion cannot be reopened by accident.
    /// Pass true for an explicit completion and false only for an explicit reopen.
    @discardableResult
    public func putLessonProgress(id: String, profileID: String, _ body: LessonProgress,
                                  completed: Bool? = nil) async throws -> LessonProgress {
        var request = URLRequest(url: endpoint("/api/v1/lessons/\(pathSegment(id))/progress"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.setValue(profileID, forHTTPHeaderField: "X-Medina-Profile")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Payload: Encodable {
            var positionSeconds: Double
            var durationSeconds: Double
            var completed: Bool?
        }
        request.httpBody = try JSONEncoder().encode(Payload(positionSeconds: body.positionSeconds,
                                                            durationSeconds: body.durationSeconds,
                                                            completed: completed))
        return try await send(request)
    }

    public func resolve(_ serverPath: String) -> URL {
        URL(string: serverPath, relativeTo: profile.origin)!.absoluteURL
    }

    /// Loads a server-advertised thumbnail using URLSession's HTTP cache and
    /// validation behavior. Callers should only invoke this for an advertised URL.
    public func thumbnailData(at serverPath: String) async throws -> Data {
        var request = URLRequest(url: resolve(serverPath), cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MedinaAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw httpStatusError(http.statusCode, data: data) }
        return data
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
