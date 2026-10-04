import SwiftUI
import PDFKit
import PencilKit

struct Book: Codable, Identifiable {
    var id: UUID
    var name: String
    var lastPage: Int
    var addedAt: Date
}
struct ReadingReply: Codable, Identifiable {
    var id = UUID()
    var page: Int
    var question: String
    var answer: String
    var source: String
    var model: String
    var inkImageDataURL: String? = nil
    var recognizedText: String? = nil
    var recognitionNote: String? = nil
    var recognitionSource: String? = nil
    var recognitionVersion: Int? = nil
    var recognitionRegions: [HandwritingRegion]? = nil
}


@MainActor
final class ReaderStore: ObservableObject {
    @Published var books: [Book] = []
    @Published var openBookIDs: [UUID] = [] {
        didSet { UserDefaults.standard.set(openBookIDs.map(\.uuidString), forKey: "openBookTabs") }
    }
    @Published var currentBook: Book?
    @Published var document: PDFDocument?
    @Published var page = 1
    @Published var tool: InkTool = .pen { didSet { UserDefaults.standard.set(tool.rawValue, forKey: "inkTool") } }
    @Published var lockPageForWriting = UserDefaults.standard.bool(forKey: "lockPageForWriting") {
        didSet { UserDefaults.standard.set(lockPageForWriting, forKey: "lockPageForWriting") }
    }
    @Published var width = 2.0 { didSet { UserDefaults.standard.set(width, forKey: "inkWidth") } }
    @Published var color: Color = .black
    @Published var replies: [ReadingReply] = []
    @Published var status = "导入 PDF，开始阅读"
    @Published var error: String?
    @Published var autoReply = UserDefaults.standard.object(forKey: "autoReply") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoReply, forKey: "autoReply")
            if !autoReply { invalidateRecognition() }
        }
    }
    @Published var autoReplyDelay = UserDefaults.standard.object(forKey: "autoReplyDelay") as? Double ?? 2.0 {
        didSet { UserDefaults.standard.set(autoReplyDelay, forKey: "autoReplyDelay") }
    }
    @Published var automaticError: String?
    @Published var busy = false
    @Published var saveStatus = "笔迹保存在本机"
    @Published var stabilization = 0.15 { didSet { UserDefaults.standard.set(stabilization, forKey: "inkStabilization") } }
    @Published var pressureSensitivity = 0.5 { didSet { UserDefaults.standard.set(pressureSensitivity, forKey: "inkPressure") } }
    weak var bridge: PDFReaderCoordinator?
    private let disk = DispatchQueue(label: "AskInk.local-storage")
    private let root: URL
    private var unreadablePages = Set<Int>()
    private var unreadableReplies = false
    private var drawingCache: [Int: PKDrawing] = [:]
    private var cacheOrder: [Int] = []
    private var recognitionTask: Task<HandwritingResult, Error>?
    private var recognitionGeneration = UUID()
    private var saveGenerations: [Int: UUID] = [:]
    private var autoState = AutomaticQuestionState()
    private var pauseTask: Task<Void, Never>?
    private let automaticSessionStarted = Date()
    private var automaticSuspended = false
    private var failedAutomaticDraft: QuestionDraft?

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        tool = InkTool(rawValue: UserDefaults.standard.string(forKey: "inkTool") ?? "pen") ?? .pen
        let savedWidth = UserDefaults.standard.double(forKey: "inkWidth")
        if savedWidth > 0 { width = min(6, max(0.8, savedWidth)) }
        if UserDefaults.standard.object(forKey: "inkStabilization") != nil { stabilization = min(1, max(0, UserDefaults.standard.double(forKey: "inkStabilization"))) }
        if UserDefaults.standard.object(forKey: "inkPressure") != nil { pressureSensitivity = min(1, max(0, UserDefaults.standard.double(forKey: "inkPressure"))) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            books = folders.compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("book.json")) else { return nil }
                return try? JSONDecoder().decode(Book.self, from: data)
            }.sorted { $0.addedAt > $1.addedAt }
            let availableIDs = Set(books.map(\.id))
            let restored = (UserDefaults.standard.stringArray(forKey: "openBookTabs") ?? []).compactMap(UUID.init(uuidString:))
            var seen = Set<UUID>()
            openBookIDs = restored.filter { availableIDs.contains($0) && seen.insert($0).inserted }
            if let id = UserDefaults.standard.string(forKey: "lastBook"), let book = books.first(where: { $0.id.uuidString == id }) {
                open(book)
            }
        } catch { self.error = "书库读取失败：\(error.localizedDescription)" }
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func importPDF(_ source: URL) {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let book = Book(id: UUID(), name: source.lastPathComponent, lastPage: 1, addedAt: Date())
        let destination = folder(book.id)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent("document.pdf"))
            guard let pdf = PDFDocument(url: destination.appendingPathComponent("document.pdf")), pdf.pageCount > 0, !pdf.isLocked else {
                throw ReaderError.message("无法打开 PDF；第一版暂不支持加密文件。")
            }
            try JSONEncoder().encode(book).write(to: destination.appendingPathComponent("book.json"), options: .atomic)
            books.insert(book, at: 0)
            open(book)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            self.error = error.localizedDescription
        }
    }

    func open(_ book: Book) {
        flush()
        guard let pdf = PDFDocument(url: folder(book.id).appendingPathComponent("document.pdf")), !pdf.isLocked else {
            error = "PDF 无法读取。"; return
        }
        currentBook = book
        if !openBookIDs.contains(book.id) { openBookIDs.append(book.id) }
        automaticError = nil; failedAutomaticDraft = nil
        invalidateRecognition()
        drawingCache.removeAll(); cacheOrder.removeAll()
        saveGenerations.removeAll()
        unreadablePages.removeAll(); unreadableReplies = false
        page = max(1, min(book.lastPage, pdf.pageCount))
        document = pdf
        let data = try? Data(contentsOf: folder(book.id).appendingPathComponent("replies.json"))
        if let data {
            do { replies = try JSONDecoder().decode([ReadingReply].self, from: data) }
            catch { replies = []; unreadableReplies = true; self.error = "回复文件读取失败，已保留原始文件。" }
        } else { replies = [] }
        UserDefaults.standard.set(book.id.uuidString, forKey: "lastBook")
        status = "Pencil 写字 · 手指滚动与缩放"
    }

    func closeTab(_ id: UUID) {
        guard let index = openBookIDs.firstIndex(of: id) else { return }
        let wasActive = currentBook?.id == id
        openBookIDs.remove(at: index)
        guard wasActive else { return }
        if !openBookIDs.isEmpty {
            let nextID = openBookIDs[min(index, openBookIDs.count - 1)]
            if let nextBook = books.first(where: { $0.id == nextID }) {
                open(nextBook)
                if currentBook?.id == nextID { return }
            }
        }
        flush()
        invalidateRecognition()
        currentBook = nil; document = nil; replies = []; page = 1
        bridge = nil
        drawingCache.removeAll(); cacheOrder.removeAll(); saveGenerations.removeAll()
        automaticError = nil; failedAutomaticDraft = nil
        status = "从书库打开文档或导入 PDF"
        UserDefaults.standard.removeObject(forKey: "lastBook")
    }

    func loadDrawing(page: Int) async -> PKDrawing {
        guard let book = currentBook else { return PKDrawing() }
        if let cached = drawingCache[page] { return cached }
        let url = folder(book.id).appendingPathComponent("page-\(page).drawing")
        let result: Result<PKDrawing, Error> = await withCheckedContinuation { continuation in
            disk.async {
                if !FileManager.default.fileExists(atPath: url.path) { continuation.resume(returning: .success(PKDrawing())); return }
                do { continuation.resume(returning: .success(try PKDrawing(data: Data(contentsOf: url)))) }
                catch { continuation.resume(returning: .failure(error)) }
            }
        }
        guard currentBook?.id == book.id else { return PKDrawing() }
        switch result {
        case .success(let drawing): cache(drawing, page: page); return drawing
        case .failure:
            unreadablePages.insert(page); self.error = "第 \(page) 页笔记读取失败，已保留文件。"; return PKDrawing()
        }
    }

    private func cache(_ drawing: PKDrawing, page: Int) {
        drawingCache[page] = drawing
        cacheOrder.removeAll { $0 == page }; cacheOrder.append(page)
        while cacheOrder.count > 8 { drawingCache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    func saveDrawing(_ drawing: PKDrawing, page: Int) {
        guard let book = currentBook, !unreadablePages.contains(page) else { return }
        cache(drawing, page: page)
        let url = folder(book.id).appendingPathComponent("page-\(page).drawing")
        saveStatus = "正在保存笔迹…"
        let generation = UUID(); saveGenerations[page] = generation
        disk.async { [weak self] in
            let started = ContinuousClock.now
            do {
                // PKDrawing is a value snapshot. Serialize AND write away from UI.
                try drawing.dataRepresentation().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                let elapsed = started.duration(to: .now).components
                let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                DispatchQueue.main.async {
                    guard self?.currentBook?.id == book.id, self?.saveGenerations[page] == generation else { return }
                    self?.saveStatus = "笔迹已保存"
                    _ = ms
                }
            } catch { DispatchQueue.main.async { self?.error = "笔迹保存失败：\(error.localizedDescription)"; self?.saveStatus = "保存失败" } }
        }
    }
    private func write(_ data: Data, to url: URL) {
        disk.async { [weak self] in
            do { try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]) }
            catch { DispatchQueue.main.async { self?.error = "保存失败：\(error.localizedDescription)" } }
        }
    }
    func savePosition() {
        guard var book = currentBook else { return }
        book.lastPage = page; currentBook = book
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
        if let data = try? JSONEncoder().encode(book) { write(data, to: folder(book.id).appendingPathComponent("book.json")) }
    }
    func saveReplies() {
        guard let book = currentBook, !unreadableReplies else { return }
        if let data = try? JSONEncoder().encode(replies) { write(data, to: folder(book.id).appendingPathComponent("replies.json")) }
    }
    func flush() {
        bridge?.flush(); savePosition()
        // Drain queued saves under a finite background grant without blocking UI.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save handwriting")
        disk.async { DispatchQueue.main.async { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } } }
    }
    func jump(_ number: Int) {
        guard let document, (1...document.pageCount).contains(number) else {
            error = "请输入 1 到 \(document?.pageCount ?? 1) 之间的页码。"; return
        }
        bridge?.go(to: number)
    }

    func invalidateRecognition() {
        pauseTask?.cancel(); pauseTask = nil; autoState.cancel()
        if recognitionTask != nil { status = "笔迹或页面已变化，请重新识别" }
        recognitionGeneration = UUID(); recognitionTask?.cancel(); recognitionTask = nil
    }

    func setAutomaticActive(_ active: Bool) {
        automaticSuspended = !active
        if !active { invalidateRecognition() }
    }

    func scheduleAutomaticQuestion() {
        guard autoReply, !automaticSuspended else { return }
        pauseTask?.cancel()
        let token = autoState.schedule()
        let delay = min(6, max(1, autoReplyDelay))
        pauseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.autoState.pending == token else { return }
            // Leave the pending token for the in-flight request's completion.
            guard self.autoState.consume(token, canStart: !self.busy) else { return }
            self.pauseTask = nil
            await self.answerAutomatically()
        }
    }

    func retryAutomaticQuestion() async {
        guard !busy else { return }
        guard let failed = failedAutomaticDraft, failed.snapshot.bookID == currentBook?.id else {
            await answerAutomatically()
            return
        }
        busy = true
        defer { busy = false; resumePendingQuestion() }
        do {
            status = "AI 正在回答…"
            try await sendAutomaticAnswer(failed)
            failedAutomaticDraft = nil; automaticError = nil
        } catch { automaticError = "自动回复失败：\(error.localizedDescription)"; status = automaticError ?? "回复失败" }
    }

    private func resumePendingQuestion() {
        guard let bookID = currentBook?.id else { return }
        let key = "\(bookID.uuidString)/\(page)"
        if autoState.pending != nil || bridge?.hasAutomaticQuestion(since: automaticSessionStarted,
            excluding: autoState.excludedStrokes(for: key)) == true {
            scheduleAutomaticQuestion()
        }
    }

    private func answerAutomatically() async {
        guard autoReply, !automaticSuspended, !busy, let bookID = currentBook?.id else { return }
        let key = "\(bookID.uuidString)/\(page)"
        let snapshot: QuestionSnapshot
        do {
            guard let value = try bridge?.questionSnapshot(block: Int.max, excluding: autoState.excludedStrokes(for: key), since: automaticSessionStarted, groupingPause: autoReplyDelay) else { return }
            snapshot = value
        } catch {
            // Source highlighting alone is not a written question.
            status = "停笔自动回复 · 在正文旁写下问题"
            return
        }
        busy = true
        var continueQueue = false
        defer { busy = false; recognitionTask = nil; if continueQueue || autoState.pending != nil { resumePendingQuestion() } }
        let generation = UUID(); recognitionGeneration = generation
        do {
            status = "正在本机识别手写…"
            let task = Task { try await HandwritingRecognizer.shared.recognize(drawing: snapshot.drawing, image: snapshot.ink) }
            recognitionTask = task
            let result = try await task.value
            guard generation == recognitionGeneration, bridge?.isCurrent(snapshot) == true else { return }
            recognitionTask = nil
            let question = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = QuestionDraft(snapshot: snapshot, text: question, candidates: result.candidates,
                source: result.source, milliseconds: result.milliseconds, recognitionNote: result.note, regions: result.regions, recognitionVersion: result.recognitionVersion)
            // Freeze the sent sentence. Later strokes become a separate pending question.
            autoState.submitted(snapshot.drawing.strokes.map { $0.path.creationDate }, for: key)
            continueQueue = true
            status = "AI 正在回答：\(question)"
            do {
                try await sendAutomaticAnswer(request)
                if currentBook?.id == snapshot.bookID { automaticError = nil; failedAutomaticDraft = nil }
            } catch {
                if currentBook?.id == snapshot.bookID {
                    failedAutomaticDraft = request
                    automaticError = "自动回复失败：\(error.localizedDescription)"
                    status = automaticError!
                }
            }
        } catch is CancellationError { }
        catch {
            if generation == recognitionGeneration {
                automaticError = "自动识别失败：\(error.localizedDescription)"; status = automaticError!
            }
        }
    }

    private func sendAutomaticAnswer(_ request: QuestionDraft) async throws {
        let snapshot = request.snapshot
        let history = replies.filter { $0.page == snapshot.page }.suffix(4).map { ["question": $0.question, "answer": $0.answer] }
        let response: AnswerResult = try await ReaderAPI.call("answer", body: [
            "question": request.text, "pageNumber": snapshot.page, "context": snapshot.context,
            "pageImageDataUrl": snapshot.pageDataURL,
            "handwritingImageDataUrl": snapshot.handwritingDataURL,
            "recognitionNote": request.recognitionNote, "questionOrigin": "automaticHandwriting",
            "contextStatus": snapshot.context.isEmpty ? "visual" : "nearby", "history": history
        ])
        let reply = ReadingReply(page: snapshot.page, question: request.text.isEmpty ? "手写问题（见笔迹图）" : request.text,
            answer: response.answer, source: snapshot.context, model: response.model, inkImageDataURL: snapshot.handwritingDataURL, recognizedText: request.text, recognitionNote: request.recognitionNote,
            recognitionSource: request.source, recognitionVersion: request.recognitionVersion, recognitionRegions: request.regions)
        if currentBook?.id == snapshot.bookID {
            replies.append(reply); saveReplies(); status = "已自动回复第 \(snapshot.page) 页"
        } else {
            let url = folder(snapshot.bookID).appendingPathComponent("replies.json")
            disk.async { [weak self] in
                do {
                    var saved: [ReadingReply] = []
                    if FileManager.default.fileExists(atPath: url.path) {
                        saved = try JSONDecoder().decode([ReadingReply].self, from: Data(contentsOf: url))
                    }
                    saved.append(reply)
                    try JSONEncoder().encode(saved).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                } catch { DispatchQueue.main.async { self?.error = "原书回复保存失败：\(error.localizedDescription)" } }
            }
        }
    }

}
