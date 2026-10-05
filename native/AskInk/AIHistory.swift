import Foundation

/// threads.json is canonical. replies.json is read only for one-time migration.
enum AIHistory {
    static func threads(_ replies: [ReadingReply], documentID: UUID) throws -> [AIThread] {
        try Dictionary(grouping: replies, by: \.conversationID).map { id, records in
            let records = records.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            let first = records[0], start = first.createdAt ?? .distantPast
            let turns = try records.flatMap { reply -> [AITurn] in
                let date = reply.createdAt ?? .distantPast
                guard var metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any] else { throw ReaderError.message("会话格式无法读取。") }
                for key in ["question", "answer", "model", "inputTokens", "cachedTokens", "outputTokens", "citations"] { metadata.removeValue(forKey: key) }
                var questionID = reply.id.uuid; questionID.15 ^= 1
                return [AITurn(id: UUID(uuid: questionID), role: "user", text: reply.question, timestamp: date),
                    AITurn(id: reply.id, role: "assistant", text: reply.answer, citations: reply.citations ?? [], model: reply.model,
                        inputTokens: reply.inputTokens, cachedTokens: reply.cachedTokens, outputTokens: reply.outputTokens,
                        timestamp: date, metadata: try JSONSerialization.data(withJSONObject: metadata))]
            }
            return AIThread(id: id, documentID: documentID, questionInkIDs: first.questionInkIDs ?? [],
                recognizedQuestion: first.recognizedText ?? first.question, anchor: first.anchor,
                targetContentIDs: first.targetContentIDs ?? [], turns: turns, createdAt: start,
                updatedAt: records.last?.createdAt ?? start)
        }.sorted { $0.createdAt < $1.createdAt }
    }
    static func replies(_ threads: [AIThread]) throws -> [ReadingReply] {
        try threads.flatMap { thread in
            var question = ""
            return try thread.turns.compactMap { turn -> ReadingReply? in
                if turn.role == "user" { question = turn.text; return nil }
                guard turn.role == "assistant", let data = turn.metadata,
                      var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReaderError.message("会话记录不完整，原文件已保留。") }
                object["question"] = question; object["answer"] = turn.text; object["model"] = turn.model ?? ""
                object["inputTokens"] = turn.inputTokens; object["cachedTokens"] = turn.cachedTokens
                object["outputTokens"] = turn.outputTokens; object["citations"] = turn.citations
                return try JSONDecoder().decode(ReadingReply.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
    static func load(folder: URL, documentID: UUID) throws -> [ReadingReply] {
        let canonical = folder.appendingPathComponent("threads.json"), legacy = folder.appendingPathComponent("replies.json")
        if FileManager.default.fileExists(atPath: canonical.path) {
            let threads = try JSONDecoder().decode([AIThread].self, from: Data(contentsOf: canonical))
            guard threads.allSatisfy({ $0.documentID == documentID }) else { throw ReaderError.message("会话文档归属不匹配。") }
            return try replies(threads)
        }
        guard FileManager.default.fileExists(atPath: legacy.path) else { return [] }
        return try JSONDecoder().decode([ReadingReply].self, from: Data(contentsOf: legacy))
    }
    static func save(_ replies: [ReadingReply], folder: URL, documentID: UUID) throws {
        let value = try threads(replies, documentID: documentID)
        let data = try JSONEncoder().encode(value)
        // Verify round-trip before replacing the old file.
        _ = try self.replies(JSONDecoder().decode([AIThread].self, from: data))
        try data.write(to: folder.appendingPathComponent("threads.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        let legacy = folder.appendingPathComponent("replies.json")
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
    }
}
