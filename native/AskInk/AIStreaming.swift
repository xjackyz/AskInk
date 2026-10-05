import Foundation

/// SSE assembly shared by all providers. No partial response is committed to history.
struct AIStreamAccumulator {
    var connection: AIConnection
    private(set) var rawText = ""
    private(set) var completed: [String: Any]?
    private var usage: [String: Any] = [:]
    private var model: String?
    private var stopReason: String?
    mutating func accept(_ data: String) throws {
        guard data != "[DONE]", let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return }
        if let error = object["error"] as? [String: Any] { throw ReaderError.message(error["message"] as? String ?? "AI 流式请求失败。") }
        switch connection.provider {
        case .openAI:
            switch object["type"] as? String {
            case "response.output_text.delta": rawText += object["delta"] as? String ?? ""
            case "response.completed": completed = object["response"] as? [String: Any]
            case "response.failed", "response.incomplete", "error", "response.refusal.delta":
                throw ReaderError.message("AI 未返回完整回答，请重试。")
            default: break
            }
        case .claude:
            if let message = object["message"] as? [String: Any] {
                model = message["model"] as? String
                usage = message["usage"] as? [String: Any] ?? [:]
            }
            if let delta = object["delta"] as? [String: Any] {
                rawText += delta["text"] as? String ?? ""
                if let reason = delta["stop_reason"] as? String { stopReason = reason }
            }
            if let update = object["usage"] as? [String: Any] { usage.merge(update) { _, new in new } }
            if object["type"] as? String == "message_stop" {
                completed = ["model": model ?? connection.model, "usage": usage, "stop_reason": stopReason ?? "unknown",
                    "content": [["type": "text", "text": rawText]]]
            }
        case .compatible:
            model = object["model"] as? String ?? model
            if let update = object["usage"] as? [String: Any] { usage = update }
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw ReaderError.message(refusal) }
                rawText += delta["content"] as? String ?? ""
                if let reason = choice["finish_reason"] as? String { stopReason = reason }
            }
            if let stopReason {
                completed = ["model": model ?? connection.model, "usage": usage,
                    "choices": [["finish_reason": stopReason, "message": ["content": rawText]]]]
            }
        }
    }
    var visibleText: String {
        let parsed = StreamingAnswerText.visible(rawText)
        return connection.provider == .compatible && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ? rawText : parsed
    }
    func result() throws -> AnswerResult {
        guard let completed else { throw ReaderError.message("连接中断，回答未完成，请重试。") }
        return try AIRequest.decode(data: JSONSerialization.data(withJSONObject: completed), status: 200, connection: connection)
    }
}

#if !SWIFT_PACKAGE
extension AIRequest {
    static func stream(connection: AIConnection, key: String, body: [String: Any],
                       onText: @Sendable (String) async -> Void) async throws -> AnswerResult {
        var body = body; body["stream"] = true
        let request = try request(connection: connection, key: key, body: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReaderError.message("AI 没有返回有效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { if data.count < 65536 { data.append(byte) } }
            return try decode(data: data, status: http.statusCode, connection: connection)
        }
        // Some compatible providers ignore stream=true and return ordinary JSON.
        if !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 2_000_000 else { throw ReaderError.message("AI 返回内容过大。") }
                data.append(byte)
            }
            let result = try decode(data: data, status: http.statusCode, connection: connection)
            await onText(result.answer); return result
        }
        var accumulator = AIStreamAccumulator(connection: connection), eventData: [String] = [], last = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if !eventData.isEmpty {
                    try accumulator.accept(eventData.joined(separator: "\n")); eventData.removeAll()
                    let text = accumulator.visibleText
                    if text != last { last = text; await onText(text) }
                }
            } else if line.hasPrefix("data:") {
                eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
            guard accumulator.rawText.utf8.count < 2_000_000 else { throw ReaderError.message("AI 返回内容过大。") }
        }
        if !eventData.isEmpty { try accumulator.accept(eventData.joined(separator: "\n")) }
        try Task.checkCancellation()
        let result = try accumulator.result()
        await onText(result.answer)
        return result
    }
}
#endif
