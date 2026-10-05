import Foundation
import UIKit
import PencilKit

// Recover unanswered questions independently of volatile OCR and network tasks.
struct SavedQuestion: Codable, Identifiable {
    var id: UUID
    var bookID: UUID
    var page: Int
    var anchor: ContentAnchor
    var question: String
    var context: String
    var ink: Data
    var handwriting: Data
    var pageImage: Data
    var drawing: Data
    var sources: [ReadingSource]
    var offline: Bool
    var textSelection: Bool? = nil
    init(_ draft: QuestionDraft, offline: Bool) {
        id = draft.id; bookID = draft.snapshot.bookID; page = draft.snapshot.page; anchor = draft.snapshot.anchor
        question = draft.text; context = draft.snapshot.context
        ink = draft.snapshot.ink.pngData() ?? Data()
        handwriting = draft.snapshot.handwritingImage.pngData() ?? Data()
        pageImage = draft.snapshot.pageImage.jpegData(compressionQuality: 0.85) ?? Data()
        drawing = draft.snapshot.drawing.dataRepresentation(); sources = draft.snapshot.sourceReferences
        self.offline = offline; textSelection = draft.snapshot.isTextSelection
    }
    func draft() -> QuestionDraft? {
        guard let ink = UIImage(data: ink), let handwriting = UIImage(data: handwriting), let pageImage = UIImage(data: pageImage), let drawing = try? PKDrawing(data: drawing) else { return nil }
        let snapshot = QuestionSnapshot(page: page, anchor: anchor, ink: ink, handwritingImage: handwriting, context: context, pageImage: pageImage,
            drawing: drawing, bookID: bookID, revision: UUID(), scope: .latest, block: 0, blockCount: 1, isTextSelection: textSelection ?? false, sourceReferences: sources)
        return QuestionDraft(id: id, snapshot: snapshot, text: question, candidates: [], source: "Saved question", milliseconds: 0, recognitionNote: "")
    }
}
