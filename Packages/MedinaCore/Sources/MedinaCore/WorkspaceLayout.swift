import Foundation

/// Window-space policy, expressed in logical points. Hysteresis keeps live
/// resizing from repeatedly opening and closing navigation near a breakpoint.
public enum WorkspaceLayout: Equatable, Sendable {
    case compact, standard, wide

    public static func resolve(width: Double, previous: WorkspaceLayout? = nil) -> WorkspaceLayout {
        let compactBoundary = previous == .compact ? 880.0 : (previous == nil ? 850.0 : 820.0)
        if width < compactBoundary { return .compact }
        let wideBoundary = previous == .wide ? 1160.0 : 1200.0
        return width >= wideBoundary ? .wide : .standard
    }

    public func sidebarWidth(preferred: Double, available: Double) -> Double {
        if self == .compact { return available < 600 ? available : min(380, available - 64) }
        // Always reserve a usable playback pane; don't overwrite the preference
        // when moving to a smaller window.
        return min(max(300, preferred), min(self == .wide ? 480 : 360, max(300, available - 500)))
    }
}

public struct LessonSearchResult: Identifiable, Sendable {
    public let lesson: TreeNode
    public let sectionPath: String
    public var id: String { lesson.id }
}

public enum LessonSearch {
    /// Matches section ancestry as well as lesson titles, in playback order.
    public static func results(in tree: TreeNode, query: String) -> [LessonSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var results: [LessonSearchResult] = []
        func visit(_ node: TreeNode, path: [String]) {
            for child in node.orderedNavigableChildren {
                if child.type == "section" {
                    visit(child, path: path + [child.title])
                } else if child.type == "lesson" {
                    let context = path.joined(separator: " › ")
                    if (child.title + " " + context).localizedStandardContains(query) {
                        results.append(LessonSearchResult(lesson: child, sectionPath: context))
                    }
                }
            }
        }
        visit(tree, path: [])
        return results
    }
}
