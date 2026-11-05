import Foundation
import XCTest
@testable import MedinaCore

final class MedinaCoreTests: XCTestCase {
    func testNullableAndMissingCollectionsDecode() throws {
        let json = #"{"id":"course","type":"course","title":"Course","items":null,"children":null,"lessons":[{"id":"lesson","type":"lesson","title":"Lesson"}]}"#.data(using: .utf8)!
        let node = try JSONDecoder().decode(TreeNode.self, from: json)
        XCTAssertNil(node.children)
        XCTAssertEqual(node.lessons?.first?.id, "lesson")
        let page = try JSONDecoder().decode(CoursePage.self, from: #"{"items":null,"nextCursor":null}"#.data(using: .utf8)!)
        XCTAssertNil(page.items)
        let missing = try JSONDecoder().decode(TreeNode.self, from: #"{"id":"x","type":"asset_directory","title":"Empty"}"#.data(using: .utf8)!)
        XCTAssertNil(missing.children)
    }

    func testLessonTraversalUsesSharedSiblingPositionsDepthFirst() {
        let lessonA = TreeNode(id: "a", type: "lesson", title: "A", position: 0,
                               assets: [TreeNode(id: "attachment", type: "asset", title: "Notes", position: 0)])
        let nested = TreeNode(id: "nested", type: "lesson", title: "Nested", position: 0)
        let section = TreeNode(id: "s", type: "section", title: "Section", position: 1, lessons: [nested])
        let lessonB = TreeNode(id: "b", type: "lesson", title: "B", position: 2)
        let root = TreeNode(id: "root", type: "course", title: "Root", sections: [section], lessons: [lessonB, lessonA])
        XCTAssertEqual(CourseTree.lessons(in: root).map(\.id), ["a", "nested", "b"])
        XCTAssertEqual(CourseTree.outline(of: root).map(\.id), ["a", "attachment", "s", "nested", "b"])
    }

    func testProvisionalAssetDirectoryDoesNotReplaceCanonicalSection() {
        let previousLesson = TreeNode(id: "lesson", type: "lesson", title: "Saved")
        let previous = TreeNode(id: "section", type: "section", title: "Canonical", lessons: [previousLesson])
        let provisional = TreeNode(id: "section", type: "asset_directory", title: "Provisional", position: 0, children: nil)
        let oldTree = TreeNode(id: "course", type: "course", title: "Course", sections: [previous])
        let newTree = TreeNode(id: "course", type: "course", title: "Course", assets: [provisional])
        let result = CourseTree.preservingCanonicalSections(old: oldTree, new: newTree, scanInProgress: true)
        XCTAssertEqual(result.sections?.first?.type, "section")
        XCTAssertEqual(result.sections?.first?.lessons?.first?.id, "lesson")
    }

    func testQueueBoundariesAndNaturalEOFAdvanceExactlyOnce() {
        let one = TreeNode(id: "one", type: "lesson", title: "One")
        let two = TreeNode(id: "two", type: "lesson", title: "Two")
        var queue = LessonQueue(lessons: [one, two], startingAt: "one")
        XCTAssertNil(queue.previous)
        XCTAssertEqual(queue.naturalEOF(for: "one", autoplay: true)?.id, "two")
        XCTAssertNil(queue.naturalEOF(for: "one", autoplay: true))
        XCTAssertNil(queue.next)
        XCTAssertEqual(queue.movePrevious()?.id, "one")
    }

    func testPausedAutoplaySettingDoesNotChangeQueueAtEOF() {
        let lesson = TreeNode(id: "one", type: "lesson", title: "One")
        var queue = LessonQueue(lessons: [lesson])
        XCTAssertNil(queue.naturalEOF(for: "one", autoplay: true))
        XCTAssertEqual(queue.current?.id, "one")
    }

    func testOriginNormalizationRejectsPathAndCredentials() throws {
        XCTAssertEqual(try ServerProfile.normalizedOrigin("http://localhost:17843/").absoluteString, "http://localhost:17843")
        XCTAssertThrowsError(try ServerProfile.normalizedOrigin("http://localhost:17843/prefix"))
        XCTAssertThrowsError(try ServerProfile.normalizedOrigin("http://user:pass@localhost:17843"))
    }
}
