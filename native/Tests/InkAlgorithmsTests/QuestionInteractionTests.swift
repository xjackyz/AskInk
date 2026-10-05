import XCTest
import CoreGraphics
@testable import InkAlgorithms

final class QuestionInteractionTests: XCTestCase {
    func testOnlyExplicitTrailingQuestionMarksAuthorizeAutomaticAPI() {
        for value in ["why?", "为什么？", "what does this mean?", "gradient = ?", "为什么？\n"] {
            XCTAssertTrue(QuestionMarkGate.endsInQuestionMark(value))
        }
        for value in ["important", "remember", "definition", "exam", "不理解", "不知道", "gradient", "chapter 4", "为什么", "why? note", "", "！"] {
            XCTAssertFalse(QuestionMarkGate.endsInQuestionMark(value))
        }
    }
    func testQuestionHookAndDotAreCandidatesButOrdinaryStraightNotesAreNot() {
        let hook = QuestionGlyph(points: [CGPoint(x: 0, y: 4), CGPoint(x: 2, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 10, y: 4), CGPoint(x: 6, y: 10), CGPoint(x: 6, y: 14)])
        let dot = QuestionGlyph(points: [CGPoint(x: 6, y: 19)])
        XCTAssertTrue(QuestionMarkGate.mightBeQuestionMark([hook, dot]))
        XCTAssertTrue(QuestionMarkGate.mightBeQuestionMark([hook]))
        XCTAssertFalse(QuestionMarkGate.mightBeQuestionMark([dot]))
        XCTAssertFalse(QuestionMarkGate.mightBeQuestionMark([QuestionGlyph(points: [.zero, CGPoint(x: 100, y: 0)])]))
        XCTAssertFalse(QuestionMarkGate.mightBeQuestionMark([hook, QuestionGlyph(points: [CGPoint(x: 120, y: 19)])]))
    }
    func testCardsStayInsideViewportAtPageEdges() {
        let viewport = CGSize(width: 768, height: 900), card = CGSize(width: 250, height: 88)
        for anchor in [CGPoint.zero, CGPoint(x: 760, y: 895), CGPoint(x: 390, y: 500)] {
            let center = AnswerPlacement.center(anchor: anchor, card: card, viewport: viewport)
            XCTAssertGreaterThanOrEqual(center.x - card.width / 2, 8)
            XCTAssertLessThanOrEqual(center.x + card.width / 2, viewport.width - 8)
            XCTAssertGreaterThanOrEqual(center.y - card.height / 2, 8)
            XCTAssertLessThanOrEqual(center.y + card.height / 2, viewport.height - 8)
        }
    }
    func testAssessedNotesDoNotLoopButRemainAvailableWhenQuestionMarkIsAdded() {
        var state = AutomaticQuestionState()
        let word = Date(timeIntervalSince1970: 10)
        state.assessedNote([word], for: "book/1")
        XCTAssertTrue(state.scannedStrokes(for: "book/1").contains(word))
        XCTAssertFalse(state.excludedStrokes(for: "book/1").contains(word))
        state.submitted([word], for: "book/1")
        XCTAssertTrue(state.excludedStrokes(for: "book/1").contains(word))
    }
    func testHighlightedSourceDoesNotAuthorizeUnpunctuatedQuestions() {
        for text in ["why", "为什么", "请解释", "remember this", "why? because", "important"] {
            XCTAssertFalse(QuestionMarkGate.isQuestionText(text))
        }
        XCTAssertTrue(QuestionMarkGate.isQuestionText("?"))
        XCTAssertTrue(QuestionMarkGate.isQuestionText("？"))
    }
    func testPlacementTriesBelowBeforeLeftAndAvoidsOccupiedText() {
        let anchor = CGPoint(x: 700, y: 150), size = CGSize(width: 250, height: 88)
        let viewport = CGSize(width: 900, height: 700)
        let below = AnswerPlacement.center(anchor: anchor, card: size, viewport: viewport)
        XCTAssertEqual(below.x, anchor.x)
        XCTAssertGreaterThan(below.y, anchor.y)
        let blocked = CGRect(x: 570, y: 168, width: 265, height: 100)
        let left = AnswerPlacement.center(anchor: anchor, card: size, viewport: viewport, occupied: [blocked])
        let card = CGRect(x: left.x - size.width / 2, y: left.y - size.height / 2, width: size.width, height: size.height)
        XCTAssertFalse(card.intersects(blocked))
        XCTAssertLessThan(left.y, anchor.y) // Left also overlaps; above is the first free candidate.
    }
    func testContinuedWritingCanWithdrawAnAlreadySubmittedSession() {
        var state = AutomaticQuestionState()
        let original = Date(timeIntervalSince1970: 10), followup = Date(timeIntervalSince1970: 12)
        state.assessedNote([original], for: "book/1")
        state.submitted([original], for: "book/1")
        state.withdrawSubmission([original], for: "book/1")
        XCTAssertFalse(state.scannedStrokes(for: "book/1").contains(original))
        XCTAssertFalse(state.excludedStrokes(for: "book/1").contains(original))
        state.submitted([followup], for: "book/2")
        XCTAssertTrue(state.excludedStrokes(for: "book/2").contains(followup))
    }

    func testPortraitPlacesAnswerBelowBeforeTryingRight() {
        let anchor = CGPoint(x: 300, y: 150), card = CGSize(width: 250, height: 96)
        let viewport = CGSize(width: 768, height: 1000)
        let below = AnswerPlacement.center(anchor: anchor, card: card, viewport: viewport, preferBelow: true)
        XCTAssertEqual(below.x, anchor.x)
        XCTAssertEqual(below.y, anchor.y + 24 + card.height / 2)
        let blocked = CGRect(x: 175, y: 172, width: 130, height: 100)
        let right = AnswerPlacement.center(anchor: anchor, card: card, viewport: viewport, occupied: [blocked], preferBelow: true)
        XCTAssertGreaterThan(right.x, anchor.x)
    }

}
