import Foundation

/// User preferences, persisted in UserDefaults (secrets go to the Keychain).
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var pushoverUserKey: String { didSet { Keychain.set(pushoverUserKey, for: "pushoverUserKey") } }
    @Published var pushoverAppToken: String { didSet { Keychain.set(pushoverAppToken, for: "pushoverAppToken") } }

    @Published var zone: Zone { didSet { save(zone, "zone") } }
    /// Minimum Vision confidence for a cat (0...1).
    @Published var minConfidence: Double { didSet { defaults.set(minConfidence, forKey: "minConfidence") } }
    /// In-zone sightings needed within a few seconds before alerting.
    @Published var requiredHits: Int { didSet { defaults.set(requiredHits, forKey: "requiredHits") } }
    /// Seconds between cat alerts.
    @Published var cooldown: Double { didSet { defaults.set(cooldown, forKey: "cooldown") } }
    /// Detection passes per second.
    @Published var detectionRate: Double { didSet { defaults.set(detectionRate, forKey: "detectionRate") } }
    @Published var useUltraWide: Bool { didSet { defaults.set(useUltraWide, forKey: "useUltraWide") } }

    @Published var priority: Int { didSet { defaults.set(priority, forKey: "priority") } }
    @Published var sound: String { didSet { defaults.set(sound, forKey: "sound") } }
    /// Send alerts about the phone itself (unplugged, overheating, camera stopped, app closed).
    @Published var healthAlerts: Bool { didSet { defaults.set(healthAlerts, forKey: "healthAlerts") } }

    /// Seconds without a touch before the screen blanks. 0 disables.
    @Published var dimAfter: Double { didSet { defaults.set(dimAfter, forKey: "dimAfter") } }

    init() {
        defaults.register(defaults: [
            "minConfidence": 0.5,
            "requiredHits": 2,
            "cooldown": 120.0,
            "detectionRate": 3.0,
            "useUltraWide": false,
            "priority": PushoverPriority.high.rawValue,
            "sound": "",
            "healthAlerts": true,
            "dimAfter": 60.0,
        ])
        pushoverUserKey = Keychain.get("pushoverUserKey")
        pushoverAppToken = Keychain.get("pushoverAppToken")
        zone = Self.load(Zone.self, "zone", defaults) ?? Zone()
        minConfidence = defaults.double(forKey: "minConfidence")
        requiredHits = defaults.integer(forKey: "requiredHits")
        cooldown = defaults.double(forKey: "cooldown")
        detectionRate = defaults.double(forKey: "detectionRate")
        useUltraWide = defaults.bool(forKey: "useUltraWide")
        priority = defaults.integer(forKey: "priority")
        sound = defaults.string(forKey: "sound") ?? ""
        healthAlerts = defaults.bool(forKey: "healthAlerts")
        dimAfter = defaults.double(forKey: "dimAfter")
    }

    var pushover: PushoverClient {
        PushoverClient(
            appToken: pushoverAppToken.trimmingCharacters(in: .whitespacesAndNewlines),
            userKey: pushoverUserKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var pushoverPriority: PushoverPriority { PushoverPriority(rawValue: priority) ?? .high }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
