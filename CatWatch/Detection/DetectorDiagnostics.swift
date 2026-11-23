import UIKit
import Vision

/// Hidden `/debug` page: runs Apple's animal detector on a known cat frame and on the live
/// picture, reporting every label and any error (the normal path swallows errors).
enum DetectorDiagnostics {
    static func report(live: CGImage?) -> Data {
        var out: [String: Any] = ["os": UIDevice.current.systemVersion]
        let regions = [CGRect(x: 0, y: 0, width: 1, height: 1),
                       CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.3),
                       CGRect(x: 0.2, y: 0.45, width: 0.45, height: 0.25)]
        if let url = Bundle.main.url(forResource: "debug-cat", withExtension: "jpg"),
           let img = UIImage(contentsOfFile: url.path)?.cgImage {
            out["sampleCGImage"] = run(regions) { VNImageRequestHandler(cgImage: img, orientation: .up, options: [:]) }
            if let pb = pixelBuffer(from: img) {
                out["samplePixelBuffer"] = run(regions) { VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]) }
                out["sampleCatDetector"] = (try? CatDetector().detect(in: pb, minConfidence: 0.01, regions: regions))?
                    .map { "\($0.confidence) \($0.box)" } ?? ["threw"]
            }
        } else {
            out["sample"] = "missing"
        }
        if let live {
            let tiles = [CGRect(x: 0, y: 0, width: 1, height: 1)] + stride(from: 0.0, to: 1.0, by: 0.25).flatMap { y in
                stride(from: 0.0, to: 1.0, by: 0.5).map { x in CGRect(x: x, y: y, width: 0.5, height: 0.25) } }
            out["live"] = run(tiles) { VNImageRequestHandler(cgImage: live, orientation: .up, options: [:]) }
            out["liveSize"] = "\(live.width)x\(live.height)"
        }
        return (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func run(_ regions: [CGRect], handler make: () -> VNImageRequestHandler) -> [String] {
        let handler = make()
        let request = VNRecognizeAnimalsRequest()
        var lines = ["revision \(request.revision)"]
        for r in regions {
            request.regionOfInterest = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
            do {
                try handler.perform([request])
                let labels = (request.results ?? []).flatMap { o in o.labels.map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" } }
                lines.append("\(r): \(labels.isEmpty ? "nothing" : labels.joined(separator: ", "))")
            } catch {
                lines.append("\(r): ERROR \(error)")
            }
        }
        return lines
    }

    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pb
    }
}
