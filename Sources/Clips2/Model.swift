import Foundation
import CoreGraphics
import SwiftUI
import AppKit

// MARK: - Basic types

struct TimeRange: Codable, Hashable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
    func contains(_ t: Double) -> Bool { t >= start && t < end }
    /// This range with `o` taken out (0, 1 or 2 pieces).
    func minus(_ o: TimeRange) -> [TimeRange] {
        if o.end <= start || o.start >= end { return [self] }
        var out: [TimeRange] = []
        if o.start > start { out.append(TimeRange(start: start, end: o.start)) }
        if o.end < end { out.append(TimeRange(start: o.end, end: end)) }
        return out
    }
}

struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent); a = Double(ns.alphaComponent)
    }
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)
    static let yellow = RGBA(r: 1, g: 0.83, b: 0.0)
}

// MARK: - Sources

/// One source file on the shared "master" timeline:  sourceTime = masterTime + offset.
/// Either a camera angle (video, usually with its own sound) or a separate audio recording (a mic).
struct AngleSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var offset: Double = 0
    var duration: Double = 0
    var width: Double = 1920
    var height: Double = 1080
    var fps: Double = 30
    var hasAudio: Bool = true
    var isVideo: Bool = true
    var gainDB: Double = 0          // level match applied when this source's audio is used
    var syncScore: Double? = nil    // how clearly it matched (≈1 = no match, 3+ = solid)
    var syncDrift: Double? = nil    // largest disagreement across the recording, seconds
    var syncedWith: String? = nil   // which source it was lined up against (nil = the reference)
    var syncFailed: Bool = false

    init(name: String, path: String, isVideo: Bool = true) {
        self.name = name; self.path = path; self.isVideo = isVideo
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1080
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? true
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        syncScore = try c.decodeIfPresent(Double.self, forKey: .syncScore)
        syncDrift = try c.decodeIfPresent(Double.self, forKey: .syncDrift)
        syncedWith = try c.decodeIfPresent(String.self, forKey: .syncedWith)
        syncFailed = try c.decodeIfPresent(Bool.self, forKey: .syncFailed) ?? false
    }

    var url: URL { URL(fileURLWithPath: path) }
    var masterStart: Double { -offset }
    var masterEnd: Double { duration - offset }
    func covers(_ t: Double) -> Bool { t >= masterStart - 0.001 && t <= masterEnd + 0.001 }
    var displaySize: CGSize { CGSize(width: width, height: height) }
    /// "A", "B" for cameras, "Mic 1" for audio files
    var shortName: String {
        if isVideo, name.hasPrefix("Angle ") { return String(name.dropFirst(6)) }
        return name
    }
}

struct Word: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
    var speaker: Int = 0
    /// Left out of the transcript and captions; the video and sound are untouched.
    /// (optional so older projects still load)
    var hidden: Bool? = nil
    var isHidden: Bool { hidden ?? false }
}

struct Speaker: Codable, Hashable {
    var name: String
    var angle: Int          // which camera to show when this person talks
}

/// A manual angle choice that starts at `time` and lasts until the next switch.
/// `angle == nil` means "go back to automatic (follow the speaker)".
struct AngleSwitch: Codable, Hashable {
    var time: Double
    var angle: Int?
}

// MARK: - Clips

enum ClipFormat: String, Codable, CaseIterable, Identifiable {
    case vertical, square, horizontal
    var id: String { rawValue }
    var label: String {
        switch self { case .vertical: return "9:16"; case .square: return "1:1"; case .horizontal: return "16:9" }
    }
    var renderSize: CGSize {
        switch self {
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        case .horizontal: return CGSize(width: 1920, height: 1080)
        }
    }
}

/// How an angle is framed inside the clip's frame. x/y = centre of the crop (0...1, can go past when zoomed out),
/// zoom 1 = fills the frame; below 1 the picture is smaller than the frame with a blurred copy behind it.
struct Framing: Codable, Hashable {
    var x: Double = 0.5
    var y: Double = 0.5
    var zoom: Double = 1.0
    /// Caption height while this camera is on screen (centre of the caption, fraction of frame height).
    /// nil = the caption style's height. (optional so older projects still load)
    var captionY: Double? = nil

