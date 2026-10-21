import UIKit

struct CatEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let confidence: Float
    var alertSent: Bool
    var alertError: String?
}

/// Detection history: JPEG snapshots plus a JSON index in Application Support.
@MainActor
final class EventStore: ObservableObject {
    @Published private(set) var events: [CatEvent] = []

    static let maxEvents = 300

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("events.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Events", isDirectory: true)
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

    @discardableResult
    func add(confidence: Float, jpeg: Data) -> CatEvent {
        let event = CatEvent(id: UUID(), date: Date(), confidence: confidence, alertSent: false)
        try? jpeg.write(to: imageURL(for: event), options: .atomic)
        events.insert(event, at: 0)
        while events.count > Self.maxEvents, let old = events.popLast() {
            try? FileManager.default.removeItem(at: imageURL(for: old))
        }
        persist()
        return event
    }

    func markAlert(_ id: UUID, sent: Bool, error: String?) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        events[i].alertSent = sent
        events[i].alertError = error
        persist()
    }

    func delete(_ event: CatEvent) {
        try? FileManager.default.removeItem(at: imageURL(for: event))
        events.removeAll { $0.id == event.id }
        persist()
    }

    func deleteAll() {
        events.forEach { try? FileManager.default.removeItem(at: imageURL(for: $0)) }
        events = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
