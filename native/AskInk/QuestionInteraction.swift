import Foundation
import CoreGraphics

struct QuestionGlyph {
    var points: [CGPoint]
    var bounds: CGRect {
        guard let first = points.first else { return .null }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                      width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                      height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
    }
}

enum QuestionMarkGate {
    static func isQuestionText(_ text: String) -> Bool {
        endsInQuestionMark(text)
    }
    static func endsInQuestionMark(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasSuffix("?") || value.hasSuffix("？")
    }
    // A cheap candidate filter, never authorization to call a paid model.
    // Candidate symbols must subsequently be confirmed by local recognition.
    static func mightBeQuestionMark(_ glyphs: [QuestionGlyph]) -> Bool {
        guard let last = glyphs.last, !last.points.isEmpty else { return false }
        let b = last.bounds
        func hook(_ glyph: QuestionGlyph) -> Bool {
            let box = glyph.bounds
            guard box.height >= 6, box.width >= 3, box.width < box.height * 3 else { return false }
            let dx = zip(glyph.points, glyph.points.dropFirst()).map { $1.x - $0.x }.filter { abs($0) > 0.3 }
            let dy = zip(glyph.points, glyph.points.dropFirst()).map { $1.y - $0.y }.filter { abs($0) > 0.3 }
            return dx.contains(where: { $0 > 0 }) && dx.contains(where: { $0 < 0 }) && dy.contains(where: { $0 > 0 })
        }
        if max(b.width, b.height) <= 12 {
            return glyphs.dropLast().suffix(2).contains { upper in
                let u = upper.bounds
                return hook(upper) && b.midY > u.midY && b.minY - u.maxY < max(18, u.height)
                    && b.midX >= u.minX - 10 && b.midX <= u.maxX + 10
            }
        }
        return hook(last)
    }
}

enum AnswerPlacement {
    static func center(anchor: CGPoint, card: CGSize, viewport: CGSize, occupied: [CGRect] = [], preferBelow: Bool = false) -> CGPoint {
        var candidates = [
            CGPoint(x: anchor.x + 14 + card.width / 2, y: anchor.y + card.height / 2),
            CGPoint(x: anchor.x, y: anchor.y + 24 + card.height / 2),
            CGPoint(x: anchor.x - 14 - card.width / 2, y: anchor.y + card.height / 2),
            CGPoint(x: anchor.x, y: anchor.y - 24 - card.height / 2)
        ]
        if preferBelow { candidates.swapAt(0, 1) }
        let available = CGRect(origin: .zero, size: viewport).insetBy(dx: 8, dy: 8)
        for center in candidates {
            let rect = CGRect(x: center.x - card.width / 2, y: center.y - card.height / 2, width: card.width, height: card.height)
            if available.contains(rect), !occupied.contains(where: { $0.intersects(rect) }) { return center }
        }
        return CGPoint(x: max(card.width / 2 + 8, min(viewport.width - card.width / 2 - 8, candidates[0].x)),
                       y: max(card.height / 2 + 8, min(viewport.height - card.height / 2 - 8, candidates[0].y)))
    }
}
