import CoreImage
import QuartzCore

struct DetectionConfig {
    var rate: Double = 3
    var minConfidence: Float = 0.5
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

    private let detector = CatDetector()
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

        let detections = (try? detector.detect(in: pixelBuffer, minConfidence: cfg.minConfidence)) ?? []
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let image = detections.isEmpty ? nil : ciContext.createCGImage(ciImage, from: ciImage.extent)
        onResult?(FrameResult(detections: detections, image: image, size: ciImage.extent.size))
    }
}
