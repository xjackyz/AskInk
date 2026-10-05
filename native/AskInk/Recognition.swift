import UIKit
import Vision
import PencilKit

struct InkQuestionCapture {
    var page: Int
    var drawing: PKDrawing
    var fileURL: URL
    var pdfBounds: CGRect
    var anchor: ContentAnchor
    var bookID: UUID
    var revision: UUID
    var scope: InkScope
    var block: Int
    var blockCount: Int
    var isTextSelection = false
    var sourceMarked = false
    var markedText: String? = nil
    var symbolDrawing: PKDrawing {
        PKDrawing(strokes: Array(drawing.strokes.suffix(3)))
    }
    var isQuestionCandidate: Bool {
        QuestionMarkGate.mightBeQuestionMark(drawing.strokes.suffix(3).map { stroke in
            QuestionGlyph(points: stroke.path.map { $0.location.applying(stroke.transform) })
        })
    }
}
struct QuestionSnapshot {
    var page: Int
    var anchor: ContentAnchor
    var ink: UIImage
    var handwritingImage: UIImage
    var context: String
    var pageImage: UIImage
    var drawing: PKDrawing
    var bookID: UUID
    var revision: UUID
    var scope: InkScope
    var block: Int
    var blockCount: Int
    var isTextSelection = false
    var sourceMarked = false
    var markedText: String? = nil
    var sourceReferences: [ReadingSource] = []
    var inkDataURL: String { "data:image/png;base64," + (ink.pngData()?.base64EncodedString() ?? "") }
    var handwritingDataURL: String { "data:image/png;base64," + (handwritingImage.pngData()?.base64EncodedString() ?? "") }
    var pageDataURL: String { "data:image/jpeg;base64," + (pageImage.jpegData(compressionQuality: 0.85)?.base64EncodedString() ?? "") }
}
struct QuestionDraft: Identifiable {
    var id = UUID()
    var snapshot: QuestionSnapshot
    var text: String
    var candidates: [HandwritingCandidate]
    var source: String
    var milliseconds: Double
    var recognitionNote: String
    var regions: [HandwritingRegion] = []
    var recognitionVersion: Int? = nil
}
