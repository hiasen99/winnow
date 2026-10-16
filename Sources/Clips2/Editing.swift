import Foundation
import AppKit
import SwiftUI

/// A transcript word placed on the timeline (output time).
struct TLWord {
    var index: Int
    var text: String
    var start: Double
    var end: Double
    var hidden: Bool = false
}

enum TrimSide { case start, end }

/// Which block edge is being dragged.
struct TrimEdge: Equatable {
    var segment: Int        // index into Clip.segments
    var side: TrimSide
}

struct TrimDrag {
    var edge: TrimEdge
    var original: Clip
    var segments: [ClipSegment]
    var edgeMaster: Double  // where the edge was (master time)
    var current: Double     // where it is now (master time)
    var startX: CGFloat
    var spp: Double         // seconds per pixel when the drag began
    var outAt: Double       // output time of the edge when the drag began (for drawing)
}

extension ProjectModel {

    // MARK: - What the timeline shows

    var tlSegments: [ClipSegment] {
        if let c = selectedClip { return c.segments }
        return [ClipSegment(master: TimeRange(start: 0, end: project.masterDuration), outStart: 0, rangeIndex: 0,
                            splitBefore: false, splitAfter: false)]
    }

    var tlPieces: [EditPiece] {
        if selectedClip == nil, let a = fullViewAngle {
            return [EditPiece(outStart: 0, masterStart: 0, duration: project.masterDuration, angle: a)]
        }
        return Schedule.pieces(project: project, clip: selectedClip, auto: auto)
    }

    /// Transcript words in output time (memoised).
    func tlWords() -> [TLWord] {
        let c = selectedClip
        let key = "\(transcriptVersion)|\(project.words.count)|\(c?.id.uuidString ?? "full")|\(c?.ranges ?? [])"
        if let w = tlWordsCache, w.key == key { return w.words }
        var out: [TLWord] = []
        if let c {
            for (i, w) in project.words.enumerated() where w.end > c.start && w.start < c.end {
                let mid = (w.start + w.end) / 2
                guard let o = c.outputTime(forMaster: mid) else { continue }
                let s = c.outputTime(forMaster: max(w.start, c.start)) ?? o
                let e = c.outputTime(forMaster: min(w.end, c.end)) ?? o
                out.append(TLWord(index: i, text: w.text, start: min(s, o), end: max(e, o), hidden: w.isHidden))
            }
        } else {
            out = project.words.enumerated().map { TLWord(index: $0.offset, text: $0.element.text, start: $0.element.start, end: $0.element.end, hidden: $0.element.isHidden) }
        }
        tlWordsCache = (key, out)
        return out
    }

    /// Block edges and camera changes, in output time.
    func editPoints() -> [Double] {
        var pts = Set<Double>()
        for s in tlSegments { pts.insert((s.outStart * 1000).rounded() / 1000); pts.insert((s.outEnd * 1000).rounded() / 1000) }
        for p in tlPieces { pts.insert((p.outStart * 1000).rounded() / 1000) }
        return pts.sorted()
    }

    /// Up / down arrows: previous / next cut (camera change, block edge or blade point), like Final Cut.
    func jumpEditPoint(next: Bool) {
        if engine.isPlaying { engine.pause() }
        let t = engine.time
        let pts = editPoints()
        if next { if let p = pts.first(where: { $0 > t + 0.01 }) { engine.seek(min(p, tlDuration)) } }
        else { if let p = pts.last(where: { $0 < t - 0.01 }) { engine.seek(p) } }
    }

    // MARK: - Snapping

    /// Nearest word edge / playhead / marker / edit point (output time) within `tol` seconds.
    func snapOutput(_ t: Double, tol: Double, includePlayhead: Bool = true) -> Double {
        guard snapping else { return t }
        var best = t, bd = tol
        func consider(_ c: Double) { let d = abs(c - t); if d < bd { bd = d; best = c } }
        let ws = tlWords()
        var lo = 0, hi = ws.count - 1
        while lo <= hi { let mid = (lo + hi) / 2; if ws[mid].start < t { lo = mid + 1 } else { hi = mid - 1 } }
        for k in max(0, lo - 3)..<min(ws.count, lo + 3) { consider(ws[k].start); consider(ws[k].end) }
        for p in editPoints() { consider(p) }
        for (_, o) in markersOnTimeline() { consider(o) }
        if includePlayhead { consider(engine.time) }
        return best
    }

