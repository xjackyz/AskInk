import Foundation
import SQLite3

// One persisted FTS5 database per document. Queries are bound, never SQL fragments.
final class LocalSearchIndex {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw ReaderError.message("无法打开本机全文索引。")
        }
        do {
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(content_id UNINDEXED, document_id UNINDEXED, reading_order UNINDEXED, terms)")
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ReaderError.message("本机全文索引操作失败。") }
    }
    func replace(graph: DocumentGraph) throws {
        try graph.validate()
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM passages")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "INSERT INTO passages(content_id,document_id,reading_order,terms) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK else {
                throw ReaderError.message("本机索引无法写入。")
            }
            defer { sqlite3_finalize(statement) }
            for block in graph.blocks where block.contentType != .sentence {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                bind(block.contentID, at: 1, to: statement)
                bind(graph.documentID.uuidString, at: 2, to: statement)
                sqlite3_bind_int64(statement, 3, Int64(block.readingOrder))
                bind(ReadingText.terms(block.text).sorted().joined(separator: " "), at: 4, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ReaderError.message("本机索引写入失败。") }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }
    func search(documentID: UUID, query: String, beforeOrder: Int? = nil, limit: Int = 30) throws -> [String] {
        let terms = ReadingText.terms(String(query.prefix(400))).sorted().prefix(40)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let expression = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        var statement: OpaquePointer?
        let sql = "SELECT content_id FROM passages WHERE passages MATCH ? AND document_id = ? AND CAST(reading_order AS INTEGER) < ? ORDER BY bm25(passages), CAST(reading_order AS INTEGER) LIMIT ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw ReaderError.message("本机搜索不可用。") }
        defer { sqlite3_finalize(statement) }
        bind(expression, at: 1, to: statement); bind(documentID.uuidString, at: 2, to: statement)
        sqlite3_bind_int64(statement, 3, Int64(beforeOrder ?? Int.max))
        sqlite3_bind_int(statement, 4, Int32(min(100, limit)))
        var ids: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { ids.append(String(cString: text)) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw ReaderError.message("本机搜索失败。") }
        return ids
    }
}

enum SemanticRanking {
    static func rank(blocks: [ContentBlock], query: ContentEmbedding, beforeOrder: Int? = nil, limit: Int = 30) -> [String] {
        guard !query.vector.isEmpty, query.vector.allSatisfy(\.isFinite) else { return [] }
        let norm = sqrt(query.vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return blocks.compactMap { block -> (String, Double)? in
            guard beforeOrder == nil || block.readingOrder < beforeOrder!, let embedding = block.embedding,
                  embedding.modelID == query.modelID, embedding.vector.count == query.vector.count,
                  embedding.vector.allSatisfy(\.isFinite) else { return nil }
            let otherNorm = sqrt(embedding.vector.reduce(0) { $0 + $1 * $1 })
            guard otherNorm > 0 else { return nil }
            let score = zip(query.vector, embedding.vector).reduce(0) { $0 + $1.0 * $1.1 } / (norm * otherNorm)
            guard score > 0.2 else { return nil }
            return (block.contentID, score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(max(0, limit)).map { $0.0 }
    }
    // Reciprocal rank fusion avoids comparing incompatible lexical/cosine scales.
    static func fuse(lexical: [String], semantic: [String], limit: Int) -> [String] {
        var scores: [String: Double] = [:]
        for list in [lexical, semantic] {
            for (rank, id) in list.enumerated() { scores[id, default: 0] += 1 / Double(60 + rank + 1) }
        }
        return scores.keys.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]! }.prefix(max(0, limit)).map { $0 }
    }
}
