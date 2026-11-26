import Foundation
import SwiftUI

// MARK: - Tighten Clip: shorten long pauses and cut stray words (um, uh, stutters, false starts)

/// What Tighten looks for. Saved between uses (UserDefaults).
struct TightenSettings: Codable, Equatable {
    var pauseOver: Double = 0.5      // pauses longer than this get shortened…
    var keepPause: Double = 0.25     // …to this
    var fillers = true               // um, uh, er… that are in the transcript
    var repeats = true               // "I I", "the the", "and-" (the first try is cut)
    var sounds = true                // short sounds between words that aren't in the transcript (an "um" it didn't write down)
    var edges = true                 // dead air before the first word and after the last

    static let key = "tightenSettings"
    static func load() -> TightenSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(TightenSettings.self, from: d) else { return TightenSettings() }
        return s
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) } }
}

enum TightenKind: String, Codable {
    case pause, filler, repeatWord = "repeat", sound, edge
    var label: String {
        switch self {
        case .pause: return "Pause"
        case .filler: return "Um / uh"
        case .repeatWord: return "Repeat"
        case .sound: return "Sound"
        case .edge: return "Dead air"
        }
    }
}

/// One stretch Tighten would take out (recording seconds).
struct TightenCut: Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var kind: TightenKind
    var text: String          // what's cut, for the list ("1.4 s", "um", "I")
    var on = true
    var length: Double { end - start }
}

