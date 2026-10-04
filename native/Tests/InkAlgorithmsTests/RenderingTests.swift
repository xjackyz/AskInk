import XCTest
import CoreGraphics
@testable import InkAlgorithms

final class RenderingTests: XCTestCase {
    func testFilledRibbonHasNoHolesWhereSegmentsAndCapsOverlap() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 40, y: 0)]
        let samples = points.enumerated().map { InkSample(point: $0.element, time: Double($0.offset), pressure: 0.5, width: 4) }
        let path = InkRendering.path(for: samples)
        for x in stride(from: 0.25, to: 40.0, by: 0.25) {
            XCTAssertTrue(path.contains(CGPoint(x: x, y: 0.5)), "Missing ink at x=\(x)")
        }
    }

    func testCoalescedEventsCrossingMultipleChunksPublishEverySegment() {
        let samples = (0..<150).map { InkSample(point: CGPoint(x: $0 * 4, y: 10), time: Double($0) / 240, pressure: 0.5, width: 3) }
        var live = InkLivePath()
        var layers: [Int: CGPath] = [:]
        for count in [5, 64, 140, 150] {
            for update in live.append(Array(samples.prefix(count))) { layers[update.index] = update.path }
        }
        XCTAssertEqual(live.committedSegments, 148)
        XCTAssertEqual(layers.count, 3)
        for x in stride(from: 0.5, to: 591.0, by: 0.5) {
            XCTAssertTrue(layers.values.contains { $0.contains(CGPoint(x: x, y: 10.25)) }, "Gap at x=\(x)")
        }
    }

    func testEstimatedCorrectionsOnlyRebuildAffectedChunksAndKeepContinuity() {
        var samples = (0..<150).map { InkSample(point: CGPoint(x: $0 * 4, y: 10), time: Double($0) / 240, pressure: 0.5, width: 3) }
        var live = InkLivePath()
        var layers = Dictionary(uniqueKeysWithValues: live.append(samples).map { ($0.index, $0.path) })
        samples[64].point.y = 12
        let updates = live.correct(samples, indices: [64])
        XCTAssertEqual(updates.map(\.index), [0, 1])
        for update in updates { layers[update.index] = update.path }
        let combined = CGMutablePath()
        layers.values.forEach { combined.addPath($0) }
        XCTAssertTrue(combined.contains(samples[64].point))
        XCTAssertTrue(combined.contains(CGPoint(x: 253, y: 11)))
        XCTAssertTrue(combined.contains(CGPoint(x: 259, y: 11)))
    }

    func testDotsRepeatedPointsAndDirectionReversalRemainVisible() {
        for points in [[CGPoint(x: 10, y: 10)],
                       [CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)],
                       [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 0, y: 0)]] {
            let samples = points.enumerated().map { InkSample(point: $0.element, time: Double($0.offset), pressure: 0.5, width: 4) }
            let path = InkRendering.path(for: samples)
            XCTAssertTrue(path.contains(points[0]))
            if points.count == 3 { XCTAssertTrue(path.contains(CGPoint(x: 10, y: 0.5))) }
        }
    }
}
