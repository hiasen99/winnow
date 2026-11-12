import Foundation
import CoreGraphics

// MARK: - Follow a point (step fol1)
//
// Pick something in the picture (a face, a logo, the corner of a window) and the framing moves with it,
// so it stays in the same place in the finished frame while the camera drifts, pans or zooms.
// All positions are in the camera picture, 0…1, top-left origin, y down (the same space as Framing.x / y).

/// Where you pointed: a moment of the recording and a box around the thing to follow.
struct FollowPick: Codable, Hashable {
    /// master time
    var time: Double
    /// x, y, width, height in the camera picture (0…1, top-left origin)
    var box: [Double]

    var rect: CGRect {
        guard box.count == 4 else { return CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1) }
        return CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
    }
    init(time: Double, rect: CGRect) {
        self.time = time
        box = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)].map { ($0 * 100_000).rounded() / 100_000 }
    }
}

/// Where the tracker found it in one frame: centre and size (√(w·h)) in the camera picture. t = master time.
struct FollowSample: Codable, Hashable {
    var t: Double
    var x: Double
    var y: Double
    var s: Double
}

/// One pick and everything tracked from it (backwards to where the previous pick ends, forwards until the
/// next pick, the end of the stretch, or until the tracker loses it).
struct FollowRun: Codable, Hashable {
    var pick: FollowPick
    /// sorted by time
    var samples: [FollowSample]
    /// the tracker lost it here going forwards (samples stop just before)
    var lostAt: Double? = nil
    /// …and here going backwards
    var lostBackAt: Double? = nil
    /// how it was followed: "face" (landmarks on a face) or "scene" (the picture around the point)
    var kind: String? = nil

    var first: Double { samples.first?.t ?? pick.time }
    var last: Double { samples.last?.t ?? pick.time }
}

/// Framing that follows a point, for camera `angle` over master [start, end].
struct FollowTrack: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var angle: Int
    var start: Double
    var end: Double
    /// sorted by pick time; their tracked stretches don't overlap
    var runs: [FollowRun] = []
    /// Keep it the same size too: when the camera zooms in, the framing zooms out to match (and the other way).
    var lockSize: Bool? = nil
    /// Zoom in just enough that the frame never runs off the edge of the camera picture (nil = on).
    var autoZoom: Bool? = nil
    /// 0 = locked tight, 1 = a loose, smooth follow (nil = 0.1)
    var smoothing: Double? = nil

    var locksSize: Bool { lockSize ?? false }
    var zoomsToFit: Bool { autoZoom ?? true }
    var smooth: Double { min(1, max(0, smoothing ?? 0.1)) }
    func contains(_ t: Double) -> Bool { t >= start - 1e-4 && t <= end + 1e-4 }
}

extension Clip {
    /// The follow that drives the shot of camera `angle` covering master [start, end), if any (the newest wins).
    func followIndex(start: Double, end: Double, angle: Int) -> Int? {
        guard let list = follows else { return nil }
        let mid = (start + end) / 2
        return list.indices.last { list[$0].angle == angle && !list[$0].runs.isEmpty && list[$0].contains(mid) }
    }
    func follow(forShotFrom start: Double, to end: Double, angle: Int) -> FollowTrack? {
        followIndex(start: start, end: end, angle: angle).flatMap { follows?[$0] }
    }
}

/// The framing at one moment of a followed shot.
struct FollowFrame {
    var t: Double           // master
    var framing: Framing
    var feature: CGPoint    // where the followed thing is in the camera picture
    var size: Double        // its size (√(w·h)) in the camera picture
    var held: Bool          // the tracker didn't see it here (lost, or before the first pick): the framing holds still
    var edge: Bool          // the frame had to stop at the edge of the camera picture
}

/// A followed shot, frame by frame.
struct FollowPath {
    var frames: [FollowFrame]
    /// extra zoom used so the frame never meets the edge (1 = none)
    var boost: Double
    /// stretches (master) where it couldn't be followed / where the frame hit the edge
    var held: [ClosedRange<Double>]
    var edges: [ClosedRange<Double>]

