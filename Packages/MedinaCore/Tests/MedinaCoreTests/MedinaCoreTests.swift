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

    func testAssetURLsUseTheConfiguredOriginAndEncodeIDs() {
        let profile = ServerProfile(origin: URL(string: "http://medina.local:17843")!)
        let client = MedinaAPIClient(profile: profile)
        XCTAssertEqual(client.assetPreviewURL(id: "file/one").absoluteString,
                       "http://medina.local:17843/api/v1/assets/file%2Fone/preview")
        XCTAssertEqual(client.assetDownloadURL(id: "asset-id").path,
                       "/api/v1/assets/asset-id/download")
        XCTAssertEqual(client.assetArchiveURL(id: "folder-id").path,
                       "/api/v1/assets/folder-id/archive.zip")
    }

    func testOriginNormalizationRejectsPathAndCredentials() throws {
        XCTAssertEqual(try ServerProfile.normalizedOrigin("http://localhost:17843/").absoluteString, "http://localhost:17843")
        XCTAssertThrowsError(try ServerProfile.normalizedOrigin("http://localhost:17843/prefix"))
        XCTAssertThrowsError(try ServerProfile.normalizedOrigin("http://user:pass@localhost:17843"))
    }

    func testLessonProgressFractionAndCompletionRule() {
        var p = LessonProgress(itemId: "a", positionSeconds: 45, durationSeconds: 100)
        XCTAssertEqual(p.fraction, 0.45, accuracy: 0.0001)
        XCTAssertFalse(p.isEffectivelyComplete)
        p.positionSeconds = 95
        XCTAssertTrue(p.isEffectivelyComplete, "reaching the last 10% counts as complete")
        let flagged = LessonProgress(itemId: "b", positionSeconds: 1, durationSeconds: 0, completed: true)
        XCTAssertTrue(flagged.isEffectivelyComplete, "explicit completion wins without a duration")
        XCTAssertEqual(flagged.fraction, 1)
    }

    func testCourseProgressFraction() {
        XCTAssertEqual(CourseProgress.empty.fraction, 0)
        XCTAssertEqual(CourseProgress(lessons: [:], completedCount: 9, totalCount: 12).fraction, 0.75, accuracy: 0.0001)
    }

    func testResumeTargetPrefersMostRecentIncompleteLesson() {
        let one = TreeNode(id: "one", type: "lesson", title: "One", position: 0)
        let two = TreeNode(id: "two", type: "lesson", title: "Two", position: 1)
        let three = TreeNode(id: "three", type: "lesson", title: "Three", position: 2)
        let root = TreeNode(id: "course", type: "course", title: "Course", lessons: [one, two, three])
        let progress = CourseProgress(lessons: [
            "one": LessonProgress(itemId: "one", positionSeconds: 100, durationSeconds: 100, completed: true, updatedAt: "2026-01-01T00:00:00Z"),
            "two": LessonProgress(itemId: "two", positionSeconds: 20, durationSeconds: 100, updatedAt: "2026-02-01T00:00:00Z"),
        ], completedCount: 1, totalCount: 3)
        XCTAssertEqual(CourseTree.resumeTarget(in: root, progress: progress)?.id, "two",
                       "the most recently touched incomplete lesson resumes")

        let allDone = CourseProgress(lessons: [
            "one": LessonProgress(itemId: "one", completed: true),
            "two": LessonProgress(itemId: "two", completed: true),
            "three": LessonProgress(itemId: "three", completed: true),
        ], completedCount: 3, totalCount: 3)
        XCTAssertEqual(CourseTree.resumeTarget(in: root, progress: allDone)?.id, "one",
                       "a finished course resumes at the first lesson")
        XCTAssertNil(CourseTree.resumeTarget(in: TreeNode(id: "empty", type: "course", title: "Empty"), progress: .empty))
    }

    func testResourceAssetsExcludeSubtitles() {
        let file = TreeNode(id: "f", type: "asset", title: "notes.pdf", position: 1)
        let folder = TreeNode(id: "d", type: "asset_directory", title: "code", position: 0)
        let sub = TreeNode(id: "s", type: "subtitle", title: "lesson.en.srt")
        let lesson = TreeNode(id: "l", type: "lesson", title: "Lesson",
                              assets: [file, folder], subtitles: [sub])
        // Resources: assets only, subtitles dropped, ordered by position.
        XCTAssertEqual(lesson.resourceAssets.map(\.id), ["d", "f"])
        // allAssets still includes subtitles (unchanged legacy behavior).
        XCTAssertTrue(lesson.allAssets.contains(where: { $0.id == "s" }))
    }

    func testSectionGroupsCountCompletionAndExposeResources() {
        let l1 = TreeNode(id: "l1", type: "lesson", title: "L1", position: 0)
        let l2 = TreeNode(id: "l2", type: "lesson", title: "L2", position: 1)
        let secAsset = TreeNode(id: "sa", type: "asset", title: "slides.pdf", position: 0)
        let section = TreeNode(id: "sec", type: "section", title: "Section", position: 1,
                               lessons: [l1, l2], assets: [secAsset])
        // A loose lesson directly under root should form a synthetic leading group.
        let loose = TreeNode(id: "loose", type: "lesson", title: "Intro", position: 0)
        let root = TreeNode(id: "course", type: "course", title: "Course",
                            sections: [section], lessons: [loose])
        let progress = CourseProgress(lessons: [
            "l1": LessonProgress(itemId: "l1", completed: true),
        ], completedCount: 1, totalCount: 3)

        let groups = CourseTree.sectionGroups(of: root, progress: progress)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups[0].isSynthetic)
        XCTAssertEqual(groups[0].directLessons.map(\.id), ["loose"])

        let real = groups[1]
        XCTAssertFalse(real.isSynthetic)
        XCTAssertEqual(real.directLessons.map(\.id), ["l1", "l2"])
        XCTAssertEqual(real.completed, 1)
        XCTAssertEqual(real.total, 2)
        XCTAssertFalse(real.isComplete)
        XCTAssertEqual(real.resources.map(\.id), ["sa"])
    }

    func testSectionGroupNestsSubsectionsPreservingOrderAndCounts() {
        // A top-level section with nested subsections must expose each subsection
        // as its own group (sections are essential and stay visible), while the
        // parent's count spans the whole subtree.
        let deep = TreeNode(id: "deep", type: "lesson", title: "Deep", position: 0,
                            assets: [TreeNode(id: "da", type: "asset", title: "deep.txt", position: 0)])
        let subB = TreeNode(id: "subB", type: "section", title: "Sub B", position: 2, lessons: [deep])
        let near = TreeNode(id: "near", type: "lesson", title: "Near", position: 0)
        let subA = TreeNode(id: "subA", type: "section", title: "Sub A", position: 1, lessons: [near])
        // A direct lesson at position 0 should sort ahead of the subsections.
        let direct = TreeNode(id: "direct", type: "lesson", title: "Direct", position: 0)
        let top = TreeNode(id: "top", type: "section", title: "Files Here", position: 0,
                           sections: [subA, subB], lessons: [direct],
                           assets: [TreeNode(id: "topfile", type: "asset", title: "readme.md", position: 0)])
        let root = TreeNode(id: "course", type: "course", title: "Course", sections: [top])

        let groups = CourseTree.sectionGroups(of: root, progress: .empty)
        XCTAssertEqual(groups.count, 1)
        let g = groups[0]
        XCTAssertEqual(g.total, 3, "subtree lesson count")
        // Ordered children: direct lesson, then the two subsections by position.
        XCTAssertEqual(g.children.map(\.id), ["direct", "subA", "subB"])
        XCTAssertEqual(g.directLessons.map(\.id), ["direct"])
        guard case .subsection(let gB) = g.children[2] else { return XCTFail("expected subsection") }
        XCTAssertEqual(gB.directLessons.map(\.id), ["deep"])
        // Parent resources: its own file + its direct lesson's; subsection files
        // belong to the subsection, not duplicated into the parent.
        XCTAssertEqual(Set(g.resources.map(\.id)), ["topfile"])
        XCTAssertEqual(Set(gB.resources.map(\.id)), ["da"])
    }

    func testResourceFileCountAndTotalSizeRecurseFolders() {
        let a = TreeNode(id: "a", type: "asset", title: "a.txt", extension: "txt", sizeBytes: 100)
        let b = TreeNode(id: "b", type: "asset", title: "b.txt", extension: "txt", sizeBytes: 250)
        let inner = TreeNode(id: "inner", type: "asset_directory", title: "inner", children: [b])
        let folder = TreeNode(id: "folder", type: "asset_directory", title: "folder", children: [a, inner])
        XCTAssertEqual(CourseTree.resourceFileCount(of: folder), 2)
        XCTAssertEqual(CourseTree.totalSize(of: folder), 350)
        XCTAssertEqual(CourseTree.resourceFileCount(of: a), 1)
    }
}
