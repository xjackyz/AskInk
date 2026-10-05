import XCTest
@testable import InkAlgorithms

final class MultimodalRequestTests: XCTestCase {
    private let ink = "data:image/png;base64,AQID"
    private let page = "data:image/jpeg;base64,BAUG"
    private func payload(_ provider: AIProvider, includeImage: Bool = true,
                         question: String = "∇f ⟂ ?", inkOverride: String? = nil) throws -> [String: Any] {
        let connection = AIConnection(provider: provider, model: "test-model",
            endpoint: provider == .compatible ? "https://example.com/v1/chat/completions" : provider.defaultEndpoint,
            includeImage: includeImage)
        let request = try AIRequest.request(connection: connection, key: "test-key", body: [
            "question": question, "context": "正文", "pageNumber": 2,
            "questionOrigin": "automaticHandwriting", "recognitionNote": "低分转录",
            "handwritingImageDataUrl": inkOverride ?? ink, "pageImageDataUrl": page
        ])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func content(_ payload: [String: Any], provider: AIProvider) throws -> [[String: Any]] {
        let messages = try XCTUnwrap(payload[provider == .openAI ? "input" : "messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
    }
    func testOpenAIReceivesIndependentInkAndSourceImages() throws {
        let blocks = try content(payload(.openAI), provider: .openAI)
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "input_image" }.compactMap { $0["image_url"] as? String }, [ink, page])
        let dataText = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertFalse(dataText.contains("base64"))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(dataText.utf8)) as? [String: Any])
        XCTAssertEqual(context["question"] as? String, "∇f ⟂ ?")
        XCTAssertEqual(context["context"] as? String, "正文")
        XCTAssertEqual(context["recognitionNote"] as? String, "低分转录")
        XCTAssertTrue((blocks[1]["text"] as? String ?? "").contains("手写问题"))
        XCTAssertTrue((blocks[3]["text"] as? String ?? "").contains("附近正文"))
    }
    func testClaudePreservesPNGInkAndJPEGSourceTypes() throws {
        let blocks = try content(payload(.claude), provider: .claude)
        let sources = blocks.filter { $0["type"] as? String == "image" }.compactMap { $0["source"] as? [String: Any] }
        XCTAssertEqual(sources.compactMap { $0["media_type"] as? String }, ["image/png", "image/jpeg"])
        XCTAssertEqual(sources.compactMap { $0["data"] as? String }, ["AQID", "BAUG"])
    }
    func testCompatibleAPIReceivesBothImages() throws {
        let blocks = try content(payload(.compatible), provider: .compatible)
        let images = blocks.filter { $0["type"] as? String == "image_url" }.compactMap { $0["image_url"] as? [String: String] }
        XCTAssertEqual(images.compactMap { $0["url"] }, [ink, page])
    }
    func testFailedTranscriptionCanStillAskWithInk() throws {
        let blocks = try content(payload(.openAI, question: ""), provider: .openAI)
        XCTAssertEqual(blocks.filter { $0["type"] as? String == "input_image" }.count, 2)
    }
    func testTextOnlyConnectionCannotSilentlyDropHandwrittenMath() {
        XCTAssertThrowsError(try payload(.compatible, includeImage: false))
    }
    func testCorruptInkIsRejectedRatherThanLeakingIntoText() {
        XCTAssertThrowsError(try payload(.claude, inkOverride: "data:image/png;base64,invalid!"))
        XCTAssertThrowsError(try payload(.openAI, inkOverride: "data:image/png;base64,"))
    }
    func testOldTextOnlyQuestionsRemainSupported() throws {
        let connection = AIConnection(provider: .compatible, model: "test-model",
            endpoint: "https://example.com/v1/chat/completions", includeImage: false)
        XCTAssertNoThrow(try AIRequest.request(connection: connection, key: "test-key", body: ["question": "为什么？", "context": "正文"]))
    }
    func testHistoryBudgetAndUsageReporting() throws {
        let connection = AIConnection(provider: .openAI, model: "test-model", endpoint: AIProvider.openAI.defaultEndpoint, includeImage: true)
        let request = try AIRequest.request(connection: connection, key: "test-key", body: ["question": "为什么？", "context": "正文",
            "history": (1...8).map { ["question": "q\($0)", "answer": String(repeating: "答", count: 1000)] }])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let blocks = try content(payload, provider: .openAI)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(blocks.first?["text"] as? String).utf8)) as? [String: Any])
        let history = try XCTUnwrap(body["history"] as? [[String: String]])
        XCTAssertLessThanOrEqual(history.reduce(0) { $0 + ($1["question"]?.count ?? 0) + ($1["answer"]?.count ?? 0) }, 1400)
        let response: [String: Any] = ["status": "completed", "model": "test-model", "usage": ["input_tokens": 123, "output_tokens": 45],
            "output": [["content": [["type": "output_text", "text": "{\"answer\":\"答\",\"needsClarification\":false}"]]]]]
        let decoded = try AIRequest.decode(data: JSONSerialization.data(withJSONObject: response), status: 200, connection: connection)
        XCTAssertEqual(decoded.inputTokens, 123); XCTAssertEqual(decoded.outputTokens, 45)
    }
    func testSummaryInputIsNotPrefixTruncated() throws {
        let connection = AIConnection(provider: .openAI, model: "test-model", endpoint: AIProvider.openAI.defaultEndpoint, includeImage: true)
        let text = String(repeating: "字", count: 4500) + "最后的否定"
        let request = try AIRequest.request(connection: connection, key: "test-key", body: ["task": "summary", "question": "总结", "context": text])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let blocks = try content(payload, provider: .openAI)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(blocks.first?["text"] as? String).utf8)) as? [String: Any])
        XCTAssertEqual(body["context"] as? String, text)
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 1000)
    }
}
