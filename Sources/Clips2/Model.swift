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

/// How an angle is framed inside the clip's frame. x/y = centre of the crop (0...1), zoom >= 1.
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
    /// Kept pieces in master time, sorted, non-overlapping. Removing words splits a range.
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

    var start: Double { ranges.first?.start ?? 0 }
    var end: Double { ranges.last?.end ?? 0 }
    var outputDuration: Double { ranges.reduce(0) { $0 + $1.duration } }

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

    /// master -> output time; a moment inside a removed part maps to where playback resumes.
    func outputTimeClamped(forMaster t: Double) -> Double {
        if let o = outputTime(forMaster: t) { return o }
        var acc = 0.0
        for r in ranges {
            if r.start >= t { return acc }
            acc += r.duration
        }
        return acc
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
        let sorted = ranges.filter { $0.duration > 0.02 }.sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in sorted {
            if var last = out.last, r.start <= last.end + 0.001 {
                last.end = max(last.end, r.end); out[out.count - 1] = last
            } else { out.append(r) }
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
        ranges.append(TimeRange(start: a, end: b))
        normalizeRanges()
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

    var wordBoxOn: Bool { wordBox ?? false }
    var wordBoxRGBA: RGBA { wordBoxColor ?? RGBA(r: 1, g: 0.83, b: 0, a: 1) }
    var wordBoxRoundness: Double { wordBoxRound ?? 0.35 }
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
