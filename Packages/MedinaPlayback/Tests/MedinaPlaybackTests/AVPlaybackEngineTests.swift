import XCTest
@testable import MedinaPlayback

@MainActor
final class AVPlaybackEngineTests: XCTestCase {
    func testInitialStateAndVolumeBounds() {
        let engine = AVPlaybackEngine()
        XCTAssertEqual(engine.state, .idle)
        engine.setVolume(1.5)
        XCTAssertEqual(engine.player.volume, 1)
        engine.setVolume(-2)
        XCTAssertEqual(engine.player.volume, 0)
        engine.shutdown()
    }

    func testChangingSpeedWhilePausedDoesNotStartPlayback() {
        let engine = AVPlaybackEngine()
        engine.setSpeed(2)
        XCTAssertEqual(engine.player.rate, 0)
        XCTAssertEqual(engine.player.defaultRate, 2)
        XCTAssertEqual(engine.playbackSpeed, 2)
        engine.shutdown()
    }

    func testSpeedBoundsAndNonFiniteInput() {
        let engine = AVPlaybackEngine()
        engine.setSpeed(9)
        XCTAssertEqual(engine.playbackSpeed, 2.5)
        engine.setSpeed(-1)
        XCTAssertEqual(engine.playbackSpeed, 0.5)
        engine.setSpeed(.nan)
        XCTAssertEqual(engine.playbackSpeed, 0.5)
        XCTAssertEqual(engine.player.defaultRate, 0.5)
        XCTAssertEqual(engine.player.rate, 0)
        engine.shutdown()
    }

    func testSpeedPreferenceSurvivesLessonLoad() {
        let engine = AVPlaybackEngine()
        let player = engine.player
        engine.setSpeed(1.25)
        engine.load(url: URL(fileURLWithPath: "/tmp/medina-test-missing-media.mp4"), title: "Lesson")
        engine.pause()
        XCTAssertTrue(engine.player === player)
        XCTAssertEqual(engine.playbackSpeed, 1.25)
        XCTAssertEqual(engine.player.defaultRate, 1.25)
        engine.shutdown()
    }

    func testReplayWithoutAnItemIsSafe() {
        let engine = AVPlaybackEngine()
        engine.replay()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.player.rate, 0)
        engine.shutdown()
    }
}
