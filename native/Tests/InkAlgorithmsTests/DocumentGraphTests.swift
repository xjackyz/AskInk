import XCTest
@testable import InkAlgorithms

final class DocumentGraphTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private func graph() -> DocumentGraph {
        var graph = DocumentGraph(documentID: id, revision: "test", sections: [], blocks: [
            ContentBlock(contentID: "earlier", documentID: id, text: "时间与过去 time and memory", sectionPath: [], readingOrder: 0,
                location: .page(1, rect: CGRect(x: 20, y: 100, width: 200, height: 30))),
            ContentBlock(contentID: "current", documentID: id, text: "So we beat on, boats against the current", sectionPath: [], readingOrder: 1,
                location: .page(9, rect: CGRect(x: 20, y: 100, width: 200, height: 30))),
            ContentBlock(contentID: "future", documentID: id, text: "Future explanation of time", sectionPath: [], readingOrder: 2,
                location: .page(10))])
        graph.linkBlocks(); return graph
    }
    func testGraphLinksAndRejectsMixedDocument() throws {
        var graph = graph(); try graph.validate()
        XCTAssertEqual(graph.blocks[1].previousBlock, "earlier")
        XCTAssertEqual(graph.blocks[1].nextBlock, "future")
        graph.blocks[0].documentID = UUID()
        XCTAssertThrowsError(try graph.validate())
    }
    func testReflowableLocatorUsesSamePlannerAndIndex() throws {
        var graph = graph()
        for i in graph.blocks.indices { graph.blocks[i].location = ContentLocation(kind: .reflowable, locator: "epubcfi(/6/\(i * 2))") }
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: "against the current", nearbyText: "", retrievedIDs: ["earlier"], history: [])
        XCTAssertTrue(packet.indexReady)
        XCTAssertTrue(packet.excerpts.contains { $0.anchor.location?.locator == "epubcfi(/6/0)" })
        XCTAssertTrue(packet.excerpts.allSatisfy { $0.anchor.location?.pageNumber == nil })
        XCTAssertTrue(packet.context.contains("against the current"))
    }
    func testExistingLibraryAndAnchorDecodeWithoutMigrationLoss() throws {
        let book = "{\"id\":\"\(id.uuidString)\",\"name\":\"old.pdf\",\"lastPage\":17,\"addedAt\":0}"
        let document = try JSONDecoder().decode(Document.self, from: Data(book.utf8))
        XCTAssertEqual(document.resolvedFormat, .pdf); XCTAssertEqual(document.lastPage, 17)
        let anchor = try JSONDecoder().decode(ContentAnchor.self, from: Data("{\"x\":23,\"y\":42}".utf8))
        XCTAssertEqual(anchor.point, CGPoint(x: 23, y: 42)); XCTAssertNil(anchor.contentID)
        XCTAssertEqual(try JSONDecoder().decode(ContentAnchor.self, from: JSONEncoder().encode(anchor)), anchor)
    }
    func testPlannerHardBudgetAndDoesNotSendBook() {
        var graph = graph()
        for index in graph.blocks.indices { graph.blocks[index].text = String(repeating: "中文🙂事实。", count: 2000) }
        graph.blocks += (3..<1000).map { order in
            ContentBlock(contentID: "unused\(order)", documentID: id, text: "UNRELATED SHOULD NOT SEND", sectionPath: [], readingOrder: order, location: .page(order))
        }
        graph.linkBlocks()
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "为什么？", anchor: graph.blocks[1].anchor,
            selectedText: "中文🙂", nearbyText: "", retrievedIDs: ["earlier"],
            history: [["question": String(repeating: "q", count: 4000), "answer": String(repeating: "a", count: 4000)]], tokenBudget: 800)
        XCTAssertLessThanOrEqual(packet.estimatedTokens, 800)
        XCTAssertLessThanOrEqual(packet.context.utf8.count, 800)
        XCTAssertTrue(packet.truncated)
        XCTAssertFalse(packet.context.contains("UNRELATED"))
        XCTAssertEqual(packet.excerpts.first?.reason, .selection)
    }
    func testMissingIndexExplicitlyUsesNearbyEvidence() {
        let packet = ContextPlanner.plan(graph: nil, documentID: id, question: "why?", anchor: ContentAnchor(x: 1, y: 2, location: .page(2)),
            selectedText: nil, nearbyText: "local paragraph", retrievedIDs: [], history: [])
        XCTAssertFalse(packet.indexReady); XCTAssertEqual(packet.revision, "unindexed")
        XCTAssertTrue(packet.context.contains("local paragraph"))
    }
    func testPersistedFTSChineseAndPreviousCutoff() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do { let index = try LocalSearchIndex(url: url); try index.replace(graph: graph()) }
        let reopened = try LocalSearchIndex(url: url)
        XCTAssertEqual(try reopened.search(documentID: id, query: "过去", beforeOrder: 1), ["earlier"])
        XCTAssertEqual(try reopened.search(documentID: id, query: "time", beforeOrder: 1), ["earlier"])
        XCTAssertEqual(try reopened.search(documentID: UUID(), query: "time"), [])
        XCTAssertEqual(try reopened.search(documentID: id, query: "zzzz OR 1=1 --"), [])
    }
    func testFTSReplaceDoesNotLeaveOldEvidence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try LocalSearchIndex(url: url); try index.replace(graph: graph())
        try index.replace(graph: DocumentGraph(documentID: id, revision: "empty", sections: [], blocks: []))
        XCTAssertEqual(try index.search(documentID: id, query: "time"), [])
    }
    func testSemanticRankingHonorsModelAndReadingOrder() {
        var graph = graph()
        graph.blocks[0].embedding = ContentEmbedding(modelID: "local:en:1", vector: [1, 0])
        graph.blocks[1].embedding = ContentEmbedding(modelID: "different", vector: [1, 0])
        graph.blocks[2].embedding = ContentEmbedding(modelID: "local:en:1", vector: [1, 0])
        let query = ContentEmbedding(modelID: "local:en:1", vector: [1, 0])
        XCTAssertEqual(SemanticRanking.rank(blocks: graph.blocks, query: query, beforeOrder: 1), ["earlier"])
        XCTAssertEqual(SemanticRanking.rank(blocks: graph.blocks, query: ContentEmbedding(modelID: "local:en:1", vector: [0, 0])), [])
        XCTAssertEqual(SemanticRanking.fuse(lexical: ["earlier", "current"], semantic: ["earlier"], limit: 1), ["earlier"])
    }
    func testGeneratedMemoryNeverLeaksFutureSources() {
        var graph = graph()
        graph.memory = [DocumentMemory(text: "FULL BOOK SPOILER", sourceContentIDs: ["earlier", "future"], kind: "generated-summary")]
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: nil, nearbyText: "", retrievedIDs: [], history: [])
        XCTAssertFalse(packet.context.contains("FULL BOOK SPOILER"))
    }
    func testPacketEvidenceSentExactlyOnce() throws {
        let graph = graph()
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: nil, nearbyText: "", retrievedIDs: ["earlier"], history: [])
        let request = try AIRequest.request(connection: AIConnection(provider: .compatible, model: "example", endpoint: "https://example.com/v1/chat/completions", includeImage: false), key: "test",
            body: ["question": "why?", "context": packet.context, "contextPacket": packet.wireValue, "history": packet.history])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let data = try XCTUnwrap(content.first?["text"] as? String).data(using: .utf8)!
        let context = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(context["context"]); XCTAssertNotNil(context["contextPacket"])
    }
}

