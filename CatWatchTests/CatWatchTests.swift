import XCTest
@testable import CatWatch

final class ZoneTests: XCTestCase {
    // Bottom half of the frame.
    let grass = Zone(points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])

    func testContains() {
        XCTAssertTrue(grass.contains(CGPoint(x: 0.5, y: 0.75)))
        XCTAssertFalse(grass.contains(CGPoint(x: 0.5, y: 0.25)))
    }

    func testConcavePolygon() {
        // An L shape: the notch at top-right is outside.
        let l = Zone(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 0.5),
                              CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        XCTAssertTrue(l.contains(CGPoint(x: 0.25, y: 0.25)))
        XCTAssertFalse(l.contains(CGPoint(x: 0.75, y: 0.25)))
        XCTAssertTrue(l.contains(CGPoint(x: 0.75, y: 0.75)))
    }

    func testCatOnDeckIsIgnored() {
        XCTAssertFalse(grass.intersects(box: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.2)))
    }

    func testCatFeetInGrassCounts() {
        // Body mostly above the line, feet just over it.
        XCTAssertTrue(grass.intersects(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)))
    }

    func testEmptyZoneMeansEverywhere() {
        XCTAssertTrue(Zone().intersects(box: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))
    }

    func testInsertionSplitsNearestEdge() {
        // Square; a point just below the bottom edge (index 2 -> 3) goes between them.
        let square = Zone(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
        XCTAssertEqual(square.insertionIndex(for: CGPoint(x: 0.5, y: 1.05)), 3)
        // Near the closing edge (index 3 -> 0) appends at the end.
        XCTAssertEqual(square.insertionIndex(for: CGPoint(x: -0.05, y: 0.5)), 4)
        XCTAssertEqual(Zone(points: [CGPoint(x: 0, y: 0)]).insertionIndex(for: .zero), 1)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(grass)
        XCTAssertEqual(try JSONDecoder().decode(Zone.self, from: data), grass)
    }
}

final class TriggerGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNeedsRequiredHits() {
        var gate = TriggerGate(requiredHits: 2, hitWindow: 4, cooldown: 60)
        XCTAssertFalse(gate.register(hit: true, at: t0))
        XCTAssertTrue(gate.register(hit: true, at: t0 + 1))
    }

    func testHitsExpireOutsideWindow() {
        var gate = TriggerGate(requiredHits: 2, hitWindow: 4, cooldown: 60)
        XCTAssertFalse(gate.register(hit: true, at: t0))
        XCTAssertFalse(gate.register(hit: true, at: t0 + 10))
    }

    func testCooldown() {
        var gate = TriggerGate(requiredHits: 1, hitWindow: 4, cooldown: 60)
        XCTAssertTrue(gate.register(hit: true, at: t0))
        XCTAssertFalse(gate.register(hit: true, at: t0 + 30))
        XCTAssertTrue(gate.register(hit: true, at: t0 + 61))
    }

    func testMissesDoNotFire() {
        var gate = TriggerGate(requiredHits: 1, hitWindow: 4, cooldown: 60)
        XCTAssertFalse(gate.register(hit: false, at: t0))
    }
}

final class MultipartTests: XCTestCase {
    func testBodyContainsFieldsAndFile() {
        let form = MultipartForm(fields: [("token", "abc")],
                                 file: .init(name: "attachment", filename: "a.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3])))
        let text = String(decoding: form.data, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"token\"\r\n\r\nabc\r\n"))
        XCTAssertTrue(text.contains("filename=\"a.jpg\""))
        XCTAssertTrue(text.hasSuffix("--\(form.boundary)--\r\n"))
        XCTAssertTrue(form.contentType.hasSuffix(form.boundary))
    }
}

final class MotionDetectorTests: XCTestCase {
    func testChangedFractionOnlyCountsMaskedCells() {
        let prev: [UInt8] = [100, 100, 100, 100]
        let cur: [UInt8] = [200, 100, 200, 105]
        // Cells 0 and 2 changed a lot; cell 2 is outside the mask; cell 3 changed below threshold.
        let mask = [true, true, false, true]
        XCTAssertEqual(MotionDetector.changedFraction(previous: prev, current: cur, mask: mask, threshold: 22), 1.0 / 3.0, accuracy: 1e-9)
    }

