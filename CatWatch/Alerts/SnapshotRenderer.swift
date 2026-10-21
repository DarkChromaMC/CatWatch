import UIKit

/// Draws the zone, cat boxes and a timestamp onto a frame and encodes it as JPEG.
enum SnapshotRenderer {
    static func jpeg(from image: CGImage, zone: Zone, detections: [CatDetection], date: Date, maxDimension: CGFloat = 1280) -> Data? {
        let full = CGSize(width: image.width, height: image.height)
        let scale = min(1, maxDimension / max(full.width, full.height))
        let size = CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { ctx in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext

            if zone.isValid {
                let path = UIBezierPath()
                for (i, p) in zone.points.enumerated() {
                    let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.close()
                UIColor.systemRed.withAlphaComponent(0.15).setFill()
                path.fill()
                UIColor.systemRed.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 3
                path.stroke()
            }

            for d in detections {
                let r = CGRect(x: d.box.minX * size.width, y: d.box.minY * size.height,
                               width: d.box.width * size.width, height: d.box.height * size.height)
                cg.setStrokeColor((d.inZone ? UIColor.systemRed : UIColor.systemYellow).cgColor)
                cg.setLineWidth(4)
                cg.stroke(r)
                label("Cat \(Int(d.confidence * 100))%", at: CGPoint(x: r.minX, y: max(0, r.minY - 28)))
            }

            let stamp = date.formatted(date: .abbreviated, time: .standard)
            label(stamp, at: CGPoint(x: 12, y: size.height - 40))
        }
        return rendered.jpegData(compressionQuality: 0.75)
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
