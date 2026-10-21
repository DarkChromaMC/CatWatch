import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if store.events.isEmpty {
                    ContentUnavailableView("No sightings yet", systemImage: "cat",
                                           description: Text("Snapshots appear here when the cat enters the zone."))
                }
                ForEach(store.events) { event in
                    NavigationLink { EventDetailView(event: event) } label: { row(event) }
                }
                .onDelete { offsets in offsets.map { store.events[$0] }.forEach(store.delete) }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .disabled(store.events.isEmpty)
                }
            }
            .confirmationDialog("Delete all sightings?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
            }
        }
    }

    private func row(_ event: CatEvent) -> some View {
        HStack(spacing: 12) {
            Thumbnail(url: store.imageURL(for: event))
                .frame(width: 60, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.body)
                Text("\(Int(event.confidence * 100))% confidence").font(.caption).foregroundStyle(.secondary)
                if event.alertSent {
                    Label("Alert sent", systemImage: "bell.fill").font(.caption).foregroundStyle(.green)
                } else if let error = event.alertError {
                    Label(error, systemImage: "bell.slash").font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: url) {
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 120, height: 160)) }.value
        }
    }
}

private struct EventDetailView: View {
    @EnvironmentObject private var store: EventStore
    let event: CatEvent

    var body: some View {
        Group {
            if let image = store.image(for: event) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text("Image missing")
            }
        }
        .navigationTitle(event.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: store.imageURL(for: event))
        }
    }
}