enum Tighten {
    static let fillerWords: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "ahh", "hmm", "hm", "mm", "eh"]
    /// Doubled words that are often meant ("had had", "that that", "very very").
    static let fineDoubles: Set<String> = ["had", "that", "very", "so", "no", "yeah", "bye", "really", "ha", "more", "now", "go", "far", "many", "much", "long", "well", "yes", "too"]

    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "'" })
    }

    /// A word that's a false start ("and-", "bec—").
    static func isFalseStart(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"”“'’"))
        return t.hasSuffix("-") || t.hasSuffix("—") || t.hasSuffix("–")
    }

    /// The cuts Tighten would make in `clip`. `level(t)` = loudness (dB) of what you hear at recording time t (nil = no sound data).
    static func plan(clip: Clip, words allWords: [Word], settings s: TightenSettings, level: ((Double) -> Float)?) -> [TightenCut] {
        // words that play in the clip, in order
        let ws = allWords.filter { w in !w.isHidden && clip.outputTime(forMaster: (w.start + w.end) / 2) != nil }
            .sorted { $0.start < $1.start }
        guard !ws.isEmpty else { return [] }
        func range(of t: Double) -> Int? { clip.ranges.firstIndex { t >= $0.start && t <= $0.end } }

        // which words are stray
        var stray = [TightenKind?](repeating: nil, count: ws.count)
        for i in ws.indices {
            let n = norm(ws[i].text)
            if s.fillers, fillerWords.contains(n) { stray[i] = .filler; continue }
            if s.repeats, isFalseStart(ws[i].text) { stray[i] = .repeatWord; continue }
            if s.repeats, i + 1 < ws.count, !n.isEmpty, n == norm(ws[i + 1].text), !fineDoubles.contains(n),
               ws[i + 1].start - ws[i].end < 0.8 { stray[i] = .repeatWord }
        }

        // how loud speech is here (to tell an untranscribed "um" from breath and room noise)
        var speech: Float = -20
        if let level {
            let mids = ws.map { level(($0.start + $0.end) / 2) }.sorted()
            if !mids.isEmpty { speech = mids[mids.count / 2] }
        }
        let loudThr = speech - 18

        var cuts: [TightenCut] = []
        let lead = s.keepPause * 0.4, tail = s.keepPause * 0.6     // pause kept after a word / before the next
        let kept = ws.indices.filter { stray[$0] == nil }
        // Word ends from the aligner can be early (a long vowel rings on), so every cut waits for real quiet.
        let quietThr = speech - 24
        func quiet(_ t: Double) -> Bool { level.map { $0(t) < quietThr } ?? true }
        /// first moment at or after t0 that stays quiet for 50 ms (limit if none)
        func quietAfter(_ t0: Double, limit: Double) -> Double {
            guard level != nil else { return t0 }
            var t = t0
            while t < limit { if (0..<5).allSatisfy({ quiet(t + Double($0) * 0.01) }) { return t }; t += 0.01 }
            return limit
        }
        /// last moment at or before t1 that has 50 ms of quiet before it (limit if none)
        func quietBefore(_ t1: Double, limit: Double) -> Double {
            guard level != nil else { return t1 }
            var t = t1
            while t > limit { if (1...5).allSatisfy({ quiet(t - Double($0) * 0.01) }) { return t }; t -= 0.01 }
            return limit
        }

        // between each pair of kept words
        for (a, b) in zip(kept, kept.dropFirst()) {
            let A = ws[a], B = ws[b]
            guard let ra = range(of: A.end), let rb = range(of: B.start), ra == rb else { continue }   // never across a cut or moved block
            let removed = (a + 1..<b).filter { stray[$0] != nil }
            if !removed.isEmpty {
                let R0 = ws[removed.first!], R1 = ws[removed.last!]
                let text = removed.map { ws[$0].text }.joined(separator: " ")
                let kind = stray[removed[0]] ?? .filler
                let qa = quietAfter(A.end, limit: R0.start), qb = quietBefore(B.start, limit: R1.end)
                let s0 = qa >= R0.start ? R0.start - 0.01 : min(qa + lead, R0.start - 0.01)
                let e0 = qb <= R1.end ? R1.end + 0.01 : max(qb - tail, R1.end + 0.01)
                if e0 > s0 + 0.03 { cuts.append(TightenCut(start: s0, end: e0, kind: kind, text: text)) }
                continue
            }
            guard B.start - A.end > 0.25 else { continue }
            let qa = quietAfter(A.end, limit: B.start), qb = quietBefore(B.start, limit: qa)
            guard qb - qa > 0.1 else { continue }                       // no real gap between the two words
            // anything loud between the quiet edges is a sound the transcript left out (an um, a cough)
            var loud = 0.0
            if level != nil { var t = qa; while t < qb { if !quiet(t) { loud += 0.01 }; t += 0.01 } }
            let silence = qb - qa - loud
            if loud >= 0.08 {
                if s.sounds, loud <= 0.8 {
                    let s0 = qa + lead, e0 = qb - tail
                    if e0 > s0 + 0.05 { cuts.append(TightenCut(start: s0, end: e0, kind: .sound, text: String(format: "%.1f s with a sound", qb - qa))) }
                }
                continue
            }
            if silence > s.pauseOver, (qb - tail) - (qa + lead) > 0.05 {
                cuts.append(TightenCut(start: qa + lead, end: qb - tail, kind: .pause, text: String(format: "%.1f s", qb - qa)))
            }
        }

        // dead air before the first kept word and after the last
        if s.edges, let f = kept.first, let l = kept.last {
            let first = ws[f], last = ws[l]
            if let r0 = clip.ranges.first, range(of: first.start) == 0 {
                let qb = quietBefore(first.start, limit: r0.start)
                if qb - r0.start > s.pauseOver, qb - tail > r0.start + 0.05 {
                    cuts.append(TightenCut(start: r0.start, end: qb - tail, kind: .edge, text: String(format: "%.1f s at the start", qb - r0.start)))
                }
            }
            if let rl = clip.ranges.last, range(of: last.end) == clip.ranges.count - 1 {
                let qa = quietAfter(last.end, limit: rl.end)
                if rl.end - qa > s.pauseOver + 0.2 {
                    cuts.append(TightenCut(start: qa + 0.35, end: rl.end, kind: .edge, text: String(format: "%.1f s at the end", rl.end - qa)))
                }
            }
            // stray words at the very start or end (outside any kept pair)
            for i in ws.indices where stray[i] != nil && (i < f || i > l) {
                cuts.append(TightenCut(start: max(ws[i].start - 0.02, i > 0 ? ws[i - 1].end : ws[i].start - 0.02),
                                       end: ws[i].end, kind: stray[i]!, text: ws[i].text))
            }
        }
        // keep at least a little of the clip
        var total = clip.outputDuration
        var out: [TightenCut] = []
        // a pause or sound cut shorter than 0.12 s only makes a jump
        for c in cuts.sorted(by: { $0.start < $1.start }) where c.end > c.start && (c.length >= 0.12 || c.kind == .filler || c.kind == .repeatWord) {
            if total - c.length < 0.5 { break }
            out.append(c); total -= c.length
        }
        return out
    }
}

