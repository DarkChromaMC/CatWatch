import SwiftUI

@main
struct CatWatchApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: EventStore
    @StateObject private var monitor: MonitorController

    init() {
        let settings = AppSettings()
        let store = EventStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: store)
        _monitor = StateObject(wrappedValue: MonitorController(settings: settings, store: store))
    }

    var body: some Scene {
        WindowGroup {
            MonitorView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(monitor)
                .preferredColorScheme(.dark)
        }
    }
}