    /// Only the picture part (centre + zoom) is at its default; the caption height doesn't count.
    var pictureIsDefault: Bool { abs(x - 0.5) < 0.002 && abs(y - 0.5) < 0.002 && abs(zoom - 1) < 0.002 }
    /// Centred and not zoomed, keeping this camera's caption height.
    var pictureReset: Framing { Framing(captionY: captionY) }
}

/// A shot framed on its own (step: per-shot framing). A shot is one stretch of one camera between cuts
/// (camera changes, cut-out parts, blade points). `time` is a moment inside the shot (master time):
/// the override belongs to whichever stretch of camera `angle` contains it, so small timing changes keep it.
/// Only the picture is overridden; the caption height still comes from the camera's framing.
struct ShotFraming: Codable, Hashable {
    var time: Double
    var angle: Int
    var x: Double = 0.5
    var y: Double = 0.5
    var zoom: Double = 1.0
}

struct AudioMix: Codable, Hashable {
    var on: [Bool]
    var gainDB: [Double]

    static func both(_ n: Int) -> AudioMix { AudioMix(on: Array(repeating: true, count: n), gainDB: Array(repeating: 0, count: n)) }
    static func only(_ i: Int, of n: Int) -> AudioMix {
        AudioMix(on: (0..<n).map { $0 == i }, gainDB: Array(repeating: 0, count: n))
    }
    func isOn(_ i: Int) -> Bool { i < on.count ? on[i] : false }
    func gain(_ i: Int) -> Double { i < gainDB.count ? gainDB[i] : 0 }
    mutating func ensure(_ n: Int) {
        while on.count < n { on.append(true) }
        while gainDB.count < n { gainDB.append(0) }
    }
}

/// A change of which sources you hear, from `time` (master) until the next change.
/// `on == nil` means "back to the clip's own sound".
struct AudioSwitch: Codable, Hashable {
    var time: Double
    var on: [Bool]?
}

/// Review mark on a clip (like Final Cut's favourite / reject).
enum ClipStatus: String, Codable, CaseIterable {
    case used, rejected
}

/// A note pinned to a moment of the recording (master time).
struct Marker: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var time: Double
    var name: String = ""
}

/// One block on the timeline's main track: a kept stretch of master time, shown at `outStart`.
struct ClipSegment: Hashable {
    var master: TimeRange
    var outStart: Double
    var rangeIndex: Int
    /// true when its left / right edge is a blade split (the neighbour continues without a gap)
    var splitBefore: Bool
    var splitAfter: Bool
    var outEnd: Double { outStart + master.duration }
}

