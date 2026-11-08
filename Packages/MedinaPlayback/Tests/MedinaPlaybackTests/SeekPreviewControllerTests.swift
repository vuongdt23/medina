import XCTest
import AppKit
@testable import MedinaPlayback

private actor ControlledThumbnails {
    private(set) var times: [Double] = []
    private var continuation: CheckedContinuation<Data, any Error>?

    func generate(_ time: Double) async throws -> Data {
        times.append(time)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ value: String) {
        let current = continuation
        continuation = nil
        current?.resume(returning: Data(value.utf8))
    }

    func fail() {
        let current = continuation
        continuation = nil
        current?.resume(throwing: CocoaError(.fileReadUnknown))
    }
}

@MainActor
final class SeekPreviewControllerTests: XCTestCase {
    private let url = URL(string: "https://example.invalid/lesson/content")!

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<15000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for thumbnail worker", file: file, line: line)
    }

    func testCoalescesRequestsRejectsStaleFrameAndCachesBySecond() async throws {
        let decoder = ControlledThumbnails()
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            { try await decoder.generate($0) }
        }
        preview.load(url: url)
        preview.request(at: 1.2)
        try await waitUntil { await decoder.times == [1] }
        preview.request(at: 2)
        preview.request(at: 3.9)
        await decoder.finish("one")
        try await waitUntil { await decoder.times == [1, 3] }
        XCTAssertNil(preview.imageData)
        await decoder.finish("three")
        try await waitUntil { preview.imageTime == 3 }
        XCTAssertEqual(preview.imageData, Data("three".utf8))
        preview.request(at: 1.8)
        XCTAssertEqual(preview.imageData, Data("one".utf8))
        let times = await decoder.times
        XCTAssertEqual(times, [1, 3])
        preview.unload()
    }

    func testDismissAndReenterWaitsForOldWorkerAndPublishesOnlyNewResult() async throws {
        let decoder = ControlledThumbnails()
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            { try await decoder.generate($0) }
        }
        preview.load(url: url)
        preview.request(at: 4)
        try await waitUntil { await decoder.times.count == 1 }
        preview.dismiss()
        XCTAssertNil(preview.imageData)
        preview.request(at: 4)
        let times = await decoder.times
        XCTAssertEqual(times, [4]) // No second decode while cancellation drains.
        await decoder.fail()
        try await waitUntil { await decoder.times == [4, 4] }
        await decoder.finish("fresh")
        try await waitUntil { preview.imageData == Data("fresh".utf8) }
        preview.unload()
    }

    func testReloadSameURLInvalidatesOldResultAndCache() async throws {
        let decoder = ControlledThumbnails()
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            { try await decoder.generate($0) }
        }
        preview.load(url: url)
        preview.request(at: 1)
        try await waitUntil { await decoder.times.count == 1 }
        await decoder.finish("cached")
        try await waitUntil { preview.imageTime == 1 }
        preview.request(at: 2)
        try await waitUntil { await decoder.times.count == 2 }
        preview.load(url: url)
        preview.request(at: 1)
        await decoder.finish("old lesson")
        try await waitUntil { await decoder.times == [1, 2, 1] }
        XCTAssertNil(preview.imageData)
        await decoder.finish("new lesson")
        try await waitUntil { preview.imageData == Data("new lesson".utf8) }
        preview.unload()
    }

    func testCacheIsBoundedAndUsesLeastRecentlyUsedEviction() async throws {
        let decoder = ControlledThumbnails()
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            { try await decoder.generate($0) }
        }
        preview.load(url: url)
        for time in [1.0, 2.0] {
            preview.request(at: time)
            try await waitUntil { await decoder.times.last == time }
            await decoder.finish("\(time)")
            try await waitUntil { preview.imageTime == Int(time) }
        }
        preview.request(at: 1) // Touch 1, making 2 the eviction candidate.
        preview.request(at: 3)
        try await waitUntil { await decoder.times.last == 3 }
        await decoder.finish("three")
        try await waitUntil { preview.imageTime == 3 }
        preview.request(at: 1)
        XCTAssertEqual(preview.imageTime, 1)
        preview.request(at: 2)
        try await waitUntil { await decoder.times == [1, 2, 3, 2] }
        await decoder.finish("two again")
        try await waitUntil { preview.imageTime == 2 }
        preview.unload()
    }

    func testFailureCanRetryAndInvalidTimesAreIgnored() async throws {
        let decoder = ControlledThumbnails()
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            { try await decoder.generate($0) }
        }
        preview.load(url: url)
        for time in [Double.nan, .infinity, -1, Double(Int.max)] { preview.request(at: time) }
        await Task.yield()
        let times = await decoder.times
        XCTAssertTrue(times.isEmpty)
        preview.request(at: 0)
        try await waitUntil { await decoder.times.count == 1 }
        await decoder.fail()
        // Retry once the failure has propagated; no scheduling assumptions.
        try await waitUntil {
            preview.request(at: 0)
            return await decoder.times.count == 2
        }
        await decoder.finish("retry")
        try await waitUntil { preview.imageData != nil }
        preview.unload()
    }

    func testFailureStatusDoesNotLeakFromSupersededRequest() async throws {
        let decoder = ControlledThumbnails()
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            { try await decoder.generate($0) }
        }
        var diagnostics: [String] = []
        preview.onDiagnostic = { _, message in diagnostics.append(message) }
        preview.load(url: url)
        preview.request(at: 1)
        try await waitUntil { await decoder.times == [1] }
        preview.request(at: 2)
        await decoder.fail()
        try await waitUntil { await decoder.times == [1, 2] }
        XCTAssertNil(preview.lastError)
        XCTAssertEqual(diagnostics.count, 1)
        await decoder.fail()
        try await waitUntil { preview.lastError != nil }
        XCTAssertEqual(diagnostics.count, 2)
        preview.request(at: 2)
        XCTAssertNil(preview.lastError)
        try await waitUntil { await decoder.times == [1, 2, 2] }
        await decoder.finish("recovered")
        try await waitUntil { preview.imageData != nil }
        XCTAssertNil(preview.lastError)
        preview.unload()
    }

    func testFactoryFailureIsVisibleAndReported() {
        let preview = SeekPreviewController(cacheLimit: 2) { _ in
            throw CocoaError(.fileReadUnknown)
        }
        var diagnostics: [String] = []
        preview.onDiagnostic = { _, message in diagnostics.append(message) }
        preview.load(url: url)
        preview.request(at: 1)
        XCTAssertNotNil(preview.lastError)
        XCTAssertNil(preview.imageData)
        XCTAssertEqual(diagnostics.count, 1)
        preview.unload()
        XCTAssertNil(preview.lastError)
    }

    func testRealThumbnailLeavesPlaybackSessionIdle() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = root.appendingPathComponent("testdata/Go Fundamentals/01 - Getting Started/01 - Welcome.mp4")
        let environment = ProcessInfo.processInfo.environment
        let mediaURL = environment["MEDINA_PREVIEW_TEST_URL"].flatMap(URL.init(string:)) ?? fixtureURL
        let time = environment["MEDINA_PREVIEW_TEST_TIME"].flatMap(Double.init) ?? 0
        let session = PlaybackSession()
        session.seekPreview.load(url: mediaURL)
        session.seekPreview.request(at: time)
        try await waitUntil { session.seekPreview.imageData != nil || session.seekPreview.lastError != nil }
        XCTAssertNil(session.seekPreview.lastError)
        let data = try XCTUnwrap(session.seekPreview.imageData)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertNotNil(NSImage(data: data))
        XCTAssertNil(session.mpvEngine)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.currentTime, 0)
        await session.shutdown()
        XCTAssertNil(session.seekPreview.imageData)
    }
}
