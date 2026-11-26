import CoreImage
import QuartzCore

struct DetectionConfig {
    var rate: Double = 3
    var minConfidence: Float = 0.5
    var recordTraining = false
    /// Ask `CatVerifier` before alerting, so hens don't count.
    var ignoreHens = true
    var zone = Zone()
}

struct FrameResult {
    /// Detections at or above the alert threshold.
    let detections: [CatDetection]
    /// Every possible cat down to 10%, for the live view.
    let allDetections: [CatDetection]
    /// The crops the detector looked at this pass.
    let regions: [CGRect]
    /// Average brightness of the frame (0...255), nil if it couldn't be measured.
    let brightness: Double?
    /// Only rendered when a cat was seen (for snapshots) or a browser is watching.
    let image: CGImage?
    let size: CGSize
}

/// Runs on the camera's video queue: throttles frames and runs the detector.
final class FrameProcessor: @unchecked Sendable {
    var onResult: ((FrameResult) -> Void)?
    /// Whether a browser is watching, so every pass needs a picture.
    var wantsPreview: (@Sendable () -> Bool)?

    let recorder = TrainingRecorder()
    private let detector = CatDetector()
    private let verifier = CatVerifier()
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
        process(pixelBuffer, now: CACurrentMediaTime())
    }

    /// `now` is passed in so recorded frames can be replayed through the real pipeline (tests).
    func process(_ pixelBuffer: CVPixelBuffer, now: CFTimeInterval) {
        let cfg = config
        guard now - lastProcessed >= 1 / max(0.2, cfg.rate) else { return }
        lastProcessed = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let frame = ciImage.extent.size
        let thumb = MotionDetector.thumbnail(pixelBuffer)
        let moved = thumb.map { motion.update(thumb: $0, zone: cfg.zone) } ?? (fraction: 0, box: nil, blobs: [])
        let regions = planner.regions(zone: cfg.zone, frame: frame, motionBox: moved.box, now: now, motionBlobs: moved.blobs)

        // Detect down to 10% so a weak sighting gets a closer look (and training can keep it);
        // alerts use the user's threshold.
        var all = (try? detector.detect(in: pixelBuffer, minConfidence: min(cfg.minConfidence, 0.1), regions: regions)) ?? []
        if let best = all.max(by: { $0.confidence < $1.confidence }) { planner.noteSighting(best.box, now: now) }
        // Second opinion only for sightings that would alert (cheap: a few per minute at most).
        if cfg.ignoreHens {
            for i in all.indices where all[i].confidence >= cfg.minConfidence {
                all[i].catScore = verifier.catProbability(in: pixelBuffer, box: all[i].box)
            }
        }
        let detections = all.filter { $0.confidence >= cfg.minConfidence && !$0.isRejected }
        var full: CGImage?
        if cfg.recordTraining {
            let best = all.max { $0.confidence < $1.confidence }
            if let name = recorder.frameName(now: now, motion: moved.fraction, isMotion: moved.box != nil,
                                             catConfidence: best?.confidence ?? 0, catScore: best?.catScore) {
                full = ciContext.createCGImage(ciImage, from: ciImage.extent)
                if let full { recorder.save(full, name: name, zone: cfg.zone) }
            }
        }
        let needImage = !detections.isEmpty || (wantsPreview?() ?? false)
        let image = needImage ? (full ?? ciContext.createCGImage(ciImage, from: ciImage.extent)) : nil
        onResult?(FrameResult(detections: detections, allDetections: all, regions: regions,
                              brightness: thumb.map(DarknessMonitor.averageBrightness), image: image, size: frame))
    }
}
