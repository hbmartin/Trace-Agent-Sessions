import XCTest
@testable import TraceCore

final class TranscriptViewportPolicyTests: XCTestCase {
    func testDelayedResizeMovesOppositeToViewportHeight() {
        XCTAssertTrue(TranscriptViewportPolicy.matchesResizeShift(actual: 780, previous: 800, viewportDelta: 20))
        XCTAssertTrue(TranscriptViewportPolicy.matchesResizeShift(actual: 820.8, previous: 800, viewportDelta: -20))
        XCTAssertFalse(TranscriptViewportPolicy.matchesResizeShift(actual: 820, previous: 800, viewportDelta: 20))
        XCTAssertFalse(TranscriptViewportPolicy.matchesResizeShift(actual: 782, previous: 800, viewportDelta: 20))
    }
    func testLastRowExtentWinsOverShortFrameAndEmptyRows() {
        XCTAssertEqual(TranscriptViewportPolicy.maximumOrigin(frameHeight: 800, lastRowBottom: 950, viewportHeight: 300), 650)
        XCTAssertEqual(TranscriptViewportPolicy.maximumOrigin(frameHeight: 100, lastRowBottom: 0, viewportHeight: 300), 0)
        XCTAssertEqual(TranscriptViewportPolicy.maximumOrigin(frameHeight: 1000, lastRowBottom: 950, viewportHeight: 300), 700)
    }
    func testRubberBandReturnPinsBeforeAccumulatedUpwardTravel() {
        XCTAssertTrue(TranscriptViewportPolicy.followsBottom(atBottom: true, withinBounds: true, upwardTravel: 24, previouslyFollowing: true))
        XCTAssertTrue(TranscriptViewportPolicy.followsBottom(atBottom: false, withinBounds: false, upwardTravel: 24, previouslyFollowing: true))
        XCTAssertFalse(TranscriptViewportPolicy.followsBottom(atBottom: false, withinBounds: true, upwardTravel: 4, previouslyFollowing: true))
        XCTAssertFalse(TranscriptViewportPolicy.followsBottom(atBottom: false, withinBounds: true, upwardTravel: 0, previouslyFollowing: false))
    }
}
