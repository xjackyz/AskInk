import Foundation
import CoreGraphics

struct HandwritingRegion: Codable {
    var text: String
    var bounds: CGRect
    var strokeIDs: [UUID]
}
struct ReadingReply: Codable, Identifiable {
    var id = UUID()
    var page: Int
    var question: String
    var answer: String
    var source: String
    var model: String
    var inkImageDataURL: String? = nil
    var recognizedText: String? = nil
    var recognitionNote: String? = nil
    var recognitionSource: String? = nil
    var recognitionVersion: Int? = nil
    var recognitionRegions: [HandwritingRegion]? = nil
    var anchor: ContentAnchor? = nil
    var threadID: UUID? = nil
    var createdAt: Date? = Date()
    var sourceReferences: [ReadingSource]? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var contextPacket: ContextPacket? = nil
    var cachedTokens: Int? = nil
    var citations: [String]? = nil
    var questionInkIDs: [String]? = nil
    var targetContentIDs: [String]? = nil
    var mode: AnswerMode? = nil
    var allowedFuture: Bool? = nil
    var conversationID: UUID { threadID ?? id }
    func annotation(documentID: UUID) -> Annotation? {
        guard var anchor else { return nil }
        anchor.documentID = documentID
        if anchor.location == nil { anchor.location = .page(page) }
        return Annotation(id: id, documentID: documentID, anchor: anchor,
            semantics: .aiAnswer, text: answer, threadID: conversationID)
    }
}




struct AITurn: Codable, Identifiable, Sendable {
    var id: UUID
    var role: String
    var text: String
    var citations: [String] = []
    var model: String? = nil
    var inputTokens: Int? = nil
    var cachedTokens: Int? = nil
    var outputTokens: Int? = nil
    var timestamp: Date
    // Legacy recognition/images/geometry retained without duplicating Q&A text.
    var metadata: Data? = nil
}
struct AIThread: Codable, Identifiable, Sendable {
    var id: UUID
    var documentID: UUID
    var questionInkIDs: [String]
    var recognizedQuestion: String
    var anchor: ContentAnchor?
    var targetContentIDs: [String]
    var turns: [AITurn]
    var createdAt: Date
    var updatedAt: Date
}

enum ThreadContext {
    /// Deterministic extractive summary: no extra model call and no invented history.
    static func compressed(_ history: [[String: String]]) -> (summary: String, recent: [[String: String]]) {
        if history.count <= 4 { return ("", ReadingText.budgetHistory(history)) }
        let older = history.dropLast(2)
        let summary = older.suffix(8).map {
            "Q: " + String(($0["question"] ?? "").prefix(100)) + "\nA: " + String(($0["answer"] ?? "").prefix(160))
        }.joined(separator: "\n")
        return (String(summary.suffix(1600)), ReadingText.budgetHistory(Array(history.suffix(2))))
    }
}