struct Clip: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// Kept pieces in master time, in the order they play, never overlapping. Usually that's recording order;
    /// blocks moved on the timeline play out of it (see `playsInOrder`). Removing words splits a range.
    var ranges: [TimeRange]
    var switches: [AngleSwitch] = []
    var audio: AudioMix
    var audioSwitches: [AudioSwitch]? = nil
    var format: ClipFormat = .vertical
    var framing: [Framing] = []
    var captions: Bool = true
    var note: String = ""
    var score: Double? = nil
    var created: Date = Date()
    // (optional so older projects still load)
    var status: ClipStatus? = nil
    /// Blade points (master time) inside kept ranges: they divide a range into separate blocks.
    var splits: [Double]? = nil
    /// Captions edited by hand (moved, re-timed, retyped, split…). nil = made automatically from the transcript.
    /// Transcript words not covered by any of these still get automatic captions (e.g. after the clip is made longer).
    var captionBlocks: [CaptionBlock]? = nil
    /// Shots framed on their own, overriding the camera's framing for just that shot. (optional so older projects still load)
    var shotFraming: [ShotFraming]? = nil
    /// Frames marked with G to save as pictures (master time). (optional so older projects still load)
    var grabs: [Double]? = nil
    /// The clip's thumbnail: which frame, and its own title text. nil = the default frame and the clip's title.
    var thumbnail: ClipThumbnail? = nil
    /// Follow / subscribe popups shown over the picture. (optional so older projects still load)
    var popups: [FollowPopup]? = nil
    /// Framing that follows a point picked in the picture (Follow… in the framing pop-over). (optional so older projects still load)
    var follows: [FollowTrack]? = nil

    /// Earliest / latest kept moment in the recording (with blocks moved, not necessarily where it starts / ends playing).
    var start: Double { ranges.lazy.map { $0.start }.min() ?? 0 }
    var end: Double { ranges.lazy.map { $0.end }.max() ?? 0 }
    var outputDuration: Double { ranges.reduce(0) { $0 + $1.duration } }

    /// true unless blocks were moved so the clip plays parts of the recording out of order.
    var playsInOrder: Bool { zip(ranges, ranges.dropFirst()).allSatisfy { $0.start < $1.start } }

    /// Where kept range `i` meets the next one: seconds of the recording cut out there (not used anywhere else in the clip),
    /// and whether the next range was moved there (it doesn't simply carry on later in the recording).
    func join(after i: Int) -> (cut: Double, moved: Bool) {
        guard i >= 0, i + 1 < ranges.count else { return (0, false) }
        let a = ranges[i].end, b = ranges[i + 1].start
        if b < a - 0.001 { return (0, true) }
        var gap = [TimeRange(start: a, end: b)]
        for (k, r) in ranges.enumerated() where k != i && k != i + 1 { gap = gap.flatMap { $0.minus(r) } }
        let cut = gap.reduce(0) { $0 + $1.duration }
        return (cut, cut < (b - a) - 0.001)
    }

    /// The clip with block `from` (index into `segments`) moved so it plays just before block `to`
    /// (`to` == segments.count: at the end). Its camera, sound, framing and captions go with it, since they belong to
    /// those moments of the recording. nil when nothing would change.
    func movingSegment(_ from: Int, before to: Int) -> Clip? {
        let segs = segments
        guard segs.indices.contains(from), to >= 0, to <= segs.count, to != from, to != from + 1 else { return nil }
        var blocks = segs.map { $0.master }
        let moved = blocks.remove(at: from)
        blocks.insert(moved, at: to > from ? to - 1 : to)
        var c = self
        c.ranges = blocks
        // every block stays a block: blade points at the moved block's edges (kept only where the pieces join up again)
        c.splits = Array(Set((splits ?? []) + [moved.start, moved.end])).sorted()
        // a hand-edited caption running across a place where the clip now jumps is split there, so each part shows with its own words
        var at = [moved.start, moved.end]
        if to < segs.count { at.append(segs[to].master.start) }
        if to > 0 { at.append(segs[to - 1].master.end) }
        if var cb = c.captionBlocks {
            for p in at { cb = cb.flatMap { $0.split(at: p) } }
            c.captionBlocks = cb.sorted { $0.start < $1.start }
        }
        c.normalizeRanges()
        return c
    }

    /// Which kept range plays at output time `o` (the last one at its very end).
    func rangeIndex(atOutput o: Double) -> Int {
        var acc = 0.0
        for (i, r) in ranges.enumerated() {
            if o < acc + r.duration { return i }
            acc += r.duration
        }
        return max(0, ranges.count - 1)
    }
    /// Output time where the kept range playing at `o` ends.
    func outputRangeEnd(containing o: Double) -> Double {
        let k = rangeIndex(atOutput: o)
        return ranges.prefix(k + 1).reduce(0) { $0 + $1.duration }
    }

    /// Where master [a, b) shows in the clip's output: the longest stretch of it that plays without a jump
    /// (with the clip in recording order that's all of it, cuts closed up). nil = all of it was cut out.
    func outputSpan(fromMaster a: Double, to b: Double) -> (start: Double, end: Double)? {
        var acc = 0.0
        var parts: [(Double, Double)] = []
        for r in ranges {
            let x = max(a, r.start), y = min(b, r.end)
            if y > x { parts.append((acc + x - r.start, acc + y - r.start)) }
            acc += r.duration
        }
        parts.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for p in parts {
            if let last = merged.last, p.0 <= last.1 + 0.002 { merged[merged.count - 1].1 = max(last.1, p.1) } else { merged.append(p) }
        }
        return merged.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }).map { (start: $0.0, end: $0.1) }
    }

    /// Remove output time [o1, o2) (whatever plays then) from the clip.
    mutating func cutOutput(_ o1: Double, _ o2: Double) {
        var acc = 0.0
        var parts: [(Double, Double)] = []
        for r in ranges {
            let a = max(o1, acc), b = min(o2, acc + r.duration)
            if b > a + 0.001 { parts.append((r.start + a - acc, r.start + b - acc)) }
            acc += r.duration
        }
        for (a, b) in parts { cut(a, b) }
    }

    /// The clip begins at `s` in the recording: earlier moments go, or the earliest kept piece reaches back to `s`.
    mutating func setRecordingStart(_ s: Double) {
        let old = start, oldEnd = end
        ranges = ranges.compactMap { r in r.end <= s ? nil : TimeRange(start: max(r.start, s), end: r.end) }
        if ranges.isEmpty { ranges = [TimeRange(start: s, end: max(s + 0.3, oldEnd))] }
        else if s < old, let k = ranges.indices.min(by: { ranges[$0].start < ranges[$1].start }) { ranges[k].start = s }
        normalizeRanges()
    }
    /// The clip ends at `e` in the recording: later moments go, or the latest kept piece reaches on to `e`.
    mutating func setRecordingEnd(_ e: Double) {
        let old = end, oldStart = start
        ranges = ranges.compactMap { r in r.start >= e ? nil : TimeRange(start: r.start, end: min(r.end, e)) }
        if ranges.isEmpty { ranges = [TimeRange(start: min(oldStart, e - 0.3), end: e)] }
        else if e > old, let k = ranges.indices.max(by: { ranges[$0].end < ranges[$1].end }) { ranges[k].end = e }
        normalizeRanges()
    }

    /// Stretches of constant sound in OUTPUT time, in play order.
    func soundOutputSegments() -> [(start: Double, end: Double, on: [Bool])] {
        let segs = soundSegments()
        if playsInOrder {
            return segs.map { (outputTimeClamped(forMaster: $0.start), outputTimeClamped(forMaster: $0.end), $0.on) }
        }
        var out: [(start: Double, end: Double, on: [Bool])] = []
        var acc = 0.0
        for r in ranges {
            for s in segs where s.end > r.start && s.start < r.end {
                let a = max(s.start, r.start), b = min(s.end, r.end)
                guard b > a else { continue }
                let oa = acc + a - r.start, ob = acc + b - r.start
                if let last = out.last, last.on == s.on, abs(last.end - oa) < 1e-6 { out[out.count - 1].end = ob }
                else { out.append((oa, ob, s.on)) }
            }
            acc += r.duration
        }
        return out.isEmpty ? [(0, acc, audio.on)] : out
    }

    /// The blocks shown on the timeline (kept ranges, divided at blade points).
    var segments: [ClipSegment] {
        var out: [ClipSegment] = []
        var acc = 0.0
        let cuts = (splits ?? []).sorted()
        for (i, r) in ranges.enumerated() {
            var bounds = [r.start]
            for s in cuts where s > r.start + 0.01 && s < r.end - 0.01 { bounds.append(s) }
            bounds.append(r.end)
            for k in 0..<(bounds.count - 1) {
                let m = TimeRange(start: bounds[k], end: bounds[k + 1])
                out.append(ClipSegment(master: m, outStart: acc, rangeIndex: i,
                                       splitBefore: k > 0, splitAfter: k < bounds.count - 2))
                acc += m.duration
            }
        }
        return out
    }

    func framing(for angle: Int) -> Framing { angle < framing.count ? framing[angle] : Framing() }

    /// The override for the shot of camera `angle` covering master [start, end), if it has one.
    func shotFramingIndex(start: Double, end: Double, angle: Int) -> Int? {
        guard let list = shotFraming else { return nil }
        return list.indices.last { list[$0].angle == angle && list[$0].time >= start - 1e-4 && list[$0].time < end - 1e-4 }
    }
    /// How a shot is framed: its own picture if it has one, otherwise the camera's; the caption height is always the camera's.
    func framing(forShotFrom start: Double, to end: Double, angle: Int) -> Framing {
        var f = framing(for: angle)
        if let i = shotFramingIndex(start: start, end: end, angle: angle), let s = shotFraming?[i] {
            f.x = s.x; f.y = s.y; f.zoom = s.zoom
        }
        return f
    }

    /// Use camera `angle` (nil = automatic) for master [a, b); whatever was showing at `b` carries on after it.
    mutating func setCamera(_ angle: Int?, from a: Double, to b: Double) {
        let sorted = switches.sorted { $0.time < $1.time }
        let after = sorted.last(where: { $0.time <= b + 1e-6 })?.angle
        var sw = sorted.filter { $0.time < a - 0.001 || $0.time > b + 0.001 }
        sw.append(AngleSwitch(time: a, angle: angle))
        if b < end - 0.02 { sw.append(AngleSwitch(time: b, angle: after)) }
        switches = Clip.tidy(sw)
    }
    /// Sorted, no switch that changes nothing, no leading "automatic" (that's the default anyway).
    static func tidy(_ list: [AngleSwitch]) -> [AngleSwitch] {
        var cleaned: [AngleSwitch] = []
        for s in list.sorted(by: { $0.time < $1.time }) {
            if let last = cleaned.last, abs(last.time - s.time) < 0.001 { cleaned[cleaned.count - 1] = s; continue }
            cleaned.append(s)
        }
        var out: [AngleSwitch] = []
        for s in cleaned where out.isEmpty || out.last!.angle != s.angle { out.append(s) }
        while let first = out.first, first.angle == nil { out.removeFirst() }
        return out
    }

    /// Hear `on` during master [a, b) (several stretches at once); what was heard at each end carries on after it.
    mutating func setSound(_ on: [Bool], ranges: [(Double, Double)]) {
        var sw = soundChanges
        for (a0, b0) in ranges {
            let a = max(start, a0), b = min(end, b0)
            guard b > a + 0.005 else { continue }
            let after = soundOn(at: b)
            sw.removeAll { $0.time >= a - 0.02 && $0.time <= b + 0.02 }
            if a <= start + 0.05 { audio.on = on } else { sw.append(AudioSwitch(time: a, on: on)) }
            if b < end - 0.05 { sw.append(AudioSwitch(time: b, on: after)) }
        }
        sw = sw.filter { $0.time > start + 0.01 && $0.time < end - 0.01 }.sorted { $0.time < $1.time }
        var cleaned: [AudioSwitch] = []
        var cur = audio.on
        for s in sw {
            let next = s.on ?? audio.on
            if next != cur { cleaned.append(AudioSwitch(time: s.time, on: next)); cur = next }
        }
        audioSwitches = cleaned.isEmpty ? nil : cleaned
    }

    var soundChanges: [AudioSwitch] { (audioSwitches ?? []).sorted { $0.time < $1.time } }

    /// Which sources are heard at master time t.
    func soundOn(at t: Double) -> [Bool] {
        if let s = soundChanges.last(where: { $0.time <= t + 1e-6 }), let on = s.on { return on }
        return audio.on
    }

    /// The clip split into stretches of constant sound, in master time.
    func soundSegments() -> [(start: Double, end: Double, on: [Bool])] {
        var out: [(Double, Double, [Bool])] = []
        var t = start
        var cur = soundOn(at: start)
        for s in soundChanges where s.time > start + 1e-6 && s.time < end - 1e-6 {
            out.append((t, s.time, cur)); t = s.time; cur = s.on ?? audio.on
        }
        out.append((t, end, cur))
        return out.map { (start: $0.0, end: $0.1, on: $0.2) }
    }

    /// master -> output time; a moment inside a removed part maps to where playback resumes
    /// (the start of the kept piece that comes next in the recording).
    func outputTimeClamped(forMaster t: Double) -> Double {
        if let o = outputTime(forMaster: t) { return o }
        var acc = 0.0
        var best: (start: Double, out: Double)? = nil
        for r in ranges {
            if r.start >= t, best == nil || r.start < best!.start { best = (r.start, acc) }
            acc += r.duration
        }
        return best?.out ?? acc
    }

    /// master time -> clip output time (nil if the moment was cut out)
    func outputTime(forMaster t: Double) -> Double? {
        var acc = 0.0
        for r in ranges {
            if t >= r.start && t <= r.end { return acc + (t - r.start) }
            acc += r.duration
        }
        return nil
    }
    /// clip output time -> master time
    func masterTime(forOutput o: Double) -> Double {
        var acc = 0.0
        for r in ranges {
            if o <= acc + r.duration { return r.start + (o - acc) }
            acc += r.duration
        }
        return end
    }

    mutating func normalizeRanges() {
        let kept = ranges.filter { $0.duration > 0.02 }
        var out: [TimeRange] = []
        if zip(kept, kept.dropFirst()).allSatisfy({ $0.start <= $1.start }) {
            // recording order: sort, join what touches or overlaps
            for r in kept {
                if var last = out.last, r.start <= last.end + 0.001 {
                    last.end = max(last.end, r.end); out[out.count - 1] = last
                } else { out.append(r) }
            }
        } else {
            // blocks were moved: keep the play order, never play a moment twice (the earlier piece keeps it),
            // and join a piece to the one before it when it simply carries on
            for r0 in kept {
                var parts = [r0]
                for o in out { parts = parts.flatMap { $0.minus(o) } }
                for r in parts where r.duration > 0.02 {
                    if var last = out.last, abs(r.start - last.end) <= 0.001 {
                        last.end = r.end; out[out.count - 1] = last
                    } else { out.append(r) }
                }
            }
        }
        ranges = out
        switches.sort { $0.time < $1.time }
        // blade points only make sense strictly inside a kept range
        if let s = splits {
            let kept = s.filter { t in ranges.contains { t > $0.start + 0.01 && t < $0.end - 0.01 } }
            splits = kept.isEmpty ? nil : Array(Set(kept.map { ($0 * 1000).rounded() / 1000 })).sorted()
        }
    }

    /// Remove [a, b) from the clip.
    mutating func cut(_ a: Double, _ b: Double) {
        var out: [TimeRange] = []
        for r in ranges {
            if b <= r.start || a >= r.end { out.append(r); continue }
            if a > r.start { out.append(TimeRange(start: r.start, end: a)) }
            if b < r.end { out.append(TimeRange(start: b, end: r.end)) }
        }
        ranges = out
        normalizeRanges()
    }

    /// Put [a, b) back (only within the clip's outer bounds unless extend == true).
    mutating func restore(_ a: Double, _ b: Double) {
        guard !playsInOrder else {
            ranges.append(TimeRange(start: a, end: b))
            normalizeRanges()
            return
        }
        // blocks were moved: each missing piece goes back next to the kept piece it touches in the recording
        var gaps = [TimeRange(start: a, end: b)]
        for r in ranges { gaps = gaps.flatMap { $0.minus(r) } }
        for g in gaps where g.duration > 0.001 {
            if let i = ranges.firstIndex(where: { abs($0.end - g.start) < 0.002 }) { ranges[i].end = g.end }
            else if let j = ranges.firstIndex(where: { abs($0.start - g.end) < 0.002 }) { ranges[j].start = g.start }
            else if let p = ranges.indices.filter({ ranges[$0].end <= g.start }).max(by: { ranges[$0].end < ranges[$1].end }) {
                ranges.insert(g, at: p + 1)
            } else { ranges.insert(g, at: 0) }
        }
        normalizeRanges()
    }
}

