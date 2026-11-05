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
        engine.shutdown()
    }
}
