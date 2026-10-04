import XCTest
import AppKit
@testable import InkAlgorithms

final class ToolTests: XCTestCase {
    func testEveryToolHasAnAvailableSystemSymbol() {
        for tool in InkTool.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), "Missing symbol: \(tool.symbol)")
        }
    }
}