/// A clip's thumbnail picture: the frame it uses (master time) and, if it differs from the clip's title, its own text.
struct ClipThumbnail: Codable, Hashable {
    var time: Double? = nil
    var title: String? = nil
    /// true = `time` is anywhere in the full recording (it can be outside the clip), shown with `angle`'s camera.
    var fromRecording: Bool? = nil
    /// The camera for a frame from the recording (nil = automatic, whoever is talking).
    var angle: Int? = nil
    /// A picture file used instead of a frame from the video.
    var imagePath: String? = nil
    /// true = made in the thumbnail editor even with no frame / title of its own (e.g. only the look was changed).
    var made: Bool? = nil

    var isEmpty: Bool { time == nil && title == nil && fromRecording != true && angle == nil && imagePath == nil && made != true }
    var source: ThumbSource { imagePath != nil ? .file : (fromRecording == true ? .recording : .clip) }
}

enum ThumbSource: String, CaseIterable, Identifiable {
    case clip, recording, file
    var id: String { rawValue }
    var label: String {
        switch self { case .clip: return "This clip"; case .recording: return "Whole recording"; case .file: return "Picture file" }
    }
}

// MARK: - Captions

enum CaptionMode: String, Codable, CaseIterable, Identifiable {
    case reveal        // words appear one at a time
    case highlight     // whole line shown, the spoken word is coloured
    case revealHighlight // appear one at a time and the newest word is coloured
    case line          // whole line, no word effect
    var id: String { rawValue }
    var label: String {
        switch self {
        case .reveal: return "Word by word"
        case .highlight: return "Highlight spoken word"
        case .revealHighlight: return "Word by word + highlight"
        case .line: return "Whole line"
        }
    }
}

