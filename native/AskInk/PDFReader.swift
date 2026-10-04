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
    private var hoverInstalled = false

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
    }

    private func configureNavigationTouches(in view: UIView) {
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
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== store.document {
            let destination = store.page
            view.pageOverlayViewProvider = nil
            context.coordinator.reset()
            view.pageOverlayViewProvider = context.coordinator
            view.document = store.document
            context.coordinator.go(to: destination)
        }
        (view as? PencilPDFView)?.lockPageForWriting = store.lockPageForWriting
        context.coordinator.applyTool()
    }
}

@MainActor
final class PDFReaderCoordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider, PencilCanvasDelegate {
    let store: ReaderStore
    weak var view: PDFView?
    var canvases: [Int: PencilCanvas] = [:]
    private var pendingSaves: [Int: DispatchWorkItem] = [:]
    private var loads: [Int: Task<Void, Never>] = [:]
    private var ready = Set<Int>()
    private var revisions: [Int: UUID] = [:]
    private var appliedTool: String?
    init(store: ReaderStore) { self.store = store }
    func attach(_ view: PDFView) {
        self.view = view; store.bridge = self
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
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
    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = pdfView.document else { return nil }
        let number = document.index(for: page) + 1
        if let existing = canvases[number] { return existing }
        let canvas = PencilCanvas()
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.isUserInteractionEnabled = false
        canvases[number] = canvas
        revisions[number] = UUID()
        let bookID = store.currentBook?.id
        loads[number] = Task { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            let drawing = await self.store.loadDrawing(page: number)
            guard !Task.isCancelled, self.store.currentBook?.id == bookID,
                  self.canvases[number] === canvas else { return }
            canvas.drawing = drawing
            self.ready.insert(number); canvas.delegate = self
            canvas.isUserInteractionEnabled = true
            self.loads.removeValue(forKey: number)
        }
        applyTool(force: true)
        return canvas
    }
    func reset() {
        (view as? PencilPDFView)?.resetPalmProtection()
        pendingSaves.values.forEach { $0.cancel() }; pendingSaves.removeAll()
        loads.values.forEach { $0.cancel() }; loads.removeAll()
        ready.removeAll(); revisions.removeAll(); appliedTool = nil
        canvases.values.forEach { $0.delegate = nil }; canvases.removeAll()
    }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let document = pdfView.document, let canvas = overlayView as? PencilCanvas else { return }
        guard document === store.document, page.document === document else { return }
        let number = document.index(for: page) + 1
        guard canvases[number] === canvas else { return }
        pendingSaves.removeValue(forKey: number)?.cancel()
        loads.removeValue(forKey: number)?.cancel()
        canvas.commitActiveStroke()
        if ready.remove(number) != nil { store.saveDrawing(canvas.drawing, page: number) }
        canvas.delegate = nil
        canvases.removeValue(forKey: number)
        updatePencilProtection()
    }
    func canvasViewDrawingDidChange(_ canvasView: PencilCanvas, reason: InkChangeReason) {
        guard let number = canvases.first(where: { $0.value === canvasView })?.key else { return }
        guard ready.contains(number) else { return }
        revisions[number] = UUID()
        store.invalidateRecognition()
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
        if reason == .estimatedCorrection, !canvasView.isUsingTool { store.scheduleAutomaticQuestion() }
    }
    private func updatePencilProtection() {
        (view as? PencilPDFView)?.setPencilDown(canvases.values.contains { $0.isUsingTool })
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PencilCanvas) {
        updatePencilProtection()
        store.invalidateRecognition()
    }
    func canvasViewDidEndUsingTool(_ canvasView: PencilCanvas, tool: InkTool, reason: InkStrokeEndReason) {
        updatePencilProtection()
        if tool != .eraser, reason == .completed { store.scheduleAutomaticQuestion() }
    }
    func flush() {
        pendingSaves.values.forEach { $0.cancel() }; pendingSaves.removeAll()
        for (number, canvas) in canvases where ready.contains(number) { canvas.commitActiveStroke(); store.saveDrawing(canvas.drawing, page: number) }
    }
    func applyTool(force: Bool = false) {
        let signature = "\(store.tool.rawValue)|\(store.width)|\(UIColor(store.color))|\(store.stabilization)|\(store.pressureSensitivity)"
        guard force || appliedTool != signature else { return }
        appliedTool = signature
        for canvas in canvases.values {
            canvas.inkTool = store.tool; canvas.inkColor = UIColor(store.color); canvas.inkWidth = store.width
            canvas.stabilization = store.stabilization; canvas.sensitivity = store.pressureSensitivity
        }
    }
    func undo() { canvases[store.page]?.commitActiveStroke(); canvases[store.page]?.undoManager?.undo() }
    func redo() { canvases[store.page]?.commitActiveStroke(); canvases[store.page]?.undoManager?.redo() }

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

    func questionSnapshot(scope: InkScope = .latest, block: Int = 0, excluding: Set<Date> = [], since: Date? = nil, groupingPause: TimeInterval = 3) throws -> QuestionSnapshot {
        guard let view, let page = view.document?.page(at: store.page - 1), let canvas = canvases[store.page] else {
            throw ReaderError.message("当前页尚未准备好，请稍后重试。")
        }
        guard ready.contains(store.page), let bookID = store.currentBook?.id, let revision = revisions[store.page] else {
            throw ReaderError.message("笔迹正在加载，请稍后重试。")
        }
        guard !canvas.isUsingTool else { throw ReaderError.message("请抬笔后再识别。") }
        let allInk = canvas.drawing.strokes.filter { !$0.renderBounds.isEmpty }
        let marks = allInk.filter { stroke in
            stroke.ink.inkType == .marker && InkGrouping.isHighlightMark(stroke.path.map { $0.location.applying(stroke.transform) })
        }
        let ink = allInk.filter { stroke in
            (since == nil || stroke.path.creationDate >= since!) && !excluding.contains(stroke.path.creationDate) && !(stroke.ink.inkType == .marker && InkGrouping.isHighlightMark(stroke.path.map { $0.location.applying(stroke.transform) }))
        }
        guard !ink.isEmpty else { throw ReaderError.message("请在高光标记旁写下问题，也可以用高光笔写字。") }
        let groups = InkGrouping.blocks(ink.enumerated().map { index, stroke in
            let start = stroke.path.creationDate.timeIntervalSince1970
            return InkStrokeDescriptor(index: index, bounds: stroke.renderBounds, started: start,
                ended: start + (stroke.path.last?.timeOffset ?? 0))
        }, pause: groupingPause)
        let selected = min(max(0, block), groups.count - 1)
        let group = scope == .page ? ink : groups[selected].map { ink[$0] }
        let drawing = PKDrawing(strokes: group)
        let blackDrawing = PKDrawing(strokes: group.map { stroke in
            let points = stroke.path.map { point in
                PKStrokePoint(location: point.location, timeOffset: point.timeOffset,
                    size: CGSize(width: 2, height: 2), opacity: 1, force: 1,
                    azimuth: point.azimuth, altitude: point.altitude)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                transform: stroke.transform, mask: stroke.mask)
        })
        let bounds = blackDrawing.bounds.insetBy(dx: -16, dy: -16)
        let scale = min(3, 1800 / max(bounds.width, bounds.height))
        let image = blackDrawing.image(from: bounds, scale: scale)
        let inkFormat = UIGraphicsImageRendererFormat(); inkFormat.scale = scale
        let whiteInk = UIGraphicsImageRenderer(size: image.size, format: inkFormat).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        // Preserve the actual shapes/widths for vision, independently of the
        // thin, black image normalized specifically for PaddleOCR.
        let originalBounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        let originalScale = min(3, 1800 / max(originalBounds.width, originalBounds.height))
        let original = drawing.image(from: originalBounds, scale: originalScale)
        let originalFormat = UIGraphicsImageRendererFormat(); originalFormat.scale = originalScale
        let handwritingImage = UIGraphicsImageRenderer(size: original.size, format: originalFormat).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: original.size))
            original.draw(at: .zero)
        }
        // A recent nearby source mark takes priority over the question's margin position.
        let questionStart = group.map { $0.path.creationDate.timeIntervalSince1970 }.min() ?? 0
        let sourceMark = marks.filter { mark in
            let end = mark.path.creationDate.timeIntervalSince1970 + (mark.path.last?.timeOffset ?? 0)
            let verticalGap = max(0, mark.renderBounds.minY - drawing.bounds.maxY, drawing.bounds.minY - mark.renderBounds.maxY)
            return abs(questionStart - end) <= 120 && verticalGap <= 120
        }.min { abs($0.renderBounds.midY - drawing.bounds.midY) < abs($1.renderBounds.midY - drawing.bounds.midY) }
        let inView = canvas.convert(sourceMark?.renderBounds ?? drawing.bounds, to: view)
        let pdfBounds = view.convert(inView, to: page)
        let pageBounds = page.bounds(for: .cropBox)
        // Rank PDF text lines spatially, then stay in the anchor's column.
        let lines = (page.selection(for: pageBounds)?.selectionsByLine() ?? []).filter {
            !($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func score(_ line: PDFSelection) -> CGFloat {
            let b = line.bounds(for: page)
            let dx = max(0, b.minX - pdfBounds.maxX, pdfBounds.minX - b.maxX)
            let dy = max(0, b.minY - pdfBounds.maxY, pdfBounds.minY - b.maxY)
            return hypot(dx, dy * 3)
        }
        var region = CGRect(x: pageBounds.minX, y: pdfBounds.minY - 100,
                            width: pageBounds.width, height: pdfBounds.height + 200).intersection(pageBounds)
        var context = ""
        if let anchor = lines.min(by: { score($0) < score($1) }), score(anchor) < pageBounds.width * 0.25 {
            let column = anchor.bounds(for: page)
            let nearby = lines.filter { line in
                let b = line.bounds(for: page)
                let overlap = max(0, min(b.maxX, column.maxX) - max(b.minX, column.minX))
                return overlap / max(1, min(b.width, column.width)) > 0.55
            }.sorted { score($0) < score($1) }.prefix(12)
                .sorted { $0.bounds(for: page).midY > $1.bounds(for: page).midY }
            context = String(nearby.compactMap(\.string).joined(separator: "\n").prefix(9000))
            region = nearby.reduce(CGRect.null) { $0.union($1.bounds(for: page)) }
                .insetBy(dx: -16, dy: -16).intersection(pageBounds)
        }
        guard !region.isNull, !region.isEmpty else { throw ReaderError.message("笔迹不在 PDF 正文区域内。") }
        let size = CGSize(width: region.width * 2, height: region.height * 2)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let pageImage = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: 2, y: -2)
            ctx.cgContext.translateBy(x: -region.minX, y: -region.minY)
            page.draw(with: .cropBox, to: ctx.cgContext)
        }
        return QuestionSnapshot(page: store.page, ink: whiteInk, handwritingImage: handwritingImage, context: context, pageImage: pageImage,
            drawing: drawing, bookID: bookID, revision: revision, scope: scope, block: selected, blockCount: groups.count)
    }
}
