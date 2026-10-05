import Foundation

struct ContextExcerpt: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case selection, spatial, neighbor, section, retrieval, memory }
    var contentID: String
    var anchor: ContentAnchor
    var text: String
    var reason: Reason
}
struct ContextPacket: Codable, Equatable, Sendable {
    var mode: AnswerMode = .compact
    var spoilerPolicy = "up_to_current_position"
    var readingPosition: ContentAnchor? = nil
    var threadSummary = ""
    var documentID: UUID
    var revision: String
    var question: String
    var excerpts: [ContextExcerpt]
    var history: [[String: String]]
    var textCharacters: Int
    var estimatedTokens: Int // Conservative UTF-8 byte bound; not measured API usage.
    var truncated: Bool
    var indexReady: Bool
    var context: String { excerpts.map { "[\($0.contentID)] \($0.text)" }.joined(separator: "\n\n") }
    var wireValue: [String: Any] {
        func values(_ reasons: Set<ContextExcerpt.Reason>) -> [[String: String]] {
            excerpts.filter { reasons.contains($0.reason) }.map {
                ["source_id": $0.contentID, "text": $0.text,
                 "location": $0.anchor.location?.pageNumber.map { "page:\($0)" } ?? $0.anchor.location?.locator ?? ""]
            }
        }
        return ["mode": mode.rawValue, "question": question,
            "document": ["id": documentID.uuidString, "revision": revision],
            "targets": values([.selection]), "local_context": values([.spatial, .neighbor, .section]),
            "retrieved_context": values([.retrieval, .memory]), "recent_turns": history,
            "thread_summary": threadSummary, "spoiler_policy": spoilerPolicy,
            "reading_position": readingPosition?.location?.pageNumber.map { "page:\($0)" } ?? "",
            "truncated": truncated, "indexReady": indexReady]

    }
}

