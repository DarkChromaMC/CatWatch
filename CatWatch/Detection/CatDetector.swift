import CoreVideo
import Vision

struct CatDetection: Identifiable, Equatable {
    let id = UUID()
    /// Normalized, origin top-left.
    let box: CGRect
    let confidence: Float
    var inZone: Bool = false
}

/// Wraps Apple's on-device animal classifier (cats and dogs).
final class CatDetector {
    private let request = VNRecognizeAnimalsRequest()

    func detect(in pixelBuffer: CVPixelBuffer, minConfidence: Float) throws -> [CatDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let cat = obs.labels.first(where: { $0.identifier == VNAnimalIdentifier.cat.rawValue }),
                  cat.confidence >= minConfidence else { return nil }
            let b = obs.boundingBox // origin bottom-left
            let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            return CatDetection(box: box, confidence: cat.confidence)
        }
    }
}
