import XCTest
@testable import MedinaPlayback

@MainActor
final class PlaybackSessionTests: XCTestCase {
    func testSessionStartsIdleWithoutCreatingMpvPlayerEarly() {
        let session = PlaybackSession()
        XCTAssertNil(session.mpvEngine)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.currentTime, 0)
        XCTAssertEqual(session.duration, 0)
        XCTAssertFalse(session.isSeekable)
    }

    func testMpvClientInitializesWithoutLoadingMedia() async {
        let engine = MpvPlaybackEngine(prefetchBufferBytes: 64 << 20)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.currentTime, 0)
        XCTAssertEqual(engine.duration, 0)
        XCTAssertTrue(engine.bufferedRanges.isEmpty)
        await engine.shutdown()
    }

    func testBufferedRangesAreSortedMergedAndClippedToTheTimeline() {
        let ranges = MpvPlaybackEngine.normalizedBufferedRanges(
            [12, 18, -2, 4, 3.98, 8, 25, 40, .nan, 50],
            duration: 30
        )
        XCTAssertEqual(ranges, [0...8, 12...18, 25...30])
    }

    func testDurationConversionUsesComponentsRatherThanTotalAttoseconds() {
        XCTAssertEqual(durationSeconds(.seconds(788.457)), 788.457, accuracy: 0.000_001)
    }

    func testNaturalEndRequiresTimelineNearKnownDuration() {
        XCTAssertFalse(MpvPlaybackEngine.naturalEndTimelineIsConsistent(time: .seconds(20), duration: .seconds(60)))
        XCTAssertTrue(MpvPlaybackEngine.naturalEndTimelineIsConsistent(time: .seconds(59), duration: .seconds(60)))
        XCTAssertTrue(MpvPlaybackEngine.naturalEndTimelineIsConsistent(time: .seconds(20), duration: nil))
        XCTAssertFalse(MpvPlaybackEngine.naturalEndTimelineIsConsistent(time: .zero, duration: nil))
    }

    func testSubtitleRetainsItsOriginalFilenameForFormatDetection() {
        let subtitle = PlaybackSubtitle(
            url: URL(string: "https://example.invalid/assets/123/content")!,
            filename: "captions.en.srt"
        )
        XCTAssertEqual(subtitle.filename, "captions.en.srt")
        XCTAssertEqual(subtitle.url.pathExtension, "")
        XCTAssertEqual(PlaybackSubtitle(url: subtitle.url, filename: "..").filename, "subtitle.srt")
    }
}
