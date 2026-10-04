import UIKit
import PencilKit

@MainActor
protocol PencilCanvasDelegate: AnyObject {
    func canvasViewDrawingDidChange(_ canvas: PencilCanvas, reason: InkChangeReason)
    func canvasViewDidBeginUsingTool(_ canvas: PencilCanvas)
    func canvasViewDidEndUsingTool(_ canvas: PencilCanvas, tool: InkTool, reason: InkStrokeEndReason)
}

// Retained vector ribbons; only a bounded live chunk and prediction tail change per event.
final class PencilCanvas: UIView {
    weak var delegate: PencilCanvasDelegate?
    var inkTool: InkTool = .pen
    var inkColor = UIColor.black
    var inkWidth = 2.0
    var stabilization = 0.1
    var sensitivity = 0.5
    var pressureSmoothing = 0.4
    private var strokes: [PKStroke] = []
    var drawing: PKDrawing {
        get { PKDrawing(strokes: strokes) }
        set { strokes = newValue.strokes; pendingEstimates = [:]; finalizationVersions = [:]; rebuild(); history.removeAllActions() }
    }
    private var finalizationVersions: [Date: UUID] = [:]
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
    private var strokeLayers: [CAShapeLayer] = []
    private var activeLayers: [CAShapeLayer] = []
    private let tail = CAShapeLayer()
    private let liveGroup = CALayer()
    private var livePath = InkLivePath()
    private var samples: [InkSample] = []
    private var estimated: [NSNumber: Int] = [:]
    private var filter = InkStabilizer()
    private var forceFilter = InkPressureFilter()
    var isUsingTool: Bool { pencil != nil }
    func commitActiveStroke() { if let touch = pencil { endStroke(touch, event: nil, reason: .forced) } }
    private var pencil: UITouch?
    private var startDate = Date()
    private var distance = 0.0
    private var activeTool = InkTool.pen
    private var activeColor = UIColor.black
    private var activeWidth = 2.0
    private var activeStability = 0.1
    private var activePressureSmoothing = 0.4
    private var activeSensitivity = 0.5
    private var beforeGesture: [PKStroke] = []
    private var lastErasePoint: CGPoint?
    private struct PendingEstimates { var points: [InkSample]; var indices: [NSNumber:Int]; var tool: InkTool; var width: Double; var sensitivity: Double; var allowAutomaticQuestion: Bool }
    private var pendingEstimates: [Date:PendingEstimates] = [:]
    override init(frame: CGRect) {
        super.init(frame: frame); isMultipleTouchEnabled = true; isOpaque = false
        layer.addSublayer(liveGroup); liveGroup.addSublayer(tail); tail.fillColor = UIColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    // Hit testing can run before UIEvent.allTouches contains the new Pencil.
    // Accept hits normally; touchesBegan handles only Pencil, while ancestor
    // PDF scroll/pinch recognizers continue to handle fingers.
    private var brush: InkBrush {
        switch activeTool { case .ballpoint: return .ballpoint; case .brush: return .brush; case .marker: return .marker; default: return .fountain }
    }
    private func makeLayer(color: UIColor, live: Bool = false) -> CAShapeLayer {
        let shape = CAShapeLayer(); shape.fillColor = color.cgColor
        shape.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        shape.actions = ["path": NSNull(), "opacity": NSNull(), "fillColor": NSNull()]
        if live { liveGroup.insertSublayer(shape, below: tail) }
        else { layer.insertSublayer(shape, below: liveGroup) }
        return shape
    }
    private func values(for stroke: PKStroke) -> [InkSample] {
        stroke.path.map { InkSample(point:$0.location.applying(stroke.transform),time:$0.timeOffset,pressure:Double($0.force),width:Double(max($0.size.width,$0.size.height))) }
    }
    private func rebuild() {
        strokeLayers.forEach { $0.removeFromSuperlayer() }; strokeLayers = []
        for stroke in strokes {
            let shape = makeLayer(color:stroke.ink.color); shape.path = InkRendering.path(for:values(for:stroke))
            shape.opacity = stroke.ink.inkType == .marker ? 0.3 : 1
            strokeLayers.append(shape)
        }
    }
    private func replace(_ replacement: [PKStroke], undo old: [PKStroke]) {
        history.registerUndo(withTarget:self) { target in target.replace(old, undo:target.strokes) }
        finalizationVersions.removeAll()
        strokes = replacement; rebuild(); delegate?.canvasViewDrawingDidChange(self, reason: .undoRedo)
    }
    private func input(_ touch: UITouch) -> InkSample {
        var roll = 0.0
        if #available(iOS 17.5, *) { roll = touch.rollAngle }
        return InkSample(point:touch.preciseLocation(in:self),time:touch.timestamp,
            pressure:touch.maximumPossibleForce > 0 ? Double(touch.force/touch.maximumPossibleForce) : 0.5,
            altitude:touch.altitudeAngle,azimuth:touch.azimuthAngle(in:self),roll:roll,rawPoint:touch.preciseLocation(in:self))
    }
    private func append(_ touch: UITouch) {
        let raw = input(touch)
        if let last = samples.last, raw.time <= last.time { return }
        var sample = filter.process(raw, strength:activeStability)
        sample.rawPressure = raw.pressure
        sample.pressure = forceFilter.process(raw.pressure, time: raw.time, strength: activePressureSmoothing)
        let last = samples.last
        let dx = sample.point.x-(last?.point.x ?? sample.point.x), dy = sample.point.y-(last?.point.y ?? sample.point.y)
        distance += hypot(dx,dy)
        sample.width = InkDynamics.width(brush:brush,base:activeWidth,pressure:sample.pressure,sensitivity:activeSensitivity,
            speed:hypot(dx,dy)/max(0.001,sample.time-(last?.time ?? sample.time)),altitude:sample.altitude,
            roll:sample.roll,direction:atan2(dy,dx),distance:distance)
        if let index = touch.estimationUpdateIndex { estimated[index] = samples.count }
        samples.append(sample)
    }
    private func updateLive(predicted: [UITouch]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        apply(livePath.append(samples))
        let committedSegments = livePath.committedSegments
        let offset = max(0, committedSegments - 1)
        var transient = Array(samples.dropFirst(offset))
        var predictedFilter = filter
        var lastTime = samples.last?.time ?? 0
        for touch in predicted.sorted(by: { $0.timestamp < $1.timestamp }).prefix(8) {
            guard touch.timestamp > lastTime else { continue }
            lastTime = touch.timestamp
            var p = predictedFilter.process(input(touch),strength:activeStability)
            p.width = samples.last?.width ?? activeWidth; transient.append(p)
        }
        tail.fillColor = activeColor.cgColor; tail.opacity = 1
        liveGroup.opacity = activeTool == .marker ? 0.3 : 1
        tail.path = InkRendering.path(for:transient, from:committedSegments-offset)
        CATransaction.commit()
    }
    private func apply(_ updates: [InkChunkUpdate]) {
        for update in updates {
            while activeLayers.count <= update.index { activeLayers.append(makeLayer(color: activeColor, live: true)) }
            activeLayers[update.index].path = update.path
        }
    }
    private func coalesced(_ touch: UITouch, event: UIEvent?) -> [UITouch] {
        let batch = event?.coalescedTouches(for: touch) ?? []
        return (batch.isEmpty ? [touch] : batch).sorted { $0.timestamp < $1.timestamp }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pencil == nil, let touch = touches.first(where: { $0.type == .pencil }) else { return }
        pencil = touch; beforeGesture = strokes; startDate = Date()
        activeTool = inkTool; activeColor = inkColor
        activeWidth = inkTool == .marker ? inkWidth*8 : inkWidth
        activeStability = stabilization; activeSensitivity = sensitivity; activePressureSmoothing = pressureSmoothing
        samples = []; estimated = [:]; filter = InkStabilizer(); forceFilter = InkPressureFilter(); distance = 0; livePath = InkLivePath(); lastErasePoint = nil
        delegate?.canvasViewDidBeginUsingTool(self)
        if activeTool == .eraser { erase(at:touch.preciseLocation(in:self)); return }
        append(touch); updateLive(predicted:event?.predictedTouches(for:touch) ?? [])
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencil, touches.contains(touch) else { return }
        for sample in coalesced(touch, event: event) {
            if activeTool == .eraser { erase(at:sample.preciseLocation(in:self)) } else { append(sample) }
        }
        if activeTool != .eraser { updateLive(predicted:event?.predictedTouches(for:touch) ?? []) }
    }
    private func erase(at point: CGPoint) {
        let previous = lastErasePoint ?? point
        lastErasePoint = point
        let sweep = CGRect(x: min(previous.x, point.x), y: min(previous.y, point.y),
            width: abs(point.x - previous.x), height: abs(point.y - previous.y)).insetBy(dx: -12, dy: -12)
        let indices = strokes.indices.filter { index in
            let stroke = strokes[index]
            guard stroke.renderBounds.intersects(sweep) else { return false }
            let values = values(for:stroke)
            if values.count == 1 { return InkDynamics.distance(values[0].point, to: previous, point) <= 12 + values[0].width/2 }
            return zip(values,values.dropFirst()).contains { a,b in InkDynamics.segmentDistance(previous, point, a.point, b.point) <= 12 + max(a.width,b.width)/2 }
        }
        for index in indices.reversed() { strokes.remove(at:index); strokeLayers.remove(at:index).removeFromSuperlayer() }
        if !indices.isEmpty { delegate?.canvasViewDrawingDidChange(self, reason: .eraser) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencil, touches.contains(touch) else { return }
        endStroke(touch, event: event, reason: .completed)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencil, touches.contains(touch) else { return }
        // Preserve actual ink already collected; only predictions are discarded.
        endStroke(touch, event: event, reason: .cancelled)
    }
    private func endStroke(_ touch: UITouch, event: UIEvent?, reason: InkStrokeEndReason) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let tool = activeTool
        var change: InkChangeReason?
        var tapered = Set<Int>()
        if tool == .eraser {
            if reason == .cancelled { strokes = beforeGesture; rebuild() }
            else if strokes.count != beforeGesture.count {
                history.registerUndo(withTarget: self) { [old = beforeGesture] target in target.replace(old, undo: target.strokes) }
            }
            change = .eraser
        } else {
            if reason == .completed {
                for value in coalesced(touch, event: event) { append(value) }
                append(touch)
            }
            if tool == .brush, reason == .completed, samples.count > 1 {
                var remaining = 0.0
                for i in stride(from: samples.count - 1, through: 0, by: -1) {
                    if i + 1 < samples.count { remaining += hypot(samples[i+1].point.x - samples[i].point.x, samples[i+1].point.y - samples[i].point.y) }
                    if remaining > max(3, activeWidth * 2) { break }
                    tapered.insert(i)
                    samples[i].width *= 0.2 + 0.8 * min(1, remaining / max(3, activeWidth * 2))
                }
            }
            if let first = samples.first {
                let points = samples.map { PKStrokePoint(location: $0.point, timeOffset: $0.time - first.time,
                    size: CGSize(width: $0.width, height: $0.width), opacity: 1, force: $0.pressure, azimuth: $0.azimuth, altitude: $0.altitude) }
                let stroke = PKStroke(ink: PKInk(tool == .marker ? .marker : .pen, color: activeColor),
                    path: PKStrokePath(controlPoints: points, creationDate: startDate))
                strokes.append(stroke)
                pendingEstimates = pendingEstimates.filter { Date().timeIntervalSince($0.key) < 2 }
                if !estimated.isEmpty {
                    pendingEstimates[startDate] = PendingEstimates(points: samples, indices: estimated, tool: tool,
                        width: activeWidth, sensitivity: activeSensitivity, allowAutomaticQuestion: reason == .completed)
                }
                let shape = makeLayer(color: activeColor)
                shape.path = livePath.complete(samples, changed: tapered); shape.opacity = tool == .marker ? 0.3 : 1
                strokeLayers.append(shape)
                history.registerUndo(withTarget: self) { [old = beforeGesture] target in target.replace(old, undo: target.strokes) }
                change = reason == .completed ? .completedStroke : .preservedStroke
                if estimated.isEmpty { finalize(startDate, samples: samples, automatic: reason == .completed) }
            }
        }
        activeLayers.forEach { $0.removeFromSuperlayer() }; activeLayers = []; tail.path = nil
        pencil = nil; samples = []; estimated = [:]; livePath = InkLivePath(); lastErasePoint = nil
        CATransaction.commit()
        // Publish the new drawing BEFORE starting the stop-writing timer.
        if let change { delegate?.canvasViewDrawingDidChange(self, reason: change) }
        delegate?.canvasViewDidEndUsingTool(self, tool: tool, reason: reason)
    }
    private func finalize(_ date: Date, samples: [InkSample], automatic: Bool) {
        let version = UUID(); finalizationVersions[date] = version
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let points = InkFinalizer.simplify(samples)
                return (points, InkRendering.path(for: points))
            }.value
            guard let self, self.finalizationVersions[date] == version,
                  self.pendingEstimates[date] == nil,
                  let index = self.strokes.firstIndex(where: { $0.path.creationDate == date }) else { return }
            self.finalizationVersions.removeValue(forKey: date)
            guard result.0.count < self.strokes[index].path.count, let first = result.0.first else { return }
            let points = result.0.map { PKStrokePoint(location: $0.point, timeOffset: $0.time - first.time,
                size: CGSize(width: $0.width, height: $0.width), opacity: 1, force: $0.pressure, azimuth: $0.azimuth, altitude: $0.altitude) }
            self.strokes[index] = PKStroke(ink: self.strokes[index].ink, path: PKStrokePath(controlPoints: points, creationDate: date))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.strokeLayers[index].path = result.1; CATransaction.commit()
            self.delegate?.canvasViewDrawingDidChange(self, reason: automatic ? .estimatedCorrection : .preservedStroke)
        }
    }
    private func corrected(_ old: InkSample, from touch: UITouch, tool: InkTool, base: Double, sensitivity: Double) -> InkSample {
        let raw = input(touch)
        var result = old
        let original = old.rawPoint ?? old.point
        result.point.x += raw.point.x-original.x; result.point.y += raw.point.y-original.y
        result.rawPoint = raw.point
        let pressureDelta = raw.pressure - (old.rawPressure ?? old.pressure)
        result.pressure = min(1, max(0, old.pressure + pressureDelta * 0.4)); result.rawPressure = raw.pressure
        result.altitude = raw.altitude; result.azimuth = raw.azimuth; result.roll = raw.roll
        let kind: InkBrush = tool == .ballpoint ? .ballpoint : tool == .brush ? .brush : tool == .marker ? .marker : .fountain
        let previousWidth = InkDynamics.width(brush:kind,base:base,pressure:old.pressure,sensitivity:sensitivity,
            speed:0,altitude:old.altitude,roll:old.roll,direction:0,distance:100)
        let newWidth = InkDynamics.width(brush:kind,base:base,pressure:result.pressure,sensitivity:sensitivity,
            speed:0,altitude:raw.altitude,roll:raw.roll,direction:0,distance:100)
        // Retain the taper and velocity factors already applied to this point.
        result.width = max(0.15, old.width * newWidth / max(0.15,previousWidth))
        return result
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        var changed = Set<Int>()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for touch in touches {
            guard let key = touch.estimationUpdateIndex else { continue }
            if pencil != nil, activeTool != .eraser, let index = estimated[key], index < samples.count {
                samples[index] = corrected(samples[index],from:touch,tool:activeTool,base:activeWidth,sensitivity:activeSensitivity)
                if touch.estimatedPropertiesExpectingUpdates.isEmpty { estimated.removeValue(forKey:key) }
                changed.insert(index)
            } else if let date = pendingEstimates.first(where: { $0.value.indices[key] != nil })?.key,
                      var pending = pendingEstimates[date], let point = pending.indices[key],
                      let index = strokes.firstIndex(where: { $0.path.creationDate == date }) {
                finalizationVersions.removeValue(forKey: date)
                pending.points[point] = corrected(pending.points[point],from:touch,tool:pending.tool,base:pending.width,sensitivity:pending.sensitivity)
                if touch.estimatedPropertiesExpectingUpdates.isEmpty { pending.indices.removeValue(forKey:key) }
                pendingEstimates[date] = pending.indices.isEmpty ? nil : pending
                let values = pending.points, firstTime = values.first?.time ?? 0
                let points = values.map { PKStrokePoint(location:$0.point,timeOffset:$0.time-firstTime,size:CGSize(width:$0.width,height:$0.width),opacity:1,force:$0.pressure,azimuth:$0.azimuth,altitude:$0.altitude) }
                strokes[index] = PKStroke(ink:strokes[index].ink,path:PKStrokePath(controlPoints:points,creationDate:date))
                strokeLayers[index].path = InkRendering.path(for:values)
                if pending.indices.isEmpty { finalize(date, samples: values, automatic: pending.allowAutomaticQuestion) }
                delegate?.canvasViewDrawingDidChange(self, reason: pending.allowAutomaticQuestion ? .estimatedCorrection : .preservedStroke)
            }
        }
        if !changed.isEmpty {
            apply(livePath.correct(samples, indices: changed))
            updateLive(predicted: [])
        }
        CATransaction.commit()
    }
}
