import Foundation
import UIKit

/// A rounded rectangle with Figma's "corner smoothing" (the figma-squircle construction): each corner is a circular
/// arc joined to the straight edges by two cubic curves, and `smoothing` (0...1) trades arc for curve. At 1 (100%)
/// the arc vanishes and the corner is a single smooth curve. `UIBezierPath`'s continuous corners match only ~60%.
func postShareSmoothRoundedRectPath(size: CGSize, cornerRadius: CGFloat, smoothing: CGFloat) -> UIBezierPath {
    let width = size.width
    let height = size.height
    let budget = min(width, height) / 2.0
    let radius = min(cornerRadius, budget)

    // Smoothing extends each corner along its edges by up to `radius * smoothing`; keep that within the budget.
    var smoothing = max(0.0, min(1.0, smoothing))
    if radius > 0.0 {
        smoothing = min(smoothing, max(0.0, budget / radius - 1.0))
    }
    let p = min((1.0 + smoothing) * radius, budget)

    func radians(_ degrees: CGFloat) -> CGFloat {
        return degrees * .pi / 180.0
    }
    let arcMeasure = 90.0 * (1.0 - smoothing)
    let arcSectionLength = sin(radians(arcMeasure / 2.0)) * radius * sqrt(2.0)
    let angleAlpha = (90.0 - arcMeasure) / 2.0
    let p3ToP4Distance = radius * tan(radians(angleAlpha / 2.0))
    let angleBeta = 45.0 * smoothing
    let c = p3ToP4Distance * cos(radians(angleBeta))
    let d = c * tan(radians(angleBeta))
    let b = (p - arcSectionLength - c - d) / 3.0
    let a = 2.0 * b

    // Each corner in its own frame: `along` runs along the edge that enters the corner, `across` along the edge
    // that leaves it, so one construction serves all four (the path runs clockwise).
    struct Corner {
        let point: CGPoint
        let along: CGPoint
        let across: CGPoint

        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            return CGPoint(x: self.point.x + self.along.x * u + self.across.x * v, y: self.point.y + self.along.y * u + self.across.y * v)
        }
    }
    let corners = [
        Corner(point: CGPoint(x: width, y: 0.0), along: CGPoint(x: 1.0, y: 0.0), across: CGPoint(x: 0.0, y: 1.0)),
        Corner(point: CGPoint(x: width, y: height), along: CGPoint(x: 0.0, y: 1.0), across: CGPoint(x: -1.0, y: 0.0)),
        Corner(point: CGPoint(x: 0.0, y: height), along: CGPoint(x: -1.0, y: 0.0), across: CGPoint(x: 0.0, y: -1.0)),
        Corner(point: CGPoint(x: 0.0, y: 0.0), along: CGPoint(x: 0.0, y: -1.0), across: CGPoint(x: 1.0, y: 0.0))
    ]

    let path = UIBezierPath()
    for (index, corner) in corners.enumerated() {
        let start = corner.map(-p, 0.0)
        if index == 0 {
            path.move(to: start)
        } else {
            path.addLine(to: start)
        }
        let arcStart = corner.map(-p + a + b + c, d)
        path.addCurve(to: arcStart, controlPoint1: corner.map(-p + a, 0.0), controlPoint2: corner.map(-p + a + b, 0.0))
        let arcEnd = corner.map(-d, p - a - b - c)
        if arcSectionLength > 0.001 {
            let center = corner.map(-radius, radius)
            let startAngle = atan2(arcStart.y - center.y, arcStart.x - center.x)
            let endAngle = atan2(arcEnd.y - center.y, arcEnd.x - center.x)
            path.addArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        }
        path.addCurve(to: corner.map(0.0, p), controlPoint1: corner.map(0.0, p - a - b), controlPoint2: corner.map(0.0, p - a))
    }
    path.close()
    return path
}