    func testEmptyZoneMasksWholeFrame() {
        XCTAssertTrue(MotionDetector.mask(for: Zone()).allSatisfy { $0 })
        XCTAssertEqual(MotionDetector.mask(for: Zone()).count, MotionDetector.cols * MotionDetector.rows)
    }

    func testFirstFrameIsNotMotion() {
        var detector = MotionDetector()
        let thumb = [UInt8](repeating: 50, count: MotionDetector.cols * MotionDetector.rows)
        XCTAssertEqual(detector.update(thumb: thumb, zone: Zone()).fraction, 0)
        var brighter = thumb
        // Change a 4x4 block of cells near the top-left.
        for r in 2..<6 { for c in 3..<7 { brighter[r * MotionDetector.cols + c] = 200 } }
        let result = detector.update(thumb: brighter, zone: Zone())
        XCTAssertEqual(result.fraction, 16.0 / Double(thumb.count), accuracy: 1e-9)
        let box = try! XCTUnwrap(result.box)
        XCTAssertEqual(box.minX, 3.0 / Double(MotionDetector.cols), accuracy: 1e-9)
        XCTAssertEqual(box.width, 4.0 / Double(MotionDetector.cols), accuracy: 1e-9)
        XCTAssertEqual(box.minY, 2.0 / Double(MotionDetector.rows), accuracy: 1e-9)
    }

    func testRecorderRateLimits() {
        let recorder = TrainingRecorder()
        recorder.deleteAll()
        XCTAssertNotNil(recorder.frameName(now: 1000, motion: 0.01, isMotion: true, catConfidence: 0))
        XCTAssertNil(recorder.frameName(now: 1001, motion: 0.01, isMotion: true, catConfidence: 0))
        XCTAssertNotNil(recorder.frameName(now: 1002.5, motion: 0, isMotion: false, catConfidence: 0.3))
        recorder.deleteAll()
    }
}

final class TrainingBudgetTests: XCTestCase {
    func testWindyHourSlowsDown() {
        let recorder = TrainingRecorder()
        recorder.deleteAll()
        var t: CFTimeInterval = 10_000
        for _ in 0..<TrainingRecorder.hourlyBudget {
            XCTAssertNotNil(recorder.frameName(now: t, motion: 0.01, isMotion: true, catConfidence: 0))
            t += 3
        }
        // Over budget: plain motion waits a minute, a possible cat still gets through.
        XCTAssertNil(recorder.frameName(now: t, motion: 0.01, isMotion: true, catConfidence: 0))
        XCTAssertNotNil(recorder.frameName(now: t, motion: 0, isMotion: false, catConfidence: 0.2))
        XCTAssertNotNil(recorder.frameName(now: t + 61, motion: 0.01, isMotion: true, catConfidence: 0))
        recorder.deleteAll()
    }
}

final class ScanPlannerTests: XCTestCase {
    let frame = CGSize(width: 1080, height: 1920)

    func testSquareAroundSmallBoxIsAtLeastATileAndInsideFrame() {
        let r = ScanPlanner.square(around: CGRect(x: 0.98, y: 0.99, width: 0.01, height: 0.005), frame: frame)
        XCTAssertEqual(r.width * frame.width, 1080 * ScanPlanner.tileFraction, accuracy: 0.5)
        XCTAssertEqual(r.width * frame.width, r.height * frame.height, accuracy: 0.5) // square in pixels
        XCTAssertLessThanOrEqual(r.maxX, 1.0001)
        XCTAssertLessThanOrEqual(r.maxY, 1.0001)
    }

    func testTilesCoverTheZone() {
        let area = CGRect(x: 0, y: 0.5, width: 1, height: 0.4)
        let tiles = ScanPlanner.tiles(covering: area, frame: frame)
        XCTAssertGreaterThan(tiles.count, 1)
        for p in [CGPoint(x: 0.01, y: 0.51), CGPoint(x: 0.99, y: 0.89), CGPoint(x: 0.5, y: 0.7)] {
            XCTAssertTrue(tiles.contains { $0.contains(p) }, "\(p) not covered")
        }
    }

