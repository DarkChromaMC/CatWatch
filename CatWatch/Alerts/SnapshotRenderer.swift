import UIKit

/// Draws the zone, cat boxes and a timestamp onto a frame and encodes it as JPEG.
enum SnapshotRenderer {
    /// - Parameters:
    ///   - minConfidence: weaker detections are drawn grey (live view shows sightings below the alert threshold).
    ///   - regions: zoomed-in crops the detector looked at, drawn as thin outlines (live view only).
    ///   - rotation: clockwise quarter turns so the picture is upright however the phone is mounted.
    ///     Boxes and the zone are in camera coordinates and are turned with it; text stays level.
    static func jpeg(from image: CGImage, zone: Zone, detections: [CatDetection], date: Date, maxDimension: CGFloat = 1280,
                     minConfidence: Float = 0, regions: [CGRect] = [], quality: CGFloat = 0.75, rotation: Int = 0) -> Data? {
        let turns = ((rotation % 4) + 4) % 4
        let full = CGSize(width: image.width, height: image.height)
        let scale = min(1, maxDimension / max(full.width, full.height))
        let drawn = CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())
        let size = turns % 2 == 1 ? CGSize(width: drawn.height, height: drawn.width) : drawn
        func rect(_ r: CGRect) -> CGRect {
            let t = PictureRotation.rect(r, turns: turns)
            return CGRect(x: t.minX * size.width, y: t.minY * size.height, width: t.width * size.width, height: t.height * size.height)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()
            switch turns {
            case 1: cg.translateBy(x: size.width, y: 0); cg.rotate(by: .pi / 2)
            case 2: cg.translateBy(x: size.width, y: size.height); cg.rotate(by: .pi)
            case 3: cg.translateBy(x: 0, y: size.height); cg.rotate(by: -.pi / 2)
            default: break
            }
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: drawn))
            cg.restoreGState()

            if zone.isValid {
                let path = UIBezierPath()
                for (i, p) in zone.points.enumerated() {
                    let q = PictureRotation.point(p, turns: turns)
                    let pt = CGPoint(x: q.x * size.width, y: q.y * size.height)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.close()
                UIColor.systemRed.withAlphaComponent(0.15).setFill()
                path.fill()
                UIColor.systemRed.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 3
                path.stroke()
            }

            cg.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.6).cgColor)
            cg.setLineWidth(1.5)
            for r in regions where r != CGRect(x: 0, y: 0, width: 1, height: 1) {
                cg.stroke(rect(r))
            }

            for d in detections {
                let r = rect(d.box)
                let color = d.confidence < minConfidence || d.isRejected
                    ? UIColor.systemGray : (d.inZone ? UIColor.systemRed : UIColor.systemYellow)
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(4)
                cg.stroke(r)
                let text = d.isRejected ? "Not your cat (\(Int((d.catScore ?? 0) * 100))%)" : "Cat \(Int(d.confidence * 100))%"
                label(text, at: CGPoint(x: r.minX, y: max(0, r.minY - 28)))
            }

            let stamp = date.formatted(date: .abbreviated, time: .standard)
            label(stamp, at: CGPoint(x: 12, y: size.height - 40))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    private static func label(_ text: String, at origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let bounds = CGRect(origin: origin, size: s.size()).insetBy(dx: -6, dy: -3)
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: 4).fill()
        s.draw(at: origin)
    }
}
