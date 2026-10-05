import SwiftUI
import PDFKit
import PencilKit

// PDFKit creates/replaces its scroll and page views during layout. Keep its
// navigation recognizers from claiming Pencil touches intended for the overlay.
final class PencilPDFView: PDFView {
    var lockPageForWriting = false { didSet { if oldValue != lockPageForWriting { updatePalmProtection() } } }
    private var pencilDown = false
    private var pencilHovering = false
    private var protected = false
    private var restoreTask: DispatchWorkItem?
    private var suppressed: [(UIGestureRecognizer, Bool)] = []
    var viewportChanged: (() -> Void)?
    var isInkSurface: ((UIView) -> Bool)?
    private var hoverInstalled = false
    var selectionAsked: ((PDFSelection) -> Void)?
    var selectionHighlighted: ((PDFSelection) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let selection = currentSelection, !(selection.string ?? "").isEmpty else { return }
        let ask = UIAction(title: "AskInk", image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.selectionAsked?(selection) }
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.selectionHighlighted?(selection) }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [highlight, ask]), atEndOfMenu: .standardEdit)
    }
    var blankTapped: (() -> Void)?
    private var tapInstalled = false
    private var previousTool: InkTool = .pen
    @objc private func blankTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let page = page(for: point, nearest: false) else { blankTapped?(); return }
        let pdfPoint = convert(point, to: page)
        let region = CGRect(x: pdfPoint.x - 4, y: pdfPoint.y - 4, width: 8, height: 8)
        guard (page.selection(for: region)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        blankTapped?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !hoverInstalled {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
            hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            hover.cancelsTouchesInView = false
            addGestureRecognizer(hover)
            hoverInstalled = true
        }
        if window == nil { resetPalmProtection() }
    }

    @objc private func hoverChanged(_ hover: UIHoverGestureRecognizer) {
        pencilHovering = hover.state == .began || hover.state == .changed
        updatePalmProtection()
    }

    func setPencilDown(_ down: Bool) {
        guard pencilDown != down else { return }
        pencilDown = down
        updatePalmProtection()
    }

    func resetPalmProtection() {
        restoreTask?.cancel(); restoreTask = nil
        pencilDown = false; pencilHovering = false
        restoreNavigation()
    }

    private func updatePalmProtection() {
        restoreTask?.cancel(); restoreTask = nil
        if lockPageForWriting || pencilDown || pencilHovering {
            protected = true
            configureNavigationTouches(in: self)
        } else if protected {
            // Keep resting palm contacts from becoming a drag between strokes.
            let task = DispatchWorkItem { [weak self] in
                guard let self, !self.lockPageForWriting, !self.pencilDown, !self.pencilHovering else { return }
                self.restoreNavigation()
            }
            restoreTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
        }
    }

    private func restoreNavigation() {
        protected = false
        for (recognizer, enabled) in suppressed { recognizer.isEnabled = enabled }
        suppressed.removeAll(); restoreTask = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureNavigationTouches(in: self)
        viewportChanged?()
    }

    private func configureNavigationTouches(in view: UIView) {
        if view is PKCanvasView || isInkSurface?(view) == true { return }
        for recognizer in view.gestureRecognizers ?? [] {
            if recognizer is UIHoverGestureRecognizer { continue }
            let types = recognizer.allowedTouchTypes.filter {
                $0.intValue != UITouch.TouchType.pencil.rawValue
            }
            if types != recognizer.allowedTouchTypes { recognizer.allowedTouchTypes = types }
            if protected, (recognizer is UIPanGestureRecognizer || recognizer is UIPinchGestureRecognizer),
               !suppressed.contains(where: { $0.0 === recognizer }) {
                suppressed.append((recognizer, recognizer.isEnabled))
                recognizer.isEnabled = false
            }
        }
        if let scroll = view as? UIScrollView {
            scroll.delaysContentTouches = false
        }
        for child in view.subviews { configureNavigationTouches(in: child) }
    }
}