extension DocumentGraphTests {
    func testSentenceTargetAndParagraphAreDistinctEvidence() throws {
        var graph = graph()
        graph.blocks[1].childContentIDs = ["sentence"]
        var sentence = ContentBlock(contentID: "sentence", documentID: id, text: "boats against the current", sectionPath: [],
            readingOrder: 2, location: .page(9), contentType: .sentence, parentContentID: "current")
        sentence.textRange = ContentTextRange(startUTF16: 14, lengthUTF16: 25)
        graph.blocks[2].readingOrder = 3; graph.blocks.insert(sentence, at: 2); graph.linkBlocks()
        try graph.validate()
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: "against the current", nearbyText: "", retrievedIDs: [], history: [])
        XCTAssertEqual(packet.excerpts.first?.contentID, "sentence")
        XCTAssertEqual(packet.excerpts.first?.anchor.textRange, sentence.textRange)
        XCTAssertEqual(packet.excerpts.filter { $0.reason == .spatial }.first?.contentID, "current")
    }
    func testRetrievedFutureAndForeignDocumentAreExcluded() {
        let graph = graph()
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: nil, nearbyText: "", retrievedIDs: ["future"], history: [])
        XCTAssertFalse(packet.excerpts.contains { $0.contentID == "future" })
        let foreign = ContextPlanner.plan(graph: graph, documentID: UUID(), question: "why?", anchor: ContentAnchor(x: 0, y: 0),
            selectedText: nil, nearbyText: "OWN DOCUMENT", retrievedIDs: ["earlier"], history: [])
        XCTAssertFalse(foreign.indexReady)
        XCTAssertFalse(foreign.context.contains("time and memory"))
    }
    func testLongSpatialEvidenceLeavesRoomForEarlierRetrievalAndConversation() {
        var graph = graph()
        graph.blocks[1].text = String(repeating: "Long selected paragraph. ", count: 2000)
        graph.blocks[0].text = String(repeating: "Previous paragraph. ", count: 2000)
        let distant = ContentBlock(contentID: "distant", documentID: id, text: "RELATED EARLIER THEME", sectionPath: [], readingOrder: -1, location: .page(1))
        graph.blocks.insert(distant, at: 0); graph.linkBlocks()
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[2].anchor,
            selectedText: String(repeating: "marked ", count: 1000), nearbyText: "", retrievedIDs: ["distant"],
            history: [["question": "Explain the previous answer", "answer": "Previous answer evidence"]], threadSummary: String(repeating: "Older history ", count: 5000))
        XCTAssertTrue(packet.context.contains("RELATED EARLIER THEME"))
        XCTAssertFalse(packet.history.isEmpty)
        XCTAssertLessThanOrEqual(packet.estimatedTokens, 6000)
        XCTAssertLessThanOrEqual(packet.threadSummary.utf8.count, 600)
    }
}
