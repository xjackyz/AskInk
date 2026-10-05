import XCTest
@testable import InkAlgorithms

final class AIReadingTests: XCTestCase {
    private func connection(_ provider: AIProvider = .openAI) -> AIConnection {
        AIConnection(provider: provider, model: "fixture", endpoint: "https://example.com/v1/responses", includeImage: true)
    }
    private func event(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func testStreamingJSONHandlesUnicodeAndEscapedQuotesWithoutShowingKeys() {
        XCTAssertEqual(StreamingAnswerText.visible(#"{"answer":"why \"eternal\"? \u4e2d"#), "why \"eternal\"? 中")
        XCTAssertEqual(StreamingAnswerText.visible(#"{"answer":"中\u4e"#), "中")
        XCTAssertEqual(StreamingAnswerText.visible(#"{"answ"#), "")
        XCTAssertEqual(StreamingAnswerText.visible(#"{"answer":"line\nnext","citations":["s1"]}"#), "line\nnext")
    }
    func testOpenAIStreamRejectsTruncationAndKeepsCachedUsage() throws {
        var stream = AIStreamAccumulator(connection: connection())
        try stream.accept(event(["type": "response.output_text.delta", "delta": "{\"answer\":\"答"] ))
        XCTAssertEqual(stream.visibleText, "答")
        XCTAssertThrowsError(try stream.result())
        let response: [String: Any] = ["status": "completed", "usage": ["input_tokens": 100, "output_tokens": 12, "input_tokens_details": ["cached_tokens": 80]],
            "output": [["content": [["type": "output_text", "text": "{\"answer\":\"答\",\"needsClarification\":false,\"citations\":[\"s1\"],\"needs_more_context\":true,\"retrieval_query\":\"definition\"}"]]]]]
        try stream.accept(event(["type": "response.completed", "response": response]))
        let result = try stream.result()
        XCTAssertEqual(result.cachedTokens, 80); XCTAssertEqual(result.citations, ["s1"])
        XCTAssertTrue(result.needsMoreContext); XCTAssertEqual(result.retrievalQuery, "definition")
        XCTAssertThrowsError(try stream.accept(event(["type": "response.incomplete"])))
    }
    func testClaudeStreamRequiresEndTurn() throws {
        var stream = AIStreamAccumulator(connection: connection(.claude))
        try stream.accept(event(["type": "message_start", "message": ["usage": ["input_tokens": 80, "cache_read_input_tokens": 40]]]))
        try stream.accept(event(["type": "content_block_delta", "delta": ["text": "{\"answer\":\"答\",\"needsClarification\":false}"]]))
        try stream.accept(event(["type": "message_delta", "delta": ["stop_reason": "max_tokens"], "usage": ["output_tokens": 20]]))
        try stream.accept(event(["type": "message_stop"]))
        XCTAssertThrowsError(try stream.result())
    }
    func testCompatibleStreamPreservesUsageTrailerAndDoesNotCommitBeforeStop() throws {
        var stream = AIStreamAccumulator(connection: connection(.compatible))
        try stream.accept(event(["choices": [["delta": ["content": "plain answer"]]]]))
        XCTAssertEqual(stream.visibleText, "plain answer"); XCTAssertThrowsError(try stream.result())
        try stream.accept(event(["choices": [["delta": [:], "finish_reason": "stop"]]]))
        try stream.accept(event(["choices": [], "usage": ["prompt_tokens": 11, "completion_tokens": 3, "prompt_tokens_details": ["cached_tokens": 5]]]))
        try stream.accept("[DONE]")
        XCTAssertEqual(try stream.result().inputTokens, 11); XCTAssertEqual(try stream.result().cachedTokens, 5)
    }
    func testCompactAndExpandedRequestBudgetsAndNoProviderConversation() throws {
        for mode in ["compact", "expanded"] {
            let request = try AIRequest.request(connection: connection(), key: "fixture", body: ["question": "?", "context": "source", "mode": mode, "stream": true])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(json["max_output_tokens"] as? Int, mode == "compact" ? 700 : 1600)
            XCTAssertEqual(json["stream"] as? Bool, true); XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertNil(json["previous_response_id"])
        }
    }
    func testThreadCompressionKeepsLatestTurnsAndBoundsSummary() {
        let history = (0..<30).map { ["question": "q\($0)", "answer": String(repeating: "a", count: 1000)] }
        let compressed = ThreadContext.compressed(history)
        XCTAssertEqual(compressed.recent.compactMap { $0["question"] }, ["q28", "q29"])
        XCTAssertLessThanOrEqual(compressed.summary.count, 1600)
        XCTAssertFalse(compressed.summary.contains("q29"))
    }
    func testSpoilerBoundaryFiltersNeighborsRetrievalAndMemory() {
        let id = UUID()
        var graph = DocumentGraph(documentID: id, revision: "r", sections: [], blocks: (0..<3).map {
            ContentBlock(contentID: "s\($0)", documentID: id, text: "evidence \($0)", sectionPath: [], readingOrder: $0, location: .page($0 + 1))
        }, memory: [DocumentMemory(text: "spoiler", sourceContentIDs: ["s0", "s2"], kind: "generated")])
        graph.linkBlocks()
        let packet = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: nil, nearbyText: "", retrievedIDs: ["s2", "s0"], history: [])
        XCTAssertFalse(packet.context.contains("evidence 2")); XCTAssertFalse(packet.context.contains("spoiler"))
        let optedIn = ContextPlanner.plan(graph: graph, documentID: id, question: "why?", anchor: graph.blocks[1].anchor,
            selectedText: nil, nearbyText: "", retrievedIDs: ["s2"], history: [], allowFuture: true)
        XCTAssertTrue(optedIn.context.contains("evidence 2")); XCTAssertTrue(optedIn.context.contains("spoiler"))
    }
    func testCitationValidationRejectsFabricatedInlineAndStructuredSources() throws {
        let valid = AnswerResult(answer: "解释 [s1]", needsClarification: false, model: "fixture", citations: ["s1"])
        XCTAssertNoThrow(try SourceCitations.validate(valid, supplied: ["s1"]))
        XCTAssertThrowsError(try SourceCitations.validate(valid, supplied: []))
        XCTAssertThrowsError(try SourceCitations.validate(AnswerResult(answer: "解释 [fake]", needsClarification: false, model: "fixture"), supplied: ["s1"]))
    }
    func testLegacyPacketStillDecodes() throws {
        let id = UUID()
        let packet = ContextPlanner.plan(graph: nil, documentID: id, question: "?", anchor: ContentAnchor(x: 0, y: 0, location: .page(1)), selectedText: nil, nearbyText: "source", retrievedIDs: [], history: [])
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(packet)) as? [String: Any])
        for key in ["mode", "spoilerPolicy", "readingPosition", "threadSummary"] { value.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ContextPacket.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(decoded.mode, .compact); XCTAssertEqual(decoded.spoilerPolicy, "up_to_current_position")
    }
}
