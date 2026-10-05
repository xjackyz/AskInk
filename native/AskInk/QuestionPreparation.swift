import UIKit
import PDFKit
import PencilKit

// Own PDF documents on the background actor, never use the PDFView's document.
actor QuestionPreparation {
    static let shared = QuestionPreparation()
    private var documents: [URL: PDFDocument] = [:]

    func symbolImage(_ capture: InkQuestionCapture) throws -> UIImage {
        try Task.checkCancellation()
        return inkImage(capture.symbolDrawing, normalized: true)
    }
    private func inkImage(_ drawing: PKDrawing, normalized: Bool) -> UIImage {
        let source: PKDrawing
        if normalized {
            source = PKDrawing(strokes: drawing.strokes.map { stroke in
                let points = stroke.path.map { PKStrokePoint(location: $0.location, timeOffset: $0.timeOffset,
                    size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: $0.azimuth, altitude: $0.altitude) }
                return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points,
                    creationDate: stroke.path.creationDate), transform: stroke.transform, mask: stroke.mask)
            })
        } else { source = drawing }
        let bounds = source.bounds.insetBy(dx: -16, dy: -16)
        let scale = min(3, 1600 / max(1, bounds.width, bounds.height))
        let image = source.image(from: bounds, scale: scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
    }
    func prepare(_ capture: InkQuestionCapture) async throws -> QuestionSnapshot {
        try Task.checkCancellation()
        let document: PDFDocument
        if let cached = documents[capture.fileURL] { document = cached }
        else {
            guard let loaded = PDFDocument(url: capture.fileURL) else { throw ReaderError.message("无法读取提问所在的 PDF。") }
            document = loaded
            if documents.count >= 2 { documents.removeAll() }
            documents[capture.fileURL] = document
        }
        guard let page = document.page(at: capture.page - 1) else { throw ReaderError.message("提问页码已失效。") }
        let pageBounds = page.bounds(for: .cropBox), pdfBounds = capture.pdfBounds
        var lines = PDFDocumentAdapter.textLines(page)
        if lines.isEmpty { lines = await LocalDocumentIndex.shared.lines(fileURL: capture.fileURL, page: capture.page) }
        func score(_ line: SourceTextLine) -> CGFloat {
            let b = line.bounds
            return hypot(max(0, b.minX - pdfBounds.maxX, pdfBounds.minX - b.maxX),
                         max(0, b.minY - pdfBounds.maxY, pdfBounds.minY - b.maxY) * 3)
        }
        var region = CGRect(x: pageBounds.minX, y: pdfBounds.minY - 100,
                            width: pageBounds.width, height: pdfBounds.height + 200).intersection(pageBounds)
        var context = ""
        if let anchor = lines.min(by: { score($0) < score($1) }), score(anchor) < pageBounds.width * 0.25 {
            let column = anchor.bounds
            let nearby = lines.filter { line in
                let b = line.bounds
                return max(0, min(b.maxX, column.maxX) - max(b.minX, column.minX)) / max(1, min(b.width, column.width)) > 0.55
            }.sorted { score($0) < score($1) }.prefix(capture.sourceMarked ? 5 : 12).sorted { $0.bounds.midY > $1.bounds.midY }
            context = String(nearby.map(\.text).joined(separator: "\n").prefix(3200))
            region = nearby.reduce(CGRect.null) { $0.union($1.bounds) }.insetBy(dx: -12, dy: -12).intersection(pageBounds)
        }
        if let marked = capture.markedText, !marked.isEmpty { context = "划线／高光原文：\n\(marked)\n\n附近正文：\n" + context }
        guard !region.isNull, !region.isEmpty else { throw ReaderError.message("无法定位问题附近的正文。") }
        try Task.checkCancellation()
        let scale = min(2, 1800 / max(region.width, region.height))
        let size = CGSize(width: region.width * scale, height: region.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let pageImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height); context.cgContext.scaleBy(x: scale, y: -scale)
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            page.draw(with: .cropBox, to: context.cgContext)
        }
        return QuestionSnapshot(page: capture.page, anchor: capture.anchor,
            ink: inkImage(capture.drawing, normalized: true), handwritingImage: inkImage(capture.drawing, normalized: false),
            context: context, pageImage: pageImage, drawing: capture.drawing, bookID: capture.bookID,
            revision: capture.revision, scope: capture.scope, block: capture.block, blockCount: capture.blockCount,
            sourceMarked: capture.sourceMarked, markedText: capture.markedText,
            sourceReferences: context.isEmpty ? [] : [ReadingSource(id: "p\(capture.page)-nearby", page: capture.page, text: context, bounds: region)])
    }
}
