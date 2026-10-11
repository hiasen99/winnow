import Foundation
import AVFoundation
import CoreGraphics

/// Small frames for the timeline's filmstrip, made in the background and kept in memory.
@MainActor
final class ThumbCache: ObservableObject {
    @Published private(set) var version = 0
    private var images: [String: CGImage] = [:]
    private var pending = Set<String>()
    private var queue: [(key: String, angle: Int, time: Double)] = []
    private var generators: [Int: AVAssetImageGenerator] = [:]
    private var assets: [Int: AVAsset] = [:]
    private var running = 0
    private var bumpScheduled = false

    /// Steps the filmstrip time grid snaps to, so zooming reuses frames.
    static let steps: [Double] = [0.25, 0.5, 1, 2, 5, 10, 20, 30, 60, 120, 300]
    static func step(for secondsPerTile: Double) -> Double { steps.first { $0 >= secondsPerTile * 0.9 } ?? 300 }

    func reset() {
        images = [:]; pending = []; queue = []; generators = [:]; assets = [:]
    }

    /// The frame of `angle` at source time `t` (rounded to `step`), or nil while it's being made.
    func image(angle: Int, sourceTime t: Double, step: Double, loaded: LoadedAngle?) -> CGImage? {
        guard let l = loaded, l.video != nil else { return nil }
        let q = max(0, min(l.duration - 0.05, (t / step).rounded() * step))
        let key = "\(angle)|\(Int((q * 100).rounded()))"
        if let img = images[key] { return img }
        if !pending.contains(key) {
            if assets[angle] !== l.asset { assets[angle] = l.asset; generators[angle] = nil }
            pending.insert(key)
            queue.append((key, angle, q))
            if queue.count > 160 {
                for old in queue.prefix(queue.count - 160) { pending.remove(old.key) }
                queue.removeFirst(queue.count - 160)
            }
            pump()
        }
        // something close while waiting
        for s in Self.steps where s > step {
            let qq = max(0, (t / s).rounded() * s)
            if let img = images["\(angle)|\(Int((qq * 100).rounded()))"] { return img }
        }
        return nil
    }

    private func generator(_ angle: Int) -> AVAssetImageGenerator? {
        if let g = generators[angle] { return g }
        guard let a = assets[angle] else { return nil }
        let g = AVAssetImageGenerator(asset: a)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 220, height: 220)
        g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        generators[angle] = g
        return g
    }

    private func pump() {
        while running < 3, let job = queue.popLast() {   // newest first: that's where you're looking
            guard let g = generator(job.angle) else { pending.remove(job.key); continue }
            running += 1
            let time = CMTime(seconds: job.time, preferredTimescale: 600)
            Task { @MainActor [weak self] in
                let img = try? await g.image(at: time).image
                guard let self else { return }
                self.running -= 1
                self.pending.remove(job.key)
                if let img {
                    if self.images.count > 3000 { self.images.removeAll() }
                    self.images[job.key] = img
                    self.scheduleBump()
                }
                self.pump()
            }
        }
    }

    private func scheduleBump() {
        guard !bumpScheduled else { return }
        bumpScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                self?.bumpScheduled = false
                self?.version += 1
            }
        }
    }
}
