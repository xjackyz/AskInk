import Foundation
import CoreGraphics

enum InkRendering {
    static func ribbon(_ values: [InkSample], segment index: Int, into path: CGMutablePath) {
        guard index + 1 < values.count else { return }
        let a = values[index], d = values[index+1]
        let (b,c) = InkDynamics.controls(values[max(0,index-1)].point, a.point, d.point, values[min(values.count-1,index+2)].point)
        let count = min(24, max(2, Int(ceil(hypot(d.point.x-a.point.x, d.point.y-a.point.y) / 2))))
        var left: [CGPoint] = [], right: [CGPoint] = []
        for step in 0...count {
            let t = CGFloat(step) / CGFloat(count), point = InkDynamics.cubic(a.point,b,c,d.point,t)
            let p0 = InkDynamics.cubic(a.point,b,c,d.point,max(0,t-0.01)), p1 = InkDynamics.cubic(a.point,b,c,d.point,min(1,t+0.01))
            let dx = p1.x-p0.x, dy = p1.y-p0.y, length = max(0.0001,hypot(dx,dy))
            let radius = (a.width + (d.width-a.width)*t) / 2
            left.append(CGPoint(x: point.x-dy/length*radius,y: point.y+dx/length*radius))
            right.append(CGPoint(x: point.x+dy/length*radius,y: point.y-dx/length*radius))
        }
        // Match CGPath ellipse winding so overlapping caps add ink instead of cutting holes.
        path.addLines(between: Array((left + right.reversed()).reversed())); path.closeSubpath()
        for value in [a,d] { let r = value.width/2; path.addEllipse(in: CGRect(x:value.point.x-r,y:value.point.y-r,width:r*2,height:r*2)) }
    }
    static func path(for values: [InkSample], from start: Int = 0) -> CGPath {
        let path = CGMutablePath()
        if values.count == 1 { let a = values[0], r = a.width/2; path.addEllipse(in:CGRect(x:a.point.x-r,y:a.point.y-r,width:r*2,height:r*2)) }
        if values.count > 1 && start < values.count-1 { for i in start..<(values.count-1) { ribbon(values, segment:i, into:path) } }
        return path
    }
}

struct InkChunkUpdate {
    var index: Int
    var path: CGPath
}

struct InkLivePath {
    static let chunkSize = 64
    private(set) var committedSegments = 0
    private var chunks: [CGMutablePath] = []

    mutating func append(_ samples: [InkSample]) -> [InkChunkUpdate] {
        var changed = Set<Int>()
        // One real look-ahead sample finalizes the cubic tangent.
        while committedSegments + 2 < samples.count {
            let index = committedSegments / Self.chunkSize
            if chunks.count <= index { chunks.append(CGMutablePath()) }
            InkRendering.ribbon(samples, segment: committedSegments, into: chunks[index])
            changed.insert(index)
            committedSegments += 1
        }
        // Return every changed chunk, including the one just crossed.
        return changed.sorted().map { InkChunkUpdate(index: $0, path: chunks[$0].copy()!) }
    }

    mutating func complete(_ samples: [InkSample], changed: Set<Int>) -> CGPath {
        _ = correct(samples, indices: changed)
        while committedSegments + 1 < samples.count {
            let index = committedSegments / Self.chunkSize
            if chunks.count <= index { chunks.append(CGMutablePath()) }
            InkRendering.ribbon(samples, segment: committedSegments, into: chunks[index])
            committedSegments += 1
        }
        let result = CGMutablePath()
        if samples.count == 1 { result.addPath(InkRendering.path(for: samples)) }
        else { chunks.forEach { result.addPath($0) } }
        return result
    }

    mutating func correct(_ samples: [InkSample], indices: Set<Int>) -> [InkChunkUpdate] {
        var affected = Set<Int>()
        for point in indices {
            let lower = max(0, point - 2), upper = min(committedSegments - 1, point + 1)
            if lower <= upper {
                for segment in lower...upper { affected.insert(segment / Self.chunkSize) }
            }
        }
        return affected.sorted().map { index in
            let path = CGMutablePath()
            let lower = index * Self.chunkSize, upper = min(committedSegments, lower + Self.chunkSize)
            for segment in lower..<upper { InkRendering.ribbon(samples, segment: segment, into: path) }
            chunks[index] = path
            return InkChunkUpdate(index: index, path: path.copy()!)
        }
    }
}

enum InkStrokeEndReason { case completed, cancelled, forced }
enum InkChangeReason { case completedStroke, preservedStroke, eraser, undoRedo, estimatedCorrection }
