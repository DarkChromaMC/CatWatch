import UIKit

struct CatEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let confidence: Float
    var alertSent: Bool
    var alertError: String?
    /// "cat" / "notcat" once the user has said what it was (web view buttons).
    var label: String?
    /// The box that triggered the alert, camera coordinates [x, y, w, h], for training.
    var box: [Double]?
}

/// Detection history: JPEG snapshots plus a JSON index in Application Support.
@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [CatEvent] = []

    static let maxEvents = 300

    private let directory: URL
    nonisolated var directoryURL: URL { Self.directoryURL }

    nonisolated static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Events", isDirectory: true)
    }
    private var indexURL: URL { directory.appendingPathComponent("events.json") }

    init() {
        directory = Self.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([CatEvent].self, from: data) {
            events = decoded
        }
    }

    func imageURL(for event: CatEvent) -> URL {
        directory.appendingPathComponent("\(event.id.uuidString).jpg")
    }

    func image(for event: CatEvent) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: event).path)
    }

    /// The camera frame without drawings or rotation, kept so a labelled alert can train the model.
    func rawURL(for event: CatEvent) -> URL {
        directory.appendingPathComponent("\(event.id.uuidString)-raw.jpg")
    }

    /// Labelled alerts end up here (Files › CatWatch › Labeled › cat / notcat).
    nonisolated static var labeledURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Labeled", isDirectory: true)
    }

    @discardableResult
    func add(confidence: Float, jpeg: Data, raw: Data? = nil, box: CGRect? = nil) -> CatEvent {
        let event = CatEvent(id: UUID(), date: Date(), confidence: confidence, alertSent: false,
                             box: box.map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) })
        try? jpeg.write(to: imageURL(for: event), options: .atomic)
        if let raw { try? raw.write(to: rawURL(for: event), options: .atomic) }
        events.insert(event, at: 0)
        while events.count > Self.maxEvents, let old = events.popLast() {
            removeFiles(of: old)
        }
        persist()
        return event
    }

    /// Alerts from the last `hours`, newest first.
    func recent(hours: Double, limit: Int, now: Date = Date()) -> [CatEvent] {
        Array(events.lazy.filter { now.timeIntervalSince($0.date) < hours * 3600 }.prefix(limit))
    }

    /// Records what the alert really was and copies its frame (+ box) into Labeled/<label>/.
    func label(_ id: UUID, as label: String) {
        guard ["cat", "notcat"].contains(label), let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].label = label
        let event = events[i]
        let fm = FileManager.default
        for other in ["cat", "notcat"] {
            for ext in ["jpg", "json"] {
                try? fm.removeItem(at: Self.labeledURL.appendingPathComponent("\(other)/\(id.uuidString).\(ext)"))
            }
        }
        let folder = Self.labeledURL.appendingPathComponent(label, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = fm.fileExists(atPath: rawURL(for: event).path) ? rawURL(for: event) : imageURL(for: event)
        try? fm.copyItem(at: source, to: folder.appendingPathComponent("\(id.uuidString).jpg"))
        let info: [String: Any] = ["date": ISO8601DateFormatter().string(from: event.date), "confidence": event.confidence,
                                   "box": event.box ?? [], "raw": source == rawURL(for: event)]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: folder.appendingPathComponent("\(id.uuidString).json"))
        }
        persist()
    }

    func delete(id: UUID) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        delete(event)
    }

    private func removeFiles(of event: CatEvent) {
        try? FileManager.default.removeItem(at: imageURL(for: event))
        try? FileManager.default.removeItem(at: rawURL(for: event))
    }

    func markAlert(_ id: UUID, sent: Bool, error: String?) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].alertSent = sent
        events[i].alertError = error
        persist()
    }

    func delete(_ event: CatEvent) {
        removeFiles(of: event)
        events.removeAll { $0.id == event.id }
        persist()
    }

    func deleteAll() {
        events.forEach { removeFiles(of: $0) }
        events = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
