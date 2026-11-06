import XCTest
@testable import MedinaPlayback

@MainActor
final class PlaybackSessionTests: XCTestCase {
    func testSessionStartsIdleWithoutCreatingVLCPlayerEarly() {
        let session = PlaybackSession()
        XCTAssertNil(session.vlcEngine)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.currentTime, 0)
        XCTAssertEqual(session.duration, 0)
        XCTAssertFalse(session.isSeekable)
    }

    func testDurationConversionUsesComponentsRatherThanTotalAttoseconds() {
        XCTAssertEqual(durationSeconds(.seconds(788.457)), 788.457, accuracy: 0.000_001)
    }

    func testNaturalEndRequiresTimelineNearKnownDuration() {
        XCTAssertFalse(VLCPlaybackEngine.naturalEndTimelineIsConsistent(time: .seconds(20), duration: .seconds(60)))
        XCTAssertTrue(VLCPlaybackEngine.naturalEndTimelineIsConsistent(time: .seconds(59), duration: .seconds(60)))
        XCTAssertTrue(VLCPlaybackEngine.naturalEndTimelineIsConsistent(time: .seconds(20), duration: nil))
        XCTAssertFalse(VLCPlaybackEngine.naturalEndTimelineIsConsistent(time: .zero, duration: nil))
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
