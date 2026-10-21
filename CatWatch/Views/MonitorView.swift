import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var monitor: MonitorController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var editingZone = false
    @State private var draft: [CGPoint] = []
    @State private var draftHistory: [[CGPoint]] = []
    @State private var dragIndex: Int?
    @State private var showSettings = false
    @State private var showHistory = false

    @State private var lastTouch = Date()
    @State private var dimmed = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var dimOffset = CGSize.zero

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let fit = aspectFitRect(monitor.videoSize, in: CGRect(origin: .zero, size: geo.size))
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: monitor.camera.session)
                    .ignoresSafeArea()
                overlay(fit: fit)
                    .ignoresSafeArea()
                VStack {
                    statusBar
                    Spacer()
                    if editingZone { zoneControls } else { mainControls }
                }
                .padding()
                if dimmed { dimOverlay }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in wake() })
        .onReceive(tick) { _ in checkDim() }
        .task { await monitor.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.scenePhaseChanged(active: true) }
            if phase == .background { monitor.scenePhaseChanged(active: false) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
    }

    // MARK: - Overlay

    private func overlay(fit: CGRect) -> some View {
        let points = editingZone ? draft : settings.zone.points
        return Canvas { ctx, _ in
            func toView(_ p: CGPoint) -> CGPoint {
                CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
            }
            if points.count >= 2 {
                var path = Path()
                path.addLines(points.map(toView))
                if points.count >= 3 { path.closeSubpath() }
                ctx.fill(path, with: .color(.red.opacity(0.18)))
                ctx.stroke(path, with: .color(.red.opacity(0.9)), lineWidth: 2)
            }
            if editingZone {
                for p in points {
                    let c = toView(p)
                    let dot = Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24))
                    ctx.fill(dot, with: .color(.red))
                    ctx.stroke(dot, with: .color(.white), lineWidth: 3)
                }
            }
            for d in monitor.detections {
                let r = CGRect(x: fit.minX + d.box.minX * fit.width, y: fit.minY + d.box.minY * fit.height,
                               width: d.box.width * fit.width, height: d.box.height * fit.height)
                ctx.stroke(Path(r), with: .color(d.inZone ? .red : .yellow), lineWidth: 3)
                ctx.draw(Text("Cat \(Int(d.confidence * 100))%").font(.caption.bold()).foregroundColor(.white),
                         at: CGPoint(x: r.minX + 4, y: r.minY - 10), anchor: .leading)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(editingZone)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard editingZone else { return }
                if dragIndex == nil {
                    // Only start a drag when the finger lands on a corner.
                    guard let i = nearestCorner(to: value.startLocation, fit: fit) else { return }
                    draftHistory.append(draft)
                    dragIndex = i
                }
                if let i = dragIndex { draft[i] = normalized(value.location, in: fit) }
            }
            .onEnded { value in
                defer { dragIndex = nil }
                guard editingZone, dragIndex == nil, fit.contains(value.location),
                      hypot(value.translation.width, value.translation.height) < 10 else { return }
                // A tap adds a corner on the nearest edge, so lines never cross.
                draftHistory.append(draft)
                let p = normalized(value.location, in: fit)
                draft.insert(p, at: Zone(points: draft).insertionIndex(for: p))
            })
    }

    private func normalized(_ p: CGPoint, in fit: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - fit.minX) / fit.width, 0), 1),
                y: min(max((p.y - fit.minY) / fit.height, 0), 1))
    }

    private func nearestCorner(to p: CGPoint, fit: CGRect) -> Int? {
        let distances = draft.map { c in
            hypot(fit.minX + c.x * fit.width - p.x, fit.minY + c.y * fit.height - p.y)
        }
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }),
              distances[best] < 44 else { return nil }
        return best
    }

    // MARK: - Chrome

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(monitor.isRunning ? Color.green : Color.gray).frame(width: 10, height: 10)
                Text(monitor.isRunning ? "Watching" : "Stopped").font(.headline)
                Spacer()
                if !settings.zone.isValid && !editingZone {
                    Text("No zone: any cat alerts").font(.caption).foregroundStyle(.yellow)
                }
            }
            if let last = monitor.lastAlertAt {
                Text("Last alert \(last.formatted(.relative(presentation: .named)))").font(.caption)
            }
            if let err = monitor.lastAlertError {
                Text("Alert failed: \(err)").font(.caption).foregroundStyle(.red)
            }
            if let err = monitor.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if settings.pushoverAppToken.isEmpty || settings.pushoverUserKey.isEmpty {
                Text("Set up Pushover in Settings to get alerts.").font(.caption).foregroundStyle(.orange)
            }
            if editingZone {
                Text("Drag the white-ringed dots so the red area covers the grass. Tap near an edge to add another corner.").font(.caption)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 40)
    }

    private var mainControls: some View {
        HStack(spacing: 12) {
            controlButton(monitor.isRunning ? "Stop" : "Start", monitor.isRunning ? "stop.fill" : "play.fill") {
                if monitor.isRunning { monitor.stop() } else { Task { await monitor.start() } }
            }
            controlButton("Zone", "skew") {
                draft = settings.zone.isValid ? settings.zone.points : Zone.starter.points
                draftHistory = []
                editingZone = true
            }
            controlButton("History", "photo.on.rectangle") { showHistory = true }
            controlButton("Settings", "gearshape") { showSettings = true }
        }
        .padding(.bottom, 20)
    }

    private var zoneControls: some View {
        HStack(spacing: 12) {
            controlButton("Undo", "arrow.uturn.backward") { if let last = draftHistory.popLast() { draft = last } }
            controlButton("Reset", "arrow.counterclockwise") {
                draftHistory.append(draft)
                draft = Zone.starter.points
            }
            controlButton("Cancel", "xmark") { editingZone = false }
            controlButton("Save", "checkmark") {
                settings.zone = Zone(points: draft.count >= 3 ? draft : [])
                editingZone = false
            }
        }
        .padding(.bottom, 20)
    }

    private func controlButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Screen dimming (OLED-friendly)

    private var dimOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text(monitor.isRunning ? "CatWatch is watching · tap to wake" : "CatWatch stopped · tap to wake")
                .font(.caption2)
                .foregroundStyle(.gray.opacity(0.5))
                .offset(dimOffset)
        }
        .onTapGesture { wake() }
    }

    private func checkDim() {
        guard settings.dimAfter > 0, !editingZone, !showSettings, !showHistory else { return }
        if dimmed {
            // Nudge the text so it doesn't burn into the OLED panel.
            dimOffset = CGSize(width: .random(in: -120...120), height: .random(in: -300...300))
        } else if Date().timeIntervalSince(lastTouch) > settings.dimAfter {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
            dimmed = true
        }
    }

    private func wake() {
        lastTouch = Date()
        if dimmed {
            dimmed = false
            UIScreen.main.brightness = savedBrightness
        }
    }
}
