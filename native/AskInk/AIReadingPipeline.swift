import Foundation

struct PreparedReadingAnswer {
    var result: AnswerResult
    var packet: ContextPacket
    var sources: [ReadingSource]
}

/// Both ink questions and follow-ups use this single bounded request pipeline.
actor AIReadingPipeline {
    static let shared = AIReadingPipeline()
    func answer(documentID: UUID, fileURL: URL, question: String, anchor: ContentAnchor,
                selectedText: String?, nearbyText: String, history: [[String: String]],
                mode: AnswerMode, allowFuture: Bool, repeatedQuestions: Int,
                connection: AIConnection, key: String, extra: [String: Any],
                onText: @Sendable (String) async -> Void) async throws -> PreparedReadingAnswer {
        let compressed = ThreadContext.compressed(history)
        var graph = await LocalDocumentIndex.shared.graph(fileURL: fileURL)
        var locatedAnchor = anchor
        if let blocks = graph?.blocks.filter({ $0.location.pageNumber == anchor.location?.pageNumber }),
           let nearest = blocks.min(by: {
               func distance(_ b: ContentBlock) -> Double {
                   if let selectedText, !selectedText.isEmpty, b.text.contains(selectedText) { return -1 }
                   let r = b.location.boundingRect ?? .zero
                   return hypot(r.midX - anchor.x, r.midY - anchor.y)
               }
               return distance($0) < distance($1)
           }) { locatedAnchor.contentID = nearest.contentID }
        let boundary = locatedAnchor.contentID.flatMap { id in graph?.blocks.first { $0.contentID == id }?.readingOrder }
        let searchQuery = question + " " + String((selectedText ?? nearbyText).prefix(350))
        var ids = await LocalDocumentIndex.shared.hybridSearch(fileURL: fileURL, query: searchQuery,
            through: allowFuture ? nil : anchor.location?.pageNumber, limit: mode == .expanded ? 8 : 4).map(\.id)
        // Lazy section memory: never summarize at import or on the first ordinary question.
        if graph != nil {
            if let memory = try? await LocalDocumentIndex.shared.memory(fileURL: fileURL, documentID: documentID,
                contentID: ids.first ?? locatedAnchor.contentID, throughOrder: allowFuture ? nil : boundary,
                connection: connection.routed(mode: .compact), key: key,
                allowGenerate: repeatedQuestions >= 3 || (mode == .expanded && !ids.isEmpty)) {
                graph?.memory.append(memory)
            }
        }
        func packet() -> ContextPacket {
            var value = ContextPlanner.plan(graph: graph, documentID: documentID, question: question,
                anchor: locatedAnchor, selectedText: selectedText, nearbyText: nearbyText,
                retrievedIDs: ids, history: compressed.recent, tokenBudget: max(0, (mode == .compact ? 6000 : 18000) - compressed.summary.utf8.count - question.utf8.count),
                allowFuture: allowFuture, threadSummary: compressed.summary)
            value.mode = mode
            return value
        }
        var context = packet()
        func body(_ packet: ContextPacket) -> [String: Any] {
            var value = extra
            value["question"] = question; value["mode"] = mode.rawValue
            value["context"] = packet.context; value["contextPacket"] = packet.wireValue
            value["prompt_version"] = AIRequest.promptVersion
            return value
        }
        var result = try await AIRequest.stream(connection: connection.routed(mode: mode), key: key, body: body(context), onText: onText)
        if result.needsMoreContext, !result.retrievalQuery.isEmpty, graph != nil {
            let more = await LocalDocumentIndex.shared.hybridSearch(fileURL: fileURL, query: result.retrievalQuery,
                through: allowFuture ? nil : anchor.location?.pageNumber, limit: 8).map(\.id)
            if more.contains(where: { !ids.contains($0) }) {
                let previous = context
                ids = more + ids.filter { !more.contains($0) }; context = packet()
                if context.excerpts != previous.excerpts {
                await onText("")
                let firstUsage = result
                result = try await AIRequest.stream(connection: connection.routed(mode: mode), key: key, body: body(context), onText: onText)
                result.inputTokens = sum(firstUsage.inputTokens, result.inputTokens)
                result.cachedTokens = sum(firstUsage.cachedTokens, result.cachedTokens)
                result.outputTokens = sum(firstUsage.outputTokens, result.outputTokens)
                }
            }
        }
        let supplied = Set(context.excerpts.map(\.contentID))
        try SourceCitations.validate(result, supplied: supplied)
        try Task.checkCancellation()
        let sources = context.excerpts.compactMap { excerpt -> ReadingSource? in
            guard let page = excerpt.anchor.location?.pageNumber else { return nil }
            return ReadingSource(id: excerpt.contentID, page: page, text: excerpt.text, bounds: excerpt.anchor.location?.boundingRect ?? .zero)
        }
        return PreparedReadingAnswer(result: result, packet: context, sources: sources)
    }
    private func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
}