    func at(_ t: Double) -> FollowFrame? {
        guard !frames.isEmpty else { return nil }
        if t <= frames[0].t { return frames[0] }
        if t >= frames[frames.count - 1].t { return frames[frames.count - 1] }
        var lo = 0, hi = frames.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if frames[m].t <= t { lo = m } else { hi = m } }
        let a = frames[lo], b = frames[hi]
        let u = (t - a.t) / max(1e-9, b.t - a.t)
        var f = a
        f.t = t
        f.framing.x = a.framing.x + (b.framing.x - a.framing.x) * u
        f.framing.y = a.framing.y + (b.framing.y - a.framing.y) * u
        f.framing.zoom = a.framing.zoom + (b.framing.zoom - a.framing.zoom) * u
        f.feature = CGPoint(x: a.feature.x + (b.feature.x - a.feature.x) * u, y: a.feature.y + (b.feature.y - a.feature.y) * u)
        f.size = a.size + (b.size - a.size) * u
        f.held = u < 0.5 ? a.held : b.held
        f.edge = a.edge || b.edge
        return f
    }
}

enum Follow {
    /// Half the frame's width / height in camera pictures at a zoom (same as ProjectModel.framingHalf).
    static func half(source: CGSize, render: CGSize, zoom: Double) -> (x: Double, y: Double) {
        let W = max(1, source.width), H = max(1, source.height)
        let s = max(render.width / W, render.height / H) * CGFloat(max(0.05, zoom))
        return (Double(render.width / (2 * W * s)), Double(render.height / (2 * H * s)))
    }
    static func limits(source: CGSize, render: CGSize, zoom: Double) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let h = half(source: source, render: render, zoom: zoom)
        return (min(h.x, 1 - h.x)...max(h.x, 1 - h.x), min(h.y, 1 - h.y)...max(h.y, 1 - h.y))
    }

    /// How tight the follow is: Gaussian smoothing of the tracked positions, in seconds.
    static func sigma(_ smooth: Double) -> Double { 0.035 + 1.4 * smooth * smooth }

    /// One run's samples, smoothed (positions by `sigma`, size always a bit more since box sizes are noisy).
    struct Series {
        var t: [Double] = [], x: [Double] = [], y: [Double] = [], s: [Double] = []
        /// stretches inside the run where it wasn't seen (a face covered for a moment): the framing glides across them
        var gaps: [ClosedRange<Double>] = []
        func inGap(_ q: Double) -> Bool { gaps.contains { $0.contains(q) } }
        var count: Int { t.count }
        func value(_ q: Double) -> (x: Double, y: Double, s: Double) {
            if q <= t[0] { return (x[0], y[0], s[0]) }
            let n = t.count
            if q >= t[n - 1] { return (x[n - 1], y[n - 1], s[n - 1]) }
            var lo = 0, hi = n - 1
            while hi - lo > 1 { let m = (lo + hi) / 2; if t[m] <= q { lo = m } else { hi = m } }
            let u = (q - t[lo]) / max(1e-9, t[hi] - t[lo])
            return (x[lo] + (x[hi] - x[lo]) * u, y[lo] + (y[hi] - y[lo]) * u, s[lo] + (s[hi] - s[lo]) * u)
        }
    }

    static func smoothed(_ run: FollowRun, sigma: Double) -> Series {
        let sm = run.samples
        var out = Series()
        guard !sm.isEmpty else {
            let r = run.pick.rect
            out.t = [run.pick.time]; out.x = [Double(r.midX)]; out.y = [Double(r.midY)]; out.s = [Double((r.width * r.height).squareRoot())]
            return out
        }
        out.t = sm.map { $0.t }
        for i in sm.indices.dropFirst() where sm[i].t - sm[i - 1].t > 0.3 { out.gaps.append(sm[i - 1].t...sm[i].t) }
        func gauss(_ v: [Double], _ sg: Double) -> [Double] {
            guard sg > 0.0005, v.count > 2 else { return v }
            var r = [Double](repeating: 0, count: v.count)
            var lo = 0, hi = 0
            for i in v.indices {
                let ti = out.t[i]
                while out.t[lo] < ti - 3 * sg { lo += 1 }
                while hi + 1 < v.count && out.t[hi + 1] <= ti + 3 * sg { hi += 1 }
                var acc = 0.0, wsum = 0.0
                for j in lo...hi {
                    let d = out.t[j] - ti
                    let w = exp(-d * d / (2 * sg * sg))
                    acc += w * v[j]; wsum += w
                }
                r[i] = wsum > 0 ? acc / wsum : v[i]
            }
            return r
        }
        out.x = gauss(sm.map { $0.x }, sigma)
        out.y = gauss(sm.map { $0.y }, sigma)
        out.s = gauss(sm.map { $0.s }, max(sigma, 0.3))
        return out
    }

    /// The path for one shot (master [a, b]) whose resting framing is `base`.
    /// At the first pick the followed thing is wherever `base` puts it; after that the framing moves so it stays there.
    static func path(_ track: FollowTrack, base: Framing, from a: Double, to b: Double,
                     source: CGSize, render: CGSize, zoomRange: ClosedRange<Double>) -> FollowPath {
        let key = PathKey(track: track, base: base, a: (a * 1000).rounded(), b: (b * 1000).rounded(),
                          sw: Double(source.width), sh: Double(source.height), rw: Double(render.width), rh: Double(render.height),
                          zlo: zoomRange.lowerBound, zhi: zoomRange.upperBound)
        if let hit = cache.get(key) { return hit }
        let p = compute(track, base: base, from: a, to: b, source: source, render: render, zoomRange: zoomRange)
        cache.put(key, p)
        return p
    }

    private struct PathKey: Hashable {
        var track: FollowTrack; var base: Framing; var a: Double; var b: Double
        var sw: Double; var sh: Double; var rw: Double; var rh: Double; var zlo: Double; var zhi: Double
    }
    private final class Cache: @unchecked Sendable {
        private var items: [PathKey: FollowPath] = [:]
        private var order: [PathKey] = []
        private let lock = NSLock()
        func get(_ k: PathKey) -> FollowPath? { lock.lock(); defer { lock.unlock() }; return items[k] }
        func put(_ k: PathKey, _ v: FollowPath) {
            lock.lock(); defer { lock.unlock() }
            if items[k] == nil { order.append(k) }
            items[k] = v
            while order.count > 48 { items[order.removeFirst()] = nil }
        }
    }
    private static let cache = Cache()

    private static func compute(_ track: FollowTrack, base: Framing, from a: Double, to b: Double,
                                source: CGSize, render: CGSize, zoomRange: ClosedRange<Double>) -> FollowPath {
        let runs = track.runs.sorted { $0.first < $1.first }
        guard !runs.isEmpty, b > a else { return FollowPath(frames: [], boost: 1, held: [], edges: []) }
        let sg = sigma(track.smooth)
        let series = runs.map { smoothed($0, sigma: sg) }
        let lock = track.locksSize

        // which run sees time t, and whether it really saw it there (held = no)
        func feature(_ t: Double) -> (k: Int, x: Double, y: Double, s: Double, held: Bool) {
            var k = 0
            for i in runs.indices where runs[i].first <= t + 1e-6 { k = i }
            let r = runs[k], sr = series[k]
            let v = sr.value(t)
            var held = sr.inGap(t)
            if t < r.first - 0.05 { held = true }                                        // before anything was tracked
            if t > r.last + 0.05 && (r.lostAt != nil || k + 1 < runs.count) { held = true } // lost, waiting for the next pick
            return (k, v.x, v.y, v.s, held)
        }

        // the times to evaluate: every tracked frame in [a, b] plus both ends
        var times: [Double] = [a, b]
        for sr in series { for t in sr.t where t > a && t < b { times.append(t) } }
        for r in runs where r.first > a && r.first < b { times.append(r.first); times.append(max(a, r.first - 0.0005)) }
        times.sort()
        var uniq: [Double] = []
        for t in times where uniq.last.map({ t - $0 > 0.0002 }) ?? true { uniq.append(t) }
        times = uniq

        func clampZ(_ z: Double) -> Double { min(zoomRange.upperBound, max(zoomRange.lowerBound, z)) }

        /// Every frame for an extra zoom `m`.
        func evaluate(_ m: Double) -> [FollowFrame] {
            // the constant part per run: K = where the thing sits relative to the frame centre (camera-picture units × zoom),
            // zb = zoom before the extra, sref = the thing's size when the run took over
            var K: [(x: Double, y: Double)] = [], zb: [Double] = [], sref: [Double] = []
            let p0 = series[0].value(runs[0].pick.time)
            K.append(((p0.x - base.x) * base.zoom, (p0.y - base.y) * base.zoom))
            zb.append(base.zoom)
            sref.append(p0.s)
            func state(_ k: Int, _ v: (x: Double, y: Double, s: Double)) -> (x: Double, y: Double, z: Double, zRaw: Double) {
                let zRaw = zb[k] * (lock ? sref[k] / max(1e-4, v.s) : 1)
                let z = clampZ(zRaw * m)
                return (v.x - K[k].x / z, v.y - K[k].y / z, z, zRaw)
            }
            for k in runs.indices.dropFirst() {
                let tau = runs[k].first
                let before = series[k - 1].value(tau)
                let prev = state(k - 1, before)
                let now = series[k].value(tau)
                K.append(((now.x - prev.x) * prev.z, (now.y - prev.y) * prev.z))
                zb.append(prev.zRaw)
                sref.append(now.s)
            }
            return times.map { t in
                let f = feature(t)
                let st = state(f.k, (f.x, f.y, f.s))
                let lim = limits(source: source, render: render, zoom: st.z)
                let cx = min(lim.x.upperBound, max(lim.x.lowerBound, st.x))
                let cy = min(lim.y.upperBound, max(lim.y.lowerBound, st.y))
                let edge = abs(cx - st.x) > 0.0015 || abs(cy - st.y) > 0.0015
                var fr = base
                fr.x = cx; fr.y = cy; fr.zoom = st.z
                return FollowFrame(t: t, framing: fr, feature: CGPoint(x: f.x, y: f.y), size: f.s, held: f.held, edge: edge)
            }
        }
        func edgeTime(_ fr: [FollowFrame]) -> Double {
            var s = 0.0
            for i in fr.indices.dropFirst() where fr[i].edge || fr[i - 1].edge { s += fr[i].t - fr[i - 1].t }
            return s + (fr.count == 1 && fr[0].edge ? 0.01 : 0)
        }

        var m = 1.0
        var frames = evaluate(1)
        if track.zoomsToFit && base.zoom >= 0.999 && frames.contains(where: { $0.edge }) {
            let top = max(1, zoomRange.upperBound / max(0.05, base.zoom))
            let atTop = evaluate(top)
            if !atTop.contains(where: { $0.edge }) {
                var lo = 1.0, hi = top
                for _ in 0..<14 {
                    let mid = (lo + hi) / 2
                    if evaluate(mid).contains(where: { $0.edge }) { lo = mid } else { hi = mid }
                }
                m = hi * 1.004
                frames = evaluate(m)
            } else {
                // can't be kept off the edge at any zoom: use the zoom that touches it least
                var best = (m: 1.0, e: edgeTime(frames))
                for i in 1...12 {
                    let mm = 1 + (top - 1) * Double(i) / 12
                    let e = edgeTime(evaluate(mm))
                    if e < best.e - 0.01 { best = (mm, e) }
                }
                m = best.m
                frames = evaluate(m)
            }
        }
        func spans(_ flag: (FollowFrame) -> Bool) -> [ClosedRange<Double>] {
            var out: [ClosedRange<Double>] = []
            var startT: Double? = nil
            for (i, f) in frames.enumerated() {
                if flag(f) { if startT == nil { startT = i > 0 ? frames[i - 1].t : f.t } }
                else if let s = startT { out.append(s...f.t); startT = nil }
            }
            if let s = startT { out.append(s...(frames.last?.t ?? s)) }
            return out.filter { $0.upperBound - $0.lowerBound > 0.02 }
        }
        return FollowPath(frames: frames, boost: m, held: spans { $0.held }, edges: spans { $0.edge })
    }
}
