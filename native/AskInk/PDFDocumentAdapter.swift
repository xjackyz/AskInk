import Foundation
import PDFKit
import UIKit
import Vision
import NaturalLanguage

// PDFKit and PDF coordinate extraction live at the format boundary.
final class PDFDocumentAdapter: DocumentAdapter {
    let format: DocumentFormat = .pdf
    let pdfDocument: PDFDocument
    init(pdfDocument: PDFDocument) { self.pdfDocument = pdfDocument }
    init(fileURL: URL) throws {
        guard let document = PDFDocument(url: fileURL), document.pageCount > 0, !document.isLocked else {
            throw ReaderError.message("无法读取 PDF 文档。")
        }
        pdfDocument = document
    }
    func extract(documentID: UUID, revision: String,
        progress: @Sendable (Int, Int, [SourceTextLine]) async -> Void) async throws -> AdapterExtraction {
        var blocks: [ContentBlock] = [], lines: [Int: [SourceTextLine]] = [:], missing: [Int] = []
        var headings: [(id: String, title: String, page: Int, parent: String?)] = []
        func collect(_ outline: PDFOutline, parent: String?) {
            let id = "section:\(documentID.uuidString):\(headings.count)"
            let page = outline.destination?.page.map { pdfDocument.index(for: $0) + 1 }
            let title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let valid = page != nil && !title.isEmpty && page! > 0
            if valid { headings.append((id, title, page!, parent)) }
            for index in 0..<outline.numberOfChildren {
                if let child = outline.child(at: index) { collect(child, parent: valid ? id : parent) }
            }
        }
        if let outline = pdfDocument.outlineRoot { collect(outline, parent: nil) }
        for number in 1...pdfDocument.pageCount {
            try Task.checkCancellation()
            guard let page = pdfDocument.page(at: number - 1) else { missing.append(number); continue }
            let extracted: ([SourceTextLine], Bool) = autoreleasepool {
                let native = Self.textLines(page)
                return native.isEmpty ? ((try? Self.recognizePage(page)) ?? [], true) : (native, false)
            }
            if extracted.0.isEmpty { missing.append(number) }
            lines[number] = extracted.0
            let section = headings.filter { $0.page <= number }.max { $0.page < $1.page }
            var path: [String] = [], node = section
            while let current = node {
                path.insert(current.id, at: 0)
                node = current.parent.flatMap { parent in headings.first { $0.id == parent } }
            }
            for source in Self.passages(extracted.0, page: number, isOCR: extracted.1) {
                let paragraphID = "\(documentID.uuidString)/\(source.id)"
                let parentIndex = blocks.count
                blocks.append(ContentBlock(contentID: paragraphID, documentID: documentID,
                    text: source.text, sectionPath: path, readingOrder: blocks.count,
                    location: .page(number, rect: source.bounds), isOCR: source.isOCR))
                let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = source.text
                var children: [String] = []
                tokenizer.enumerateTokens(in: source.text.startIndex..<source.text.endIndex) { range, _ in
                    let text = String(source.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return true }
                    let childID = paragraphID + "/s\(children.count)", offsets = NSRange(range, in: source.text)
                    children.append(childID)
                    blocks.append(ContentBlock(contentID: childID, documentID: documentID, text: text,
                        sectionPath: path, readingOrder: blocks.count, location: .page(number, rect: source.bounds),
                        contentType: .sentence, isOCR: source.isOCR, parentContentID: paragraphID,
                        textRange: ContentTextRange(startUTF16: offsets.location, lengthUTF16: offsets.length)))
                    return true
                }
                blocks[parentIndex].childContentIDs = children
            }
            await progress(number, pdfDocument.pageCount, extracted.0)
            await Task.yield()
        }
        let sections = headings.compactMap { heading -> DocumentSection? in
            let members = blocks.filter { $0.sectionPath.contains(heading.id) }
            guard let first = members.first, let last = members.last else { return nil }
            return DocumentSection(id: heading.id, title: heading.title, parentID: heading.parent,
                startOrder: first.readingOrder, endOrder: last.readingOrder)
        }
        var graph = DocumentGraph(documentID: documentID, revision: revision, sections: sections, blocks: blocks)
        graph.linkBlocks(); try graph.validate()
        return AdapterExtraction(graph: graph, pageCount: pdfDocument.pageCount, lines: lines, unreadablePages: missing)
    }
    static func textLines(_ page: PDFPage) -> [SourceTextLine] {
        (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []).compactMap { selection in
            let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = selection.bounds(for: page)
            guard !text.isEmpty, !bounds.isEmpty, !bounds.isNull else { return nil }
            return SourceTextLine(text: text, bounds: bounds)
        }
    }

    private static func recognizePage(_ page: PDFPage) throws -> [SourceTextLine] {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0, let reference = page.pageRef else { return [] }
        let scale = min(3, 2200 / max(bounds.width, bounds.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: bounds.height * scale)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
            // Draw raw page content without display rotation; OCR coordinates
            // consequently map directly back to PDF coordinates.
            ctx.cgContext.drawPDFPage(reference)
        }
        guard let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let b = observation.boundingBox
            return SourceTextLine(text: candidate.string, bounds: CGRect(x: bounds.minX + b.minX * bounds.width,
                y: bounds.minY + b.minY * bounds.height, width: b.width * bounds.width, height: b.height * bounds.height))
        }
    }

    static func passages(_ lines: [SourceTextLine], page: Int, isOCR: Bool) -> [ReadingSource] {
        var pending = lines.sorted { abs($0.bounds.midY - $1.bounds.midY) < 3 ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY }
        var result: [ReadingSource] = []
        while !pending.isEmpty {
            var group = [pending.removeFirst()]
            while group.count < 5, group.map(\.text).joined().count < 650, let last = group.last,
                  let next = pending.firstIndex(where: { candidate in
                      let overlap = max(0, min(last.bounds.maxX, candidate.bounds.maxX) - max(last.bounds.minX, candidate.bounds.minX))
                      let gap = last.bounds.minY - candidate.bounds.maxY
                      return candidate.bounds.midY < last.bounds.midY && gap >= -3 && gap < max(12, last.bounds.height * 1.2)
                          && overlap / max(1, min(last.bounds.width, candidate.bounds.width)) > 0.6
                  }) {
                group.append(pending.remove(at: next))
            }
            result.append(ReadingSource(id: "p\(page)-b\(result.count)", page: page,
                text: group.map(\.text).joined(separator: "\n"), bounds: group.reduce(CGRect.null) { $0.union($1.bounds) }, isOCR: isOCR))
        }
        return result
    }
}
