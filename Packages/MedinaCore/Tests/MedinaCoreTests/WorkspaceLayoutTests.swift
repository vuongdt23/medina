import XCTest
@testable import MedinaCore

final class WorkspaceLayoutTests: XCTestCase {
    func testWindowSizesAndBreakpointHysteresis() {
        XCTAssertEqual(WorkspaceLayout.resolve(width: 480), .compact)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 1000), .standard)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 1800), .wide)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 860, previous: .compact), .compact)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 840, previous: .standard), .standard)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 810, previous: .standard), .compact)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 890, previous: .compact), .standard)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 1180, previous: .wide), .wide)
        XCTAssertEqual(WorkspaceLayout.resolve(width: 1180, previous: .standard), .standard)
    }

    func testSidebarClampsWithoutChangingPreference() {
        XCTAssertEqual(WorkspaceLayout.wide.sidebarWidth(preferred: 420, available: 1600), 420)
        XCTAssertEqual(WorkspaceLayout.standard.sidebarWidth(preferred: 420, available: 850), 350)
        XCTAssertEqual(WorkspaceLayout.wide.sidebarWidth(preferred: 900, available: 1600), 480)
        XCTAssertEqual(WorkspaceLayout.wide.sidebarWidth(preferred: 100, available: 1600), 300)
        XCTAssertEqual(WorkspaceLayout.compact.sidebarWidth(preferred: 420, available: 480), 480)
        XCTAssertEqual(WorkspaceLayout.compact.sidebarWidth(preferred: 420, available: 750), 380)
    }

    func testSearchPreservesAncestryAndPlaybackOrder() {
        let one = TreeNode(id: "1", type: "lesson", title: "Abstract classes", position: 0)
        let two = TreeNode(id: "2", type: "lesson", title: "Interfaces", position: 1)
        let nested = TreeNode(id: "nested", type: "section", title: "Inheritance", lessons: [two, one])
        let section = TreeNode(id: "kotlin", type: "section", title: "Kotlin", sections: [nested])
        let tree = TreeNode(id: "root", type: "course", title: "Course", sections: [section])
        XCTAssertEqual(LessonSearch.results(in: tree, query: " kotlin ").map(\.id), ["1", "2"])
        XCTAssertEqual(LessonSearch.results(in: tree, query: "ABSTRACT").first?.sectionPath, "Kotlin › Inheritance")
        XCTAssertTrue(LessonSearch.results(in: tree, query: "   ").isEmpty)
        XCTAssertTrue(LessonSearch.results(in: tree, query: "missing").isEmpty)
    }

    func testSearchOmitsRedundantWrapperSectionFromBreadcrumb() {
        let lesson = TreeNode(id: "1", type: "lesson", title: "Welcome to Data Engineering Essentials", position: 0)
        let sec1 = TreeNode(id: "s1", type: "section", title: "Welcome to Data Engineering Essentials", position: 0, lessons: [lesson])
        let sec2 = TreeNode(id: "s2", type: "section", title: "Overview of Modern Data Architecture", position: 1,
                            lessons: [TreeNode(id: "2", type: "lesson", title: "Architecture", position: 0)])
        let wrapper = TreeNode(id: "wrap", type: "section",
                               title: "data-engineering-essentials-hands-on-sql-python-and-spark",
                               sections: [sec1, sec2])
        let tree = TreeNode(id: "root", type: "course",
                            title: "[FreeCourseSite.com] Udemy - Data Engineering Essentials Hands-on - SQL, Python, and Spark",
                            sections: [wrapper])
        XCTAssertEqual(LessonSearch.results(in: tree, query: "Welcome").first?.sectionPath,
                       "Welcome to Data Engineering Essentials")
    }
}
