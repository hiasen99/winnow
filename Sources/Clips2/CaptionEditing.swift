import Foundation
import AppKit

/// A caption as the timeline and the captions panel show it (output time).
struct CaptionItem: Identifiable, Hashable {
    var id: UUID
    var start: Double
    var end: Double
    var text: String
    var isHand: Bool        // edited by hand (false = still automatic from the transcript)
}

/// A caption being moved or re-timed on the timeline.
struct CaptionDrag {
    enum Mode { case move, start, end }
    var id: UUID
    var mode: Mode
    var original: [CaptionBlock]
    var anchor: Double      // output time where the mouse went down
}

extension ProjectModel {

    /// An automatic caption's id comes from where it starts, so it keeps its identity once it's edited.
    static func autoCaptionID(_ masterStart: Double) -> UUID {
        let ms = UInt64(max(0, (masterStart * 1000).rounded()))
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llX", ms)) ?? UUID()
    }

    private func captionKey(_ c: Clip) -> String {
        "\(c.id)|\(c.ranges.hashValue)|\(c.captionBlocks?.hashValue ?? 0)|\(c.format.rawValue)|\(project.captionStyle.hashValue)|\(transcriptVersion)|\(project.words.count)"
    }

    /// One id per caption page: hand-edited ones keep theirs, automatic ones get one from where they start (never a duplicate).
    func captionIDs(_ t: CaptionTrack, clip c: Clip) -> [UUID] {
        var used = Set((c.captionBlocks ?? []).map { $0.id })
        return t.pages.map { p in
            if let id = p.blockID { return id }
            var m = p.wordIndexes.first.map { t.words[$0].mStart } ?? c.masterTime(forOutput: p.start)
            var id = Self.autoCaptionID(m)
            while used.contains(id) { m += 0.001; id = Self.autoCaptionID(m) }
            used.insert(id)
            return id
        }
    }

    /// The selected clip's captions (memoised).
    var captionItems: [CaptionItem] {
        guard let c = selectedClip else { return [] }
        let key = captionKey(c)
        if let cc = captionCache, cc.key == key { return cc.items }
        let t = Captions.track(for: c, project: project)
        let ids = captionIDs(t, clip: c)
        let items: [CaptionItem] = t.pages.enumerated().map { k, p in
            let idx = p.wordIndexes
            return CaptionItem(id: ids[k], start: p.start, end: p.end, text: idx.map { t.words[$0].raw }.joined(separator: " "),
                               isHand: p.blockID != nil)
        }
        captionCache = (key, items)
        return items
    }

    var captionsEdited: Bool { !(selectedClip?.captionBlocks ?? []).isEmpty }

    func captionItem(_ id: UUID?) -> CaptionItem? {
        guard let id else { return nil }
        return captionItems.first { $0.id == id }
    }

