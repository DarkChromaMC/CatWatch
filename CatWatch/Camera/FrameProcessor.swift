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

        // Detect down to 10% so training can keep weak sightings; alerts use the user's threshold.
        let all = (try? detector.detect(in: pixelBuffer, minConfidence: min(cfg.minConfidence, 0.1))) ?? []
        let detections = all.filter { $0.confidence >= cfg.minConfidence }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        var full: CGImage?
        if cfg.recordTraining {
            let moved = MotionDetector.thumbnail(pixelBuffer).map { motion.update(thumb: $0, zone: cfg.zone) } ?? 0
            let best = all.map(\.confidence).max() ?? 0
            if let name = recorder.frameName(now: now, motion: moved, isMotion: moved >= motion.minFraction, catConfidence: best) {
                full = ciContext.createCGImage(ciImage, from: ciImage.extent)
                if let full { recorder.save(full, name: name, zone: cfg.zone) }
            }
        } else {
            motion.reset()
        }
        let image = detections.isEmpty ? nil : (full ?? ciContext.createCGImage(ciImage, from: ciImage.extent))
        onResult?(FrameResult(detections: detections, image: image, size: ciImage.extent.size))
    }
}
