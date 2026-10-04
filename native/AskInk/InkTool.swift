import Foundation

enum InkTool: String, CaseIterable, Identifiable {
    case pen, ballpoint, brush, marker, eraser
    var id: String { rawValue }
    var title: String { ["pen":"钢笔", "ballpoint":"圆珠笔", "brush":"画笔", "marker":"荧光笔", "eraser":"橡皮"][rawValue]! }
    var symbol: String { ["pen":"pencil.tip", "ballpoint":"pencil", "brush":"paintbrush", "marker":"highlighter", "eraser":"eraser"][rawValue]! }
}
