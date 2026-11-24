import CoreML
import CoreVideo
import Vision

/// Second opinion on each sighting: a small model trained on this garden's camera that tells
/// the user's Siamese from the hens (and grass, feeders, birds) Apple's detector calls "cat".
///
/// v2 (2026-11-22): trained on two evenings of camera frames incl. dusk (hens etc. = not cat),
    /// 8 real frames of the cat at the feeder, plus the cat
/// cut out of the user's photos and pasted into those frames at camera size.
final class CatVerifier {
    /// Below this chance of being the cat, a sighting is treated as a hen and no alert is sent.
    /// 0.85 (was 0.3): replay on the phone let 2 hens through at 0.78 and 0.44 while the real
    /// cat always scored 1.00; held-out synthetic cats kept 98.7% at 0.3 and at 0.85 alike.
    static let threshold: Float = 0.85

    private let model: VNCoreMLModel?

    init() {
        if let url = Bundle.main.url(forResource: "CatOrNot", withExtension: "mlmodelc"),
           let ml = try? MLModel(contentsOf: url) {
            model = try? VNCoreMLModel(for: ml)
        } else {
            model = nil
        }
    }

    var isAvailable: Bool { model != nil }

    /// Chance (0...1) that `box` shows the cat, or nil if the model couldn't run (then don't block).
    func catProbability(in pixelBuffer: CVPixelBuffer, box: CGRect) -> Float? {
        guard let model else { return nil }
        let frame = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let crop = Self.cropRegion(box: box, frame: frame)
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        // Vision wants origin bottom-left.
        request.regionOfInterest = CGRect(x: crop.minX, y: 1 - crop.maxY, width: crop.width, height: crop.height)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results as? [VNClassificationObservation] else { return nil }
        return results.first { $0.identifier == "cat" }?.confidence
    }

    /// The square the model was trained on: 1.6x the box's longer side (at least 80 px of a
    /// 1080-wide frame), centred on the box and kept inside the frame. Normalized, origin top-left.
    static func cropRegion(box: CGRect, frame: CGSize) -> CGRect {
        let W = frame.width, H = frame.height
        guard W > 0, H > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let minSide = 80 / 1080 * W
        var side = max(box.width * W, box.height * H) * 1.6
        side = min(max(side, minSide), min(W, H))
        let cx = box.midX * W, cy = box.midY * H
        let x = min(max(cx - side / 2, 0), W - side)
        let y = min(max(cy - side / 2, 0), H - side)
        return CGRect(x: x / W, y: y / H, width: side / W, height: side / H)
    }
}
