import Foundation

struct DocumentIndex: Codable, Sendable {
    var version = 2
    var fileStamp: String
    var pageCount: Int
    var graph: DocumentGraph
    var lines: [Int: [SourceTextLine]]
    var unreadablePages: [Int]
    // Legacy PDF UI projections; storage/search/context use the graph.
    var sources: [ReadingSource] { graph.blocks.filter { $0.contentType != .sentence }.compactMap(ReadingSource.init(block:)) }
    var semanticBlockCount: Int { graph.blocks.filter { $0.embedding != nil }.count }
}

actor LocalDocumentIndex {
    static let shared = LocalDocumentIndex()
    private var cached: [URL: DocumentIndex] = [:]
    private var fullText: [URL: LocalSearchIndex] = [:]
    private var partialLines: [URL: [Int: [SourceTextLine]]] = [:]
    private var generations: [URL: UUID] = [:]
    static func stamp(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.size] ?? 0)-\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    func lines(fileURL: URL, page: Int) -> [SourceTextLine] { cached[fileURL]?.lines[page] ?? partialLines[fileURL]?[page] ?? [] }
    func graph(fileURL: URL) -> DocumentGraph? { cached[fileURL]?.graph }
    func searchIDs(fileURL: URL, query: String, beforeOrder: Int? = nil, limit: Int = 30) -> [String] {
        guard let graph = cached[fileURL]?.graph else { return [] }
        let lexical = (try? fullText[fileURL]?.search(documentID: graph.documentID, query: query, beforeOrder: beforeOrder, limit: 30)) ?? []
        let semantic = NativeSemanticIndex.embed(query).map { SemanticRanking.rank(blocks: graph.blocks, query: $0, beforeOrder: beforeOrder) } ?? []
        return SemanticRanking.fuse(lexical: lexical, semantic: semantic, limit: limit)
    }
    func search(fileURL: URL, query: String, before page: Int? = nil, limit: Int = 3) -> [ReadingSource] {
        guard let index = cached[fileURL] else { return [] }
        let cutoff = page.flatMap { number in index.graph.blocks.first { ($0.location.pageNumber ?? Int.max) >= number }?.readingOrder }
        let ids = searchIDs(fileURL: fileURL, query: query, beforeOrder: cutoff, limit: limit)
        let byID = Dictionary(uniqueKeysWithValues: index.sources.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }
    func hybridSearch(fileURL: URL, query: String, through page: Int?, limit: Int) -> [ReadingSource] {
        guard let graph = cached[fileURL]?.graph else { return [] }
        let cutoff = page.flatMap { number in graph.blocks.first { ($0.location.pageNumber ?? Int.max) > number }?.readingOrder }
        let ids = searchIDs(fileURL: fileURL, query: query, beforeOrder: cutoff, limit: limit)
        let byID = Dictionary(uniqueKeysWithValues: graph.blocks.map { ($0.contentID, $0) })
        return ids.compactMap { byID[$0].flatMap(ReadingSource.init(block:)) }.filter { page == nil || $0.page <= page! }
    }
    func memory(fileURL: URL, documentID: UUID, contentID: String?, throughOrder: Int?,
                connection: AIConnection, key: String, allowGenerate: Bool) async throws -> DocumentMemory? {
        guard let graph = graph(fileURL: fileURL), graph.documentID == documentID, let contentID,
              let block = graph.blocks.first(where: { $0.contentID == contentID }),
              let section = graph.sections.first(where: { $0.id == block.sectionPath.last }),
              throughOrder == nil || section.endOrder <= throughOrder! else { return nil }
        let sources = graph.blocks.filter { $0.contentType != .sentence && $0.readingOrder >= section.startOrder && $0.readingOrder <= section.endOrder }
        // Avoid costly implicit multi-chunk summarization of large chapters.
        let text = sources.map(\.text).joined(separator: "\n")
        guard !text.isEmpty, text.utf8.count <= 24000 else { return nil }
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("reading-memory-v1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(section.startOrder)-\(section.endOrder).json")
        struct Cache: Codable { var revision: String; var memory: DocumentMemory }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Cache.self, from: data), saved.revision == graph.revision { return saved.memory }
        guard allowGenerate else { return nil }
        let request = try AIRequest.request(connection: connection, key: key, body: ["task": "summary",
            "question": "Create a concise 150–300 token reading memory: ideas, entities, claims, definitions and relationships. Preserve uncertainty.", "context": text])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        let answer = try AIRequest.decode(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 500, connection: connection)
        let memory = DocumentMemory(text: String(answer.answer.prefix(1200)), sourceContentIDs: sources.map(\.contentID), kind: "generated section memory")
        try JSONEncoder().encode(Cache(revision: graph.revision, memory: memory)).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return memory
    }
    func rememberSummary(fileURL: URL, text: String, coveredPages: [Int]) throws -> DocumentGraph? {
        guard var index = cached[fileURL] else { return nil }
        let pages = Set(coveredPages)
        let ids = index.graph.blocks.filter { $0.contentType != .sentence && ($0.location.pageNumber.map(pages.contains) ?? false) }.map(\.contentID)
        guard !ids.isEmpty else { return nil }
        index.graph.memory.removeAll { $0.kind == "generated-summary" }
        index.graph.memory.append(DocumentMemory(text: text, sourceContentIDs: ids, kind: "generated-summary"))
        let cacheURL = fileURL.deletingLastPathComponent().appendingPathComponent("document-index-v2.json")
        try JSONEncoder().encode(index).write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        cached[fileURL] = index
        return index.graph
    }
    func forget(fileURL: URL) {
        cached.removeValue(forKey: fileURL); fullText.removeValue(forKey: fileURL)
        partialLines.removeValue(forKey: fileURL); generations.removeValue(forKey: fileURL)
    }
    func build(fileURL: URL, documentID: UUID, format: DocumentFormat = .pdf,
        progress: @Sendable (Int, Int, [SourceTextLine]) async -> Void) async throws -> DocumentIndex {
        let stamp = try Self.stamp(fileURL)
        let cacheURL = fileURL.deletingLastPathComponent().appendingPathComponent("document-index-v2.json")
        if let existing = cached[fileURL], existing.fileStamp == stamp, existing.graph.documentID == documentID { return existing }
        if let data = try? Data(contentsOf: cacheURL), let existing = try? JSONDecoder().decode(DocumentIndex.self, from: data),
           existing.version == 2, existing.fileStamp == stamp, existing.graph.documentID == documentID,
           (try? existing.graph.validate()) != nil {
            try remember(existing, url: fileURL); return existing
        }
        let adapter: any DocumentAdapter
        switch format {
        case .pdf: adapter = try PDFDocumentAdapter(fileURL: fileURL)
        case .epub, .docx: throw ReaderError.message("此格式的导入适配器尚未安装。")
        }
        let generation = UUID(); generations[fileURL] = generation; partialLines[fileURL] = [:]
        defer { if generations[fileURL] == generation { partialLines.removeValue(forKey: fileURL); generations.removeValue(forKey: fileURL) } }
        var extracted = try await adapter.extract(documentID: documentID, revision: stamp) { [weak self] done, total, lines in
            await self?.rememberLines(lines, page: done, url: fileURL, generation: generation)
            await progress(done, total, lines)
        }
        for index in extracted.graph.blocks.indices {
            try Task.checkCancellation()
            guard generations[fileURL] == generation else { throw CancellationError() }
            if extracted.graph.blocks[index].contentType != .sentence {
                extracted.graph.blocks[index].embedding = NativeSemanticIndex.embed(extracted.graph.blocks[index].text)
            }
            if index % 20 == 0 { await Task.yield() }
        }
        let index = DocumentIndex(fileStamp: stamp, pageCount: extracted.pageCount, graph: extracted.graph,
            lines: extracted.lines, unreadablePages: extracted.unreadablePages)
        try Task.checkCancellation()
        guard generations[fileURL] == generation else { throw CancellationError() }
        try remember(index, url: fileURL)
        try JSONEncoder().encode(index).write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        return index
    }
    private func rememberLines(_ lines: [SourceTextLine], page: Int, url: URL, generation: UUID) {
        if generations[url] == generation { partialLines[url]?[page] = lines }
    }
    private func remember(_ index: DocumentIndex, url: URL) throws {
        let database = try LocalSearchIndex(url: url.deletingLastPathComponent().appendingPathComponent("document-search-v2.sqlite"))
        try database.replace(graph: index.graph)
        if cached.count >= 2 { cached.removeAll(); fullText.removeAll() }
        cached[url] = index; fullText[url] = database
    }
}
