import UIKit
import PencilKit

enum InkStrokeEndReason { case completed, cancelled, forced }
enum InkChangeReason { case completedStroke, preservedStroke, eraser, undoRedo, finalDrawingUpdate }

@MainActor
protocol InkEngine: AnyObject {
    var view: UIView { get }
    var drawing: PKDrawing { get set }
    var events: InkEngineDelegate? { get set }
    var isUsingTool: Bool { get }
    var toolChanged: ((InkTool) -> Void)? { get set }
    func setTool(_ tool: InkTool, color: UIColor, width: Double, eraser: InkEraserMode)
    func restoreDrawing(_ drawing: PKDrawing)
    func commitActiveStroke()
    func undo()
    func redo()
}

@MainActor
enum InkEngineFactory {
    static func make() -> any InkEngine { PencilKitInkEngine() }
}

@MainActor
protocol InkEngineDelegate: AnyObject {
    func inkEngineDrawingDidChange(_ engine: any InkEngine, reason: InkChangeReason)
    func inkEngineAsk(_ engine: any InkEngine, at point: CGPoint)
    func inkEngineDidBeginUsingTool(_ engine: any InkEngine)
    func inkEngineDidEndUsingTool(_ engine: any InkEngine, tool: InkTool, reason: InkStrokeEndReason)
}

// Input capture, predictions, pressure, rendering, erasing and selection belong
// to PencilKit. Engines publish lifecycle events instead of injecting raw touches.
final class PencilKitInkEngine: PKCanvasView, InkEngine, PKCanvasViewDelegate,
    UIContextMenuInteractionDelegate, UIPencilInteractionDelegate {
    var view: UIView { self }
    private let pageHistory = UndoManager()
    override var undoManager: UndoManager? { pageHistory }
    weak var events: InkEngineDelegate?
    private(set) var isUsingTool = false
    var toolChanged: ((InkTool) -> Void)?
    private var selectedTool: InkTool = .ballpoint
    private var activeTool: InkTool = .ballpoint
    private var lastDrawingTool: InkTool = .ballpoint
    private var forced = false
    private var automaticChangesAllowed = false
    private var lastChange: InkChangeReason = .preservedStroke
    func restoreDrawing(_ drawing: PKDrawing) {
        automaticChangesAllowed = false; lastChange = .preservedStroke
        self.drawing = drawing
        pageHistory.removeAllActions()
    }


    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        drawingPolicy = .pencilOnly
        backgroundColor = .clear; isOpaque = false
        isScrollEnabled = false; bounces = false
        minimumZoomScale = 1; maximumZoomScale = 1
        // Finger navigation stays with the parent PDFView.
        panGestureRecognizer.isEnabled = false
        pinchGestureRecognizer?.isEnabled = false
        addInteraction(UIContextMenuInteraction(delegate: self))
        let interaction = UIPencilInteraction(); interaction.delegate = self
        addInteraction(interaction)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func setTool(_ kind: InkTool, color: UIColor, width: Double, eraser: InkEraserMode) {
        selectedTool = kind
        switch kind {
        case .eraser:
            let bounds = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
            let clamped = min(bounds.upperBound, max(bounds.lowerBound, CGFloat(width)))
            tool = eraser == .stroke ? PKEraserTool(.vector) : PKEraserTool(.fixedWidthBitmap, width: clamped)
        case .lasso: tool = PKLassoTool()
        default:
            let type: PKInkingTool.InkType
            switch kind {
            case .pen: type = .fountainPen
            case .pencil: type = .pencil
            case .marker: type = .marker
            default: type = .monoline
            }
            let bounds = type.validWidthRange
            let clamped = min(bounds.upperBound, max(bounds.lowerBound, CGFloat(width)))
            tool = PKInkingTool(type, color: color, width: clamped)
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        activeTool = selectedTool; isUsingTool = true; forced = false
        automaticChangesAllowed = activeTool.isWritingTool
        lastChange = activeTool == .eraser ? .eraser : activeTool == .lasso ? .undoRedo : .completedStroke
        events?.inkEngineDidBeginUsingTool(self)
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let reason: InkChangeReason = automaticChangesAllowed && !isUsingTool ? .finalDrawingUpdate : lastChange
        events?.inkEngineDrawingDidChange(self, reason: reason)
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard isUsingTool else { return }
        isUsingTool = false
        let cancelled = drawingGestureRecognizer.state == .cancelled || drawingGestureRecognizer.state == .failed
        if forced || cancelled { automaticChangesAllowed = false; lastChange = .preservedStroke }
        events?.inkEngineDidEndUsingTool(self, tool: activeTool, reason: forced ? .forced : cancelled ? .cancelled : .completed)
    }
    func commitActiveStroke() {
        guard isUsingTool else { return }
        forced = true; automaticChangesAllowed = false
        drawingGestureRecognizer.isEnabled = false
        drawingGestureRecognizer.isEnabled = true
        if isUsingTool { canvasViewDidEndUsingTool(self) }
    }
    func undo() {
        commitActiveStroke(); automaticChangesAllowed = false; lastChange = .undoRedo
        undoManager?.undo()
    }
    func redo() {
        commitActiveStroke(); automaticChangesAllowed = false; lastChange = .undoRedo
        undoManager?.redo()
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if selectedTool == .eraser { toolChanged?(lastDrawingTool) }
        else { if selectedTool.isWritingTool { lastDrawingTool = selectedTool }; toolChanged?(.eraser) }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !isUsingTool, drawing.strokes.contains(where: { $0.renderBounds.insetBy(dx: -24, dy: -24).contains(location) }) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Ask ✦", image: UIImage(systemName: "sparkles")) { _ in
                guard let self else { return }; self.events?.inkEngineAsk(self, at: location)
            }])
        }
    }
}
