import Foundation
import CoreGraphics

struct SourceTextLine: Codable, Equatable, Sendable {
    var text: String
    var bounds: CGRect
}

struct ReadingSource: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var page: Int
    var text: String
    var bounds: CGRect
    var isOCR: Bool = false
    init(id: String, page: Int, text: String, bounds: CGRect, isOCR: Bool = false) {
        self.id = id; self.page = page; self.text = text; self.bounds = bounds; self.isOCR = isOCR
    }
    init?(block: ContentBlock) {
        guard let page = block.location.pageNumber else { return nil }
        self.init(id: block.contentID, page: page, text: block.text, bounds: block.location.boundingRect ?? .zero, isOCR: block.isOCR)
    }
}

enum SourceMarkLocator {
    // Coordinates use PDF's upward y axis. Require a real text baseline: long
    // horizontals in margin notes and minus signs must remain handwriting.
    static func underlineLines(points: [CGPoint], lines: [SourceTextLine]) -> [Int] {
        guard points.count >= 2, let first = points.first, let last = points.last else { return [] }
        let b = QuestionGlyph(points: points).bounds
        guard b.width >= 28, b.height <= max(8, min(18, b.width * 0.08)), b.width > max(1, b.height) * 8,
              abs(last.x - first.x) >= b.width * 0.85 else { return [] }
        let travel = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + abs($1.1.x - $1.0.x) }
        guard travel <= b.width * 1.3 else { return [] }
        return lines.indices.filter { index in
            let line = lines[index].bounds
            let overlap = max(0, min(b.maxX, line.maxX) - max(b.minX, line.minX))
            let below = line.minY - b.midY
            return b.width >= line.height * 2 && overlap / max(1, b.width) >= 0.65 &&
                below >= -1 && below <= max(7, min(12, line.height * 0.6))
        }.sorted { abs(lines[$0].bounds.minY - b.midY) < abs(lines[$1].bounds.minY - b.midY) }
    }
}

enum ReadingText {
    static func terms(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let stop: Set<String> = ["为什么", "是什么", "怎么", "这里", "这个", "这段", "前面", "之前", "解释", "一下", "the", "and", "what", "why", "is", "this", "that"]
        var result = Set<String>()
        for word in words where !stop.contains(word) {
            let chars = Array(word)
            let chinese = chars.contains { $0.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } }
            if chinese {
                if chars.count == 1 { result.insert(word) }
                else {
                    for i in 0..<(chars.count - 1) {
                        let pair = String(chars[i...i + 1])
                        if !stop.contains(pair) { result.insert(pair) }
                    }
                }
            } else if word.count >= 2 { result.insert(word) }
        }
        return result
    }

    static func search(_ sources: [ReadingSource], query: String, before page: Int? = nil, limit: Int = 30) -> [ReadingSource] {
        let terms = terms(String(query.prefix(400)))
        guard !terms.isEmpty, limit > 0 else { return [] }
        let candidates = sources.filter { page == nil || $0.page < page! }
        let documentTerms = candidates.map { Self.terms($0.text) }
        var frequencies: [String: Int] = [:]
        for set in documentTerms { for term in terms.intersection(set) { frequencies[term, default: 0] += 1 } }
        let scored = candidates.indices.compactMap { i -> (Int, Double)? in
            let matches = terms.intersection(documentTerms[i])
            guard !matches.isEmpty else { return nil }
            let score = matches.reduce(0.0) { $0 + log(1 + Double(candidates.count) / Double(frequencies[$1, default: 1])) }
                / sqrt(Double(max(8, documentTerms[i].count)))
            return (i, score)
        }.sorted { $0.1 == $1.1 ? candidates[$0.0].page < candidates[$1.0].page : $0.1 > $1.1 }
        return scored.prefix(limit).map { candidates[$0.0] }
    }

    // A character budget, not a token count. Never apply this to whole-book
    // summaries: every source chunk must be processed there.
    static func budgetHistory(_ history: [[String: String]], characters: Int = 1400) -> [[String: String]] {
        var remaining = max(0, characters), output: [[String: String]] = []
        for item in history.reversed() where remaining > 0 {
            let question = String((item["question"] ?? "").prefix(min(240, remaining)))
            remaining -= question.count
            let answer = String((item["answer"] ?? "").prefix(min(650, remaining)))
            remaining -= answer.count
            output.append(["question": question, "answer": answer])
        }
        return output.reversed()
    }

    static func chunks(_ text: String, characters: Int) -> [String] {
        guard characters > 0 else { return [] }
        var result: [String] = [], start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: characters, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end])); start = end
        }
        return result
    }
}
