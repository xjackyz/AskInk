import XCTest
import CoreGraphics
@testable import InkAlgorithms

final class GroupingTests: XCTestCase {
    func stroke(_ index: Int, _ start: Double, _ end: Double, _ x: Double, _ y: Double, _ width: Double = 12, _ height: Double = 20) -> InkStrokeDescriptor {
        InkStrokeDescriptor(index: index, bounds: CGRect(x: x, y: y, width: width, height: height), started: start, ended: end)
    }
    func testPauseUsesEndOfLongStroke() {
        let result = InkGrouping.blocks([stroke(0, 0, 10, 0, 0), stroke(1, 10.5, 11, 16, 0)])
        XCTAssertEqual(result, [[0, 1]]) // Start-to-start would incorrectly split.
    }
    func testNearbyNewQuestionAfterLongPauseStaysSeparate() {
        XCTAssertEqual(InkGrouping.blocks([stroke(0, 0, 1, 0, 0), stroke(1, 20, 21, 20, 0)]), [[1], [0]])
    }
    func testDifferentMarginsDoNotMergeDuringFastWriting() {
        XCTAssertEqual(InkGrouping.blocks([stroke(0, 0, 1, 0, 0), stroke(1, 1.2, 2, 500, 0)]), [[1], [0]])
    }
    func testLineWrapIsKeptWithQuestion() {
        let input = [stroke(0, 0, 1, 0, 0), stroke(1, 1.1, 2, 30, 0), stroke(2, 2.1, 3, 0, 30)]
        XCTAssertEqual(InkGrouping.blocks(input), [[0, 1, 2]])
    }
    func testLongHorizontalAndDotAreNeverDeleted() {
        let input = [stroke(0, 0, 1, 0, 0, 100, 2), stroke(1, 1.1, 2, 102, 0, 2, 2)]
        XCTAssertEqual(InkGrouping.blocks(input).flatMap { $0 }.sorted(), [0, 1])
    }
    func testLateCorrectionRejoinsOldBlockAndBecomesLatest() {
        let input = [stroke(0, 0, 1, 0, 0), stroke(1, 2, 3, 400, 0), stroke(2, 8, 9, 4, 5)]
        XCTAssertEqual(InkGrouping.blocks(input), [[0, 2], [1]])
    }
    func testInputIsSortedByWritingTime() {
        let input = [stroke(1, 2, 3, 16, 0), stroke(0, 0, 1, 0, 0)]
        XCTAssertEqual(InkGrouping.blocks(input), [[0, 1]])
    }
    func testHighlightSourceMarksAndWrittenQuestions() {
        XCTAssertTrue(InkGrouping.isHighlightMark([CGPoint(x: 0, y: 10), CGPoint(x: 200, y: 12)]))
        XCTAssertFalse(InkGrouping.isHighlightMark([CGPoint(x: 0, y: 10), CGPoint(x: 20, y: 10)]))
        XCTAssertFalse(InkGrouping.isHighlightMark([CGPoint(x: 0, y: 10), CGPoint(x: 20, y: 30)]))
        XCTAssertFalse(InkGrouping.isHighlightMark([CGPoint(x: 2, y: 2)]))
        XCTAssertFalse(InkGrouping.isHighlightMark([]))
    }
    func testEmptyInput() { XCTAssertTrue(InkGrouping.blocks([]).isEmpty) }
    func testSourceMarkSeparatesPriorNoteFromNewQuestion() {
        let input = [stroke(0, 0, 1, 0, 0), stroke(1, 3, 4, 4, 2)]
        XCTAssertEqual(InkGrouping.blocks(input, pause: 6, boundaries: [2]), [[1], [0]])
    }
}