enum ContextPlanner {
    // Evidence and history share a hard text bound. Images/output have separate costs.
    static func plan(graph: DocumentGraph?, documentID: UUID, question: String,
        anchor: ContentAnchor, selectedText: String?, nearbyText: String,
        retrievedIDs: [String], history: [[String: String]], tokenBudget: Int = 6000, allowFuture: Bool = false, threadSummary: String = "") -> ContextPacket {
        let graph = graph?.documentID == documentID ? graph : nil
        var remaining = max(0, tokenBudget), truncated = false
        var excerpts: [ContextExcerpt] = [], seen = Set<String>()
        func bounded(_ text: String, cap: Int) -> String {
            var result = "", used = 0
            for character in text {
                let value = String(character), size = value.utf8.count
                guard used + size <= cap else { break }
                result += value; used += size
            }
            if result.count < text.count { truncated = true }
            return result
        }
        // Reserve recent conversation before broad evidence; otherwise a long
        // paragraph can erase the context needed to understand a follow-up.
        var budgetedHistory: [[String: String]] = []
        var historyAllowance = min(1000, remaining / 4)
        for item in history.reversed().prefix(4) where historyAllowance > 0 {
            let q = bounded(item["question"] ?? "", cap: min(240, historyAllowance))
            historyAllowance -= q.utf8.count; remaining -= q.utf8.count
            let a = bounded(item["answer"] ?? "", cap: min(600, historyAllowance))
            historyAllowance -= a.utf8.count; remaining -= a.utf8.count
            budgetedHistory.append(["question": q, "answer": a])
        }
        let summary = bounded(threadSummary, cap: min(600, remaining / 8))
        remaining -= summary.utf8.count
        // IDs and separators count towards the evidence budget too.
        func append(id: String, text: String, anchor: ContentAnchor, reason: ContextExcerpt.Reason) {
            guard !seen.contains(id), !text.isEmpty else { return }
            let overhead = id.utf8.count + 8
            guard remaining > overhead else { truncated = true; return }
            let cap: Int
            switch reason {
            case .selection: cap = 800
            case .spatial: cap = 1200
            case .neighbor: cap = 450
            case .retrieval: cap = 900
            case .section: cap = 400
            case .memory: cap = 700
            }
            let value = bounded(text, cap: min(cap, remaining - overhead))
            guard !value.isEmpty else { return }
            remaining -= value.utf8.count + overhead; seen.insert(id)
            excerpts.append(ContextExcerpt(contentID: id, anchor: anchor, text: value, reason: reason))
        }
        let allBlocks = graph?.blocks ?? []
        let passages = allBlocks.filter { $0.contentType != .sentence }
        let positionBlock = anchor.contentID.flatMap { id in allBlocks.first { $0.contentID == id } }
            ?? passages.filter { block in
                if anchor.location?.kind == .reflowable { return block.location.locator == anchor.location?.locator }
                return block.location.pageNumber == anchor.location?.pageNumber
            }.min { a, b in
                func distance(_ block: ContentBlock) -> Double {
                    if let selectedText, !selectedText.isEmpty, block.text.contains(selectedText) { return -1 }
                    guard let rect = block.location.boundingRect else { return 0 }
                    return hypot(rect.midX - anchor.x, rect.midY - anchor.y)
                }
                return distance(a) < distance(b)
            }
        let orderBoundary = positionBlock?.readingOrder
        let blocks = passages.filter { block in
            if allowFuture { return true }
            if let orderBoundary { return block.readingOrder <= orderBoundary }
            return false
        }
        let eligibleIDs = Set(blocks.map(\.contentID))
        let byID = Dictionary(uniqueKeysWithValues: allBlocks.map { ($0.contentID, $0) })
        let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let anchored = positionBlock
        let current = anchored?.parentContentID.flatMap { byID[$0] } ?? anchored ?? blocks.filter {
            $0.location.kind == anchor.location?.kind &&
            (anchor.location?.kind == .fixedPage ? $0.location.pageNumber == anchor.location?.pageNumber : $0.location.locator == anchor.location?.locator)
        }.min { a, b in
            func distance(_ block: ContentBlock) -> Double {
                if !selected.isEmpty, block.text.contains(selected) { return -1 }
                guard let rect = block.location.boundingRect else { return 0 }
                return hypot(rect.midX - anchor.x, rect.midY - anchor.y)
            }
            return distance(a) < distance(b)
        }
        if !selected.isEmpty {
            let sentence = current?.childContentIDs?.compactMap { byID[$0] }.first { $0.text.contains(selected) }
            var selectionAnchor = sentence?.anchor ?? current?.anchor ?? anchor; selectionAnchor.textQuote = selected
            append(id: sentence?.contentID ?? "selection:\(current?.contentID ?? documentID.uuidString)", text: selected, anchor: selectionAnchor, reason: .selection)
        }
        if let current {
            append(id: current.contentID, text: current.text, anchor: current.anchor, reason: .spatial)
            if let index = blocks.firstIndex(where: { $0.contentID == current.contentID }) {
                for neighbor in [index - 1, index + 1] where blocks.indices.contains(neighbor) {
                    let block = blocks[neighbor]
                    append(id: block.contentID, text: block.text, anchor: block.anchor, reason: .neighbor)
                }
            }
        } else { append(id: "nearby:\(documentID.uuidString)", text: nearbyText, anchor: anchor, reason: .spatial) }
        // Ranked whole-document candidates precede the section preview, so broad context
        // cannot crowd out relevant earlier evidence.
        for id in retrievedIDs.prefix(tokenBudget > 6000 ? 8 : 4) {
            if eligibleIDs.contains(id), let block = byID[id] { append(id: id, text: block.text, anchor: block.anchor, reason: .retrieval) }
        }
        if let current, let sectionID = current.sectionPath.last,
           let overview = blocks.first(where: { $0.sectionPath.contains(sectionID) }) {
            append(id: overview.contentID, text: overview.text, anchor: overview.anchor, reason: .section)
        }
        for (index, memory) in (graph?.memory ?? []).enumerated() {
            guard let first = memory.sourceContentIDs.first.flatMap({ byID[$0] }) else { continue }
            // Memories containing future material are omitted from a current reading question.
            if !allowFuture && (orderBoundary == nil || memory.sourceContentIDs.contains(where: { (byID[$0]?.readingOrder ?? Int.max) > orderBoundary! })) { continue }
            append(id: "memory:\(index):\(graph?.revision ?? "")", text: "[\(memory.kind)] " + memory.text, anchor: first.anchor, reason: .memory)
        }
        let chars = summary.count + excerpts.reduce(0) { $0 + $1.text.count } + budgetedHistory.reduce(0) { $0 + ($1["question"]?.count ?? 0) + ($1["answer"]?.count ?? 0) }
        return ContextPacket(spoilerPolicy: allowFuture ? "allow_future" : "up_to_current_position", readingPosition: anchor, threadSummary: summary, documentID: documentID, revision: graph?.revision ?? "unindexed", question: question,
            excerpts: excerpts, history: budgetedHistory.reversed(), textCharacters: chars,
            estimatedTokens: max(0, tokenBudget) - remaining, truncated: truncated, indexReady: graph != nil)
    }
}

// Existing replies may contain the earlier packet schema.
extension ContextPacket {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(AnswerMode.self, forKey: .mode) ?? .compact
        spoilerPolicy = try c.decodeIfPresent(String.self, forKey: .spoilerPolicy) ?? "up_to_current_position"
        readingPosition = try c.decodeIfPresent(ContentAnchor.self, forKey: .readingPosition)
        threadSummary = try c.decodeIfPresent(String.self, forKey: .threadSummary) ?? ""
        documentID = try c.decode(UUID.self, forKey: .documentID)
        revision = try c.decode(String.self, forKey: .revision)
        question = try c.decode(String.self, forKey: .question)
        excerpts = try c.decode([ContextExcerpt].self, forKey: .excerpts)
        history = try c.decode([[String: String]].self, forKey: .history)
        textCharacters = try c.decode(Int.self, forKey: .textCharacters)
        estimatedTokens = try c.decode(Int.self, forKey: .estimatedTokens)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        indexReady = try c.decode(Bool.self, forKey: .indexReady)
    }
}
