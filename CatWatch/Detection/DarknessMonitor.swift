import Foundation

/// Decides when the picture is too dark for the detector, with hysteresis so dusk,
/// clouds or a passing headlight don't flip it back and forth.
struct DarknessMonitor {
    /// Average brightness (0...255) below which the frame counts as dark.
    var darkBelow = 28.0
    /// Average brightness above which it counts as light again.
    var lightAbove = 45.0
    /// How long the new state must hold before it changes.
    var holdFor: TimeInterval = 120

    private(set) var isDark = false
    private var candidateSince: Date?

    /// Feeds one frame's average brightness. Returns the new state when it changes.
    mutating func update(brightness: Double, at now: Date) -> Bool? {
        let pointsOtherWay = isDark ? brightness > lightAbove : brightness < darkBelow
        guard pointsOtherWay else {
            candidateSince = nil
            return nil
        }
        guard let since = candidateSince else {
            candidateSince = now
            return nil
        }
        guard now.timeIntervalSince(since) >= holdFor else { return nil }
        isDark.toggle()
        candidateSince = nil
        return isDark
    }

    static func averageBrightness(_ thumb: [UInt8]) -> Double {
        thumb.isEmpty ? 0 : Double(thumb.reduce(0) { $0 + Int($1) }) / Double(thumb.count)
    }
}
