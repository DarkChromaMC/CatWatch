import CoreGraphics

/// A polygon in normalized image coordinates (0...1, origin top-left, portrait frame).
struct Zone: Codable, Equatable {
    var points: [CGPoint] = []

    var isValid: Bool { points.count >= 3 }

    /// A box over the bottom half of the frame, for the user to drag into place.
    static let starter = Zone(points: [
        CGPoint(x: 0.1, y: 0.55), CGPoint(x: 0.9, y: 0.55),
        CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9),
    ])

    /// Where to insert `p` so it splits the nearest edge instead of crossing the shape.
    func insertionIndex(for p: CGPoint) -> Int {
        guard points.count >= 3 else { return points.count }
        var best = (index: points.count, distance: CGFloat.infinity)
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            let d = Self.distance(from: p, toSegment: a, b)
            if d < best.distance { best = (i + 1, d) }
        }
        return best.index
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Even-odd ray casting.
    func contains(_ p: CGPoint) -> Bool {
        guard isValid else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y) {
                let xCross = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Whether a detection box counts as "in the zone".
    ///
    /// True when the box's bottom-centre (where the cat touches the ground) is inside,
    /// or when at least `minCoverage` of a 5x5 sample grid over the box is inside.
    /// An invalid (empty) zone means the whole frame is the zone.
    func intersects(box: CGRect, minCoverage: Double = 0.3) -> Bool {
        guard isValid else { return true }
        if contains(CGPoint(x: box.midX, y: box.maxY)) { return true }
        let steps = 5
        var hits = 0
        for ix in 0..<steps {
            for iy in 0..<steps {
                let p = CGPoint(
                    x: box.minX + box.width * (CGFloat(ix) + 0.5) / CGFloat(steps),
                    y: box.minY + box.height * (CGFloat(iy) + 0.5) / CGFloat(steps)
                )
                if contains(p) { hits += 1 }
            }
        }
        return Double(hits) / Double(steps * steps) >= minCoverage
    }
}