struct PDFReader: UIViewRepresentable {
    @ObservedObject var store: ReaderStore
    func makeCoordinator() -> PDFReaderCoordinator { PDFReaderCoordinator(store: store) }
    func makeUIView(context: Context) -> PDFView {
        let view = PencilPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor.systemBackground : UIColor(red: 0.945, green: 0.958, blue: 0.984, alpha: 1)
        }
        view.pageOverlayViewProvider = context.coordinator
        view.isInMarkupMode = true
        view.pageBreakMargins = UIEdgeInsets(top: 64, left: 12, bottom: 72, right: 12)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(PDFReaderCoordinator.blankTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]; tap.cancelsTouchesInView = false
        let zoom = UITapGestureRecognizer(target: context.coordinator, action: #selector(PDFReaderCoordinator.doubleTap(_:)))
        zoom.numberOfTapsRequired = 2; zoom.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.require(toFail: zoom); view.addGestureRecognizer(zoom); view.addGestureRecognizer(tap)
        context.coordinator.attach(view)
        return view
    }
    static func dismantleUIView(_ view: PDFView, coordinator: PDFReaderCoordinator) {
        if coordinator.store.document === view.document { coordinator.flush() }
        coordinator.store.invalidateRecognition()
        coordinator.reset()
        (view as? PencilPDFView)?.viewportChanged = nil
        (view as? PencilPDFView)?.isInkSurface = nil
        view.pageOverlayViewProvider = nil
        view.document = nil
        if coordinator.store.bridge === coordinator { coordinator.store.bridge = nil }
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== store.document {
            context.coordinator.restoringScale = true
            defer { context.coordinator.restoringScale = false }
            let destination = store.page
            view.pageOverlayViewProvider = nil
            context.coordinator.reset()
            view.pageOverlayViewProvider = context.coordinator
            view.document = store.document
            context.coordinator.go(to: destination)
            if let book = store.currentBook, UserDefaults.standard.object(forKey: "rememberBookZoom") as? Bool ?? true {
                let factor = UserDefaults.standard.double(forKey: "bookZoom.\(book.id.uuidString)")
                if factor > 0 { view.scaleFactor = view.scaleFactorForSizeToFit * factor }
            }
        }
        (view as? PencilPDFView)?.lockPageForWriting = store.lockPageForWriting
        view.displayMode = (UserDefaults.standard.object(forKey: "continuousScroll") as? Bool ?? true) ? .singlePageContinuous : .singlePage
        let background = UserDefaults.standard.string(forKey: "readingBackground") ?? "Warm"
        view.backgroundColor = background == "Dark" ? UIColor(white: 0.12, alpha: 1) : background == "White" ? .systemBackground : UIColor { traits in traits.userInterfaceStyle == .dark ? .systemBackground : UIColor(red: 0.9804, green: 0.9725, blue: 0.9529, alpha: 1) }
        context.coordinator.applyTool()
    }
}

