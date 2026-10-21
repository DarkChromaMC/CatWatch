import Foundation

/// Debounces detections: fires only after `requiredHits` in-zone sightings within
/// `hitWindow` seconds, and never more often than once per `cooldown`.
struct TriggerGate {
    var requiredHits: Int
    var hitWindow: TimeInterval
    var cooldown: TimeInterval

    private(set) var hits: [Date] = []
    private(set) var lastFired: Date?

    init(requiredHits: Int = 2, hitWindow: TimeInterval = 4, cooldown: TimeInterval = 120) {
        self.requiredHits = requiredHits
        self.hitWindow = hitWindow
        self.cooldown = cooldown
    }

    /// Returns true when an alert should be sent for this frame.
    mutating func register(hit: Bool, at now: Date) -> Bool {
        hits.removeAll { now.timeIntervalSince($0) > hitWindow }
        guard hit else { return false }
        hits.append(now)
        guard hits.count >= max(1, requiredHits) else { return false }
        if let lastFired, now.timeIntervalSince(lastFired) < cooldown { return false }
        lastFired = now
        hits.removeAll()
        return true
    }

    var isCoolingDown: Bool {
        guard let lastFired else { return false }
        return Date().timeIntervalSince(lastFired) < cooldown
    }
}
