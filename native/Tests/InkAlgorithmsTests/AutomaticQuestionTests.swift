import XCTest
@testable import InkAlgorithms

final class AutomaticQuestionTests: XCTestCase {
    func testContinuedWritingReplacesPauseAndOnlyLatestCanFire() {
        var state = AutomaticQuestionState()
        let old = state.schedule()
        let latest = state.schedule()
        XCTAssertFalse(state.consume(old))
        XCTAssertTrue(state.consume(latest))
        XCTAssertFalse(state.consume(latest))
    }
    func testWritingPageChangeOrBackgroundCancelsPendingRecognition() {
        var state = AutomaticQuestionState()
        let token = state.schedule()
        state.cancel()
        XCTAssertFalse(state.consume(token))
    }
    func testNewSentenceWaitsForInFlightAnswer() {
        var state = AutomaticQuestionState()
        let next = state.schedule()
        XCTAssertFalse(state.consume(next, canStart: false))
        XCTAssertEqual(state.pending, next)
        XCTAssertTrue(state.consume(next, canStart: true))
    }
    func testSubmittedSentenceIsExcludedWithoutLosingNewInkOrOtherPages() {
        var state = AutomaticQuestionState()
        let sent = Date(timeIntervalSince1970: 10)
        let next = Date(timeIntervalSince1970: 11)
        state.submitted([sent], for: "bookA/1")
        XCTAssertTrue(state.excludedStrokes(for: "bookA/1").contains(sent))
        XCTAssertFalse(state.excludedStrokes(for: "bookA/1").contains(next))
        XCTAssertTrue(state.excludedStrokes(for: "bookA/2").isEmpty)
        XCTAssertTrue(state.excludedStrokes(for: "bookB/1").isEmpty)
        state.cancel()
        XCTAssertTrue(state.excludedStrokes(for: "bookA/1").contains(sent))
    }
}