    /// Every caption in the clip as a hand-edited block (what an edit starts from).
    func handBlocks(_ c: Clip) -> [CaptionBlock] {
        let existing = Dictionary((c.captionBlocks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let t = Captions.track(for: c, project: project)
        let ids = captionIDs(t, clip: c)
        var out: [CaptionBlock] = []
        for (k, p) in t.pages.enumerated() {
            if let id = p.blockID, let b = existing[id] { out.append(b); continue }
            let ws = p.wordIndexes.map { t.words[$0] }
            guard let first = ws.first else { continue }
            let words = ws.map { Word(text: $0.raw, start: $0.mStart, end: $0.mEnd) }
            let s = min(first.mStart, c.masterTime(forOutput: p.start))
            let e = max(s + 0.1, c.masterTime(forOutput: p.end))
            out.append(CaptionBlock(id: ids[k], start: s, end: e, words: words, covers: TimeRange(start: s, end: e)))
        }
        // hand-made captions that are cut out of the clip right now are kept as they are
        let shown = Set(out.map { $0.id })
        out.append(contentsOf: (c.captionBlocks ?? []).filter { !shown.contains($0.id) })
        return out.sorted { $0.start < $1.start }
    }

    /// Edits the selected clip's captions as hand-edited blocks (one undo step).
    func changeCaptions(_ change: (inout [CaptionBlock], Clip) -> Void) {
        guard let i = clipIndex, let c = selectedClip else { return }
        var blocks = handBlocks(c)
        change(&blocks, c)
        blocks.sort { $0.start < $1.start }
        edit { $0.clips[i].captionBlocks = blocks }
    }

    /// A caption moved / stretched so it shows from output time `ns` to `ne`. Worked out in the clip's
    /// output time so words never land inside a part that was cut out.
    static func remap(_ b: CaptionBlock, clip c: Clip, toOutput ns: Double, _ ne: Double) -> CaptionBlock {
        let os = c.outputTimeClamped(forMaster: b.start), oe = c.outputTimeClamped(forMaster: b.end)
        let od = max(0.001, oe - os), nd = max(0.001, ne - ns)
        func f(_ m: Double) -> Double { c.masterTime(forOutput: ns + (c.outputTimeClamped(forMaster: m) - os) / od * nd) }
        var n = b
        n.words = b.words.map { w in
            var x = w
            x.start = f(w.start)
            x.end = max(x.start, f(w.end))
            return x
        }
        n.start = c.masterTime(forOutput: ns)
        n.end = max(n.start + 0.05, c.masterTime(forOutput: ne))
        return n
    }

    /// New words over old ones, spread in the clip's output time (so none fall into a cut).
    static func respell(_ toks: [String], over old: [Word], clip c: Clip) -> [Word] {
        if toks.count == old.count { return zip(toks, old).map { var w = $1; w.text = $0; return w } }
        let outOld = old.map { w -> Word in
            var x = w
            x.start = c.outputTimeClamped(forMaster: w.start)
            x.end = max(x.start, c.outputTimeClamped(forMaster: w.end))
            return x
        }
        return spread(toks, over: outOld).map { w in
            var x = w
            x.start = c.masterTime(forOutput: w.start)
            x.end = max(x.start, c.masterTime(forOutput: w.end))
            return x
        }
    }

    // MARK: - Text

    /// Retypes a caption. Same number of words keeps each word's timing; empty text leaves no caption there.
    func setCaptionText(_ id: UUID, _ text: String) {
        let toks = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let cur = captionItem(id), toks != cur.text.split(separator: " ").map(String.init) else { return }
        changeCaptions { blocks, c in
            guard let k = blocks.firstIndex(where: { $0.id == id }) else { return }
            let b = blocks[k]
            if toks.isEmpty { blocks[k].words = [] }
            else if b.words.isEmpty { blocks[k].words = Self.respell(toks, over: [Word(text: "", start: b.start, end: b.end)], clip: c) }
            else { blocks[k].words = Self.respell(toks, over: b.words, clip: c) }
        }
        captionChanged(toks.isEmpty ? "Removed the caption. Type in its row to bring one back." : nil)
    }

    func deleteCaption(_ id: UUID) { setCaptionText(id, "") }

    // MARK: - Split / join / reset

    /// Splits a caption at an output time (words go to the side their middle is on).
    func splitCaption(_ id: UUID, atOutput t: Double) {
        guard let c = selectedClip else { return }
        let m = c.masterTime(forOutput: t)
        guard let it = captionItem(id), t > it.start + 0.1, t < it.end - 0.1 else {
            notice = "Put the playhead inside the caption where you want to split it."
            return
        }
        changeCaptions { blocks, _ in
            guard let k = blocks.firstIndex(where: { $0.id == id }) else { return }
            let b = blocks[k]
            guard m > b.start + 0.05, m < b.end - 0.05 else { return }
            var left = b, right = b
            left.words = b.words.filter { ($0.start + $0.end) / 2 < m }
            right.words = b.words.filter { ($0.start + $0.end) / 2 >= m }
            left.end = m
            right.start = m
            right.id = UUID()
            blocks[k] = left
            blocks.insert(right, at: k + 1)
        }
        captionChanged(nil)
    }

    func splitCaptionAtPlayhead() {
        let t = engine.time
        guard let it = captionItems.first(where: { t > $0.start && t < $0.end }) else {
            notice = "Put the playhead inside the caption you want to split."
            return
        }
        splitCaption(it.id, atOutput: t)
    }

    func canJoinNext(_ id: UUID) -> Bool {
        let items = captionItems
        guard let k = items.firstIndex(where: { $0.id == id }) else { return false }
        return k + 1 < items.count
    }

    /// Joins a caption with the one after it.
    func joinCaptionWithNext(_ id: UUID) {
        let items = captionItems
        guard let k = items.firstIndex(where: { $0.id == id }), k + 1 < items.count else { return }
        let nextID = items[k + 1].id
        changeCaptions { blocks, _ in
            guard let a = blocks.firstIndex(where: { $0.id == id }), let b = blocks.firstIndex(where: { $0.id == nextID }) else { return }
            blocks[a].words += blocks[b].words
            blocks[a].end = max(blocks[a].end, blocks[b].end)
            if let ca = blocks[a].covers, let cb = blocks[b].covers {
                blocks[a].covers = TimeRange(start: min(ca.start, cb.start), end: max(ca.end, cb.end))
            } else { blocks[a].covers = blocks[a].covers ?? blocks[b].covers }
            blocks.remove(at: b)
        }
        captionChanged(nil)
    }

    /// Back to captions made automatically from the transcript (undo brings the edits back).
    func resetCaptions() {
        guard selectedClip?.captionBlocks != nil else { return }
        updateClip { $0.captionBlocks = nil }
        selectedCaption = nil
        notice = "Captions are automatic again (⌘Z brings your edits back)."
    }

    private func captionChanged(_ message: String?) {
        if let m = message { notice = m }
    }

    // MARK: - Moving and re-timing on the timeline

    func beginCaptionDrag(_ id: UUID, mode: CaptionDrag.Mode, atOutput t: Double) {
        guard let i = clipIndex, let c = selectedClip else { return }
        engine.pause()
        let blocks = handBlocks(c)
        guard blocks.contains(where: { $0.id == id }) else { return }
        beginGesture()
        liveEdit { $0.clips[i].captionBlocks = blocks }
        captionDrag = CaptionDrag(id: id, mode: mode, original: blocks, anchor: t)
        selectedCaption = id
    }

    /// Moving or re-timing a caption. If it runs into its neighbour, the neighbour gives way
    /// (its edge follows, like a roll edit) down to a short minimum.
    func updateCaptionDrag(toOutput t: Double, spp: Double) {
        guard let d = captionDrag, let i = clipIndex, let c = selectedClip,
              let k = d.original.firstIndex(where: { $0.id == d.id }) else { return }
        func out(_ m: Double) -> Double { c.outputTimeClamped(forMaster: m) }
        let b = d.original[k]
        let os = out(b.start), oe = out(b.end)
        let prev = k > 0 ? d.original[k - 1] : nil
        let next = k + 1 < d.original.count ? d.original[k + 1] : nil
        let minLen = 0.3
        let lo = prev.map { min(os, out($0.start) + minLen) } ?? 0
        let hi = next.map { max(oe, out($0.end) - minLen) } ?? max(oe, c.outputDuration)
        let tol = 8 * spp
        var ns = os, ne = oe
        switch d.mode {
        case .move:
            var dt = t - d.anchor
            // snap the caption's start (or else its end) to a word, the playhead, an edit point
            let s1 = snapOutput(os + dt, tol: tol)
            if abs(s1 - (os + dt)) > 1e-9 { dt = s1 - os }
            else { let e1 = snapOutput(oe + dt, tol: tol); dt = e1 - oe }
            dt = max(min(dt, hi - oe), lo - os)
            ns = os + dt; ne = oe + dt
        case .start:
            ns = min(max(snapOutput(t, tol: tol), lo), oe - 0.2)
        case .end:
            ne = max(min(snapOutput(t, tol: tol), hi), os + 0.2)
        }
        var blocks = d.original
        blocks[k] = Self.remap(b, clip: c, toOutput: ns, ne)
        if let p = prev, ns < out(p.end) - 1e-6 { blocks[k - 1] = Self.remap(p, clip: c, toOutput: out(p.start), ns) }
        if let n = next, ne > out(n.start) + 1e-6 { blocks[k + 1] = Self.remap(n, clip: c, toOutput: ne, out(n.end)) }
        liveEdit { $0.clips[i].captionBlocks = blocks }
    }

    func endCaptionDrag() {
        guard captionDrag != nil else { return }
        captionDrag = nil
        endGesture()
        rebuild()
    }
}