    func testRegionsRotateTilesAndFocusOnSightings() {
        var planner = ScanPlanner()
        let zone = Zone(points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 0.9), CGPoint(x: 0, y: 0.9)])
        let first = planner.regions(zone: zone, frame: frame, motionBox: nil, now: 0)
        let second = planner.regions(zone: zone, frame: frame, motionBox: nil, now: 0.3)
        XCTAssertEqual(first.first, ScanPlanner.whole)
        XCTAssertEqual(first.count, 2)
        XCTAssertNotEqual(first[1], second[1])
        planner.noteSighting(CGRect(x: 0.2, y: 0.2, width: 0.05, height: 0.03), now: 1)
        XCTAssertEqual(planner.regions(zone: zone, frame: frame, motionBox: nil, now: 2).count, 3)
        XCTAssertEqual(planner.regions(zone: zone, frame: frame, motionBox: nil, now: 7).count, 2)
    }

    func testMergeKeepsMostConfidentOfOverlappingBoxes() {
        let a = CatDetection(box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), confidence: 0.4)
        let b = CatDetection(box: CGRect(x: 0.12, y: 0.12, width: 0.1, height: 0.1), confidence: 0.8)
        let c = CatDetection(box: CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1), confidence: 0.3)
        let merged = CatDetector.mergeOverlapping([a, b, c])
        XCTAssertEqual(merged.map(\.confidence), [0.8, 0.3])
    }
}

final class LiveServerTests: XCTestCase {
    func body(_ response: Data) -> String { String(decoding: response, as: UTF8.self) }

