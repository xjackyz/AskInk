import XCTest
@testable import InkAlgorithms

final class DynamicsTests: XCTestCase {
    func testBallpointIgnoresPressureVelocityAndRoll() {
        for p in [0.0,0.2,0.9,1.0] {
            XCTAssertEqual(InkDynamics.width(brush:.ballpoint,base:2,pressure:p,sensitivity:1,speed:3000,altitude:0.2,roll:1,direction:2,distance:0),2)
        }
    }
    func testPressureIsMonotonicAndFountainBounded() {
        let widths = (0...10).map { InkDynamics.width(brush:.fountain,base:2,pressure:Double($0)/10,sensitivity:1,speed:0,altitude:.pi/2,roll:0,direction:0,distance:10) }
        XCTAssertEqual(widths, widths.sorted()); XCTAssertGreaterThanOrEqual(widths[0],0.8); XCTAssertLessThanOrEqual(widths.last!,3.3)
        let brush = InkDynamics.width(brush:.brush,base:2,pressure:1,sensitivity:1,speed:0,altitude:1,roll:0,direction:0,distance:20)
        XCTAssertGreaterThan(brush,widths.last!)
    }
    func testZeroStabilizationPreservesInputAndFullReducesJitter() {
        var off = InkStabilizer(), high = InkStabilizer(); var sum = 0.0
        for i in 0..<120 {
            let sample = InkSample(point:CGPoint(x:i,y:i%2 == 0 ? 1 : -1),time:Double(i)/240,pressure:0.5)
            XCTAssertEqual(off.process(sample,strength:0).point,sample.point)
            let value = high.process(sample,strength:1)
            XCTAssertTrue(value.point.x.isFinite); sum += abs(value.point.y)
        }
        XCTAssertLessThan(sum,60)
    }
    func testBezierEndpointsAndCornerTangentsAreBounded() {
        let a = CGPoint(x:0,y:0), d = CGPoint(x:1,y:0)
        let (b,c) = InkDynamics.controls(CGPoint(x:-100,y:100),a,d,CGPoint(x:200,y:-100))
        XCTAssertEqual(InkDynamics.cubic(a,b,c,d,0),a); XCTAssertEqual(InkDynamics.cubic(a,b,c,d,1),d)
        XCTAssertLessThanOrEqual(hypot(b.x-a.x,b.y-a.y),1.0/3+1e-8)
        XCTAssertLessThanOrEqual(hypot(c.x-d.x,c.y-d.y),1.0/3+1e-8)
    }
    func testEraseSegmentDistanceIncludingDot() {
        XCTAssertEqual(InkDynamics.distance(CGPoint(x:5,y:3),to:.zero,CGPoint(x:10,y:0)),3,accuracy:0.001)
        XCTAssertEqual(InkDynamics.distance(CGPoint(x:3,y:4),to:.zero,.zero),5,accuracy:0.001)
    }
    func testFastEraserSweepHitsCrossedInkEvenWhenBothEndpointsAreFarAway() {
        XCTAssertEqual(InkDynamics.segmentDistance(CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 0, y: -40), CGPoint(x: 0, y: 40)), 0)
        XCTAssertEqual(InkDynamics.segmentDistance(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 40, y: 30), CGPoint(x: 60, y: 30)), 30)
        XCTAssertEqual(InkDynamics.segmentDistance(.zero, .zero, CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 4)), 5)
    }
}
