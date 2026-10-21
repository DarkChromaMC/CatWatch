import CoreGraphics

/// A polygon in normalized image coordinates (0...1, origin top-left, portrait frame).
struct Zone: Codable, Equatable {
    var points: [CGPoint] = []

    var isValid: Bool { points.count >= 3 }

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
