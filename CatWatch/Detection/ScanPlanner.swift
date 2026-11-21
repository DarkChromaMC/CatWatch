import CoreGraphics

/// Chooses zoomed-in crops for the detector each pass: around fresh motion, around the last
/// possible cat (so a sighting gets checked again up close), and one tile of the zone in
/// rotation so a still cat is found within a few seconds.
struct ScanPlanner {
    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Tile and minimum crop size, as a fraction of the frame width.
    static let tileFraction: CGFloat = 0.4

    private var tileIndex = 0
    private var tiles: [CGRect] = []
    private var tilesKey: (Zone, CGSize)?
    private var focus: (box: CGRect, until: Double)?

    /// A square crop (in pixels) around `box`, 1.6x its size, at least a tile, clamped to the frame. Normalized in and out.
    static func square(around box: CGRect, frame: CGSize) -> CGRect {
        let px = CGRect(x: box.minX * frame.width, y: box.minY * frame.height,
                        width: box.width * frame.width, height: box.height * frame.height)
        let side = min(min(frame.width, frame.height), max(px.width, px.height, 1) * 1.6, .infinity)
        let s = max(side, min(frame.width, frame.height) * tileFraction)
        let x = min(max(px.midX - s / 2, 0), frame.width - s)
        let y = min(max(px.midY - s / 2, 0), frame.height - s)
        return CGRect(x: x / frame.width, y: y / frame.height, width: s / frame.width, height: s / frame.height)
    }

    /// Overlapping square tiles covering `area` (normalized), sized `tileFraction` of the frame width.
    static func tiles(covering area: CGRect, frame: CGSize) -> [CGRect] {
        let side = min(frame.width, frame.height) * tileFraction
        let px = CGRect(x: area.minX * frame.width, y: area.minY * frame.height,
                        width: area.width * frame.width, height: area.height * frame.height)
        func starts(_ origin: CGFloat, _ length: CGFloat, _ limit: CGFloat) -> [CGFloat] {
            guard length > side else { return [min(max(origin + length / 2 - side / 2, 0), limit - side)] }
            let count = Int(ceil((length - side) / (side * 0.75))) + 1
            return (0..<count).map { origin + (length - side) * CGFloat($0) / CGFloat(max(1, count - 1)) }
        }
        return starts(px.minY, px.height, frame.height).flatMap { y in
            starts(px.minX, px.width, frame.width).map { x in
                CGRect(x: x / frame.width, y: y / frame.height, width: side / frame.width, height: side / frame.height)
            }
        }
    }

    static func bounds(of zone: Zone) -> CGRect {
        guard zone.isValid else { return whole }
        let xs = zone.points.map(\.x), ys = zone.points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .intersection(whole)
    }

    /// Regions to run the detector on this pass.
    mutating func regions(zone: Zone, frame: CGSize, motionBox: CGRect?, now: Double) -> [CGRect] {
        if tilesKey.map({ $0.0 != zone || $0.1 != frame }) ?? true {
            tiles = Self.tiles(covering: Self.bounds(of: zone), frame: frame)
            tilesKey = (zone, frame)
            tileIndex = 0
        }
        var out = [Self.whole]
        func add(_ r: CGRect) {
            // Skip crops that mostly repeat one already planned.
            let repeats = out.dropFirst().contains { o in
                let i = o.intersection(r)
                return !i.isNull && (i.width * i.height) / (r.width * r.height) > 0.6
            }
            if !repeats { out.append(r) }
        }
        if let focus, now < focus.until { add(Self.square(around: focus.box, frame: frame)) }
        if let motionBox { add(Self.square(around: motionBox, frame: frame)) }
        if !tiles.isEmpty {
            add(tiles[tileIndex % tiles.count])
            tileIndex += 1
        }
        return out
    }

    /// Remember a possible cat so the next passes look at it up close.
    mutating func noteSighting(_ box: CGRect, now: Double) {
        focus = (box, now + 5)
    }
}