struct CaptionStyle: Codable, Hashable {
    var fontName: String = "AvenirNext-Heavy"
    /// Weight on a variable font's weight axis (nil = the font's own weight). Optional so older projects still load.
    var fontWeight: Double? = nil
    var fontSize: Double = 0.075          // fraction of frame width
    var textColor: RGBA = .white
    var activeColor: RGBA = .yellow
    var mode: CaptionMode = .revealHighlight
    var uppercase: Bool = false
    var strokeWidth: Double = 0.0         // fraction of font size (0 = none)
    var strokeColor: RGBA = .black
    var shadow: Bool = true
    var box: Bool = false
    var boxColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
    var maxCharsPerLine: Int = 18
    var maxLines: Int = 2
    var positionY: Double = 0.66          // centre of the caption block, fraction of frame height
    var lineSpacing: Double = 1.15
    var sideMargin: Double = 0.09         // safe zone each side, fraction of width
    var pauseBreak: Double = 0.7          // start a new caption after a pause this long
    // box behind the word being spoken (optional so older projects still load)
    var wordBox: Bool? = nil
    var wordBoxColor: RGBA? = nil
    var wordBoxRound: Double? = nil       // 0 = square corners, 1 = pill
    var wordBoxGlide: Bool? = nil         // the box glides to each new word on a spring (nil = on)