    func testPinRequired() {
        let server = LiveServer()
        server.pin = "4321"
        XCTAssertTrue(body(server.respond(to: "/")).contains("Enter the PIN"))
        XCTAssertTrue(body(server.respond(to: "/status.json?pin=1111")).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(body(server.respond(to: "/?pin=4321")).contains("Recent alerts"))
    }

    func testFrameAndViewerTracking() {
        let server = LiveServer()
        server.pin = "1"
        XCTAssertFalse(server.hasViewer)
        XCTAssertTrue(body(server.respond(to: "/frame.jpg?pin=1")).hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue(server.hasViewer)
        server.update(frame: Data([0xFF, 0xD8]))
        let r = server.respond(to: "/frame.jpg?pin=1")
        XCTAssertTrue(body(r).hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(r.suffix(2), Data([0xFF, 0xD8]))
        XCTAssertTrue(body(server.respond(to: "/nope?pin=1")).hasPrefix("HTTP/1.1 404"))
    }
}

final class DarknessMonitorTests: XCTestCase {
    func testNeedsToStayDarkBeforeSwitching() {
        var m = DarknessMonitor()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertNil(m.update(brightness: 10, at: t0))
        XCTAssertNil(m.update(brightness: 10, at: t0.addingTimeInterval(60)))
        // A brief bright frame (headlight) restarts the wait.
        XCTAssertNil(m.update(brightness: 120, at: t0.addingTimeInterval(90)))
        XCTAssertNil(m.update(brightness: 10, at: t0.addingTimeInterval(100)))
        XCTAssertNil(m.update(brightness: 10, at: t0.addingTimeInterval(200)))
        XCTAssertEqual(m.update(brightness: 10, at: t0.addingTimeInterval(221)), true)
        XCTAssertTrue(m.isDark)
    }

    func testHysteresisBand() {
        var m = DarknessMonitor()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = m.update(brightness: 5, at: t0)
        XCTAssertEqual(m.update(brightness: 5, at: t0.addingTimeInterval(121)), true)
        // Between the thresholds: stays dark.
        _ = m.update(brightness: 35, at: t0.addingTimeInterval(130))
        XCTAssertNil(m.update(brightness: 35, at: t0.addingTimeInterval(400)))
        _ = m.update(brightness: 80, at: t0.addingTimeInterval(500))
        XCTAssertEqual(m.update(brightness: 80, at: t0.addingTimeInterval(621)), false)
    }

    func testAverageBrightness() {
        XCTAssertEqual(DarknessMonitor.averageBrightness([0, 100, 200]), 100)
    }

    // MARK: - Hen filter

    func testVerifierCropIsSquareAroundBox() {
        let frame = CGSize(width: 1080, height: 1920)
        let box = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05) // 108 x 96 px
        let r = CatVerifier.cropRegion(box: box, frame: frame)
        XCTAssertEqual(r.width * 1080, r.height * 1920, accuracy: 0.5)   // square in pixels
        XCTAssertEqual(r.width * 1080, 108 * 1.6, accuracy: 0.5)
        XCTAssertEqual(r.midX, box.midX, accuracy: 0.001)
        XCTAssertEqual(r.midY, box.midY, accuracy: 0.001)
    }

    func testVerifierCropHasMinimumSizeAndStaysInFrame() {
        let frame = CGSize(width: 1080, height: 1920)
        let tiny = CatVerifier.cropRegion(box: CGRect(x: 0.99, y: 0.0, width: 0.01, height: 0.005), frame: frame)
        XCTAssertEqual(tiny.width * 1080, 80, accuracy: 0.5)
        XCTAssertLessThanOrEqual(tiny.maxX, 1.0001)
        XCTAssertGreaterThanOrEqual(tiny.minY, 0)
        let huge = CatVerifier.cropRegion(box: CGRect(x: 0, y: 0, width: 1, height: 1), frame: frame)
        XCTAssertEqual(huge.width, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(huge.maxY, 1.0001)
    }

    func testRejectedOnlyWhenVerifierSaysNotCat() {
        var d = CatDetection(box: .zero, confidence: 0.6)
        XCTAssertFalse(d.isRejected)            // not checked: never blocked
        d.catScore = 0.05
        XCTAssertTrue(d.isRejected)
        d.catScore = 0.9
        XCTAssertFalse(d.isRejected)
    }

    func testFrameNameIncludesVerifierScore() {
        let r = TrainingRecorder()
        r.deleteAll(); defer { r.deleteAll() }
        let name = r.frameName(now: 1000, motion: 0.01, isMotion: true, catConfidence: 0.6, catScore: 0.12)
        XCTAssertNotNil(name)
        XCTAssertTrue(name!.hasSuffix("_m10_c60_v12.jpg"), name!)
    }

    // MARK: - Picture rotation

    func testGravityToQuarterTurns() {
        XCTAssertEqual(OrientationMonitor.quarterTurns(gravityX: 0, gravityY: -1), 0)
        XCTAssertEqual(OrientationMonitor.quarterTurns(gravityX: -1, gravityY: 0.1), 3)
        XCTAssertEqual(OrientationMonitor.quarterTurns(gravityX: 0.95, gravityY: 0), 1)
        XCTAssertEqual(OrientationMonitor.quarterTurns(gravityX: 0, gravityY: 0.9), 2)
        XCTAssertNil(OrientationMonitor.quarterTurns(gravityX: 0.1, gravityY: 0.1)) // lying flat
    }

    func testRotationGeometry() {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        XCTAssertEqual(PictureRotation.point(CGPoint(x: 0, y: 0), turns: 1), CGPoint(x: 1, y: 0))
        XCTAssertEqual(PictureRotation.point(CGPoint(x: 0, y: 0), turns: 3), CGPoint(x: 0, y: 1))
        let r1 = PictureRotation.rect(r, turns: 1)
        XCTAssertEqual(r1.minX, 0.7, accuracy: 1e-9); XCTAssertEqual(r1.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r1.width, 0.1, accuracy: 1e-9); XCTAssertEqual(r1.height, 0.3, accuracy: 1e-9)
        for t in 0..<4 {   // four turns of one quarter = back where it started
            var x = r
            for _ in 0..<4 { x = PictureRotation.rect(x, turns: 1) }
            XCTAssertEqual(x.minX, r.minX, accuracy: 1e-9, "\(t)")
        }
        XCTAssertEqual(PictureRotation.rect(PictureRotation.rect(r, turns: 1), turns: 3).minY, r.minY, accuracy: 1e-9)
    }
}