    /// Same, in master time (used while trimming an edge).
    func snapMaster(_ m: Double, tol: Double) -> Double {
        guard snapping else { return m }
        var best = m, bd = tol
        func consider(_ c: Double) { let d = abs(c - m); if d < bd { bd = d; best = c } }
        let ws = project.words
        var lo = 0, hi = ws.count - 1
        while lo <= hi { let mid = (lo + hi) / 2; if ws[mid].start < m { lo = mid + 1 } else { hi = mid - 1 } }
        for k in max(0, lo - 3)..<min(ws.count, lo + 3) { consider(ws[k].start - 0.03); consider(ws[k].end + 0.05) }
        for mk in project.markers ?? [] { consider(mk.time) }
        return best
    }

    // MARK: - Blocks: select, blade, delete

    func segmentIndex(atOutput t: Double) -> Int? {
        let segs = tlSegments
        return segs.firstIndex { t >= $0.outStart - 1e-6 && t < $0.outEnd } ?? (segs.isEmpty ? nil : segs.count - 1)
    }

    /// Click on a block: select the whole block (Delete removes it).
    func selectSegment(atOutput t: Double) {
        guard selectedClip != nil, let k = segmentIndex(atOutput: t) else { return }
        let s = tlSegments[k]
        tlSel = s.outStart...s.outEnd
        tlSegmentSelected = true
    }

