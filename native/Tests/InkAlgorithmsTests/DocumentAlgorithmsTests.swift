import XCTest
import CoreGraphics
@testable import InkAlgorithms

final class DocumentAlgorithmsTests: XCTestCase {
    private let lines = [SourceTextLine(text: "被划线的原句", bounds: CGRect(x: 50, y: 200, width: 180, height: 14)),
                         SourceTextLine(text: "下一行", bounds: CGRect(x: 50, y: 170, width: 180, height: 14))]
    func testPenUnderlineSelectsTheSentenceAboveIt() {
        XCTAssertEqual(SourceMarkLocator.underlineLines(points: [CGPoint(x: 60, y: 197), CGPoint(x: 120, y: 196), CGPoint(x: 210, y: 197)], lines: lines), [0])
    }
    func testSlightlyCurvedUnderlineAndRightToLeftStrokeStillMatch() {
        XCTAssertEqual(SourceMarkLocator.underlineLines(points: [CGPoint(x: 210, y: 202), CGPoint(x: 140, y: 190), CGPoint(x: 60, y: 196)], lines: lines), [0])
    }
    func testMarginMinusAndCharacterHorizontalsRemainInk() {
        XCTAssertTrue(SourceMarkLocator.underlineLines(points: [CGPoint(x: 250, y: 197), CGPoint(x: 350, y: 197)], lines: lines).isEmpty)
        XCTAssertTrue(SourceMarkLocator.underlineLines(points: [CGPoint(x: 60, y: 197), CGPoint(x: 75, y: 197)], lines: lines).isEmpty)
    }
    func testStrikeThroughAndScribbleDoNotBecomeUnderlines() {
        XCTAssertTrue(SourceMarkLocator.underlineLines(points: [CGPoint(x: 60, y: 207), CGPoint(x: 210, y: 207)], lines: lines).isEmpty)
        XCTAssertTrue(SourceMarkLocator.underlineLines(points: [CGPoint(x: 60, y: 197), CGPoint(x: 210, y: 197), CGPoint(x: 70, y: 197)], lines: lines).isEmpty)
    }
    func testNearbyLineDoesNotOverrideUnderlinedLine() {
        XCTAssertEqual(SourceMarkLocator.underlineLines(points: [CGPoint(x: 60, y: 166), CGPoint(x: 210, y: 167)], lines: lines), [1])
    }
    func testChineseAndEnglishSearchRespectPreviousPageBoundary() {
        let sources = [ReadingSource(id: "early", page: 2, text: "熵增加的定义 entropy", bounds: .zero),
                       ReadingSource(id: "later", page: 20, text: "熵增加的定义 entropy", bounds: .zero),
                       ReadingSource(id: "other", page: 1, text: "能量守恒", bounds: .zero)]
        XCTAssertEqual(ReadingText.search(sources, query: "熵增加", before: 10).map(\.id), ["early"])
        XCTAssertEqual(ReadingText.search(sources, query: "entropy", before: 10).map(\.id), ["early"])
        XCTAssertTrue(ReadingText.search(sources, query: "为什么").isEmpty)
    }
    func testHistoryKeepsRecentTurnsWithinCharacterBudget() {
        let history = (1...8).map { ["question": "q\($0)", "answer": String(repeating: "答", count: 1000)] }
        let result = ReadingText.budgetHistory(history, characters: 900)
        XCTAssertEqual(result.last?["question"], "q8")
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + ($1["question"]?.count ?? 0) + ($1["answer"]?.count ?? 0) }, 900)
    }
    func testSummaryChunkingCoversTheEndOfLongUnicodeText() {
        let original = String(repeating: "长句🙂中文", count: 2000) + "最后的重要否定：不是。"
        let chunks = ReadingText.chunks(original, characters: 960)
        XCTAssertEqual(chunks.joined(), original)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 960 })
    }
}
