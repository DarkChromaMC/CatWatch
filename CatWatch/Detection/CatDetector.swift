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
///
/// The classifier shrinks whatever it looks at to a small input, so a cat that is only a
/// sliver of the frame scores 0%. Passing zoomed-in `regions` (crops of the same frame)
/// lets it see a distant cat at full detail: a quarter-width cat goes from 0% to ~80%.
final class CatDetector {
    private let request = VNRecognizeAnimalsRequest()

    /// - Parameter regions: normalized, origin top-left. `nil` entries are not allowed; pass
    ///   `CGRect(x: 0, y: 0, width: 1, height: 1)` for the whole frame.
    func detect(in pixelBuffer: CVPixelBuffer, minConfidence: Float,
                regions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1)]) throws -> [CatDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var found: [CatDetection] = []
        for region in regions {
            // Vision wants origin bottom-left; result boxes come back in whole-image coordinates.
            request.regionOfInterest = CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height)
            try handler.perform([request])
            for obs in request.results ?? [] {
                guard let cat = obs.labels.first(where: { $0.identifier == VNAnimalIdentifier.cat.rawValue }),
                      cat.confidence >= minConfidence else { continue }
                let b = obs.boundingBox
                found.append(CatDetection(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                                          confidence: cat.confidence))
            }
        }
        return Self.mergeOverlapping(found)
    }

    /// The same cat seen in several crops: keep the most confident box of each overlapping group.
    static func mergeOverlapping(_ detections: [CatDetection]) -> [CatDetection] {
        var kept: [CatDetection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { k in
                let i = k.box.intersection(d.box)
                guard !i.isNull else { return false }
                let smaller = min(k.box.width * k.box.height, d.box.width * d.box.height)
                return smaller > 0 && (i.width * i.height) / smaller > 0.5
            }
            if !duplicate { kept.append(d) }
        }
        return kept
    }
}
