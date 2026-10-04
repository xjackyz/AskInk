import Foundation
import CoreGraphics

enum InkBrush { case ballpoint, fountain, brush, marker }
struct InkSample {
    var point: CGPoint
    var time: Double
    var pressure: Double
    var altitude: Double = .pi / 2
    var azimuth: Double = 0
    var roll: Double = 0
    var width: Double = 2
    var rawPoint: CGPoint? = nil
}

// Adaptive low-pass (1 Euro): suppress slow micro-jitter, increase cutoff at speed.
// Source: Casiez et al., CHI 2012, https://gery.casiez.net/1euro/
struct InkStabilizer {
    private var previous: InkSample?
    private var filtered = CGPoint.zero
    private var velocity = CGPoint.zero
    mutating func process(_ sample: InkSample, strength: Double) -> InkSample {
        guard let previous else { self.previous = sample; filtered = sample.point; return sample }
        let dt = max(1.0 / 1000, min(0.1, sample.time - previous.time))
        func alpha(_ cutoff: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
        let derivative = CGPoint(x: (sample.point.x - previous.point.x) / dt, y: (sample.point.y - previous.point.y) / dt)
        let a = alpha(8)
        velocity.x += a * (derivative.x - velocity.x); velocity.y += a * (derivative.y - velocity.y)
        let s = min(1, max(0, strength))
        let cutoff = 45 * (1 - s) + 1.5 * s + (0.12 * (1 - s) + 0.015) * hypot(velocity.x, velocity.y)
        let smoothing = s == 0 ? 1 : alpha(cutoff)
        filtered.x += smoothing * (sample.point.x - filtered.x)
        filtered.y += smoothing * (sample.point.y - filtered.y)
        self.previous = sample
        var result = sample; result.point = filtered; return result
    }
}
enum InkDynamics {
    static func width(brush: InkBrush, base: Double, pressure: Double, sensitivity: Double,
                      speed: Double, altitude: Double, roll: Double, direction: Double, distance: Double) -> Double {
        let p = min(1, max(0, pressure)), s = min(1, max(0, sensitivity))
        switch brush {
        case .ballpoint, .marker: return base
        case .fountain:
            // Bounded linear pressure. Roll/tilt adds a restrained broad-nib effect.
            let force = 1 + (p - 0.5) * (0.4 + 0.8 * s)
            let tilt = min(1, max(0, 1 - altitude / (.pi / 2)))
            let nib = 1 + 0.12 * tilt * abs(sin(direction - roll))
            return max(base * 0.45, base * force * nib)
        case .brush:
            let force = 0.3 + p * (1.1 + 1.5 * s)
            let velocity = 1 + min(0.12, max(0, speed) / 12000)
            let taper = 0.2 + 0.8 * min(1, distance / max(3, base * 2))
            return max(0.15, base * force * velocity * taper)
        }
    }
    static func controls(_ before: CGPoint, _ start: CGPoint, _ end: CGPoint, _ after: CGPoint) -> (CGPoint, CGPoint) {
        // Catmull–Rom to cubic Bezier; bound tangents to avoid overshoot at corners.
        let limit = hypot(end.x - start.x, end.y - start.y) / 3
        func control(_ origin: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            let length = hypot(dx, dy); let ratio = length > limit && length > 0 ? limit / length : 1
            return CGPoint(x: origin.x + dx * ratio, y: origin.y + dy * ratio)
        }
        return (control(start, (end.x - before.x) / 6, (end.y - before.y) / 6),
                control(end, (start.x - after.x) / 6, (start.y - after.y) / 6))
    }
    static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                       y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
    }
    static func segmentDistance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Double {
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        if cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0 { return 0 }
        return min(distance(a, to: c, d), distance(b, to: c, d), distance(c, to: a, b), distance(d, to: a, b))
    }
    static func distance(_ point: CGPoint, to a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx*dx + dy*dy
        let t = length > 0 ? min(1, max(0, ((point.x-a.x)*dx + (point.y-a.y)*dy) / length)) : 0
        return hypot(point.x - a.x - t*dx, point.y - a.y - t*dy)
    }
}
