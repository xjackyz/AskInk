import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

struct ShareFile: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct ArchiveFile: Codable { let name: String; let data: Data }
struct AskInkArchive: Codable { var format = "AskInk-v1"; let files: [ArchiveFile] }
enum ExportKind: String, CaseIterable, Identifiable {
    case original = "原始 PDF", annotated = "批注 PDF", archive = "AskInk Archive"
    var id: String { rawValue }
}

extension ReaderStore {
    func toggleBookmark() {
        if bookmarks.contains(page) { bookmarks.remove(page) } else { bookmarks.insert(page) }
        guard let book = currentBook else { return }
        do { try JSONEncoder().encode(bookmarks.sorted()).write(to: folder(book.id).appendingPathComponent("bookmarks.json"), options: .atomic) }
        catch { self.error = "书签暂时无法保存。" }
    }
    func rename(_ book: Document, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        var changed = books[index]; changed.name = cleaned
        do {
            try JSONEncoder().encode(changed).write(to: folder(book.id).appendingPathComponent("book.json"), options: .atomic)
            books[index] = changed
            if currentBook?.id == book.id { currentBook = changed }
        } catch { self.error = "文档名称暂时无法保存。" }
    }
    func toggleFavorite(_ book: Document) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        var changed = books[index]; changed.favorite = !(changed.favorite ?? false)
        do {
            try JSONEncoder().encode(changed).write(to: folder(book.id).appendingPathComponent("book.json"), options: .atomic)
            books[index] = changed; if currentBook?.id == book.id { currentBook = changed }
        } catch { self.error = "收藏暂时无法保存。" }
    }
    func removeBook(_ book: Document) async {
        cancelReadingWork(bookID: book.id)
        flush(); invalidateRecognition(); await waitForLocalSaves()
        do {
            try FileManager.default.removeItem(at: folder(book.id))
            books.removeAll { $0.id == book.id }; openBookIDs.removeAll { $0 == book.id }
            if currentBook?.id == book.id {
                currentBook = nil; document = nil; replies = []; bookmarks = []; failedQuestion = nil
                UserDefaults.standard.removeObject(forKey: "lastBook")
            }
        } catch { self.error = "文档暂时无法移除。" }
    }
    func deleteAIHistory() {
        guard !busy else { return }
        replies = []; saveReplies(); failedQuestion = nil; unanswered = []; automaticError = nil
        eraseStoredAIHistory()
    }
    func deleteThread(_ threadID: UUID) { replies.removeAll { $0.conversationID == threadID }; saveReplies() }
    func export(_ book: Document, kind: ExportKind) async throws -> URL {
        flush()
        await waitForLocalSaves()
        let directory = folder(book.id)
        // loadDrawing returns cached snapshots; wait for these before exporting.
        var drawings: [Int: PKDrawing] = [:]
        if kind != .original, currentBook?.id == book.id, let document {
            for page in 1...document.pageCount { drawings[page] = await loadDrawing(page: page) }
        }
        let capturedDrawings = drawings
        return try await Task.detached(priority: .utility) {
            let source = directory.appendingPathComponent("document.pdf")
            let exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let base = String(book.name.replacingOccurrences(of: "/", with: "-").prefix(120))
            if kind == .archive {
                let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                var files = try urls.filter { $0.lastPathComponent == "document.pdf" || $0.pathExtension == "drawing" || ["threads.json", "replies.json", "book.json", "bookmarks.json", "unanswered.json"].contains($0.lastPathComponent) }.map { ArchiveFile(name: $0.lastPathComponent, data: try Data(contentsOf: $0)) }
                for (number, drawing) in capturedDrawings {
                    files.removeAll { $0.name == "page-\(number).drawing" }
                    files.append(ArchiveFile(name: "page-\(number).drawing", data: drawing.dataRepresentation()))
                }
                let url = exportDirectory.appendingPathComponent(base + ".askink.json")
                try JSONEncoder().encode(AskInkArchive(files: files)).write(to: url, options: .atomic)
                return url
            }
            let url = exportDirectory.appendingPathComponent(base.hasSuffix(".pdf") ? base : base + ".pdf")
            if kind == .original { try FileManager.default.copyItem(at: source, to: url); return url }
            guard let pdf = PDFDocument(url: source) else { throw ReaderError.message("无法准备导出文档。") }
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            try renderer.writePDF(to: url) { context in
                for index in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: index) else { continue }
                    let bounds = page.bounds(for: .cropBox)
                    let output = CGRect(origin: .zero, size: bounds.size)
                    context.beginPage(withBounds: output, pageInfo: [:])
                    let cg = context.cgContext
                    cg.saveGState(); cg.translateBy(x: -bounds.minX, y: bounds.height + bounds.minY); cg.scaleBy(x: 1, y: -1)
                    page.draw(with: .cropBox, to: cg); cg.restoreGState()
                    let drawing = capturedDrawings[index + 1] ?? (try? PKDrawing(data: Data(contentsOf: directory.appendingPathComponent("page-\(index + 1).drawing"))))
                    drawing?.image(from: output, scale: 2).draw(in: output)
                }
            }
            return url
        }.value
    }
    func highlightText(_ marks: [(Int, CGRect)]) async {
        guard let book = currentBook else { return }
        flush(); await waitForLocalSaves()
        let url = folder(book.id).appendingPathComponent("document.pdf")
        do {
            try await Task.detached(priority: .utility) {
                guard let pdf = PDFDocument(url: url) else { throw ReaderError.message("无法读取文档。") }
                for (index, bounds) in marks {
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = UIColor.systemYellow.withAlphaComponent(0.35); pdf.page(at: index)?.addAnnotation(annotation)
                }
                guard let data = pdf.dataRepresentation() else { throw ReaderError.message("无法保存高光。") }
                try data.write(to: url, options: .atomic)
            }.value
            if currentBook?.id == book.id { document = PDFDocument(url: url); bookIndex = nil }
        } catch { self.error = "高光暂时无法保存。" }
    }

    func importArchive(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID(); let destination = folder(id)
        do {
            let archive = try JSONDecoder().decode(AskInkArchive.self, from: Data(contentsOf: url))
            guard archive.format == "AskInk-v1", let pdf = archive.files.first(where: { $0.name == "document.pdf" }),
                  let document = PDFDocument(data: pdf.data), document.pageCount > 0, !document.isLocked else { throw ReaderError.message("不是有效的 AskInk 备份。") }
            let old = archive.files.first(where: { $0.name == "book.json" }).flatMap { try? JSONDecoder().decode(Document.self, from: $0.data) }
            let book = Document(id: id, name: old?.name ?? "恢复的 PDF", lastPage: min(old?.lastPage ?? 1, document.pageCount), addedAt: Date(), pageCount: document.pageCount)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in archive.files where file.name == "document.pdf" || file.name == "replies.json" || file.name == "threads.json" || file.name == "bookmarks.json" || file.name == "unanswered.json" || (file.name.hasPrefix("page-") && file.name.hasSuffix(".drawing")) {
                guard file.name == URL(fileURLWithPath: file.name).lastPathComponent, !file.name.contains("..") else { throw ReaderError.message("备份文件名不正确。") }
                var data = file.data
                if file.name == "threads.json" {
                    var threads = try JSONDecoder().decode([AIThread].self, from: data)
                    for index in threads.indices { threads[index].documentID = id; threads[index].anchor?.documentID = id }
                    // Rebuild legacy metadata with the new library document identity.
                    var restored = try AIHistory.replies(threads)
                    for index in restored.indices {
                        restored[index].anchor?.documentID = id
                        restored[index].contextPacket = nil // Source IDs belong to the old graph; rebuild on next question.
                    }
                    data = try JSONEncoder().encode(AIHistory.threads(restored, documentID: id))
                }
                if file.name == "unanswered.json", var questions = try? JSONDecoder().decode([SavedQuestion].self, from: data) {
                    for index in questions.indices { questions[index].bookID = id }; data = try JSONEncoder().encode(questions)
                }
                try data.write(to: destination.appendingPathComponent(file.name), options: .atomic)
            }
            try JSONEncoder().encode(book).write(to: destination.appendingPathComponent("book.json"), options: .atomic)
            books.insert(book, at: 0); open(book)
        } catch { try? FileManager.default.removeItem(at: destination); self.error = "无法恢复这份备份。" }
    }
    func openSample() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Calculus — Sample.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                let title = "The direction of greatest change"
                title.draw(in: CGRect(x: 64, y: 85, width: 480, height: 70), withAttributes: [.font: UIFont.systemFont(ofSize: 25, weight: .semibold)])
                let text = "The gradient points in the direction of greatest increase.\n\nA directional derivative measures how fast a function changes as you move a unit distance in a chosen direction.\n\nThe dot product of the gradient and a unit direction vector is largest when the two point in the same direction.\n\nRead. Write. Ask.\n\nWrite notes anywhere. End a question with ? to ask about the nearby text."
                text.draw(in: CGRect(x: 64, y: 190, width: 380, height: 450), withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.darkGray])
            }
            importPDF(url)
            if var book = currentBook {
                book.isSample = true; currentBook = book
                if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
                try JSONEncoder().encode(book).write(to: folder(book.id).appendingPathComponent("book.json"), options: .atomic)
            }
        } catch { self.error = "示例暂时无法打开。" }
    }
}
