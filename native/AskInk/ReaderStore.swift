import SwiftUI
import PDFKit
import PencilKit

@MainActor
final class ReaderStore: ObservableObject {
    @Published var books: [Document] = []
    @Published var openBookIDs: [UUID] = [] {
        didSet { UserDefaults.standard.set(openBookIDs.map(\.uuidString), forKey: "openBookTabs") }
    }
    @Published var currentBook: Document?
    @Published private var pdfAdapter: PDFDocumentAdapter?
    // PDF reader presentation only. Document is the format-neutral library object.
    var document: PDFDocument? {
        get { pdfAdapter?.pdfDocument }
        set { pdfAdapter = newValue.map(PDFDocumentAdapter.init(pdfDocument:)) }
    }
    var documentGraph: DocumentGraph? { bookIndex?.graph }
    var aiThreads: [AIThread] {
        guard let documentID = currentBook?.id else { return [] }
        return (try? AIHistory.threads(replies, documentID: documentID)) ?? []
    }
    @Published var bookIndex: DocumentIndex?
    @Published var indexStatus = ""
    @Published var indexBuilding = false
    @Published var searchResults: [ReadingSource] = []
    @Published var bookSummary: BookSummary?
    @Published var summaryProgress: String?
    @Published var summaryError: String?
    @Published var returnPage: Int?
    @Published var currentSourceLines: [SourceTextLine] = []
    @Published var bookmarks: Set<Int> = []
    @Published var chromeHidden = false
    @Published var paletteCollapsed = false
    @Published var palettePinned = UserDefaults.standard.bool(forKey: "palettePinned") { didSet { UserDefaults.standard.set(palettePinned, forKey: "palettePinned") } }
    @Published var scrollRevision = 0
    @Published var firstPencilContact = false
    @Published var consentQuestion: QuestionDraft?
    @Published var failedQuestion: QuestionDraft?
    @Published var questionOffline = false
    @Published var unanswered: [SavedQuestion] = [] { didSet { bridge?.updateAnswerPositions() } }
    @Published var page = 1 { didSet { if oldValue != page { refreshCurrentSourceLines() } } }
    @Published var tool: InkTool = .ballpoint { didSet {
        let defaults = UserDefaults.standard
        defaults.set(tool.rawValue, forKey: "inkTool")
        guard oldValue != tool else { return }
        defaults.set(width, forKey: "toolWidth.\(oldValue.rawValue)")
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true) {
            defaults.set(data, forKey: "toolColor.\(oldValue.rawValue)")
        }
        width = defaults.object(forKey: "toolWidth.\(tool.rawValue)") as? Double ?? tool.defaultWidth
        if let data = defaults.data(forKey: "toolColor.\(tool.rawValue)"),
           let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) {
            color = Color(uiColor: stored)
        } else { color = tool == .marker ? .yellow : .black }
        if InkTool.penStyles.contains(tool) { defaults.set(tool.rawValue, forKey: "lastPenStyle") }
    } }
    @Published var eraserMode = InkEraserMode(rawValue: UserDefaults.standard.string(forKey: "eraserMode") ?? "partial") ?? .partial {
        didSet { UserDefaults.standard.set(eraserMode.rawValue, forKey: "eraserMode") }
    }
    var preferredPen: InkTool {
        let value = InkTool(rawValue: UserDefaults.standard.string(forKey: "lastPenStyle") ?? "ballpoint") ?? .ballpoint
        return InkTool.penStyles.contains(value) ? value : .ballpoint
    }
    @Published var lockPageForWriting = UserDefaults.standard.bool(forKey: "lockPageForWriting") {
        didSet { UserDefaults.standard.set(lockPageForWriting, forKey: "lockPageForWriting") }
    }
    @Published var width = 2.0 { didSet { UserDefaults.standard.set(width, forKey: "inkWidth"); UserDefaults.standard.set(width, forKey: "toolWidth.\(tool.rawValue)") } }
    @Published var color: Color = .black { didSet {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true) { UserDefaults.standard.set(data, forKey: "defaultInkColor") }
    } }
    @Published var replies: [ReadingReply] = [] { didSet { bridge?.updateAnswerPositions() } }
    let answerViewport = AnswerViewportState()
    var thinkingQuestion: (bookID: UUID, page: Int, anchor: ContentAnchor)? { didSet { bridge?.updateAnswerPositions() } }
    var overlayReplies: [ReadingReply] {
        var latest: [UUID: ReadingReply] = [:]
        replies.forEach { latest[$0.conversationID] = $0 }
        return latest.values.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
    @Published var status = "导入 PDF，开始阅读"
    @Published var error: String?
    @Published var autoReply = UserDefaults.standard.object(forKey: "autoReply") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoReply, forKey: "autoReply")
            if !autoReply { invalidateRecognition() }
        }
    }
    @Published var autoReplyDelay = UserDefaults.standard.object(forKey: "autoReplyDelay") as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(autoReplyDelay, forKey: "autoReplyDelay") }
    }
    @Published var automaticError: String?
    @Published var streamingText = ""
    @Published var streamingThreadID: UUID?
    @Published var streamingQuestion = ""
    @Published var busy = false
    @Published var saveStatus = "笔迹保存在本机"
    weak var bridge: PDFReaderCoordinator?
    private let disk = DispatchQueue(label: "AskInk.local-storage")
    private let root: URL
    private var unreadablePages = Set<Int>()
    private var unreadableReplies = false
    private var drawingCache: [Int: PKDrawing] = [:]
    private var cacheOrder: [Int] = []
    private var recognitionTask: Task<HandwritingResult, Error>?
    private var answerTask: Task<(AnswerResult, String), Error>?
    private var recognitionGeneration = UUID()
    private var saveGenerations: [Int: UUID] = [:]
    private var autoState = AutomaticQuestionState()
    private var pauseTask: Task<Void, Never>?
    private let automaticSessionStarted = Date()
    private var automaticSuspended = false
    private var failedAutomaticDraft: QuestionDraft?
    private var indexTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var indexGeneration = UUID()
    private var summaryGeneration = UUID()
    private var readingReturnDestination: PDFDestination?

    init() {
        for key in ["inkStabilization", "inkPressure", "inkPressureSmoothing", "toolWidth.brush", "toolColor.brush"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        tool = InkTool(rawValue: UserDefaults.standard.string(forKey: "inkTool") ?? "ballpoint") ?? .ballpoint
        if let data = UserDefaults.standard.data(forKey: "defaultInkColor"), let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data) { color = Color(uiColor: stored) }
        let savedWidth = UserDefaults.standard.object(forKey: "toolWidth.\(tool.rawValue)") as? Double
        width = min(tool.widthLimits.upperBound, max(tool.widthLimits.lowerBound, savedWidth ?? tool.defaultWidth))
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            books = folders.compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("book.json")) else { return nil }
                return try? JSONDecoder().decode(Document.self, from: data)
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
        let book = Document(id: UUID(), name: source.lastPathComponent, lastPage: 1, addedAt: Date())
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

    func open(_ book: Document) {
        flush()
        guard let pdf = PDFDocument(url: folder(book.id).appendingPathComponent("document.pdf")), !pdf.isLocked else {
            error = "PDF 无法读取。"; return
        }
        var openedBook = book
        openedBook.lastOpenedAt = Date(); openedBook.pageCount = pdf.pageCount
        currentBook = openedBook
        unanswered = (try? JSONDecoder().decode([SavedQuestion].self, from: Data(contentsOf: folder(book.id).appendingPathComponent("unanswered.json")))) ?? []
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = openedBook }
        bookmarks = Set((try? JSONDecoder().decode([Int].self, from: Data(contentsOf: folder(book.id).appendingPathComponent("bookmarks.json")))) ?? [])
        chromeHidden = false; paletteCollapsed = false; failedQuestion = nil
        indexTask?.cancel(); summaryTask?.cancel(); summaryTask = nil
        indexGeneration = UUID(); summaryGeneration = UUID()
        bookIndex = nil; searchResults = []; bookSummary = nil; summaryProgress = nil; summaryError = nil; returnPage = nil
        currentSourceLines = []
        readingReturnDestination = nil
        if !openBookIDs.contains(book.id) { openBookIDs.append(book.id) }
        automaticError = nil; failedAutomaticDraft = nil
        invalidateRecognition()
        drawingCache.removeAll(); cacheOrder.removeAll()
        saveGenerations.removeAll()
        unreadablePages.removeAll(); unreadableReplies = false
        page = max(1, min(book.lastPage, pdf.pageCount))
        document = pdf
        do { replies = try AIHistory.load(folder: folder(book.id), documentID: book.id) }
        catch { replies = []; unreadableReplies = true; self.error = "回复文件读取失败，已保留原始文件。" }
        UserDefaults.standard.set(book.id.uuidString, forKey: "lastBook")
        status = "Pencil 写字 · 手指滚动与缩放"
        savePosition()
        buildIndex()
    }

    func buildIndex() {
        guard let book = currentBook else { return }
        indexTask?.cancel(); indexBuilding = true; indexStatus = "准备本机全文索引…"
        let generation = UUID(); indexGeneration = generation
        let fileURL = folder(book.id).appendingPathComponent("document.pdf")
        indexTask = Task { [weak self] in
            guard let owner = self else { return }
            do {
                let index = try await LocalDocumentIndex.shared.build(fileURL: fileURL, documentID: book.id, format: book.resolvedFormat) { done, total, lines in
                    await MainActor.run {
                        guard owner.currentBook?.id == book.id, owner.indexGeneration == generation else { return }
                        owner.indexStatus = "本机提取正文 \(done) / \(total) 页"
                        if owner.page == done { owner.currentSourceLines = lines }
                    }
                }
                guard !Task.isCancelled, self?.currentBook?.id == book.id, self?.indexGeneration == generation else { return }
                self?.bookIndex = index; self?.indexBuilding = false
                owner.currentSourceLines = index.lines[owner.page] ?? []
                self?.indexStatus = "全文索引已就绪 · FTS5 · \(index.semanticBlockCount) / \(index.graph.blocks.count) 块有本机语义向量"
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self?.currentBook?.id == book.id, self?.indexGeneration == generation else { return }
                self?.indexBuilding = false; self?.indexStatus = "索引失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshCurrentSourceLines() {
        currentSourceLines = bookIndex?.lines[page] ?? []
        guard currentSourceLines.isEmpty, let book = currentBook else { return }
        let number = page, url = folder(book.id).appendingPathComponent("document.pdf")
        Task { [weak self] in
            let lines = await LocalDocumentIndex.shared.lines(fileURL: url, page: number)
            guard self?.currentBook?.id == book.id, self?.page == number else { return }
            self?.currentSourceLines = lines
        }
    }

    func searchBook(_ query: String, previousOnly: Bool) async {
        guard let book = currentBook else { return }
        let fileURL = folder(book.id).appendingPathComponent("document.pdf")
        let results = await LocalDocumentIndex.shared.search(fileURL: fileURL, query: query, before: previousOnly ? page : nil, limit: 30)
        guard !Task.isCancelled, currentBook?.id == book.id else { return }
        searchResults = results
    }

    func jumpToSource(_ source: ReadingSource) {
        if returnPage == nil {
            returnPage = page
            readingReturnDestination = bridge?.currentDestination
        }
        bridge?.go(to: source.page, bounds: source.bounds)
        chromeHidden = false
    }
    func returnToReading() {
        guard let destination = returnPage else { return }
        let location = readingReturnDestination
        returnPage = nil; readingReturnDestination = nil
        if let location { bridge?.go(to: location) } else { jump(destination) }
        chromeHidden = false
    }

    func summarizeBook(mode: BookSummaryMode) {
        guard summaryTask == nil, let index = bookIndex, let book = currentBook else { return }
        summaryError = nil; summaryProgress = "准备全文总结…"
        let generation = UUID(); summaryGeneration = generation
        let directory = folder(book.id), connection = AIConnection.stored(AIProvider.selected)
        let key = mode == .cloud ? ProviderKey.read(provider: connection.provider) : ""
        summaryTask = Task { [weak self] in
            guard let owner = self else { return }
            defer { if self?.summaryGeneration == generation { self?.summaryProgress = nil; self?.summaryTask = nil } }
            do {
                let summary = try await BookSummarizer.shared.summarize(index: index, folder: directory, mode: mode, connection: connection, key: key) { progress in
                    await MainActor.run {
                        if owner.currentBook?.id == book.id, owner.summaryGeneration == generation { owner.summaryProgress = progress }
                    }
                }
                guard !Task.isCancelled, self?.currentBook?.id == book.id, self?.summaryGeneration == generation else { return }
                self?.bookSummary = summary
                let url = directory.appendingPathComponent("document.pdf")
                if let graph = try await LocalDocumentIndex.shared.rememberSummary(fileURL: url, text: summary.text, coveredPages: summary.coveredPages),
                   self?.currentBook?.id == book.id, self?.summaryGeneration == generation {
                    self?.bookIndex?.graph = graph
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self?.currentBook?.id == book.id, self?.summaryGeneration == generation { self?.summaryError = error.localizedDescription } }
        }
    }
    func cancelSummary() { summaryTask?.cancel() }
    func cancelReadingWork(bookID: UUID) {
        if currentBook?.id == bookID {
            indexTask?.cancel(); summaryTask?.cancel(); summaryTask = nil
            indexGeneration = UUID(); summaryGeneration = UUID()
            indexBuilding = false; indexStatus = ""; bookIndex = nil; currentSourceLines = []
            searchResults = []; bookSummary = nil; summaryProgress = nil; summaryError = nil
            returnPage = nil; readingReturnDestination = nil
        }
        let url = folder(bookID).appendingPathComponent("document.pdf")
        Task { await LocalDocumentIndex.shared.forget(fileURL: url) }
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
        indexTask?.cancel(); summaryTask?.cancel(); summaryTask = nil
        indexGeneration = UUID(); summaryGeneration = UUID()
        bookIndex = nil; bookSummary = nil; searchResults = []; indexBuilding = false; summaryProgress = nil; returnPage = nil
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
        let records = replies, directory = folder(book.id)
        disk.async { [weak self] in
            do { try AIHistory.save(records, folder: directory, documentID: book.id) }
            catch { DispatchQueue.main.async { self?.error = "会话保存失败：\(error.localizedDescription)" } }
        }
    }
    func eraseStoredAIHistory() {
        let directories = books.map { ($0.id, folder($0.id)) }
        disk.async { [weak self] in
            do {
                for (id, directory) in directories {
                    try AIHistory.save([], folder: directory, documentID: id)
                    try JSONEncoder().encode([SavedQuestion]()).write(to: directory.appendingPathComponent("unanswered.json"), options: .atomic)
                }
            } catch { DispatchQueue.main.async { self?.error = "部分回答记录无法删除。" } }
        }
    }
    func waitForLocalSaves() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in disk.async { continuation.resume() } }
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

    func invalidateRecognition(cancelRequest: Bool = false) {
        if cancelRequest { answerTask?.cancel() }
        pauseTask?.cancel(); pauseTask = nil; autoState.cancel()
        if recognitionTask != nil { status = "笔迹或页面已变化，请重新识别" }
        recognitionGeneration = UUID(); recognitionTask?.cancel(); recognitionTask = nil
    }

    func setAutomaticActive(_ active: Bool) {
        automaticSuspended = !active
        if !active { invalidateRecognition() }
    }

    func scheduleAutomaticQuestion() {
        guard autoReply, !automaticSuspended, consentQuestion == nil else { return }
        pauseTask?.cancel()
        let token = autoState.schedule()
        let delay = min(0.7, max(0.5, autoReplyDelay))
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
        guard UserDefaults.standard.bool(forKey: "aiPrivacyConsent") else { consentQuestion = failed; return }
        busy = true
        defer { busy = false; thinkingQuestion = nil; resumePendingQuestion() }
        do {
            if let failed = failedAutomaticDraft { thinkingQuestion = (failed.snapshot.bookID, failed.snapshot.page, failed.snapshot.anchor) }
            try await sendAutomaticAnswer(failed)
            failedAutomaticDraft = nil; automaticError = nil; failedQuestion = nil
            removeSavedQuestion(failed.id)
        } catch {
            questionOffline = (error as? URLError)?.code == .notConnectedToInternet
            saveUnanswered(failed, offline: questionOffline)
            automaticError = questionOffline ? "当前离线，联网后可重试。" : "暂时无法回答，可重试。"
        }
    }

    private func resumePendingQuestion() {
        guard let bookID = currentBook?.id else { return }
        let key = "\(bookID.uuidString)/\(page)"
        if autoState.pending != nil || bridge?.hasAutomaticQuestion(since: automaticSessionStarted,
            excluding: autoState.scannedStrokes(for: key)) == true {
            scheduleAutomaticQuestion()
        }
    }

    private func saveUnanswered(_ draft: QuestionDraft, offline: Bool) {
        guard let book = currentBook, book.id == draft.snapshot.bookID else { return }
        unanswered.removeAll { $0.id == draft.id }
        unanswered.append(SavedQuestion(draft, offline: offline))
        if let data = try? JSONEncoder().encode(unanswered) { write(data, to: folder(book.id).appendingPathComponent("unanswered.json")) }
    }
    private func removeSavedQuestion(_ id: UUID) {
        unanswered.removeAll { $0.id == id }
        if let book = currentBook, let data = try? JSONEncoder().encode(unanswered) { write(data, to: folder(book.id).appendingPathComponent("unanswered.json")) }
    }
    func retrySavedQuestion(_ saved: SavedQuestion) async {
        guard !busy, currentBook?.id == saved.bookID, let draft = saved.draft() else { return }
        failedAutomaticDraft = draft; failedQuestion = draft; questionOffline = saved.offline
        await retryAutomaticQuestion()
    }

    func acceptAIPrivacy() async {
        UserDefaults.standard.set(true, forKey: "aiPrivacyConsent")
        guard let question = consentQuestion else { return }
        consentQuestion = nil
        guard currentBook?.id == question.snapshot.bookID, !busy, question.snapshot.isTextSelection || bridge?.isCurrent(question.snapshot) == true || unanswered.contains(where: { $0.id == question.id }) else { return }
        let key = "\(question.snapshot.bookID.uuidString)/\(question.snapshot.page)"
        autoState.submitted(question.snapshot.drawing.strokes.map { $0.path.creationDate }, for: key)
        failedAutomaticDraft = question; failedQuestion = question
        await retryAutomaticQuestion()
    }
    func deferAIPrivacy() {
        if let request = consentQuestion { failedAutomaticDraft = request; failedQuestion = request; saveUnanswered(request, offline: false) }
        consentQuestion = nil; thinkingQuestion = nil
    }
    func readerScrolled() {
        scrollRevision += 1
        if UserDefaults.standard.object(forKey: "toolbarAutoHide") as? Bool ?? true { chromeHidden = true }
        if !palettePinned { paletteCollapsed = true }
    }

    func askSelectedText(_ text: String, page number: Int, bounds: CGRect) async {
        guard !busy, let book = currentBook, let page = document?.page(at: number - 1) else { return }
        let region = bounds.insetBy(dx: -16, dy: -24).intersection(page.bounds(for: .cropBox))
        guard !region.isNull, !region.isEmpty else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { ctx in UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: region.width * 2, height: region.height * 2), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: region.width * 2, height: region.height * 2))
            ctx.cgContext.translateBy(x: 0, y: region.height * 2); ctx.cgContext.scaleBy(x: 2, y: -2)
            ctx.cgContext.translateBy(x: -region.minX, y: -region.minY); page.draw(with: .cropBox, to: ctx.cgContext)
        }
        let snapshot = QuestionSnapshot(page: number, anchor: ContentAnchor(x: bounds.maxX, y: bounds.midY, documentID: book.id, location: .page(number, rect: region), textQuote: text), ink: blank, handwritingImage: blank,
            context: text, pageImage: image, drawing: PKDrawing(), bookID: book.id, revision: UUID(), scope: .latest, block: 0, blockCount: 1,
            isTextSelection: true, sourceReferences: [ReadingSource(id: "p\(number)-selection", page: number, text: text, bounds: region)])
        let draft = QuestionDraft(snapshot: snapshot, text: "请解释这段文字：\(text)", candidates: [], source: "Selected text", milliseconds: 0, recognitionNote: "")
        if !UserDefaults.standard.bool(forKey: "aiPrivacyConsent") { consentQuestion = draft; return }
        failedAutomaticDraft = draft; failedQuestion = draft
        await retryAutomaticQuestion()
    }

    func askInk(at point: CGPoint) async { await answerAutomatically(force: true, near: point) }

    private func answerAutomatically(force: Bool = false, near: CGPoint? = nil) async {
        guard (autoReply || force), !automaticSuspended, !busy, let bookID = currentBook?.id else { return }
        let key = "\(bookID.uuidString)/\(page)"
        var capture: InkQuestionCapture
        do {
            guard let value = try bridge?.questionCapture(block: Int.max, excluding: force ? [] : autoState.scannedStrokes(for: key), since: force ? nil : automaticSessionStarted, groupingPause: autoReplyDelay, near: near) else { return }
            capture = value
        } catch { return }
        let starts = capture.drawing.strokes.map { $0.path.creationDate }
        // Ordinary note shapes do no image preparation, OCR, or API work.
        guard force || capture.isQuestionCandidate else {
            autoState.assessedNote(starts, for: key); resumePendingQuestion(); return
        }
        busy = true
        var continueQueue = false
        defer {
            busy = false; recognitionTask = nil; thinkingQuestion = nil
            if continueQueue || autoState.pending != nil { resumePendingQuestion() }
        }
        let generation = UUID(); recognitionGeneration = generation
        do {
            var probeText = ""
            if !force {
                let symbolImage = try await QuestionPreparation.shared.symbolImage(capture)
                guard generation == recognitionGeneration, bridge?.isCurrent(capture) == true else { return }
                let probeTask = Task { try await HandwritingRecognizer.shared.recognize(drawing: capture.symbolDrawing, image: symbolImage) }
                recognitionTask = probeTask
                let probe = try await probeTask.value
                guard generation == recognitionGeneration, bridge?.isCurrent(capture) == true else { return }
                guard QuestionMarkGate.endsInQuestionMark(probe.text) else {
                    autoState.assessedNote(starts, for: key); continueQueue = true; return
                }
                probeText = probe.text
            }
            if !force, let complete = try bridge?.questionCapture(excluding: autoState.excludedStrokes(for: key),
                since: automaticSessionStarted, groupingPause: max(6, autoReplyDelay),
                near: CGPoint(x: capture.drawing.bounds.midX, y: capture.drawing.bounds.midY)) {
                capture = complete
            }
            thinkingQuestion = (capture.bookID, capture.page, capture.anchor)
            let snapshot = try await QuestionPreparation.shared.prepare(capture)
            guard generation == recognitionGeneration, bridge?.isCurrent(capture) == true else { return }
            let task = Task { try await HandwritingRecognizer.shared.recognize(drawing: snapshot.drawing, image: snapshot.ink) }
            recognitionTask = task
            let result = try await task.value
            guard generation == recognitionGeneration, bridge?.isCurrent(capture) == true else { return }
            recognitionTask = nil
            let recognized = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !force && !QuestionMarkGate.endsInQuestionMark(recognized.isEmpty ? probeText : recognized) {
                autoState.assessedNote(starts, for: key); continueQueue = true; return
            }
            let question = recognized.isEmpty ? (force ? "请解释这段笔记。" : probeText) : recognized
            let request = QuestionDraft(snapshot: snapshot, text: question, candidates: result.candidates,
                source: result.source, milliseconds: result.milliseconds, recognitionNote: result.note,
                regions: result.regions, recognitionVersion: result.recognitionVersion)
            if !UserDefaults.standard.bool(forKey: "aiPrivacyConsent"), currentBook?.isSample != true {
                consentQuestion = request
                return
            }
            autoState.submitted(capture.drawing.strokes.map { $0.path.creationDate }, for: key); continueQueue = true
            do {
                try await sendAutomaticAnswer(request)
                if currentBook?.id == snapshot.bookID { automaticError = nil; failedAutomaticDraft = nil; failedQuestion = nil }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    autoState.withdrawSubmission(capture.drawing.strokes.map { $0.path.creationDate }, for: key)
                    return
                }
                if currentBook?.id == snapshot.bookID {
                    failedAutomaticDraft = request; failedQuestion = request
                    saveUnanswered(request, offline: (error as? URLError)?.code == .notConnectedToInternet)
                    questionOffline = (error as? URLError)?.code == .notConnectedToInternet
                    automaticError = questionOffline ? "当前离线，联网后可重试。" : "暂时无法回答，可重试。"
                }
            }
        } catch is CancellationError { }
        catch { if generation == recognitionGeneration { status = "笔记已保存" } }
    }

    func askFollowup(replyID: UUID, question: String, style: String? = nil) async -> Bool {
        guard !busy, let original = replies.first(where: { $0.id == replyID }), let book = currentBook else { return false }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        busy = true
        if let anchor = original.anchor { thinkingQuestion = (book.id, original.page, anchor) }
        defer { busy = false; thinkingQuestion = nil; resumePendingQuestion() }
        let mode: AnswerMode = style == "Detailed" || style == "Tutor" ? .expanded : .compact
        let allowFuture = UserDefaults.standard.bool(forKey: "allowSpoilers")
        let history = replies.filter { $0.conversationID == original.conversationID && (allowFuture || $0.allowedFuture != true) }.map { ["question": $0.question, "answer": $0.answer] }
        let connection = AIConnection.stored(AIProvider.selected), key = ProviderKey.read(provider: AIProvider.selected)
        let url = folder(book.id).appendingPathComponent("document.pdf")
        var anchor = original.anchor ?? ContentAnchor(x: 0, y: 0)
        anchor.location = .page(original.page); anchor.documentID = book.id
        streamingThreadID = original.conversationID; streamingQuestion = text; streamingText = ""
        defer { streamingThreadID = nil; streamingQuestion = ""; streamingText = "" }
        if book.isSample == true {
            let reply = ReadingReply(page: original.page, question: text, answer: "示例说明：方向导数比较单位距离内的变化。当单位方向与梯度同向时，增长最快。自己的 PDF 可使用高级设置中的 AI 连接回答。", source: original.source, model: "Sample", anchor: original.anchor, threadID: original.conversationID, sourceReferences: original.sourceReferences)
            recordAnswer(reply, bookID: book.id); return true
        }
        do {
            let prepared = try await AIReadingPipeline.shared.answer(documentID: book.id, fileURL: url,
                question: text, anchor: anchor, selectedText: original.sourceReferences?.first(where: { original.targetContentIDs?.contains($0.id) == true })?.text,
                nearbyText: original.source, history: history, mode: mode, allowFuture: allowFuture,
                repeatedQuestions: history.count, connection: connection, key: key,
                extra: ["questionOrigin": "followup"]) { [weak self] text in
                    guard let owner = self else { return }
                    await MainActor.run { if owner.currentBook?.id == book.id { owner.streamingText = text } }
                }
            let response = prepared.result
            let reply = ReadingReply(page: original.page, question: text, answer: response.answer, source: prepared.packet.context,
                model: response.model, anchor: original.anchor, threadID: original.conversationID,
                sourceReferences: prepared.sources, inputTokens: response.inputTokens, outputTokens: response.outputTokens,
                cachedTokens: response.cachedTokens, citations: response.citations,
                targetContentIDs: prepared.packet.excerpts.filter { $0.reason == .selection }.map(\.contentID), mode: mode, allowedFuture: allowFuture)
            recordAnswer(reply, bookID: book.id)
            return true
        } catch { return false }
    }

    private func recordAnswer(_ reply: ReadingReply, bookID: UUID) {
        guard FileManager.default.fileExists(atPath: folder(bookID).appendingPathComponent("document.pdf").path) else { return }
        if currentBook?.id == bookID { replies.append(reply); saveReplies() }
        else {
            let directory = folder(bookID)
            disk.async { [weak self] in
                do {
                    var saved = try AIHistory.load(folder: directory, documentID: bookID)
                    saved.append(reply)
                    try AIHistory.save(saved, folder: directory, documentID: bookID)
                } catch { DispatchQueue.main.async { self?.error = "原书回复保存失败。" } }
            }
        }
    }

    private func sendAutomaticAnswer(_ request: QuestionDraft) async throws {
        let snapshot = request.snapshot
        if currentBook?.id == snapshot.bookID, currentBook?.isSample == true {
            let reply = ReadingReply(page: snapshot.page, question: request.text,
                answer: "示例：梯度指向函数增长最快的方向。方向导数是梯度与单位方向向量的点积；方向一致时，这个点积最大。", source: snapshot.context, model: "Sample", anchor: snapshot.anchor,
                sourceReferences: snapshot.sourceReferences)
            recordAnswer(reply, bookID: snapshot.bookID)
            return
        }

        // A new ink question starts a new thread; unrelated same-page answers are not history.
        let repeatedQuestions = replies.filter { $0.page == snapshot.page }.count
        let allowFuture = UserDefaults.standard.bool(forKey: "allowSpoilers")
        let connection = AIConnection.stored(AIProvider.selected), key = ProviderKey.read(provider: AIProvider.selected)
        let url = folder(snapshot.bookID).appendingPathComponent("document.pdf")
        var anchor = snapshot.anchor
        anchor.location = .page(snapshot.page); anchor.documentID = snapshot.bookID
        let frozenAnchor = anchor
        streamingThreadID = request.id; streamingQuestion = request.text; streamingText = ""
        defer { streamingThreadID = nil; streamingQuestion = ""; streamingText = "" }
        var preparedPacket: ContextPacket?
        var preparedSources: [ReadingSource] = []
        let task = Task { () async throws -> (AnswerResult, String) in
            let images = await Task.detached(priority: .utility) { (snapshot.handwritingDataURL, snapshot.pageDataURL) }.value
            var extra: [String: Any] = ["handwritingImageDataUrl": images.0,
                "recognitionNote": request.recognitionNote,
                "questionOrigin": snapshot.isTextSelection ? "userEdited" : "automaticHandwriting"]
            if snapshot.isTextSelection { extra.removeValue(forKey: "handwritingImageDataUrl") }
            if UserDefaults.standard.object(forKey: "useContextImages") as? Bool ?? true || snapshot.context.isEmpty {
                extra["pageImageDataUrl"] = images.1
            }
            let prepared = try await AIReadingPipeline.shared.answer(documentID: snapshot.bookID, fileURL: url,
                question: request.text, anchor: frozenAnchor, selectedText: snapshot.markedText ?? (snapshot.isTextSelection ? snapshot.context : nil),
                nearbyText: snapshot.context, history: [], mode: .compact, allowFuture: allowFuture,
                repeatedQuestions: repeatedQuestions, connection: connection, key: key, extra: extra) { [weak self] text in
                    guard let owner = self else { return }
                    await MainActor.run { if owner.currentBook?.id == snapshot.bookID { owner.streamingText = text } }
                }
            preparedPacket = prepared.packet; preparedSources = prepared.sources
            try Task.checkCancellation()
            return (prepared.result, images.0)
        }
        answerTask = task
        defer { answerTask = nil }
        let prepared = try await task.value
        try Task.checkCancellation()
        let response = prepared.0
        var answerAnchor = frozenAnchor
        if let source = preparedPacket?.excerpts.first(where: { $0.reason == .spatial }) {
            answerAnchor.contentID = source.anchor.contentID
            answerAnchor.location = source.anchor.location
            answerAnchor.textQuote = snapshot.markedText
        }
        let reply = ReadingReply(page: snapshot.page, question: request.text.isEmpty ? "手写问题（见笔迹图）" : request.text,
            answer: response.answer, source: preparedPacket?.context ?? snapshot.context, model: response.model, inkImageDataURL: prepared.1, recognizedText: request.text, recognitionNote: request.recognitionNote,
            recognitionSource: request.source, recognitionVersion: request.recognitionVersion, recognitionRegions: request.regions, anchor: answerAnchor,
            threadID: request.id, sourceReferences: preparedSources, inputTokens: response.inputTokens, outputTokens: response.outputTokens,
            contextPacket: preparedPacket, cachedTokens: response.cachedTokens, citations: response.citations,
            questionInkIDs: snapshot.drawing.strokes.map { String($0.path.creationDate.timeIntervalSince1970) },
            targetContentIDs: preparedPacket?.excerpts.filter { $0.reason == .selection }.map(\.contentID), mode: .compact, allowedFuture: allowFuture)
        recordAnswer(reply, bookID: snapshot.bookID)
        if currentBook?.id == snapshot.bookID { removeSavedQuestion(request.id) }
        status = "答案已贴在问题旁"
    }
}
