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
