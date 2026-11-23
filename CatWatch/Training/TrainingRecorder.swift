import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves camera frames for training a custom cat model: whenever something moves in the
/// zone or Apple's detector sees a possible cat (at most every 2 s, slower when it's windy), plus a baseline every
/// 10 quiet minutes. Frames land in Documents/TrainingFrames, visible in the Files app.
final class TrainingRecorder: @unchecked Sendable {
    static let maxFrames = 3000
    static let minInterval: CFTimeInterval = 2
    static let baselineInterval: CFTimeInterval = 600
    /// Windy grass can look like motion all day; past this many frames in an hour, keep
    /// only possible cats and one frame a minute.
    static let hourlyBudget = 400
    static let busyInterval: CFTimeInterval = 60

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrainingFrames", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "catwatch.training", qos: .utility)
    private let lock = NSLock()
    private var lastSaved: CFTimeInterval = -.infinity
    private var lastBaseline: CFTimeInterval = -.infinity
    private var recentSaves: [CFTimeInterval] = []
    private var count = TrainingRecorder.frameCount()
    private var savedZone: Zone?

    static func frameCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jpg") }.count
    }

    /// Returns a file name when this frame should be kept. Called on the video queue.
    func frameName(now: CFTimeInterval, motion: Double, isMotion: Bool, catConfidence: Float, catScore: Float? = nil) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard count < Self.maxFrames, now - lastSaved >= Self.minInterval else { return nil }
        recentSaves.removeAll { now - $0 > 3600 }
        let busy = recentSaves.count >= Self.hourlyBudget
        let tag: String
        if catConfidence > 0 || (isMotion && (!busy || now - lastSaved >= Self.busyInterval)) {
            tag = "m\(Int((motion * 1000).rounded()))_c\(Int((catConfidence * 100).rounded()))"
                + (catScore.map { "_v\(Int(($0 * 100).rounded()))" } ?? "")
        } else if now - lastBaseline >= Self.baselineInterval {
            tag = "base"
        } else {
            return nil
        }
        // Any saved frame resets the baseline timer, so baselines only fill quiet stretches.
        lastSaved = now
        lastBaseline = now
        recentSaves.append(now)
        count += 1
        return "\(Self.stamp.string(from: Date()))_\(tag).jpg"
    }

    func save(_ image: CGImage, name: String, zone: Zone) {
        queue.async { [self] in
            let dir = Self.directory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if savedZone != zone, let data = try? JSONEncoder().encode(zone) {
                try? data.write(to: dir.appendingPathComponent("zone.json"))
                savedZone = zone
            }
            let url = dir.appendingPathComponent(name) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    func deleteAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: Self.directory)
            savedZone = nil
        }
        lock.lock(); count = 0; lock.unlock()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()
}
