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

    /// Feeds the next frame's thumbnail; returns the changed fraction since the previous one.
    mutating func update(thumb: [UInt8], zone: Zone) -> Double {
        if maskZone != zone {
            mask = Self.mask(for: zone)
            maskZone = zone
        }
        defer { previous = thumb }
        guard let previous else { return 0 }
        return Self.changedFraction(previous: previous, current: thumb, mask: mask, threshold: pixelThreshold)
    }

    mutating func reset() { previous = nil }
}