@MainActor
final class PDFReaderCoordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, InkEngineDelegate {
    let store: ReaderStore
    weak var view: PDFView?
    var canvases: [Int: any InkEngine] = [:]
    private var pendingSaves: [Int: DispatchWorkItem] = [:]
    private var pendingReleases: [Int: DispatchWorkItem] = [:]
    private var loads: [Int: Task<Void, Never>] = [:]
    private var ready = Set<Int>()
    private var revisions: [Int: UUID] = [:]
    private var appliedTool: String?
    var restoringScale = false
    private var scrollStarted: Date?
    private var lastScroll: Date?
    private var lastOffset: CGFloat?
    private var lastReported = Date.distantPast
    @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
        guard let view else { return }
        let fit = view.scaleFactorForSizeToFit
        view.scaleFactor = abs(view.scaleFactor - fit) < 0.1 ? min(view.maxScaleFactor, fit * 1.8) : fit
    }
    @objc func blankTap(_ gesture: UITapGestureRecognizer) {
        guard let view else { return }
        let point = gesture.location(in: view)
        if let page = view.page(for: point, nearest: false) {
            let p = view.convert(point, to: page)
            if !(page.selection(for: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        }
        store.chromeHidden.toggle()
    }
    private func readScroll(_ scroll: UIScrollView) {
        let now = Date()
        if lastScroll == nil || now.timeIntervalSince(lastScroll!) > 0.4 { scrollStarted = now; store.scrollRevision += 1 }
        lastScroll = now
        if scroll.contentOffset.y < 10 || (lastOffset.map { scroll.contentOffset.y < $0 - 8 } ?? false) { store.chromeHidden = false }
        else if let started = scrollStarted, now.timeIntervalSince(started) > 1, now.timeIntervalSince(lastReported) > 0.5 { store.readerScrolled(); lastReported = now }
        lastOffset = scroll.contentOffset.y
    }
    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    init(store: ReaderStore) { self.store = store }
    func attach(_ view: PDFView) {
        self.view = view; store.bridge = self
        (view as? PencilPDFView)?.isInkSurface = { [weak self] node in
            self?.canvases.values.contains(where: { $0.view === node }) == true
        }
        (view as? PencilPDFView)?.selectionAsked = { [weak self, weak view] selection in
            guard let self, let view, let page = selection.pages.first, let document = view.document else { return }
            Task { await self.store.askSelectedText(selection.string ?? "", page: document.index(for: page) + 1, bounds: selection.bounds(for: page)) }
        }
        (view as? PencilPDFView)?.selectionHighlighted = { [weak self, weak view] selection in
            guard let self, let view, let document = view.document else { return }
            let marks = selection.selectionsByLine().compactMap { line -> (Int, CGRect)? in
                guard let page = line.pages.first else { return nil }; return (document.index(for: page), line.bounds(for: page))
            }
            Task { await self.store.highlightText(marks) }
        }
        (view as? PencilPDFView)?.viewportChanged = { [weak self] in self?.observeScrolling(); self?.updateAnswerPositions() }
        NotificationCenter.default.addObserver(self, selector: #selector(viewportScaleChanged), name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func viewportScaleChanged() {
        updateAnswerPositions()
        if !restoringScale, let view, let book = store.currentBook, UserDefaults.standard.object(forKey: "rememberBookZoom") as? Bool ?? true {
            UserDefaults.standard.set(view.scaleFactor / max(0.01, view.scaleFactorForSizeToFit), forKey: "bookZoom.\(book.id.uuidString)")
        }
    }
    private func observeScrolling() {
        func walk(_ node: UIView) {
            if let scroll = node as? UIScrollView {
                let key = ObjectIdentifier(scroll)
                if scrollObservations[key] == nil {
                    scrollObservations[key] = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        DispatchQueue.main.async {
                            self?.updateAnswerPositions()
                            if scroll.isDragging || scroll.isDecelerating { self?.readScroll(scroll) }
                        }
                    }
                }
            }
            node.subviews.forEach(walk)
        }
        if let view { walk(view) }
    }
    func updateAnswerPositions() {
        guard let view, let document = view.document else { return }
        var positions: [UUID: CGPoint] = [:]
        for reply in store.overlayReplies {
            if let anchor = reply.anchor, let page = document.page(at: reply.page - 1) {
                positions[reply.conversationID] = view.convert(anchor.point, from: page)
            }
        }
        var thinking: CGPoint?
        if let question = store.thinkingQuestion, question.bookID == store.currentBook?.id,
           let page = document.page(at: question.page - 1) {
            thinking = view.convert(question.anchor.point, from: page)
        }
        for issue in store.unanswered { if let page = document.page(at: issue.page - 1) { positions[issue.id] = view.convert(issue.anchor.point, from: page) } }
        var failure: CGPoint?
        if let failed = store.failedQuestion, failed.snapshot.bookID == store.currentBook?.id,
           let page = document.page(at: failed.snapshot.page - 1) { failure = view.convert(failed.snapshot.anchor.point, from: page) }
        var occupied: [CGRect] = []
        for reply in store.overlayReplies {
            if let page = document.page(at: reply.page - 1), let source = reply.sourceReferences?.first(where: { $0.page == reply.page }) { occupied.append(view.convert(source.bounds, from: page)) }
        }
        for (number, canvas) in canvases {
            if document.page(at: number - 1) != nil { occupied += canvas.drawing.strokes.prefix(120).map { canvas.view.convert($0.renderBounds.insetBy(dx: -4, dy: -4), to: view) } }
        }
        store.answerViewport.update(positions: positions, thinking: thinking, failure: failure, occupied: occupied)
    }
    @objc private func pageChanged() {
        guard let view, let page = view.currentPage, let document = view.document, document === store.document else { return }
        let number = document.index(for: page) + 1
        guard store.page != number else { return }
        store.invalidateRecognition(); store.page = number; store.savePosition()
    }
    func go(to number: Int) {
        guard let view, let page = view.document?.page(at: number - 1) else { return }
        if store.page != number { store.invalidateRecognition() }
        view.go(to: page)
        store.page = number; store.savePosition()
    }
    var currentDestination: PDFDestination? { view?.currentDestination }
    func go(to destination: PDFDestination) {
        guard let view, let page = destination.page, page.document === view.document else { return }
        store.invalidateRecognition(); view.clearSelection(); view.go(to: destination)
        store.page = (view.document?.index(for: page) ?? 0) + 1; store.savePosition()
    }
    func go(to number: Int, bounds: CGRect) {
        guard let view, let page = view.document?.page(at: number - 1) else { return }
        store.invalidateRecognition()
        view.go(to: bounds.insetBy(dx: -12, dy: -24), on: page)
        view.clearSelection()
        if let selection = page.selection(for: bounds) {
            selection.color = .systemYellow
            view.setCurrentSelection(selection, animate: true)
        }
        store.page = number; store.savePosition()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in view?.clearSelection() }
    }
    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = pdfView.document else { return nil }
        let number = document.index(for: page) + 1
        pendingReleases.removeValue(forKey: number)?.cancel()
        if let existing = canvases[number] { return existing.view }
        let canvas = InkEngineFactory.make()
        canvas.view.backgroundColor = .clear; canvas.view.isOpaque = false
        canvas.toolChanged = { [weak self] tool in self?.store.tool = tool }
        canvas.view.isUserInteractionEnabled = false
        canvases[number] = canvas
        revisions[number] = UUID()
        let bookID = store.currentBook?.id
        loads[number] = Task { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            let drawing = await self.store.loadDrawing(page: number)
            guard !Task.isCancelled, self.store.currentBook?.id == bookID,
                  self.canvases[number] === canvas else { return }
            canvas.restoreDrawing(drawing)
            self.ready.insert(number); canvas.events = self
            canvas.view.isUserInteractionEnabled = true
            self.loads.removeValue(forKey: number)
        }
        applyTool(force: true)
        return canvas.view
    }
    func reset() {
        pendingReleases.values.forEach { $0.cancel() }; pendingReleases.removeAll()
        (view as? PencilPDFView)?.resetPalmProtection()
        pendingSaves.values.forEach { $0.cancel() }; pendingSaves.removeAll()
        loads.values.forEach { $0.cancel() }; loads.removeAll()
        ready.removeAll(); revisions.removeAll(); appliedTool = nil
        scrollObservations.removeAll(); store.answerViewport.update(positions: [:], thinking: nil)
        canvases.values.forEach { $0.events = nil }; canvases.removeAll()
    }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let document = pdfView.document, document === store.document, page.document === document else { return }
        let number = document.index(for: page) + 1
        guard let canvas = canvases[number], canvas.view === overlayView else { return }
        canvas.commitActiveStroke()
        if ready.contains(number) { store.saveDrawing(canvas.drawing, page: number) }
        // PencilKit can publish its final pressure/mask update after tool-end.
        // Keep callbacks alive briefly rather than dropping the final drawing.
        let bookID = store.currentBook?.id
        let release = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas, self.store.currentBook?.id == bookID,
                  self.canvases[number] === canvas else { return }
            self.pendingSaves.removeValue(forKey: number)?.cancel()
            self.loads.removeValue(forKey: number)?.cancel()
            if self.ready.remove(number) != nil { self.store.saveDrawing(canvas.drawing, page: number) }
            canvas.events = nil; self.canvases.removeValue(forKey: number)
            self.pendingReleases.removeValue(forKey: number)
            self.updatePencilProtection()
        }
        pendingReleases[number]?.cancel(); pendingReleases[number] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: release)
        updatePencilProtection()
    }
    func inkEngineDrawingDidChange(_ canvasView: any InkEngine, reason: InkChangeReason) {
        guard let number = canvases.first(where: { $0.value === canvasView })?.key else { return }
        guard ready.contains(number) else { return }
        revisions[number] = UUID()
        store.invalidateRecognition(cancelRequest: reason != .preservedStroke)
        pendingSaves[number]?.cancel()
        let bookID = store.currentBook?.id
        let work = DispatchWorkItem { [weak self, weak canvasView] in
            guard let self, let canvasView, self.store.currentBook?.id == bookID,
                  self.canvases[number] === canvasView else { return }
            self.store.saveDrawing(canvasView.drawing, page: number)
            self.pendingSaves.removeValue(forKey: number)
        }
        pendingSaves[number] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        if reason == .finalDrawingUpdate, number == store.page, !canvasView.isUsingTool { store.scheduleAutomaticQuestion() }
    }
    private func updatePencilProtection() {
        (view as? PencilPDFView)?.setPencilDown(canvases.values.contains { $0.isUsingTool })
    }
    func inkEngineAsk(_ canvasView: any InkEngine, at point: CGPoint) {
        guard let number = canvases.first(where: { $0.value === canvasView })?.key, ready.contains(number) else { return }
        if store.page != number { store.page = number }
        Task { await store.askInk(at: point) }
    }
    func inkEngineDidBeginUsingTool(_ canvasView: any InkEngine) {
        if let number = canvases.first(where: { $0.value === canvasView })?.key, number != store.page {
            store.page = number; store.savePosition()
        }
        updatePencilProtection()
        store.invalidateRecognition(cancelRequest: true)
        store.firstPencilContact = true
    }
    func inkEngineDidEndUsingTool(_ canvasView: any InkEngine, tool: InkTool, reason: InkStrokeEndReason) {
        updatePencilProtection()
        if tool != .eraser && tool != .lasso, reason == .completed { store.scheduleAutomaticQuestion() }
    }
    func flush() {
        pendingSaves.values.forEach { $0.cancel() }; pendingSaves.removeAll()
        for (number, canvas) in canvases where ready.contains(number) { canvas.commitActiveStroke(); store.saveDrawing(canvas.drawing, page: number) }
    }
    func applyTool(force: Bool = false) {
        let signature = "\(store.tool.rawValue)|\(store.width)|\(UIColor(store.color))|\(store.eraserMode.rawValue)"
        guard force || appliedTool != signature else { return }
        appliedTool = signature
        for canvas in canvases.values {
            canvas.setTool(store.tool, color: UIColor(store.color), width: store.width, eraser: store.eraserMode)
        }
    }
    func undo() { canvases[store.page]?.commitActiveStroke(); canvases[store.page]?.undo() }
    func redo() { canvases[store.page]?.commitActiveStroke(); canvases[store.page]?.redo() }

    func isCurrent(_ snapshot: QuestionSnapshot) -> Bool {
        store.currentBook?.id == snapshot.bookID && store.page == snapshot.page && revisions[snapshot.page] == snapshot.revision
    }
    func hasAutomaticQuestion(since: Date, excluding: Set<Date>) -> Bool {
        guard ready.contains(store.page), let canvas = canvases[store.page], !canvas.isUsingTool else { return false }
        return canvas.drawing.strokes.contains { stroke in
            stroke.path.creationDate >= since && !excluding.contains(stroke.path.creationDate) &&
            !stroke.renderBounds.isEmpty && !(stroke.ink.inkType == .marker &&
                InkGrouping.isHighlightMark(stroke.path.map { $0.location.applying(stroke.transform) }))
        }
    }

    func questionCapture(scope: InkScope = .latest, block: Int = 0, excluding: Set<Date> = [], since: Date? = nil, groupingPause: TimeInterval = 3, near: CGPoint? = nil) throws -> InkQuestionCapture {
        guard let view, let page = view.document?.page(at: store.page - 1), let canvas = canvases[store.page] else {
            throw ReaderError.message("当前页尚未准备好，请稍后重试。")
        }
        guard ready.contains(store.page), let bookID = store.currentBook?.id, let revision = revisions[store.page] else {
            throw ReaderError.message("笔迹正在加载，请稍后重试。")
        }
        guard !canvas.isUsingTool else { throw ReaderError.message("请抬笔后再识别。") }
        let allInk = canvas.drawing.strokes.filter { !$0.renderBounds.isEmpty }
        let pageLines = PDFDocumentAdapter.textLines(page)
        let sourceLines = pageLines.isEmpty ? store.currentSourceLines : pageLines
        func isMark(_ stroke: PKStroke) -> Bool {
            if stroke.ink.inkType == .marker && InkGrouping.isHighlightMark(stroke.path.map { $0.location.applying(stroke.transform) }) { return true }
            guard !sourceLines.isEmpty else { return false }
            let bounds = view.convert(canvas.view.convert(stroke.renderBounds, to: view), to: page)
            guard bounds.width >= 28, bounds.height <= 24, bounds.width > max(1, bounds.height) * 3 else { return false }
            let points = stroke.path.map { point in
                view.convert(canvas.view.convert(point.location.applying(stroke.transform), to: view), to: page)
            }
            return !SourceMarkLocator.underlineLines(points: points, lines: sourceLines).isEmpty
        }
        let marks = allInk.filter(isMark)
        let ink = allInk.filter { stroke in
            (since == nil || stroke.path.creationDate >= since!) && !excluding.contains(stroke.path.creationDate) && !isMark(stroke)
        }
        guard !ink.isEmpty else { throw ReaderError.message("请在高光标记旁写下问题，也可以用高光笔写字。") }
        let groups = InkGrouping.blocks(ink.enumerated().map { index, stroke in
            let start = stroke.path.creationDate.timeIntervalSince1970
            return InkStrokeDescriptor(index: index, bounds: stroke.renderBounds, started: start,
                ended: start + (stroke.path.last?.timeOffset ?? 0))
        }, pause: groupingPause, boundaries: marks.map {
            $0.path.creationDate.timeIntervalSince1970 + ($0.path.last?.timeOffset ?? 0)
        })
        var selected = min(max(0, block), groups.count - 1)
        if let near {
            selected = groups.indices.min { a, b in
                func distance(_ indices: [Int]) -> CGFloat {
                    let bounds = indices.reduce(CGRect.null) { $0.union(ink[$1].renderBounds) }
                    return hypot(max(0, bounds.minX - near.x, near.x - bounds.maxX), max(0, bounds.minY - near.y, near.y - bounds.maxY))
                }
                return distance(groups[a]) < distance(groups[b])
            } ?? selected
        }
        let group = scope == .page ? ink : groups[selected].map { ink[$0] }
        let drawing = PKDrawing(strokes: group)
        // A recent nearby source mark takes priority over the question's margin position.
        let questionStart = group.map { $0.path.creationDate.timeIntervalSince1970 }.min() ?? 0
        let sourceMark = marks.filter { mark in
            let end = mark.path.creationDate.timeIntervalSince1970 + (mark.path.last?.timeOffset ?? 0)
            let verticalGap = max(0, mark.renderBounds.minY - drawing.bounds.maxY, drawing.bounds.minY - mark.renderBounds.maxY)
            return questionStart >= end - 1 && questionStart - end <= 120 && verticalGap <= 120
        }.min { abs($0.renderBounds.midY - drawing.bounds.midY) < abs($1.renderBounds.midY - drawing.bounds.midY) }
        let inView = canvas.view.convert(sourceMark?.renderBounds ?? drawing.bounds, to: view)
        var pdfBounds = view.convert(inView, to: page)
        var markedText: String?
        if let sourceMark {
            let points = sourceMark.path.map { point in
                view.convert(canvas.view.convert(point.location.applying(sourceMark.transform), to: view), to: page)
            }
            let matches = SourceMarkLocator.underlineLines(points: points, lines: sourceLines)
            let matchedLine = matches.first.map { sourceLines[$0] } ?? sourceLines.min { a, b in
                func distance(_ line: SourceTextLine) -> CGFloat {
                    let overlap = max(0, min(pdfBounds.maxX, line.bounds.maxX) - max(pdfBounds.minX, line.bounds.minX))
                    return abs(line.bounds.midY - pdfBounds.midY) + (overlap == 0 ? 1000 : 0)
                }
                return distance(a) < distance(b)
            }
            if let line = matchedLine, abs(line.bounds.midY - pdfBounds.midY) < max(24, line.bounds.height * 2) {
                let left = max(pdfBounds.minX, line.bounds.minX), right = min(pdfBounds.maxX, line.bounds.maxX)
                if right > left {
                    pdfBounds = CGRect(x: left, y: line.bounds.minY, width: right - left, height: line.bounds.height)
                    markedText = page.selection(for: pdfBounds.insetBy(dx: -1, dy: 0))?.string ?? line.text
                }
            }
        }
        let inkPoint = canvas.view.convert(CGPoint(x: drawing.bounds.maxX, y: drawing.bounds.maxY), to: view)
        let anchor = view.convert(inkPoint, to: page)
        return InkQuestionCapture(page: store.page, drawing: drawing,
            fileURL: store.folder(bookID).appendingPathComponent("document.pdf"), pdfBounds: pdfBounds,
            anchor: ContentAnchor(x: anchor.x, y: anchor.y, documentID: bookID, location: .page(store.page, rect: pdfBounds), textQuote: markedText), bookID: bookID, revision: revision,
            scope: scope, block: selected, blockCount: groups.count,
            sourceMarked: sourceMark != nil, markedText: markedText)
    }
    func isCurrent(_ capture: InkQuestionCapture) -> Bool {
        store.currentBook?.id == capture.bookID && store.page == capture.page && revisions[capture.page] == capture.revision
    }
}
