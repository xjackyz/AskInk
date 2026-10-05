import Foundation
import CoreGraphics

// Domain objects contain no PDFKit, PencilKit or reader-view state.
enum DocumentFormat: String, Codable, Sendable { case pdf, epub, docx }
struct Document: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var lastPage: Int // Legacy fixed-layout reading position; reflowable formats use lastLocation.
    var addedAt: Date
    var lastOpenedAt: Date? = nil
    var pageCount: Int? = nil
    var favorite: Bool? = nil
    var isSample: Bool? = nil
    var format: DocumentFormat? = nil // Missing in existing book.json: PDF.
    var lastLocation: ContentLocation? = nil
    var resolvedFormat: DocumentFormat { format ?? .pdf }
}

struct ContentLocation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case fixedPage, reflowable }
    var kind: Kind
    var pageNumber: Int? = nil
    var locator: String? = nil // Adapter-owned opaque locator (e.g. EPUB CFI).
    var boundingRect: CGRect? = nil
    static func page(_ number: Int, rect: CGRect? = nil) -> Self {
        Self(kind: .fixedPage, pageNumber: number, boundingRect: rect)
    }
}

struct ContentAnchor: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var documentID: UUID? = nil
    var contentID: String? = nil
    var location: ContentLocation? = nil
    var textQuote: String? = nil
    var textRange: ContentTextRange? = nil
    // x/y are retained to decode old anchors without losing existing annotations.
    var point: CGPoint { CGPoint(x: x, y: y) }
    private enum CodingKeys: String, CodingKey { case x, y, documentID, contentID, location, textQuote, textRange }
    init(x: Double = 0, y: Double = 0, documentID: UUID? = nil, contentID: String? = nil,
         location: ContentLocation? = nil, textQuote: String? = nil, textRange: ContentTextRange? = nil) {
        self.x = x; self.y = y; self.documentID = documentID; self.contentID = contentID
        self.location = location; self.textQuote = textQuote; self.textRange = textRange
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try values.decodeIfPresent(Double.self, forKey: .y) ?? 0
        documentID = try values.decodeIfPresent(UUID.self, forKey: .documentID)
        contentID = try values.decodeIfPresent(String.self, forKey: .contentID)
        location = try values.decodeIfPresent(ContentLocation.self, forKey: .location)
        textQuote = try values.decodeIfPresent(String.self, forKey: .textQuote)
        textRange = try values.decodeIfPresent(ContentTextRange.self, forKey: .textRange)
    }
}

struct ContentTextRange: Codable, Equatable, Sendable {
    var startUTF16: Int
    var lengthUTF16: Int
}

enum ContentType: String, Codable, Sendable { case paragraph, sentence, heading, figure, table, footnote, quote }
struct ContentEmbedding: Codable, Equatable, Sendable {
    var modelID: String
    var vector: [Double]
}
struct ContentBlock: Codable, Equatable, Identifiable, Sendable {
    var contentID: String
    var documentID: UUID
    var text: String
    var sectionPath: [String]
    var readingOrder: Int
    var location: ContentLocation
    var previousBlock: String? = nil
    var nextBlock: String? = nil
    var embedding: ContentEmbedding? = nil
    var contentType: ContentType = .paragraph
    var isOCR = false
    var parentContentID: String? = nil
    var childContentIDs: [String]? = nil
    var textRange: ContentTextRange? = nil
    var id: String { contentID }
    var anchor: ContentAnchor {
        ContentAnchor(x: Double(location.boundingRect?.maxX ?? 0), y: Double(location.boundingRect?.midY ?? 0),
            documentID: documentID, contentID: contentID, location: location, textQuote: text, textRange: textRange)
    }
}
struct DocumentSection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var parentID: String? = nil
    var startOrder: Int
    var endOrder: Int
}
struct DocumentMemory: Codable, Equatable, Sendable {
    var text: String
    var sourceContentIDs: [String]
    var kind: String // Generated summary or extractive section preview; never confuse these.
}
struct DocumentGraph: Codable, Equatable, Sendable {
    var documentID: UUID
    var revision: String
    var sections: [DocumentSection]
    var blocks: [ContentBlock]
    var memory: [DocumentMemory] = []

    mutating func linkBlocks() {
        blocks.sort { $0.readingOrder < $1.readingOrder }
        for index in blocks.indices {
            blocks[index].previousBlock = index > 0 ? blocks[index - 1].contentID : nil
            blocks[index].nextBlock = index + 1 < blocks.count ? blocks[index + 1].contentID : nil
        }
    }
    func validate() throws {
        let ids = Set(blocks.map(\.contentID))
        let byID = Dictionary(blocks.map { ($0.contentID, $0) }, uniquingKeysWith: { first, _ in first })
        guard ids.count == blocks.count, blocks.allSatisfy({ $0.documentID == documentID }),
              Set(blocks.map(\.readingOrder)).count == blocks.count else {
            throw ReaderError.message("文档图包含重复内容或错误的文档归属。")
        }
        for (index, block) in blocks.enumerated() {
            if let parent = block.parentContentID {
                guard byID[parent]?.childContentIDs?.contains(block.contentID) == true else {
                    throw ReaderError.message("内容块父子关系不完整。")
                }
            }
            if let children = block.childContentIDs {
                guard children.allSatisfy({ byID[$0]?.parentContentID == block.contentID }) else {
                    throw ReaderError.message("内容块包含失效的子节点。")
                }
            }
            guard block.previousBlock == (index > 0 ? blocks[index - 1].contentID : nil),
                  block.nextBlock == (index + 1 < blocks.count ? blocks[index + 1].contentID : nil) else {
                throw ReaderError.message("文档阅读顺序不完整。")
            }
        }
    }
}

struct Annotation: Codable, Identifiable, Sendable {
    enum Semantics: String, Codable, Sendable { case note, highlight, underline, aiAnswer }
    var id: UUID
    var documentID: UUID
    var anchor: ContentAnchor
    var semantics: Semantics
    var text: String? = nil
    var threadID: UUID? = nil
}

struct AdapterExtraction: Sendable {
    var graph: DocumentGraph
    var pageCount: Int
    var lines: [Int: [SourceTextLine]]
    var unreadablePages: [Int]
}
protocol DocumentAdapter {
    var format: DocumentFormat { get }
    func extract(documentID: UUID, revision: String,
        progress: @Sendable (Int, Int, [SourceTextLine]) async -> Void) async throws -> AdapterExtraction
}
