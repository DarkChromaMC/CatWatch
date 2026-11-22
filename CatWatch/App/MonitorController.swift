import AVFoundation
import Combine
import UIKit

/// Ties the camera, detector, trigger gate, history and alerts together.
@MainActor
final class MonitorController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var detections: [CatDetection] = []
    @Published private(set) var videoSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var lastAlertAt: Date?
    @Published private(set) var lastAlertError: String?
    /// The picture is too dark for the detector to see a cat.
    @Published private(set) var isTooDark = false
    @Published var errorMessage: String?

    let camera = CameraService()
    let web = LiveServer()
    private var lastStatusAt = Date.distantPast
    private var darkness = DarknessMonitor()
    private let processor = FrameProcessor()
    private let settings: AppSettings
    private let store: EventStore
    private var gate = TriggerGate()
    private var watchdog: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastHealthAlert: [String: Date] = [:]
    private var wasRunningBeforeBackground = false

    init(settings: AppSettings, store: EventStore) {
        self.settings = settings
        self.store = store

        processor.onResult = { @Sendable [weak self] result in
            Task { @MainActor in self?.handle(result) }
        }
        camera.onFrame = { @Sendable [processor] buffer in processor.process(buffer) }
        processor.wantsPreview = { @Sendable [web] in web.hasViewer }
        web.setEventsDirectory(store.directoryURL)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        applySettings()
        observeDevice()
    }

    // MARK: - Control

    func start() async {
        guard !isRunning else { return }
        guard await CameraService.requestAccess() else {
            errorMessage = CameraError.notAuthorized.localizedDescription
            return
        }
        let camera = self.camera
        let ultraWide = settings.useUltraWide
        let error: Error? = await withCheckedContinuation { cont in
            camera.start(useUltraWide: ultraWide) { @Sendable in cont.resume(returning: $0) }
        }
        if let error {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        isRunning = true
        lastFrameAt = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        startWatchdog()
    }

    func stop() {
        camera.stop()
        isRunning = false
        detections = []
        if web.isRunning { publishStatus() }
        watchdog?.invalidate()
        watchdog = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Restart the camera, e.g. after switching lenses.
    func restart() async {
        guard isRunning else { return }
        stop()
        await start()
    }

    func sendTestAlert() async -> String? {
        do {
            try await settings.pushover.send(title: "CatWatch test", message: "Pushover is set up correctly. Real alerts sound like this. 🐈",
                                              priority: settings.pushoverPriority, sound: settings.sound)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Darkness

    /// Always sent (even with health alerts off): a silent night would look like "no cat".
    private func darknessChanged(_ dark: Bool) {
        isTooDark = dark
        let message = dark
            ? "It's too dark for CatWatch to see, so it can't spot your cat. It will tell you when it can see again."
            : "CatWatch can see again and is watching for your cat."
        let client = settings.pushover
        let sound = settings.sound
        Task { try? await client.send(title: dark ? "🌙 CatWatch" : "☀️ CatWatch", message: message, priority: .normal, sound: sound) }
        if web.isRunning { publishStatus() }
    }

    // MARK: - Web view

    private func updateWebServer() {
        web.pin = settings.webPin
        if settings.webViewEnabled {
            if !web.isRunning {
                do { try web.start() } catch { errorMessage = "Web view could not start (\(error.localizedDescription))" }
            }
            publishStatus()
        } else if web.isRunning {
            web.stop()
        }
    }

    private func publishLiveView(_ result: FrameResult, zone: Zone) {
        if Date().timeIntervalSince(lastStatusAt) >= 1 { publishStatus() }
        guard web.hasViewer, let image = result.image else { return }
        let all = result.allDetections.map { d -> CatDetection in
            var d = d
            d.inZone = zone.intersects(box: d.box)
            return d
        }
        let minConfidence = Float(settings.minConfidence)
        let web = self.web
        Task.detached(priority: .utility) {
            if let jpeg = SnapshotRenderer.jpeg(from: image, zone: zone, detections: all, date: Date(), maxDimension: 900,
                                                minConfidence: minConfidence, regions: result.regions, quality: 0.6) {
                web.update(frame: jpeg)
            }
        }
    }

    private func publishStatus() {
        lastStatusAt = Date()
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let best = detections.map(\.confidence).max()
        let status: [String: Any] = [
            "running": isRunning,
            "dark": isTooDark,
            "cats": best.map { Int($0 * 100) } ?? 0,
            "battery": level < 0 ? "?" : "\(Int(level * 100))%",
            "charging": state == .charging || state == .full,
            "hot": ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
            "lastAlert": lastAlertAt.map { Date().timeIntervalSince($0) as Any } ?? NSNull(),
            "events": store.events.prefix(12).map { e -> [String: Any] in
                ["id": e.id.uuidString, "date": ISO8601DateFormatter().string(from: e.date),
                 "confidence": Int(e.confidence * 100), "sent": e.alertSent]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status) { web.update(status: data) }
    }

    // MARK: - Training frames

    func deleteTrainingFrames() {
        processor.recorder.deleteAll()
    }

    // MARK: - Frames

    private func applySettings() {
        // objectWillChange fires before the new value lands; read on the next run loop turn.
        DispatchQueue.main.async { [self] in
            processor.config = DetectionConfig(rate: settings.detectionRate, minConfidence: Float(settings.minConfidence),
                                               recordTraining: settings.recordTraining, ignoreHens: settings.ignoreHens,
                                               zone: settings.zone)
            gate.requiredHits = settings.requiredHits
            gate.cooldown = settings.cooldown
            updateWebServer()
        }
    }

    private func handle(_ result: FrameResult) {
        guard isRunning else { return }
        lastFrameAt = Date()
        if result.size != videoSize { videoSize = result.size }

        let zone = settings.zone
        let marked = result.detections.map { d -> CatDetection in
            var d = d
            d.inZone = zone.intersects(box: d.box)
            return d
        }
        detections = marked
        if let brightness = result.brightness, let dark = darkness.update(brightness: brightness, at: Date()) {
            darknessChanged(dark)
        }
        if web.isRunning { publishLiveView(result, zone: zone) }

        let inZone = marked.filter(\.inZone)
        guard gate.register(hit: !inZone.isEmpty, at: Date()), let image = result.image else { return }
        let best = inZone.max { $0.confidence < $1.confidence }!
        Task { await fireAlert(image: image, detections: marked, confidence: best.confidence) }
    }

    private func fireAlert(image: CGImage, detections: [CatDetection], confidence: Float) async {
        let zone = settings.zone
        let now = Date()
        let jpeg = await Task.detached(priority: .userInitiated) {
            SnapshotRenderer.jpeg(from: image, zone: zone, detections: detections, date: now)
        }.value
        guard let jpeg else { return }

        let event = store.add(confidence: confidence, jpeg: jpeg)
        lastAlertAt = now
        let message = zone.isValid
            ? "Cat in the no-go zone (\(Int(confidence * 100))% sure)."
            : "Cat spotted (\(Int(confidence * 100))% sure)."
        do {
            try await settings.pushover.send(title: "🐈 CatWatch", message: message,
                                              priority: settings.pushoverPriority, sound: settings.sound, jpeg: jpeg)
            store.markAlert(event.id, sent: true, error: nil)
            lastAlertError = nil
        } catch {
            store.markAlert(event.id, sent: false, error: error.localizedDescription)
            lastAlertError = error.localizedDescription
        }
    }

    // MARK: - Health

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkFrames() }
        }
    }

    private func checkFrames() async {
        guard isRunning, let lastFrameAt, Date().timeIntervalSince(lastFrameAt) > 30 else { return }
        healthAlert("camera", "Camera stopped delivering frames. Trying to restart it.")
        await restart()
    }

    private func observeDevice() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default

        nc.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning, UIDevice.current.batteryState == .unplugged else { return }
                self.healthAlert("unplugged", "The CatWatch phone was unplugged (battery \(Self.batteryPercent)).")
            }
            .store(in: &cancellables)

        nc.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let level = UIDevice.current.batteryLevel
                guard let self, self.isRunning, level >= 0, level < 0.2,
                      UIDevice.current.batteryState == .unplugged else { return }
                self.healthAlert("battery", "CatWatch battery is low (\(Self.batteryPercent)).")
            }
            .store(in: &cancellables)

        nc.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                switch ProcessInfo.processInfo.thermalState {
                case .serious, .critical:
                    self.processor.config.rate = 1
                    self.healthAlert("thermal", "CatWatch phone is overheating; detection slowed to 1/sec. Move it out of direct sun.")
                default:
                    self.applySettings()
                }
            }
            .store(in: &cancellables)

        nc.publisher(for: AVCaptureSession.runtimeErrorNotification, object: camera.session)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.healthAlert("camera", "Camera error. Restarting.")
                Task { await self.restart() }
            }
            .store(in: &cancellables)
    }

    func scenePhaseChanged(active: Bool) {
        if active {
            if wasRunningBeforeBackground {
                wasRunningBeforeBackground = false
                Task { await start() }
            }
        } else if isRunning {
            wasRunningBeforeBackground = true
            healthAlert("background", "CatWatch left the foreground, so monitoring is paused. Reopen the app (tip: use Guided Access).")
            stop()
        }
    }

    private func healthAlert(_ kind: String, _ message: String) {
        guard settings.healthAlerts else { return }
        if let last = lastHealthAlert[kind], Date().timeIntervalSince(last) < 30 * 60 { return }
        lastHealthAlert[kind] = Date()
        let client = settings.pushover
        let sound = settings.sound
        let task = UIApplication.shared.beginBackgroundTask(withName: "health-alert")
        Task {
            try? await client.send(title: "⚠️ CatWatch", message: message, priority: .normal, sound: sound)
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    private static var batteryPercent: String {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "unknown" : "\(Int(level * 100))%"
    }
}
