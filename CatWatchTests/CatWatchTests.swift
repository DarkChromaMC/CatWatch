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
        XCTAssertEqual(detector.update(thumb: thumb, zone: Zone()), 0)
        let brighter = [UInt8](repeating: 120, count: thumb.count)
        XCTAssertEqual(detector.update(thumb: brighter, zone: Zone()), 1)
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
