import CoreGraphics
import CoreMotion

/// Works out how the phone is mounted from gravity, so pictures sent to the browser and
/// Pushover can be turned upright. Uses the accelerometer, so it works even though the app
/// is locked to portrait and with the Control Center rotation lock on.
final class OrientationMonitor {
    /// Clockwise quarter turns that make the camera picture upright (0...3).
    private(set) var quarterTurns = 0
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity,
                  let turns = Self.quarterTurns(gravityX: g.x, gravityY: g.y) else { return }
            self.quarterTurns = turns
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }

    /// The camera buffer is portrait. Gravity is in device axes (+x = right edge, +y = top edge
    /// when held upright). Returns nil when the phone is lying flat or between positions.
    static func quarterTurns(gravityX x: Double, gravityY y: Double) -> Int? {
        let threshold = 0.6
        if abs(x) >= threshold, abs(x) > abs(y) { return x < 0 ? 3 : 1 }   // top to the left: turn back 90° anticlockwise
        if abs(y) >= threshold { return y < 0 ? 0 : 2 }
        return nil
    }
}

/// Geometry for turning a picture by clockwise quarter turns. Normalized, origin top-left.
enum PictureRotation {
    static func point(_ p: CGPoint, turns: Int) -> CGPoint {
        switch ((turns % 4) + 4) % 4 {
        case 1: return CGPoint(x: 1 - p.y, y: p.x)
        case 2: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 3: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    static func rect(_ r: CGRect, turns: Int) -> CGRect {
        let a = point(CGPoint(x: r.minX, y: r.minY), turns: turns)
        let b = point(CGPoint(x: r.maxX, y: r.maxY), turns: turns)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
