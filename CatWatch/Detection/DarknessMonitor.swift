import Foundation

/// Decides when the picture is too dark for the detector.
///
/// Slow to say "too dark" (3 minutes of mostly dark frames) and quick to take it back
/// (15 seconds of mostly light frames), so moving or bumping the phone, a shadow or a few
/// odd frames never leave it stuck on "too dark" in daylight.
struct DarknessMonitor {
    /// Average brightness (0...255) below which a frame counts as dark.
    var darkBelow = 28.0
    /// Average brightness above which a frame counts as light.
    var lightAbove = 45.0
    /// How long it must have been mostly dark before saying so.
    var darkAfter: TimeInterval = 180
    /// How long it must have been mostly light before saying it can see again.
    var lightAfter: TimeInterval = 15
    /// Frames this black are camera glitches (starting up, covered for a moment), not night.
    var ignoreBelow = 2.0

    private(set) var isDark = false
    private var samples: [(at: Date, brightness: Double)] = []

    /// Forget history, e.g. when the camera restarts.
    mutating func reset() { samples.removeAll() }

    /// Feeds one frame's average brightness. Returns the new state when it changes.
    mutating func update(brightness: Double, at now: Date) -> Bool? {
        guard brightness >= ignoreBelow else { return nil }
        samples.append((now, brightness))
        samples.removeAll { now.timeIntervalSince($0.at) > max(darkAfter, lightAfter) }

        if isDark {
            let recent = samples.filter { now.timeIntervalSince($0.at) <= lightAfter }
            guard let first = samples.first, now.timeIntervalSince(first.at) >= lightAfter * 0.8 || recent.count >= 3,
                  recent.count >= 3,
                  Double(recent.filter { $0.brightness > lightAbove }.count) >= Double(recent.count) * 0.8
            else { return nil }
            isDark = false
            return false
        } else {
            guard let first = samples.first, now.timeIntervalSince(first.at) >= darkAfter * 0.95, samples.count >= 10,
                  Double(samples.filter { $0.brightness < darkBelow }.count) >= Double(samples.count) * 0.9
            else { return nil }
            isDark = true
            return true
        }
    }

    static func averageBrightness(_ thumb: [UInt8]) -> Double {
        thumb.isEmpty ? 0 : Double(thumb.reduce(0) { $0 + Int($1) }) / Double(thumb.count)
    }
}
