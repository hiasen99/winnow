import Foundation

/// A stretch of master time shown from one angle.
struct AngleSegment: Hashable {
    var start: Double
    var end: Double
    var angle: Int
    var duration: Double { end - start }
}

/// A stretch of a clip's OUTPUT, sourced from master time [masterStart, masterStart+duration) on one angle.
struct EditPiece: Hashable {
    var outStart: Double
    var masterStart: Double
    var duration: Double
    var angle: Int
}

enum Schedule {

    /// Speaker turns -> camera cuts for the whole recording ("auto" multicam).
    static func auto(project p: Project) -> [AngleSegment] {
        let total = p.masterDuration
        guard total > 0 else { return [] }
        let words = p.words
        let fallback = firstCovering(p, at: 0) ?? 0
        let vids = p.videoIndices
        guard !words.isEmpty, p.speakers.count > 1 else {
            let a = p.speakers.first.map { $0.angle } ?? fallback
            return [AngleSegment(start: 0, end: total, angle: vids.contains(a) ? a : fallback)]
        }
        // turns
        var turns: [(start: Double, speaker: Int)] = []
        for w in words {
            if turns.last?.speaker != w.speaker {
                turns.append((max(0, w.start - p.switchLead), w.speaker))
            }
        }
        var segs: [(start: Double, end: Double, speaker: Int)] = []
        for (i, t) in turns.enumerated() {
            let s = i == 0 ? 0 : t.start
            let e = i + 1 < turns.count ? turns[i + 1].start : total
            if e > s { segs.append((s, e, t.speaker)) }
        }
        // swallow short interjections ("yeah", "right") into the shot before them
        var merged: [(start: Double, end: Double, speaker: Int)] = []
        for s in segs {
            if let last = merged.last {
                if s.speaker == last.speaker || s.end - s.start < p.minShot {
                    merged[merged.count - 1].end = s.end
                    continue
                }
            }
            merged.append(s)
        }
        // a short opening shot gets folded into the next one
        if merged.count > 1, merged[0].end - merged[0].start < p.minShot {
            merged[1].start = 0; merged.removeFirst()
        }
        var out: [AngleSegment] = []
        for m in merged {
            let a = m.speaker < p.speakers.count ? p.speakers[m.speaker].angle : 0
            if var last = out.last, last.angle == a {
                last.end = m.end; out[out.count - 1] = last
            } else {
                out.append(AngleSegment(start: m.start, end: m.end, angle: a))
            }
        }
        return out
    }

    static func firstCovering(_ p: Project, at t: Double) -> Int? {
        p.videoIndices.first { p.angles[$0].covers(t) } ?? p.videoIndices.first
    }

    static func autoAngle(_ auto: [AngleSegment], at t: Double) -> Int {
        // binary search
        var lo = 0, hi = auto.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if t < auto[mid].start { hi = mid - 1 } else if t >= auto[mid].end { lo = mid + 1 } else { return auto[mid].angle }
        }
        return auto.last?.angle ?? 0
    }

    /// Effective angle at master time t for a clip (manual switches win over auto).
    static func angle(at t: Double, clip: Clip?, auto: [AngleSegment], project p: Project) -> Int {
        var a = autoAngle(auto, at: t)
        if let clip {
            if let sw = clip.switches.last(where: { $0.time <= t + 1e-6 }), let forced = sw.angle { a = forced }
        }
        if a >= p.angles.count || !p.angles[a].isVideo || !p.angles[a].covers(t) { a = firstCovering(p, at: t) ?? 0 }
        return a
    }

    /// Breaks a clip (or the whole recording when clip == nil) into pieces, one angle each.
    static func pieces(project p: Project, clip: Clip?, auto: [AngleSegment]) -> [EditPiece] {
        let ranges = clip?.ranges ?? [TimeRange(start: 0, end: p.masterDuration)]
        var cutPoints = Set<Double>()
        for s in auto { cutPoints.insert(s.start); cutPoints.insert(s.end) }
        for sw in clip?.switches ?? [] { cutPoints.insert(sw.time) }
        for a in p.angles where a.isVideo { cutPoints.insert(a.masterStart); cutPoints.insert(a.masterEnd) }
        let sortedCuts = cutPoints.sorted()

        var out: [EditPiece] = []
        var outPos = 0.0
        for r in ranges where r.duration > 0 {
            var bounds = [r.start]
            for c in sortedCuts where c > r.start + 1e-4 && c < r.end - 1e-4 { bounds.append(c) }
            bounds.append(r.end)
            for i in 0..<(bounds.count - 1) {
                let a = bounds[i], b = bounds[i + 1]
                let mid = (a + b) / 2
                let ang = angle(at: mid, clip: clip, auto: auto, project: p)
                if var last = out.last, last.angle == ang,
                   abs(last.masterStart + last.duration - a) < 1e-6 {
                    last.duration += b - a; out[out.count - 1] = last
                } else {
                    out.append(EditPiece(outStart: outPos, masterStart: a, duration: b - a, angle: ang))
                }
                outPos += b - a
            }
        }
        return out
    }
}