    var wordBoxOn: Bool { wordBox ?? false }
    var wordBoxRGBA: RGBA { wordBoxColor ?? RGBA(r: 1, g: 0.83, b: 0, a: 1) }
    var wordBoxRoundness: Double { wordBoxRound ?? 0.35 }
    var wordBoxGlides: Bool { wordBoxGlide ?? true }
}

/// One caption you've edited by hand: shown from `start` to `end` (master time) with its own words.
/// An empty `words` list means "no caption here" (so the transcript doesn't fill the gap back in).
struct CaptionBlock: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var words: [Word]
    /// The stretch of the transcript this caption was made from: those words stay with it even after it's moved.
    var covers: TimeRange? = nil
    var text: String { words.map { $0.text }.joined(separator: " ") }
    /// Two captions, before and after master time `p` (itself when it doesn't run across `p`).
    func split(at p: Double) -> [CaptionBlock] {
        guard start < p - 0.01, end > p + 0.01 else { return [self] }
        var a = self, b = self
        b.id = UUID()
        a.end = p; b.start = p
        a.words = words.filter { ($0.start + $0.end) / 2 < p }
        b.words = words.filter { ($0.start + $0.end) / 2 >= p }
        if let c = covers {
            a.covers = c.start < p ? TimeRange(start: c.start, end: min(c.end, p)) : nil
            b.covers = c.end > p ? TimeRange(start: max(c.start, p), end: c.end) : nil
        }
        return [a, b]
    }
    func owns(_ w: Word) -> Bool {
        let mid = (w.start + w.end) / 2
        if mid >= start && mid < end { return true }
        if let c = covers, mid >= c.start && mid < c.end { return true }
        return false
    }
}