// MARK: - Model

extension ProjectModel {
    /// Loudness (dB) of what's heard in `clip` at recording time t: the loudest source that's on.
    func tightenLevel(for clip: Clip) -> ((Double) -> Float)? {
        let p = project
        let heard = audibleSources(clip).filter { $0 < envelopes.count && envelopes[$0] != nil && p.angles[$0].hasAudio }
        guard !heard.isEmpty else { return nil }
        let envs = heard.map { (envelopes[$0]!, p.angles[$0].offset, Float(p.angles[$0].gainDB)) }
        return { t in
            var mx: Float = -120
            for (e, off, g) in envs {
                let k = Int(((t + off) * AudioAnalysis.envRate).rounded())
                if k >= 0, k < e.count { mx = max(mx, e[k] + g) }
            }
            return mx
        }
    }

    func tightenPlan(_ clip: Clip, _ s: TightenSettings) -> [TightenCut] {
        Tighten.plan(clip: clip, words: project.words, settings: s, level: tightenLevel(for: clip))
    }

    /// Takes the cuts that are on out of the clip: one Undo step. Each one shows on the timeline as a cut you can put back.
    @discardableResult
    func applyTighten(clipID: UUID, _ cuts: [TightenCut]) -> String {
        let on = cuts.filter { $0.on }
        guard let i = project.clips.firstIndex(where: { $0.id == clipID }), !on.isEmpty else { return "Nothing to cut." }
        let before = project.clips[i].outputDuration
        edit(rebuild: selectedClipID == clipID) { p in
            for c in on { p.clips[i].cut(c.start, c.end) }
            p.clips[i].normalizeRanges()
        }
        let after = project.clips[i].outputDuration
        func n(_ k: [TightenKind], _ one: String, _ many: String) -> String? {
            let c = on.filter { k.contains($0.kind) }.count
            return c == 0 ? nil : "\(c) \(c == 1 ? one : many)"
        }
        let parts = [n([.pause, .edge], "pause", "pauses"), n([.filler], "um/uh", "ums/uhs"), n([.repeatWord], "repeat", "repeats"),
                     n([.sound], "stray sound", "stray sounds")].compactMap { $0 }
        let msg = "Tightened: " + parts.joined(separator: ", ") + String(format: " — %.1f s shorter (%.1f → %.1f s). Undo puts it back.", before - after, before, after)
        notice = msg
        return msg
    }
}

// MARK: - Transcript drift

extension ProjectModel {
    /// The transcript ran on a slightly different clock from the picture (e.g. it came from a separate recorder):
    /// word time = offset + scale × true time. Moves every word and every hand-edited caption to the true time.
    /// Clips (starts, ends, cuts) stay where they are. One Undo step.
    @discardableResult
    func fixTranscriptDrift(offset: Double, scale: Double) -> String {
        guard scale > 0.98, scale < 1.02 else { return "Scale must be close to 1." }
        func f(_ t: Double) -> Double { (t - offset) / scale }
        var moved = 0
        edit { p in
            for i in p.words.indices { p.words[i].start = f(p.words[i].start); p.words[i].end = f(p.words[i].end) }
            for c in p.clips.indices {
                guard var bs = p.clips[c].captionBlocks else { continue }
                for k in bs.indices {
                    bs[k].start = f(bs[k].start); bs[k].end = f(bs[k].end)
                    for w in bs[k].words.indices { bs[k].words[w].start = f(bs[k].words[w].start); bs[k].words[w].end = f(bs[k].words[w].end) }
                    if let cv = bs[k].covers { bs[k].covers = TimeRange(start: f(cv.start), end: f(cv.end)) }
                    moved += 1
                }
                p.clips[c].captionBlocks = bs
            }
        }
        let end = project.masterDuration
        let msg = String(format: "Moved %d words and %d hand-edited captions: %+.2f s at the start, %+.2f s at the end. Clips unchanged. Undo puts it back.",
                         project.words.count, moved, f(0) - 0, f(end * scale + offset) - (end * scale + offset))
        notice = msg
        return msg
    }
}