    /// B / ⌘B: split the block at the playhead.
    func bladeAtPlayhead() {
        guard let c = selectedClip else {
            notice = "The blade works inside a clip. On the full recording, select a stretch and press C to make a clip."
            return
        }
        let m = c.masterTime(forOutput: engine.time)
        guard c.ranges.contains(where: { m > $0.start + 0.05 && m < $0.end - 0.05 }) else { return }
        // a shot framed on its own keeps that framing on both sides of the new cut
        let shot = shotAtPlayhead
        updateClip { clip in
            clip.splits = (clip.splits ?? []) + [m]
            if let pc = shot, let k = clip.shotFramingIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle),
               var list = clip.shotFraming {
                let s = list[k]
                list[k].time = (pc.masterStart + m) / 2
                var copy = s; copy.time = (m + pc.masterStart + pc.duration) / 2
                list.append(copy)
                clip.shotFraming = list
            }
        }
    }

    /// Removes the blade split at an edit point (output time), joining the two blocks again.
    func joinSplit(atOutput t: Double) {
        guard let c = selectedClip else { return }
        let m = c.masterTime(forOutput: t)
        updateClip { clip in clip.splits?.removeAll { abs($0 - m) < 0.02 } }
    }

    /// Fills the gap at an edit point (puts back what was cut between two blocks).
    func closeGap(afterRange i: Int) {
        guard let c = selectedClip, i + 1 < c.ranges.count else { return }
        let a = c.ranges[i].end, b = c.ranges[i + 1].start
        updateClip { $0.restore(a, b) }
        notice = String(format: "Put back %.1f s.", b - a)
    }

    // MARK: - Trimming edges with the mouse

    /// The clip with one block edge moved to master time `m` (ripple trim: everything after slides).
    func trimmed(_ original: Clip, segments: [ClipSegment], edge: TrimEdge, to m: Double) -> Clip {
        var c = original
        guard edge.segment < segments.count else { return c }
        let seg = segments[edge.segment]
        let i = seg.rangeIndex
        let maxT = project.masterDuration
        switch edge.side {
        case .end:
            if seg.splitAfter {
                // a blade point: material can only be taken away here
                let v = max(seg.master.start + 0.1, min(m, seg.master.end))
                if v < seg.master.end - 0.001 { c.cut(v, seg.master.end) }
            } else {
                let hi = i + 1 < c.ranges.count ? c.ranges[i + 1].start : maxT
                c.ranges[i].end = max(seg.master.start + 0.1, min(m, hi))
                c.normalizeRanges()
            }
        case .start:
            if seg.splitBefore {
                let v = min(seg.master.end - 0.1, max(m, seg.master.start))
                if v > seg.master.start + 0.001 { c.cut(seg.master.start, v) }
            } else {
                let lo = i > 0 ? c.ranges[i - 1].end : 0
                c.ranges[i].start = min(seg.master.end - 0.1, max(m, lo))
                c.normalizeRanges()
            }
        }
        return c
    }

    func beginTrim(_ edge: TrimEdge, x: CGFloat, secondsPerPixel spp: Double) {
        guard let c = selectedClip else { return }
        let segs = c.segments
        guard edge.segment < segs.count else { return }
        engine.pause(); engine.endSkim()
        let s = segs[edge.segment]
        let m = edge.side == .end ? s.master.end : s.master.start
        trimDrag = TrimDrag(edge: edge, original: c, segments: segs, edgeMaster: m, current: m, startX: x, spp: spp,
                            outAt: edge.side == .end ? s.outEnd : s.outStart)
        tlSel = nil
        beginGesture()
    }

    func updateTrim(x: CGFloat) {
        guard var d = trimDrag, let i = clipIndex else { return }
        var m = d.edgeMaster + Double(x - d.startX) * d.spp
        m = snapMaster(m, tol: 8 * d.spp)
        d.current = m
        trimDrag = d
        let new = trimmed(d.original, segments: d.segments, edge: d.edge, to: m)
        if project.clips[i] != new { liveEdit { $0.clips[i] = new } }
    }

    func endTrim() {
        guard let d = trimDrag else { return }
        trimDrag = nil
        endGesture()
        recomputeAuto()
        let c = selectedClip ?? d.original
        let delta = c.outputDuration - d.original.outputDuration
        // land on the frame just inside the trimmed edge
        let target = min(max(0, c.outputTimeClamped(forMaster: d.current) - (d.edge.side == .end ? 0.04 : 0)), c.outputDuration)
        rebuild(at: target, play: false)
        if abs(delta) > 0.005 { notice = String(format: "%@ %.2f s", delta > 0 ? "Added" : "Removed", abs(delta)) }
    }

    /// ⌥[ / ⌥] : the clip starts / ends at the playhead.
    func trimStartToPlayhead() {
        guard let c = selectedClip else { return }
        let m = c.masterTime(forOutput: engine.time)
        guard m > c.start + 0.02, m < c.end - 0.2 else { return }
        updateClip { $0.cut($0.start, m) }
        engine.seek(0)
    }
    func trimEndToPlayhead() {
        guard let c = selectedClip else { return }
        let m = c.masterTime(forOutput: engine.time)
        guard m < c.end - 0.02, m > c.start + 0.2 else { return }
        updateClip { $0.cut(m, $0.end) }
    }

    // MARK: - Range (I / O)

    func setRangeIn() {
        let t = engine.time
        let hi = tlSel?.upperBound ?? tlDuration
        tlSel = t < hi - 0.02 ? t...hi : t...tlDuration
    }
    func setRangeOut() {
        let t = engine.time
        let lo = tlSel?.lowerBound ?? 0
        tlSel = lo < t - 0.02 ? lo...t : 0...t
    }

    // MARK: - Markers

    func markersOnTimeline() -> [(Marker, Double)] {
        (project.markers ?? []).compactMap { mk in outputTime(mk.time).map { (mk, $0) } }
    }
    func addMarker() {
        let m = masterTime(engine.time)
        edit(rebuild: false) { p in
            var ms = p.markers ?? []
            ms.removeAll { abs($0.time - m) < 0.05 }
            ms.append(Marker(time: m, name: "Marker \(ms.count + 1)"))
            p.markers = ms.sorted { $0.time < $1.time }
        }
    }
    func deleteMarker(_ id: UUID) {
        edit(rebuild: false) { p in p.markers?.removeAll { $0.id == id }; if p.markers?.isEmpty == true { p.markers = nil } }
    }
    func renameMarker(_ id: UUID, _ name: String) {
        edit(rebuild: false) { p in
            if let k = p.markers?.firstIndex(where: { $0.id == id }) { p.markers?[k].name = name }
        }
    }
    func askRenameMarker(_ mk: Marker) {
        let a = NSAlert()
        a.messageText = "Rename marker"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = mk.name
        a.accessoryView = f
        a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { renameMarker(mk.id, f.stringValue) }
    }

    // MARK: - Review marks

    func setStatus(_ s: ClipStatus?, for id: UUID? = nil) {
        guard let id = id ?? selectedClipID, let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        edit(rebuild: false) { $0.clips[i].status = s }
    }
    func toggleStatus(_ s: ClipStatus, for id: UUID? = nil) {
        guard let id = id ?? selectedClipID, let c = project.clips.first(where: { $0.id == id }) else { return }
        setStatus(c.status == s ? nil : s, for: id)
    }

    // MARK: - Fixing the transcript

    func beginEditingText() {
        engine.pause()
        if let s = selection { editingWords = s }
        else if let w = currentWord { editingWords = w...w }
        else { notice = "Select the words to fix first (or double-click a word)." }
    }

    func text(of r: ClosedRange<Int>) -> String {
        guard r.upperBound < project.words.count else { return "" }
        return project.words[r].map { $0.text }.joined(separator: " ")
    }

    static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
    }
    static func splitPunct(_ s: String) -> (lead: String, core: String, trail: String) {
        let chars = Array(s)
        var a = 0, b = chars.count
        while a < b, !(chars[a].isLetter || chars[a].isNumber) { a += 1 }
        while b > a, !(chars[b - 1].isLetter || chars[b - 1].isNumber) { b -= 1 }
        return (String(chars[..<a]), String(chars[a..<b]), String(chars[b...]))
    }

    /// Every place the same words were heard (ignoring case and punctuation), not overlapping.
    func occurrences(of r: ClosedRange<Int>) -> [ClosedRange<Int>] {
        let ws = project.words
        guard r.upperBound < ws.count else { return [r] }
        let key = ws[r].map { Self.norm($0.text) }
        guard !key.joined().isEmpty else { return [r] }
        let n = key.count
        let normed = ws.map { Self.norm($0.text) }
        var out: [ClosedRange<Int>] = []
        var i = 0
        while i + n <= ws.count {
            if Array(normed[i..<(i + n)]) == key { out.append(i...(i + n - 1)); i += n } else { i += 1 }
        }
        return out.isEmpty ? [r] : out
    }

    /// Replaces the words in `r` with `text` (timing spread over the same stretch). `everywhere` fixes
    /// every place the same words were heard. Empty text removes the words from the transcript.
    func correctWords(_ r: ClosedRange<Int>, to text: String, everywhere: Bool) {
        guard r.upperBound < project.words.count else { editingWords = nil; return }
        let typed = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if typed == project.words[r].map({ $0.text }) && !everywhere { editingWords = nil; return }
        let targets = everywhere ? occurrences(of: r) : [r]
        // the typed words without their outer punctuation (each other place keeps its own)
        var core = typed
        if !core.isEmpty {
            let n = core.count
            let p0 = Self.splitPunct(core[0])
            let first = n == 1 ? p0.core : p0.core + p0.trail
            core[0] = first
            if n > 1 {
                let pl = Self.splitPunct(core[n - 1])
                core[n - 1] = pl.lead + pl.core
            }
            core = core.filter { !$0.isEmpty }
        }
        edit { p in
            for occ in targets.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                let old = Array(p.words[occ])
                var toks = typed
                if occ != r, !core.isEmpty {
                    toks = core
                    let lead = Self.splitPunct(old.first!.text).lead, trail = Self.splitPunct(old.last!.text).trail
                    toks[0] = lead + toks[0]
                    toks[toks.count - 1] += trail
                }
                p.words.replaceSubrange(occ, with: Self.spread(toks, over: old))
            }
        }
        transcriptVersion += 1
        selection = nil
        editingWords = nil
        if targets.count > 1 { notice = "Fixed \(targets.count) places in the transcript." }
        Log.write("transcript fix: \(targets.count) place(s) -> \(text)")
    }

    /// New words over the old words' time: same count keeps each word's own timing.
    static func spread(_ toks: [String], over old: [Word]) -> [Word] {
        guard let first = old.first, let last = old.last else { return [] }
        if toks.count == old.count {
            return zip(toks, old).map { var w = $1; w.text = $0; return w }
        }
        let weights = toks.map { Double(max(1, $0.count)) + 1 }
        let total = weights.reduce(0, +)
        let span = max(0.05, last.end - first.start)
        var t = first.start
        return zip(toks, weights).map { tok, w in
            let d = span * w / total
            defer { t += d }
            return Word(text: tok, start: t, end: t + d * 0.94, speaker: first.speaker)
        }
    }

    // MARK: - Hiding words (kept in the video, left out of the transcript and captions)

    var hiddenWordCount: Int { project.words.reduce(0) { $0 + ($1.isHidden ? 1 : 0) } }

    /// true when every word in `r` is hidden
    func allHidden(_ r: ClosedRange<Int>) -> Bool {
        r.upperBound < project.words.count && project.words[r].allSatisfy { $0.isHidden }
    }

    /// Hides words from the transcript and captions (or shows them again). The video and sound are not touched.
    /// `everywhere` does the same to every place the same words were heard.
    func setHidden(_ r: ClosedRange<Int>, _ hide: Bool, everywhere: Bool = false) {
        guard r.upperBound < project.words.count else { return }
        let targets = everywhere ? occurrences(of: r) : [r]
        var what = text(of: r)
        if what.count > 30 { what = String(what.prefix(30)) + "…" }
        edit(rebuild: selectedClip != nil) { p in
            for occ in targets { for i in occ where i < p.words.count { p.words[i].hidden = hide ? true : nil } }
        }
        transcriptVersion += 1
        selection = nil
        let places = targets.count > 1 ? " in \(targets.count) places" : ""
        if hide {
            notice = "Hid “\(what)”\(places). It stays in the video but is left out of the transcript and captions."
                + (showHiddenWords ? "" : " Click the eye above the transcript to see hidden words.")
        } else {
            notice = "“\(what)” is back in the transcript and captions\(places)."
        }
        Log.write("words \(hide ? "hidden" : "shown"): \(targets.count) place(s) '\(what)'")
    }

    /// H: hide the selected words, or show them again if they're all hidden.
    func toggleHiddenSelection() {
        guard let s = selection else { notice = "Select the words to hide first."; return }
        setHidden(s, !allHidden(s))
    }

    // MARK: - Framing

    /// Centre positions that keep the frame filled (no black edges), for an angle at a zoom.
    func framingLimits(angle i: Int, format: ClipFormat, zoom: Double) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        guard i < sources.count, let l = sources[i] else { return (0...1, 0...1) }
        let render = format.renderSize
        let W = max(1, l.naturalSize.width), H = max(1, l.naturalSize.height)
        let s = max(render.width / W, render.height / H) * CGFloat(max(1, zoom))
        let hx = min(0.5, Double(render.width / (2 * W * s))), hy = min(0.5, Double(render.height / (2 * H * s)))
        return (hx...(1 - hx), hy...(1 - hy))
    }

    func setFraming(_ i: Int, _ f: Framing) {
        updateClipLive { c in
            while c.framing.count <= i { c.framing.append(Framing()) }
            c.framing[i] = f
        }
    }

    /// The camera on screen at the playhead.
    var angleOnScreen: Int? { shotAtPlayhead?.angle }

    /// The shot (one camera between two cuts) at the playhead.
    var shotAtPlayhead: EditPiece? {
        guard selectedClip != nil else { return nil }
        return tlPieces.last(where: { $0.outStart <= engine.time + 1e-4 })
    }

    func shotHasOwnFraming(_ pc: EditPiece) -> Bool {
        selectedClip?.shotFramingIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle) != nil
    }
    /// How a shot looks right now (its own framing, or its camera's).
    func framing(of pc: EditPiece) -> Framing {
        selectedClip?.framing(forShotFrom: pc.masterStart, to: pc.masterStart + pc.duration, angle: pc.angle) ?? Framing()
    }

    /// Dragging in the viewer and the framing sliders change this shot only (rather than every shot from its camera):
    /// when the shot already has its own framing, or "This shot" is picked.
    func framesShot(_ pc: EditPiece) -> Bool { shotHasOwnFraming(pc) || frameScope == .shot }

    /// Gives a shot its own framing (made from the camera's framing the first time). Live: one undo step per gesture.
    func setShotFraming(_ pc: EditPiece, _ f: Framing) {
        updateClipLive { c in
            var list = c.shotFraming ?? []
            if let k = c.shotFramingIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle) {
                list[k].x = f.x; list[k].y = f.y; list[k].zoom = f.zoom
            } else {
                list.append(ShotFraming(time: pc.masterStart + pc.duration / 2, angle: pc.angle, x: f.x, y: f.y, zoom: f.zoom))
            }
            c.shotFraming = list
        }
    }
    /// The shot goes back to its camera's framing.
    func removeShotFraming(_ pc: EditPiece) {
        updateClip { c in
            guard let k = c.shotFramingIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle) else { return }
            c.shotFraming?.remove(at: k)
            if c.shotFraming?.isEmpty == true { c.shotFraming = nil }
        }
    }
    func removeAllShotFraming() { updateClip { $0.shotFraming = nil } }

    /// Changes the framing of the shot at the playhead, or of its camera, whichever `framesShot` says.
    func setFramingAtPlayhead(_ f: Framing) {
        guard let pc = shotAtPlayhead else { return }
        if framesShot(pc) { setShotFraming(pc, f) } else { setFraming(pc.angle, f) }
    }

    /// Dragging the picture in the viewer: it follows the mouse. `dx`, `dy` in view points (y up), `k` = view points per render pixel.
    func dragFraming(dx: CGFloat, dy: CGFloat, k: CGFloat) {
        guard let c = selectedClip, let pc = shotAtPlayhead, pc.angle < sources.count, let l = sources[pc.angle] else { return }
        let a = pc.angle
        var f = framing(of: pc)
        let render = c.format.renderSize
        let W = max(1, l.naturalSize.width), H = max(1, l.naturalSize.height)
        let s = max(render.width / W, render.height / H) * CGFloat(max(1, f.zoom))
        let lim = framingLimits(angle: a, format: c.format, zoom: f.zoom)
        f.x = min(lim.x.upperBound, max(lim.x.lowerBound, min(lim.x.upperBound, max(lim.x.lowerBound, f.x)) - Double(dx / max(0.0001, k) / (W * s))))
        f.y = min(lim.y.upperBound, max(lim.y.lowerBound, min(lim.y.upperBound, max(lim.y.lowerBound, f.y)) + Double(dy / max(0.0001, k) / (H * s))))
        setFramingAtPlayhead(f)
    }

    func pinchFraming(_ m: CGFloat) {
        guard let pc = shotAtPlayhead else { return }
        var f = framing(of: pc)
        f.zoom = min(2.5, max(1, f.zoom * Double(1 + m)))
        setFramingAtPlayhead(f)
    }

    /// Can the picture be moved in the viewer right now?
    var canDragFraming: Bool {
        guard let c = selectedClip, let pc = shotAtPlayhead else { return false }
        let lim = framingLimits(angle: pc.angle, format: c.format, zoom: framing(of: pc).zoom)
        return lim.x.upperBound - lim.x.lowerBound > 0.001 || lim.y.upperBound - lim.y.lowerBound > 0.001
    }

    func copyFramingToAllClips() {
        guard let c = selectedClip else { return }
        let others = project.clips.filter { $0.id != c.id && $0.format == c.format }.count
        edit(rebuild: false) { p in
            for k in p.clips.indices where p.clips[k].id != c.id && p.clips[k].format == c.format { p.clips[k].framing = c.framing }
        }
        notice = "Used this framing on \(others) other \(c.format.label) clip\(others == 1 ? "" : "s")."
    }
}
