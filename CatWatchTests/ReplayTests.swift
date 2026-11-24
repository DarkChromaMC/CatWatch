import XCTest
@testable import CatWatch

/// Feeds real recorded camera frames through the app's whole detection pipeline on the device:
/// motion → zoomed crops → Apple's detector → hen filter → zone → alert rule.
///
/// The frames are photos of the user's garden, so they are NOT in git (CatWatchTests/Replay/ is
/// gitignored). Without them (e.g. on GitHub) these tests skip.
final class ReplayTests: XCTestCase {
    struct Outcome { var alerts = 0; var framesWithCat = 0; var frames = 0; var notes: [String] = [] }

    func frames(_ prefix: String) -> [URL] {
        (Bundle(for: Self.self).urls(forResourcesWithExtension: "jpg", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix + "_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var zone: Zone {
        guard let url = Bundle(for: Self.self).url(forResource: "replay_zone", withExtension: "json"),
              let data = try? Data(contentsOf: url), let z = try? JSONDecoder().decode(Zone.self, from: data) else { return Zone() }
        return z
    }

    /// Each frame is shown to the camera pipeline for ~2 s at the app's 3 checks a second,
    /// like a cat standing still between recorded frames.
    func replay(_ urls: [URL], checksPerFrame: Int = 6) throws -> Outcome {
        let processor = FrameProcessor()
        processor.config = DetectionConfig(rate: 3, minConfidence: Float(0.5), recordTraining: false, ignoreHens: true, zone: zone)
        var gate = TriggerGate(requiredHits: 1)
        var outcome = Outcome()
        var latest: FrameResult?
        processor.onResult = { latest = $0 }
        var t: CFTimeInterval = 1000
        for url in urls {
            guard let image = UIImage(contentsOfFile: url.path)?.cgImage,
                  let buffer = DetectorDiagnostics.pixelBuffer(from: image) else { throw XCTSkip("can't read \(url.lastPathComponent)") }
            outcome.frames += 1
            var seen = false
            for _ in 0..<checksPerFrame {
                t += 1.0 / 3
                latest = nil
                processor.process(buffer, now: t)
                guard let result = latest else { continue }
                let inZone = result.detections.filter { zone.intersects(box: $0.box) }
                if !inZone.isEmpty { seen = true }
                for d in result.allDetections where d.confidence >= 0.3 {
                    outcome.notes.append("\(url.lastPathComponent) det \(String(format: "%.2f", d.confidence)) v=\(d.catScore.map { String(format: "%.3f", $0) } ?? "-") box=\(String(format: "%.2f,%.2f %.2fx%.2f", d.box.minX, d.box.minY, d.box.width, d.box.height)) zone=\(zone.intersects(box: d.box))")
                }
                if gate.register(hit: !inZone.isEmpty, at: Date(timeIntervalSince1970: t)) { outcome.alerts += 1 }
            }
            if seen { outcome.framesWithCat += 1 }
        }
        return outcome
    }

    func testRealCatFramesAlert() throws {
        let cat = frames("cat")
        try XCTSkipIf(cat.isEmpty, "Replay frames not present (kept out of git).")
        let o = try replay(cat)
        print("REPLAY cat: \(o.framesWithCat)/\(o.frames) frames spotted the cat, \(o.alerts) alert(s).\n" + Set(o.notes).sorted().joined(separator: "\n"))
        XCTAssertGreaterThan(o.alerts, 0, "The cat at the feeder never caused an alert.")
        XCTAssertGreaterThanOrEqual(o.framesWithCat, 4, "Spotted the cat in fewer frames than v0.1.21 did (4 of 9; 3 are blurred running/leaving shots).")
    }

    func testHenOnlyFramesDoNotAlert() throws {
        let hens = frames("hen") + frames("hen2") + frames("hen3")
        try XCTSkipIf(hens.isEmpty, "Replay frames not present (kept out of git).")
        let o = try replay(hens)
        print("REPLAY hens: \(o.framesWithCat)/\(o.frames) frames passed as cat, \(o.alerts) alert(s).\n" + Set(o.notes).sorted().joined(separator: "\n"))
        XCTAssertEqual(o.alerts, 0, "Hens caused alerts: \(o.framesWithCat) frames passed as cat.")
    }
}
