import Foundation

enum InkTool: String, CaseIterable, Identifiable {
    case pen, ballpoint, pencil, marker, eraser, lasso
    var id: String { rawValue }
    var title: String { ["pen":"钢笔", "ballpoint":"圆珠笔", "pencil":"铅笔", "marker":"荧光笔", "eraser":"橡皮", "lasso":"套索"][rawValue]! }
    var symbol: String { ["pen":"pencil.tip", "ballpoint":"pencil", "pencil":"pencil.line", "marker":"highlighter", "eraser":"eraser", "lasso":"lasso"][rawValue]! }
    static let penStyles: [InkTool] = [.ballpoint, .pen, .pencil]
    static let available: [InkTool] = [.ballpoint, .pen, .pencil, .marker, .eraser, .lasso]
    var isWritingTool: Bool { self != .eraser && self != .lasso }
    var presetWidths: [Double] {
        switch self {
        case .marker: return [8, 16, 24]
        case .eraser: return [8, 16, 32]
        case .pencil: return [2, 4, 6]
        default: return [1, 2, 3.5]
        }
    }
    var widthLimits: ClosedRange<Double> {
        switch self { case .marker: return 4...40; case .eraser: return 4...60; default: return 0.8...8 }
    }
    var defaultWidth: Double { presetWidths[1] }
}

enum InkEraserMode: String, CaseIterable, Identifiable {
    case partial, stroke
    var id: String { rawValue }
    var title: String { self == .partial ? "局部擦除" : "整笔擦除" }
}
