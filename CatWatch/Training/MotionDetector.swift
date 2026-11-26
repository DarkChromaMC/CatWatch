import CoreVideo
import CoreGraphics

/// Cheap frame-difference motion check on a coarse grayscale grid, limited to the zone.
/// Used to decide which frames are worth keeping for training a custom cat model.
struct MotionDetector {
    static let cols = 54
    static let rows = 96

    /// Brightness change (0...255) for a grid cell to count as changed.
    var pixelThreshold = 22
    /// Fraction of the zone's cells that must change to count as motion.
    var minFraction = 0.003

    private var previous: [UInt8]?
    private var mask: [Bool] = []
    private var maskZone: Zone?

    /// Average brightness of each grid cell (2x2 samples per cell) of a BGRA frame.
    static func thumbnail(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                var sum = 0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let x = min(w - 1, (c * 2 + sx) * w / (cols * 2) + w / (cols * 4))
                        let y = min(h - 1, (r * 2 + sy) * h / (rows * 2) + h / (rows * 4))
                        let i = y * bytesPerRow + x * 4
                        // BGRA -> luma (approx. 0.11 B + 0.59 G + 0.30 R).
                        sum += (Int(p[i]) * 28 + Int(p[i + 1]) * 151 + Int(p[i + 2]) * 77) >> 8
                    }
                }
                out[r * cols + c] = UInt8(sum / 4)
            }
        }
        return out
    }

    /// Fraction of masked cells whose brightness changed by more than `threshold`.
    static func changedFraction(previous: [UInt8], current: [UInt8], mask: [Bool], threshold: Int) -> Double {
        guard previous.count == current.count, current.count == mask.count else { return 0 }
        var total = 0, changed = 0
        for i in current.indices where mask[i] {
            total += 1
            if abs(Int(current[i]) - Int(previous[i])) > threshold { changed += 1 }
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }

    /// Which grid cells lie inside the zone (all of them when the zone is empty).
    static func mask(for zone: Zone) -> [Bool] {
        (0..<rows).flatMap { r in
            (0..<cols).map { c in
                zone.isValid
                    ? zone.contains(CGPoint(x: (Double(c) + 0.5) / Double(cols), y: (Double(r) + 0.5) / Double(rows)))
                    : true
            }
        }
    }

    /// Feeds the next frame's thumbnail; returns the changed fraction since the previous one
    /// and the bounding box (normalized, origin top-left) of the changed cells in the zone.
    mutating func update(thumb: [UInt8], zone: Zone) -> (fraction: Double, box: CGRect?, blobs: [CGRect]) {
        if maskZone != zone {
            mask = Self.mask(for: zone)
            maskZone = zone
        }
        defer { previous = thumb }
        guard let previous, previous.count == thumb.count else { return (0, nil, []) }
        let fraction = Self.changedFraction(previous: previous, current: thumb, mask: mask, threshold: pixelThreshold)
        let blobs = Self.blobs(previous: previous, current: thumb, mask: mask, threshold: pixelThreshold)
        guard fraction >= minFraction else { return (fraction, nil, blobs) }
        return (fraction, Self.changedBox(previous: previous, current: thumb, mask: mask, threshold: pixelThreshold), blobs)
    }

    /// Separate moving things (normalized boxes, biggest first). Sun and wind move shadows all over
    /// the lawn, so one box around *all* change is useless; an animal is a compact blob. Blobs larger
    /// than `maxSide` of the frame (shadow sweeps, the camera being bumped) are left out.
    static func blobs(previous: [UInt8], current: [UInt8], mask: [Bool], threshold: Int,
                      maxCount: Int = 3, minCells: Int = 2, maxSide: Double = 0.45) -> [CGRect] {
        var changed = [Bool](repeating: false, count: cols * rows)
        for i in current.indices where mask[i] && abs(Int(current[i]) - Int(previous[i])) > threshold { changed[i] = true }
        // Join cells one apart (a cat's legs and body change in separate cells).
        var grown = changed
        for r in 0..<rows { for c in 0..<cols where changed[r * cols + c] {
            for (dr, dc) in [(0, 1), (1, 0), (0, -1), (-1, 0)] {
                let nr = r + dr, nc = c + dc
                if nr >= 0, nr < rows, nc >= 0, nc < cols { grown[nr * cols + nc] = true }
            }
        } }
        var seen = [Bool](repeating: false, count: cols * rows)
        var found: [(cells: Int, box: CGRect)] = []
        for start in grown.indices where grown[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var cells = 0, minC = cols, minR = rows, maxC = -1, maxR = -1
            while let i = stack.popLast() {
                let r = i / cols, c = i % cols
                if changed[i] { cells += 1 }
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for (dr, dc) in [(0, 1), (1, 0), (0, -1), (-1, 0)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    let j = nr * cols + nc
                    if grown[j] && !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            let w = Double(maxC - minC + 1) / Double(cols), h = Double(maxR - minR + 1) / Double(rows)
            guard cells >= minCells, w <= maxSide, h <= maxSide else { continue }
            found.append((cells, CGRect(x: Double(minC) / Double(cols), y: Double(minR) / Double(rows), width: w, height: h)))
        }
        return found.sorted { $0.cells > $1.cells }.prefix(maxCount).map(\.box)
    }

    static func changedBox(previous: [UInt8], current: [UInt8], mask: [Bool], threshold: Int) -> CGRect? {
        var minC = cols, minR = rows, maxC = -1, maxR = -1
        for i in current.indices where mask[i] && abs(Int(current[i]) - Int(previous[i])) > threshold {
            let r = i / cols, c = i % cols
            minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
        }
        guard maxC >= 0 else { return nil }
        return CGRect(x: Double(minC) / Double(cols), y: Double(minR) / Double(rows),
                      width: Double(maxC - minC + 1) / Double(cols), height: Double(maxR - minR + 1) / Double(rows))
    }

    mutating func reset() { previous = nil }
}