struct CaptionPreset: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var style: CaptionStyle
}

// MARK: - Project

struct Project: Codable {
    var version: Int = 1
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
    var angles: [AngleSource]
    var syncConfidence: Double? = nil
    var words: [Word] = []
    var speakers: [Speaker] = []
    var clips: [Clip] = []
    var captionStyle: CaptionStyle = CaptionStyle()
    var stage: Stage = .new
    var language: String = "en-US"
    var speakerCamerasByHand: Bool? = nil   // true once the user picks cameras for speakers
    var minShot: Double = 2.0
    var switchLead: Double = 0.25
    var markers: [Marker]? = nil
    /// Frames marked with G on the full recording (master time). (optional so older projects still load)
    var grabs: [Double]? = nil
    /// How clip thumbnails look in this project (title, shade, logo, picture). nil = the default thumbnail style.
    var thumbnailStyle: ThumbnailStyle? = nil
    /// The project's brand (from the brand library): who follow popups are for. nil = none picked.
    var brandID: UUID? = nil

    enum Stage: String, Codable { case new, synced, transcribed }

    /// The timeline runs while there's picture (separate audio recordings that run longer are trimmed to it).
    var masterDuration: Double {
        let v = angles.filter { $0.isVideo }
        return (v.isEmpty ? angles : v).map { $0.masterEnd }.max() ?? 0
    }
    var videoIndices: [Int] { angles.indices.filter { angles[$0].isVideo } }
    var micIndices: [Int] { angles.indices.filter { !angles[$0].isVideo && angles[$0].hasAudio } }
    /// Sources used for the transcript and for telling speakers apart:
    /// the separate mics if there are any (cleaner), otherwise every camera's sound.
    var speechIndices: [Int] {
        let mics = micIndices
        return mics.isEmpty ? angles.indices.filter { angles[$0].hasAudio } : mics
    }
    /// What you hear by default: the mics if there are any, otherwise all camera sound.
    var defaultMix: AudioMix {
        var m = AudioMix.both(angles.count)
        let use = Set(speechIndices)
        for i in angles.indices { m.on[i] = use.contains(i) }
        return m
    }

    func newClip(title: String, start: Double, end: Double) -> Clip {
        var c = Clip(title: title, ranges: [TimeRange(start: start, end: end)], audio: defaultMix)
        c.framing = angles.map { _ in Framing() }
        return c
    }
}

// MARK: - Time formatting

func fmtTime(_ t: Double, frac: Bool = false) -> String {
    let tt = max(0, t)
    let h = Int(tt) / 3600, m = (Int(tt) % 3600) / 60, s = Int(tt) % 60
    let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    if frac { return base + String(format: ".%d", Int((tt - floor(tt)) * 10)) }
    return base
}

/// Parses "1:02:03.5", "02:03", "123.4"
func parseTime(_ s: String) -> Double? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    var total = 0.0
    for p in parts {
        guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
        total = total * 60 + v
    }
    return total
}