// MARK: - Sheet

struct TightenSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) var dismiss
    @State private var s = TightenSettings.load()
    @State private var cuts: [TightenCut] = []
    @State private var selected: UUID? = nil

    func replan() {
        guard let c = model.selectedClip else { cuts = []; return }
        let offIDs = Set(cuts.filter { !$0.on }.map { "\($0.kind.rawValue)|\(Int($0.start * 10))" })
        cuts = model.tightenPlan(c, s).map { var x = $0; if offIDs.contains("\(x.kind.rawValue)|\(Int(x.start * 10))") { x.on = false }; return x }
        s.save()
    }
    var cutTotal: Double { cuts.filter { $0.on }.reduce(0) { $0 + $1.length } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tighten Clip", systemImage: "scissors").font(.title3.weight(.semibold))
                Spacer()
                if let c = model.selectedClip {
                    Text(String(format: "%.1f s → %.1f s", c.outputDuration, c.outputDuration - cutTotal)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Form {
                HStack {
                    Text("Shorten pauses longer than")
                    Slider(value: $s.pauseOver, in: 0.3...2.0, step: 0.05)
                    Text(String(format: "%.2f s", s.pauseOver)).monospacedDigit().frame(width: 52)
                }
                HStack {
                    Text("Leave this much pause")
                    Slider(value: $s.keepPause, in: 0.05...0.6, step: 0.05)
                    Text(String(format: "%.2f s", s.keepPause)).monospacedDigit().frame(width: 52)
                }
                Toggle("Cut ums and uhs in the transcript", isOn: $s.fillers)
                Toggle("Cut repeated words and false starts (\"I I\", \"and-\")", isOn: $s.repeats)
                Toggle("Cut short sounds the transcript left out (an um it didn't write down)", isOn: $s.sounds)
                Toggle("Cut dead air before the first word and after the last", isOn: $s.edges)
            }
            .formStyle(.grouped)
            .frame(height: 250)
            Text(cuts.isEmpty ? "Nothing to cut with these settings." :
                    "\(cuts.filter { $0.on }.count) of \(cuts.count) cuts on. Click one to hear the moment; untick any you want to keep.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selected) {
                ForEach($cuts) { $c in
                    HStack {
                        Toggle("", isOn: $c.on).labelsHidden()
                        Text(timeLabel(c)).monospacedDigit().frame(width: 60, alignment: .leading)
                        Text(c.kind.label).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                        Text(c.text).lineLimit(1)
                        Spacer()
                        Text(String(format: "−%.2f s", c.length)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(c.id)
                }
            }
            .frame(minHeight: 200)
            .onChange(of: selected) { _, id in
                guard let id, let c = cuts.first(where: { $0.id == id }), let clip = model.selectedClip,
                      let o = clip.outputTime(forMaster: c.start) else { return }
                model.engine.seek(max(0, o - 1.0))
                model.engine.play()
            }
            HStack {
                Button("All on") { for i in cuts.indices { cuts[i].on = true } }
                Button("All off") { for i in cuts.indices { cuts[i].on = false } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(format: "Cut %.1f s", cutTotal)) {
                    if let id = model.selectedClipID { model.applyTighten(clipID: id, cuts) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cuts.filter { $0.on }.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560, height: 640)
        .onAppear { replan() }
        .onChange(of: s) { _, _ in replan() }
    }

    func timeLabel(_ c: TightenCut) -> String {
        guard let clip = model.selectedClip, let o = clip.outputTime(forMaster: c.start) else { return "" }
        return String(format: "%d:%04.1f", Int(o) / 60, o.truncatingRemainder(dividingBy: 60))
    }
}
