import Foundation
import CoreGraphics

// Pure geometry/timing logic: no rendering, OCR or PDF dependencies.
struct InkStrokeDescriptor {
    var index: Int
    var bounds: CGRect
    var started: TimeInterval
    var ended: TimeInterval
}

enum InkGrouping {
    /// Classify only broad, horizontal highlighter sweeps as source marks.
    /// Character strokes (including short horizontals and dots) remain questions.
    static func isHighlightMark(_ points: [CGPoint]) -> Bool {
        guard let first = points.first else { return false }
        let b = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        return b.width > 60 && b.height < 14 && b.width > max(1, b.height) * 6
    }

    /// Keep every pen stroke, including minus signs, dots and long horizontals.
    /// Time ends a block; space prevents unrelated margin notes from merging.
    static func blocks(_ input: [InkStrokeDescriptor], pause: TimeInterval = 3) -> [[Int]] {
        let ordered = input.sorted { $0.started == $1.started ? $0.index < $1.index : $0.started < $1.started }
        var groups: [[InkStrokeDescriptor]] = []
        for stroke in ordered {
            guard var last = groups.last else { groups.append([stroke]); continue }
            let previous = last.last!
            let gap = max(0, stroke.started - previous.ended)
            let recent = Array(last.suffix(24))
            let heights = recent.map { $0.bounds.height }.filter { $0 > 4 }.sorted()
            let letterHeight = max(12, min(64, heights.isEmpty ? 20 : heights[heights.count / 2]))
            let sameArea = recent.contains { candidate in
                let b = candidate.bounds
                let dx = max(0, b.minX - stroke.bounds.maxX, stroke.bounds.minX - b.maxX)
                let dy = max(0, b.minY - stroke.bounds.maxY, stroke.bounds.minY - b.maxY)
                return dx <= letterHeight * 2.5 && dy <= letterHeight * 0.8
            }
            // Permit a new line near the left edge of the most recent block.
            let bounds = recent.reduce(CGRect.null) { $0.union($1.bounds) }
            let newLine = stroke.bounds.minY >= previous.bounds.minY &&
                stroke.bounds.minY - bounds.maxY <= letterHeight * 1.5 &&
                abs(stroke.bounds.minX - bounds.minX) <= letterHeight * 2
            if gap <= pause && (sameArea || newLine) {
                last.append(stroke); groups[groups.count - 1] = last
            } else {
                // A late correction to an older block belongs to that block,
                // only when it overlaps its writing area; no global time guessing.
                if gap <= 12, let correction = groups.indices.reversed().first(where: { index in
                    groups[index].contains { $0.bounds.insetBy(dx: -letterHeight * 0.4, dy: -letterHeight * 0.4).intersects(stroke.bounds) }
                }) {
                    groups[correction].append(stroke)
                } else { groups.append([stroke]) }
            }
        }
        // Latest edited block first, keeping natural stroke order within blocks.
        return groups.sorted { ($0.last?.started ?? 0) > ($1.last?.started ?? 0) }.map { $0.map(\.index) }
    }
}

enum InkScope: String, CaseIterable, Identifiable {
    case latest, page
    var id: String { rawValue }
    var title: String { self == .latest ? "最近一段" : "本页全部笔迹" }
}
