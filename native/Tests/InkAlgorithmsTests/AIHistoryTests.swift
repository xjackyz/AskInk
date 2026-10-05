import XCTest
@testable import InkAlgorithms

final class AIHistoryTests: XCTestCase {
    func testLegacyMigrationPreservesRecognitionInkSourcesAndUsage() throws {
        let documentID = UUID(), threadID = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchor = ContentAnchor(x: 20, y: 30, documentID: documentID, location: .page(3))
        let original = ReadingReply(page: 3, question: "why?", answer: "answer", source: "source", model: "fixture",
            inkImageDataURL: "data:image/png;base64,AQID", recognizedText: "why?", recognitionSource: "fixtureOCR",
            recognitionRegions: [HandwritingRegion(text: "why?", bounds: .zero, strokeIDs: [UUID()])],
            anchor: anchor, threadID: threadID, sourceReferences: [ReadingSource(id: "s1", page: 3, text: "source", bounds: .zero)],
            inputTokens: 30, outputTokens: 10, cachedTokens: 20, citations: ["s1"], questionInkIDs: ["ink1"], targetContentIDs: ["s1"], mode: .compact)
        try JSONEncoder().encode([original]).write(to: directory.appendingPathComponent("replies.json"))
        let loaded = try AIHistory.load(folder: directory, documentID: documentID)
        try AIHistory.save(loaded, folder: directory, documentID: documentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("replies.json").path))
        let restored = try XCTUnwrap(AIHistory.load(folder: directory, documentID: documentID).first)
        XCTAssertEqual(restored.id, original.id); XCTAssertEqual(restored.conversationID, threadID)
        XCTAssertEqual(restored.answer, "answer"); XCTAssertEqual(restored.question, "why?")
        XCTAssertEqual(restored.inkImageDataURL, original.inkImageDataURL)
        XCTAssertEqual(restored.recognitionRegions?.first?.strokeIDs, original.recognitionRegions?.first?.strokeIDs)
        XCTAssertEqual(restored.cachedTokens, 20); XCTAssertEqual(restored.citations, ["s1"])
        XCTAssertEqual(restored.anchor, anchor); XCTAssertEqual(restored.targetContentIDs, ["s1"])
        let thread = try XCTUnwrap(AIHistory.threads([original], documentID: documentID).first)
        XCTAssertEqual(thread.turns.map(\.role), ["user", "assistant"])
        XCTAssertEqual(thread.questionInkIDs, ["ink1"])
        XCTAssertEqual(thread.turns.first?.id, try AIHistory.threads([original], documentID: documentID).first?.turns.first?.id)
    }
    func testCorruptCanonicalHistoryNeverFallsBackToStaleLegacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory.appendingPathComponent("threads.json")
        try Data("corrupt".utf8).write(to: canonical)
        try JSONEncoder().encode([ReadingReply]()).write(to: directory.appendingPathComponent("replies.json"))
        XCTAssertThrowsError(try AIHistory.load(folder: directory, documentID: UUID()))
        XCTAssertEqual(try String(contentsOf: canonical), "corrupt")
    }
    func testCanonicalHistoryRejectsWrongDocumentAndDeletesWholeThread() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), thread = UUID()
        let replies = [ReadingReply(page: 1, question: "q", answer: "a", source: "s", model: "fixture", threadID: thread),
            ReadingReply(page: 1, question: "follow-up", answer: "a2", source: "s", model: "fixture", threadID: thread)]
        try AIHistory.save(replies, folder: directory, documentID: id)
        XCTAssertEqual(try AIHistory.load(folder: directory, documentID: id).count, 2)
        XCTAssertThrowsError(try AIHistory.load(folder: directory, documentID: UUID()))
        try AIHistory.save([], folder: directory, documentID: id)
        XCTAssertEqual(try AIHistory.load(folder: directory, documentID: id).count, 0)
    }
}
