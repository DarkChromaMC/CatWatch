import CoreImage
import QuartzCore

struct DetectionConfig {
    var rate: Double = 3
    var minConfidence: Float = 0.5
    var recordTraining = false
    var zone = Zone()
}

struct FrameResult {
    let detections: [CatDetection]
    /// Only rendered when a cat was seen, for snapshots.
    let image: CGImage?
    let size: CGSize
}

/// Runs on the camera's video queue: throttles frames and runs the detector.
final class FrameProcessor: @unchecked Sendable {
    var onResult: ((FrameResult) -> Void)?

    let recorder = TrainingRecorder()
    private let detector = CatDetector()
    private var motion = MotionDetector()
    private var planner = ScanPlanner()
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var _config = DetectionConfig()
    private var lastProcessed: CFTimeInterval = 0

    var config: DetectionConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    func process(_ pixelBuffer: CVPixelBuffer) {
        let cfg = config
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= 1 / max(0.2, cfg.rate) else { return }
        lastProcessed = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let frame = ciImage.extent.size
        let moved = MotionDetector.thumbnail(pixelBuffer).map { motion.update(thumb: $0, zone: cfg.zone) } ?? (0, nil)
        let regions = planner.regions(zone: cfg.zone, frame: frame, motionBox: moved.box, now: now)

        // Detect down to 10% so a weak sighting gets a closer look (and training can keep it);
        // alerts use the user's threshold.
        let all = (try? detector.detect(in: pixelBuffer, minConfidence: min(cfg.minConfidence, 0.1), regions: regions)) ?? []
        if let best = all.max(by: { $0.confidence < $1.confidence }) { planner.noteSighting(best.box, now: now) }
        let detections = all.filter { $0.confidence >= cfg.minConfidence }
        var full: CGImage?
        if cfg.recordTraining {
            let best = all.map(\.confidence).max() ?? 0
            if let name = recorder.frameName(now: now, motion: moved.fraction, isMotion: moved.box != nil, catConfidence: best) {
                full = ciContext.createCGImage(ciImage, from: ciImage.extent)
                if let full { recorder.save(full, name: name, zone: cfg.zone) }
            }
        }
        let image = detections.isEmpty ? nil : (full ?? ciContext.createCGImage(ciImage, from: ciImage.extent))
        onResult?(FrameResult(detections: detections, image: image, size: frame))
    }
}
