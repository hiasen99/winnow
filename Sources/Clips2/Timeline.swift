import SwiftUI
import AppKit

// MARK: - Layout

/// Where everything sits in the timeline area (view points, y down).
struct TLLayout {
    var width: CGFloat
    var height: CGFloat
    var start: Double          // first visible second (output time)
    var vd: Double             // visible seconds
    var hasClipsLane: Bool
    var clipRows: Int = 1
    /// inside a clip the lane under the picture shows its captions (on the full recording: the words)
    var capsMode: Bool = false

    static let rulerH: CGFloat = 22
    static let clipRowH: CGFloat = 15
    var clipsH: CGFloat { CGFloat(clipRows) * Self.clipRowH + 4 }
    static let wordsH: CGFloat = 20
    static let captionsH: CGFloat = 34
    var wordsLaneH: CGFloat { capsMode ? Self.captionsH : Self.wordsH }
    static let scrollH: CGFloat = 12

    var rulerY: CGFloat { 0 }
    var clipsY: CGFloat { Self.rulerH }
    var videoY: CGFloat { Self.rulerH + (hasClipsLane ? clipsH + 2 : 2) }
    var videoH: CGFloat { max(40, min(84, (height - videoY - Self.scrollH - wordsLaneH) * 0.5)) }
    var wordsY: CGFloat { videoY + videoH + 3 }
    var audioY: CGFloat { wordsY + wordsLaneH + 3 }
    var audioH: CGFloat { max(20, height - Self.scrollH - 3 - audioY) }
    var scrollY: CGFloat { height - Self.scrollH }

    var spp: Double { vd / Double(max(1, width)) }
    func x(_ t: Double) -> CGFloat { CGFloat((t - start) / vd) * width }
    func t(_ x: CGFloat) -> Double { start + Double(x / max(1, width)) * vd }
}

enum TLZone { case ruler, clips, video, words, audio, scroller }

extension TLLayout {
    func zone(_ y: CGFloat) -> TLZone {
        if y >= scrollY - 1 { return .scroller }
        if y < Self.rulerH { return .ruler }
        if hasClipsLane && y < videoY { return .clips }
        if y < wordsY - 1 { return .video }
        if y < audioY - 1 { return .words }
        return .audio
    }
}

/// Mouse position while hovering (kept outside SwiftUI state so hovering doesn't redraw the whole timeline).
final class TLHover: ObservableObject {
    @Published var x: CGFloat? = nil
}

// MARK: - Timeline panel

/// The full-width timeline at the bottom of the window: ruler with markers, the clips on the full
/// recording, the picture track (filmstrip, camera colours, blocks you can trim by their edges),
/// the words, and the sound. Modelled on Final Cut's timeline.
struct TimelinePanel: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var thumbs: ThumbCache
    @AppStorage("waveEachSource") var each = false
    @State private var hover = TLHover()

    @State private var dragMode: DragMode = .none
    @State private var dragAnchor: Double = 0
    @State private var dragStartX: CGFloat = 0
    @State private var scrollGrab: Double = 0
    @State private var capPending: (id: UUID, mode: CaptionDrag.Mode, t: Double)? = nil
    enum DragMode { case none, scrub, select, trim, scroll, capPending, capDrag }

    var engine: PlayerEngine { model.engine }

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(model: model, engine: model.engine)
                .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            GeometryReader { g in
                let L = layout(g.size)
                let tiles = filmstrip(L)
                let columns = max(10, Int(L.width / 2))
                let lanes = model.waveform(columns: columns, each: each, from: L.start, to: L.start + L.vd)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(ctx, L, tiles: tiles, lanes: lanes, columns: columns) }
                    PlayheadOverlay(model: model, engine: model.engine, hover: hover, L: L)
                        .allowsHitTesting(false)
                    TimelineMouse(
                        onDown: { p, e in down(p, e, L) },
                        onDrag: { p in dragged(p, L) },
                        onUp: { p, e in up(p, e, L) },
                        onMove: { p in moved(p, L) },
                        onExit: { hover.x = nil; engine.endSkim() },
                        onScroll: { e, p in scrolled(e, p, L) },
                        onMagnify: { m, p in model.zoomTimeline(by: 1 + Double(m), around: L.t(p.x)) },
                        onMenu: { p in menu(p, L) },
                        cursor: { p in cursor(p, L) }
                    )
                }
                .clipped()
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
        .onChange(of: model.selectedClipID) { _, _ in hover.x = nil }
    }

    func layout(_ size: CGSize) -> TLLayout {
        let d = model.tlDuration
        let vd = d / max(1, model.tlZoom)
        let start = max(0, min(model.tlStart, d - vd))
        let rows = model.selectedClip == nil ? clipRows().count : 1
        return TLLayout(width: max(1, size.width), height: max(1, size.height), start: start, vd: max(0.001, vd),
                        hasClipsLane: model.selectedClip == nil && !model.project.clips.isEmpty, clipRows: max(1, rows),
                        capsMode: model.selectedClip != nil)
    }

    /// Clips on the full recording stacked so overlapping ones don't cover each other (up to 3 rows).
    func clipRows() -> (count: Int, row: [UUID: Int]) {
        var ends: [Double] = []
        var row: [UUID: Int] = [:]
        for c in model.project.clips.sorted(by: { $0.start < $1.start }) {
            if let k = ends.firstIndex(where: { $0 <= c.start + 0.01 }) { ends[k] = c.end; row[c.id] = k }
            else if ends.count < 3 { ends.append(c.end); row[c.id] = ends.count - 1 }
            else { let k = ends.indices.min { ends[$0] < ends[$1] }!; ends[k] = max(ends[k], c.end); row[c.id] = k }
        }
        return (ends.count, row)
    }

    // MARK: hit testing

    /// The block edge under the mouse (within 6 pt), choosing the side the mouse is on.
    func edge(at p: CGPoint, _ L: TLLayout) -> TrimEdge? {
        guard model.selectedClip != nil, L.zone(p.y) == .video else { return nil }
        let segs = model.tlSegments
        var best: (TrimEdge, CGFloat)? = nil
        for (k, s) in segs.enumerated() {
            for (side, t) in [(TrimSide.start, s.outStart), (TrimSide.end, s.outEnd)] {
                let ex = L.x(t)
                let d = abs(p.x - ex)
                guard d <= 6 else { continue }
                // at a join, the block on the mouse's side wins
                let onSide = side == .start ? p.x >= ex - 1 : p.x <= ex + 1
                let score = d - (onSide ? 10 : 0)
                if best == nil || score < best!.1 { best = (TrimEdge(segment: k, side: side), score) }
            }
        }
        return best?.0
    }

    func marker(at p: CGPoint, _ L: TLLayout) -> Marker? {
        guard p.y < TLLayout.rulerH + 2 || L.zone(p.y) == .video else { return nil }
        return model.markersOnTimeline().first { abs(L.x($0.1) - p.x) <= 5 }?.0
    }

    func clip(at p: CGPoint, _ L: TLLayout) -> Clip? {
        guard L.hasClipsLane, L.zone(p.y) == .clips else { return nil }
        let t = L.t(p.x)
        let rows = clipRows().row
        let r = Int((p.y - L.clipsY - 2) / TLLayout.clipRowH)
        return model.project.clips.last { t >= $0.start && t <= $0.end && rows[$0.id] == r }
            ?? model.project.clips.last { t >= $0.start && t <= $0.end }
    }

    /// The caption under the mouse, and whether it's an edge (re-time) or the middle (move).
    func caption(at p: CGPoint, _ L: TLLayout) -> (item: CaptionItem, mode: CaptionDrag.Mode)? {
        guard L.capsMode, L.zone(p.y) == .words else { return nil }
        let items = model.captionItems
        var best: (CaptionItem, CaptionDrag.Mode, CGFloat)? = nil
        for it in items {
            let xa = L.x(it.start), xb = L.x(it.end)
            guard p.x >= xa - 5, p.x <= xb + 5 else { continue }
            let w = xb - xa
            let edgeTol: CGFloat = w < 18 ? 3 : 6
            var mode = CaptionDrag.Mode.move
            var score: CGFloat = 100
            if abs(p.x - xa) <= edgeTol { mode = .start; score = abs(p.x - xa) }
            else if abs(p.x - xb) <= edgeTol { mode = .end; score = abs(p.x - xb) }
            else if p.x > xa && p.x < xb { mode = .move; score = 50 }
            else { continue }
            if best == nil || score < best!.2 { best = (it, mode, score) }
        }
        return best.map { ($0.0, $0.1) }
    }

    func word(at p: CGPoint, _ L: TLLayout) -> TLWord? {
        let t = L.t(p.x)
        return model.tlWords().first { t >= $0.start - L.spp * 2 && t <= $0.end + L.spp * 2 }
    }

    func cursor(_ p: CGPoint, _ L: TLLayout) -> NSCursor {
        if dragMode == .trim || edge(at: p, L) != nil { return .resizeLeftRight }
        if dragMode == .capDrag, let d = model.captionDrag { return d.mode == .move ? .closedHand : .resizeLeftRight }
        if let c = caption(at: p, L) { return c.mode == .move ? .openHand : .resizeLeftRight }
        switch L.zone(p.y) {
        case .ruler: return marker(at: p, L) != nil ? .pointingHand : .resizeLeftRight
        case .clips: return clip(at: p, L) != nil ? .pointingHand : .arrow
        case .scroller: return .openHand
        default: return .arrow
        }
    }

    // MARK: mouse

    func clampT(_ t: Double) -> Double { max(0, min(model.tlDuration, t)) }

    func down(_ p: CGPoint, _ e: NSEvent, _ L: TLLayout) {
        let t = clampT(L.t(p.x))
        dragStartX = p.x
        dragMode = .none
        engine.endSkim()
        let zone = L.zone(p.y)
        if zone == .scroller {
            let d = model.tlDuration
            let a = CGFloat(L.start / d) * L.width, b = CGFloat((L.start + L.vd) / d) * L.width
            if p.x >= a && p.x <= b { scrollGrab = Double(p.x - a) / Double(L.width) * d }
            else { scrollGrab = L.vd / 2; scrollTo(p.x, L) }
            dragMode = .scroll
            return
        }
        if let mk = marker(at: p, L), zone == .ruler {
            if e.clickCount == 2 { model.askRenameMarker(mk) } else if let o = model.outputTime(mk.time) { engine.seek(o) }
            return
        }
        if zone == .ruler { dragMode = .scrub; engine.scrub(t); return }
        if zone == .clips {
            if let c = clip(at: p, L) {
                if e.clickCount == 2 { model.select(clip: c.id) }
                else { engine.seek(c.start); model.tlSel = c.start...c.end }
            }
            return
        }
        if L.capsMode, zone == .words {
            if let hit = caption(at: p, L) {
                let it = hit.item, mode = hit.mode
                model.tlSel = nil
                model.selectedCaption = it.id
                if e.clickCount == 2 {
                    engine.seek(it.start)
                    model.editingCaption = it.id
                    return
                }
                capPending = (it.id, mode, t)
                dragMode = .capPending
                return
            }
            model.selectedCaption = nil
        }
        if let ed = edge(at: p, L) {
            dragMode = .trim
            model.beginTrim(ed, x: p.x, secondsPerPixel: L.spp)
            return
        }
        if zone == .words, e.clickCount == 2, let w = word(at: p, L) {
            model.selection = w.index...w.index
            model.beginEditingText()
            return
        }
        dragMode = .select
        if e.modifierFlags.contains(.shift), let sel = model.tlSel {
            dragAnchor = abs(t - sel.lowerBound) > abs(t - sel.upperBound) ? sel.lowerBound : sel.upperBound
            model.tlSel = min(dragAnchor, t)...max(dragAnchor, t)
        } else {
            dragAnchor = model.snapOutput(t, tol: 8 * L.spp, includePlayhead: true)
        }
    }

    func dragged(_ p: CGPoint, _ L: TLLayout) {
        let t = clampT(L.t(p.x))
        switch dragMode {
        case .scrub: engine.scrub(t); autoScroll(p.x, L)
        case .select:
            if abs(p.x - dragStartX) > 3 {
                let s = model.snapOutput(t, tol: 8 * L.spp, includePlayhead: true)
                model.tlSel = min(dragAnchor, s)...max(dragAnchor, s)
            }
            autoScroll(p.x, L)
        case .trim: model.updateTrim(x: p.x)
        case .scroll: scrollTo(p.x, L)
        case .capPending:
            if abs(p.x - dragStartX) > 3, let c = capPending {
                model.beginCaptionDrag(c.id, mode: c.mode, atOutput: c.t)
                dragMode = .capDrag
                model.updateCaptionDrag(toOutput: t, spp: L.spp)
            }
        case .capDrag:
            model.updateCaptionDrag(toOutput: t, spp: L.spp)
            autoScroll(p.x, L)
        case .none: break
        }
    }

    func up(_ p: CGPoint, _ e: NSEvent, _ L: TLLayout) {
        let t = clampT(L.t(p.x))
        switch dragMode {
        case .scrub: engine.seek(t)
        case .select:
            if abs(p.x - dragStartX) <= 3 && !e.modifierFlags.contains(.shift) {
                model.tlSel = nil
                let zone = L.zone(p.y)
                if zone == .words, let w = word(at: p, L) { engine.seek(w.start) }
                else {
                    engine.seek(t)
                    if zone == .video { model.selectSegment(atOutput: t) }
                }
            } else if let s = model.tlSel, s.upperBound - s.lowerBound < 0.02 {
                model.tlSel = nil
            }
        case .trim: model.endTrim()
        case .capPending:
            // a click on a caption: select it and show it in the viewer
            if let c = capPending, let it = model.captionItem(c.id) { engine.seek(min(max(t, it.start), max(it.start, it.end - 0.01))) }
        case .capDrag: model.endCaptionDrag()
        case .scroll, .none: break
        }
        capPending = nil
        dragMode = .none
    }

    func moved(_ p: CGPoint, _ L: TLLayout) {
        hover.x = p.x
        guard model.skimming, dragMode == .none, !engine.isPlaying else { return }
        let z = L.zone(p.y)
        if z == .scroller || z == .clips { engine.endSkim(); return }
        engine.skim(clampT(L.t(p.x)))
    }

    func scrolled(_ e: NSEvent, _ p: CGPoint, _ L: TLLayout) {
        let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 8
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.command) {
            model.zoomTimeline(by: exp(Double(dy) * 0.01), around: L.t(p.x))
        } else if abs(dx) > abs(dy) {
            model.panTimeline(seconds: -Double(dx) * L.spp)
        } else if model.tlZoom > 1 {
            model.panTimeline(seconds: -Double(dy) * L.spp)
        }
    }

    func scrollTo(_ px: CGFloat, _ L: TLLayout) {
        model.tlStart = Double(px / L.width) * model.tlDuration - scrollGrab
        model.clampTimeline()
    }

    func autoScroll(_ px: CGFloat, _ L: TLLayout) {
        guard model.tlZoom > 1 else { return }
        if px < 0 { model.panTimeline(seconds: -L.vd * 0.03) }
        if px > L.width { model.panTimeline(seconds: L.vd * 0.03) }
    }

    // MARK: right-click

    func menu(_ p: CGPoint, _ L: TLLayout) -> NSMenu? {
        let m = ClosureMenu()
        let t = clampT(L.t(p.x))
        if let mk = marker(at: p, L) {
            m.add("Rename “\(mk.name)”…") { model.askRenameMarker(mk) }
            m.add("Delete Marker") { model.deleteMarker(mk.id) }
            return m
        }
        switch L.zone(p.y) {
        case .clips:
            if let c = clip(at: p, L) {
                m.add("Open “\(c.title)”") { model.select(clip: c.id) }
                m.addSeparator()
                m.add("Used", checked: c.status == .used) { model.toggleStatus(.used, for: c.id) }
                m.add("Rejected", checked: c.status == .rejected) { model.toggleStatus(.rejected, for: c.id) }
                return m
            }
        case .words where L.capsMode:
            if let it = caption(at: p, L)?.item {
                model.selectedCaption = it.id
                m.add("Edit Text") { engine.seek(it.start); model.editingCaption = it.id }
                if engine.time > it.start + 0.1 && engine.time < it.end - 0.1 {
                    m.add("Split at Playhead") { model.splitCaption(it.id, atOutput: engine.time) }
                } else {
                    m.add("Split Here") { model.splitCaption(it.id, atOutput: t) }
                }
                if model.canJoinNext(it.id) { m.add("Join with Next Caption") { model.joinCaptionWithNext(it.id) } }
                if !it.text.isEmpty { m.add("Delete Caption") { model.deleteCaption(it.id) } }
                m.addSeparator()
            }
            if model.captionsEdited {
                m.add("Reset Captions to the Transcript") { model.resetCaptions() }
                m.addSeparator()
            }
        case .words:
            if let w = word(at: p, L) {
                m.add("Fix “\(w.text)”…") { model.selection = w.index...w.index; model.beginEditingText() }
                m.add(w.hidden ? "Show “\(w.text)” in Transcript & Captions" : "Hide “\(w.text)” from Transcript & Captions") {
                    model.setHidden(w.index...w.index, !w.hidden)
                }
                m.addSeparator()
            }
        case .video:
            if let c = model.selectedClip, let k = model.segmentIndex(atOutput: t) {
                let segs = c.segments
                let s = segs[k]
                m.add("Delete This Block") { model.selectSegment(atOutput: t); model.cutTimelineSelection() }
                m.add("Blade at Playhead") { model.bladeAtPlayhead() }
                // the edit point nearest the mouse
                let nearEnd = abs(L.x(s.outEnd) - p.x) < abs(L.x(s.outStart) - p.x)
                let joinIdx = nearEnd ? k : k - 1
                if joinIdx >= 0, joinIdx + 1 < segs.count {
                    if segs[joinIdx].splitAfter {
                        m.add("Join Blocks (remove the blade cut)") { model.joinSplit(atOutput: segs[joinIdx].outEnd) }
                    } else {
                        let gap = c.ranges[segs[joinIdx].rangeIndex + 1].start - c.ranges[segs[joinIdx].rangeIndex].end
                        m.add(String(format: "Put Back the %.1f s Cut Here", gap)) { model.closeGap(afterRange: segs[joinIdx].rangeIndex) }
                    }
                }
                m.addSeparator()
            }
        default: break
        }
        if model.tlSel != nil {
            if model.selectedClip != nil { m.add("Cut Selection") { model.cutTimelineSelection() } }
            else { m.add("Make Clip from Selection") { model.timelineSelectionToClip() } }
        }
        m.add("Add Marker at Playhead") { model.addMarker() }
        m.add("Zoom to Fit") { model.fitTimeline() }
        return m
    }

    // MARK: filmstrip

    struct Tile { var rect: CGRect; var clip: CGRect; var image: CGImage?; var color: Color }

    func filmstrip(_ L: TLLayout) -> [Tile] {
        let _ = thumbs.version
        let clip = model.selectedClip
        let segs = model.tlSegments
        let pieces = model.tlPieces
        let h = L.videoH - 8
        var out: [Tile] = []
        for pc in pieces {
            let a = max(L.start, pc.outStart), b = min(L.start + L.vd, pc.outStart + pc.duration)
            guard b > a, pc.angle < model.project.angles.count else { continue }
            let src = pc.angle < model.sources.count ? model.sources[pc.angle] : nil
            let aspect = src.map { $0.naturalSize.width / max(1, $0.naturalSize.height) } ?? 16 / 9
            let tileW = max(24, h * aspect)
            let step = ThumbCache.step(for: Double(tileW) * L.spp)
            let x0 = L.x(0)
            let xa = L.x(a), xb = L.x(b)
            var k = Int(floor((xa - x0) / tileW))
            let color = angleColors[pc.angle % angleColors.count]
            while x0 + CGFloat(k) * tileW < xb {
                let tx = x0 + CGFloat(k) * tileW
                let tc = min(b, max(a, L.t(tx + tileW / 2)))
                let master = clip?.masterTime(forOutput: tc) ?? tc
                let img = thumbs.image(angle: pc.angle, sourceTime: master + model.project.angles[pc.angle].offset,
                                       step: step, loaded: src)
                // clip to the block this piece is in
                var cr = CGRect(x: xa, y: L.videoY + 5, width: xb - xa, height: h)
                if let s = segs.first(where: { tc >= $0.outStart - 1e-6 && tc <= $0.outEnd + 1e-6 }) {
                    cr = cr.intersection(CGRect(x: L.x(s.outStart) + 1, y: cr.minY, width: L.x(s.outEnd) - L.x(s.outStart) - 2, height: h))
                }
                out.append(Tile(rect: CGRect(x: tx, y: L.videoY + 5, width: tileW, height: h), clip: cr, image: img, color: color))
                k += 1
                if out.count > 400 { break }
            }
        }
        return out
    }

    // MARK: drawing

    func draw(_ ctx: GraphicsContext, _ L: TLLayout, tiles: [Tile], lanes: [WaveLane], columns: Int) {
        let W = L.width
        let end = L.start + L.vd
        let p = model.project
        let clip = model.selectedClip

        // lane backgrounds
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: TLLayout.rulerH)), with: .color(Color.primary.opacity(0.05)))
        ctx.fill(Path(CGRect(x: 0, y: L.videoY, width: W, height: L.videoH)), with: .color(Color.black.opacity(0.18)))
        ctx.fill(Path(CGRect(x: 0, y: L.audioY, width: W, height: L.audioH)), with: .color(Color.primary.opacity(0.04)))

        // ruler
        let ticks = [1.0 / 30, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200]
        let step = ticks.first { CGFloat($0 / L.vd) * W >= 70 } ?? 1200
        var t = (L.start / step).rounded(.down) * step
        while t <= end {
            let px = L.x(t)
            ctx.fill(Path(CGRect(x: px, y: TLLayout.rulerH - 7, width: 1, height: 7)), with: .color(.secondary.opacity(0.8)))
            let label = step < 1 ? String(format: "%@.%02d", fmtTime(t), Int((t - floor(t)) * 100 + 0.5) % 100) : fmtTime(t)
            ctx.draw(Text(label).font(.system(size: 9.5).monospacedDigit()).foregroundColor(.secondary), at: CGPoint(x: px + 3, y: 2), anchor: .topLeading)
            for k in 1..<5 {
                let mt = t + step * Double(k) / 5
                if mt < end { ctx.fill(Path(CGRect(x: L.x(mt), y: TLLayout.rulerH - 3, width: 1, height: 3)), with: .color(.secondary.opacity(0.4))) }
            }
            t += step
        }

        // clips on the full recording
        if L.hasClipsLane {
            let rows = clipRows().row
            for c in p.clips where c.end > L.start && c.start < end {
                let xa = max(-2, L.x(c.start)), xb = min(W + 2, L.x(c.end))
                let r = CGRect(x: xa, y: L.clipsY + 2 + CGFloat(rows[c.id] ?? 0) * TLLayout.clipRowH, width: max(2, xb - xa), height: TLLayout.clipRowH - 2)
                let col: Color = c.status == .used ? Brand.gold : c.status == .rejected ? .red : .purple
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(col.opacity(c.status == .rejected ? 0.3 : 0.55)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(col.opacity(0.9)), lineWidth: 1)
                if r.width > 30 {
                    var lctx = ctx; lctx.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
                    let mark = c.status == .used ? "✓ " : c.status == .rejected ? "✕ " : ""
                    lctx.draw(Text(mark + c.title).font(.system(size: 9.5, weight: .semibold)).foregroundColor(.primary),
                              at: CGPoint(x: r.minX + 4, y: r.midY), anchor: .leading)
                }
            }
        }

        // picture track: blocks with filmstrip
        let segs = model.tlSegments
        for s in segs where s.outEnd > L.start && s.outStart < end {
            let r = CGRect(x: L.x(s.outStart) + 1, y: L.videoY + 2, width: max(2, L.x(s.outEnd) - L.x(s.outStart) - 2), height: L.videoH - 4)
            ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(Color(white: 0.16)))
        }
        for tile in tiles {
            var tctx = ctx
            tctx.clip(to: Path(tile.clip))
            if let img = tile.image {
                tctx.draw(Image(decorative: img, scale: 1), in: tile.rect)
            } else {
                tctx.fill(Path(tile.rect.insetBy(dx: 0.5, dy: 0)), with: .color(tile.color.opacity(0.25)))
            }
            tctx.fill(Path(CGRect(x: tile.rect.maxX - 0.5, y: tile.rect.minY, width: 0.5, height: tile.rect.height)), with: .color(.black.opacity(0.35)))
        }
        // camera colour band + names
        for pc in model.tlPieces {
            let a = max(L.start, pc.outStart), b = min(end, pc.outStart + pc.duration)
            guard b > a else { continue }
            let xa = L.x(a), xb = L.x(b)
            let col = angleColors[pc.angle % angleColors.count]
            ctx.fill(Path(CGRect(x: xa, y: L.videoY + 2, width: max(1, xb - xa), height: 4)), with: .color(col))
            if pc.outStart > L.start { ctx.fill(Path(CGRect(x: L.x(pc.outStart) - 0.5, y: L.videoY + 2, width: 1, height: L.videoH - 4)), with: .color(col.opacity(0.9))) }
            if xb - xa > 26, pc.angle < p.angles.count {
                let name = p.angles[pc.angle].shortName
                let lr = CGRect(x: xa + 3, y: L.videoY + 8, width: CGFloat(name.count) * 7 + 8, height: 14)
                ctx.fill(Path(roundedRect: lr, cornerRadius: 3), with: .color(.black.opacity(0.55)))
                ctx.draw(Text(name).font(.system(size: 9.5, weight: .bold)).foregroundColor(col),
                         at: CGPoint(x: lr.minX + 4, y: lr.midY), anchor: .leading)
            }
        }
        // block outlines, edit points
        for (k, s) in segs.enumerated() where s.outEnd > L.start && s.outStart < end {
            let r = CGRect(x: L.x(s.outStart) + 1, y: L.videoY + 2, width: max(2, L.x(s.outEnd) - L.x(s.outStart) - 2), height: L.videoH - 4)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(.white.opacity(0.35)), lineWidth: 1)
            if clip != nil, k + 1 < segs.count, !s.splitAfter {
                // something was cut out here
                let ex = L.x(s.outEnd)
                var tri = Path()
                tri.move(to: CGPoint(x: ex - 5, y: L.videoY - 1)); tri.addLine(to: CGPoint(x: ex + 5, y: L.videoY - 1)); tri.addLine(to: CGPoint(x: ex, y: L.videoY + 5))
                ctx.fill(tri, with: .color(.red))
            }
        }
        if model.tlSegmentSelected, let sel = model.tlSel,
           let s = segs.first(where: { abs($0.outStart - sel.lowerBound) < 0.001 && abs($0.outEnd - sel.upperBound) < 0.001 }) {
            let r = CGRect(x: L.x(s.outStart) + 1, y: L.videoY + 2, width: max(2, L.x(s.outEnd) - L.x(s.outStart) - 2), height: L.videoH - 4)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 5), with: .color(.yellow), lineWidth: 3)
        }
        // manual camera cuts
        if let c = clip {
            for sw in c.switches {
                if let o = c.outputTime(forMaster: sw.time), o >= L.start, o <= end {
                    let px = L.x(o)
                    var tri = Path()
                    tri.move(to: CGPoint(x: px - 4, y: L.videoY + 6)); tri.addLine(to: CGPoint(x: px + 4, y: L.videoY + 6)); tri.addLine(to: CGPoint(x: px, y: L.videoY + 12))
                    ctx.fill(tri, with: .color(.white))
                }
            }
        }
        // the edge being trimmed
        if let d = model.trimDrag {
            let bx = d.startX + CGFloat((d.current - d.edgeMaster) / d.spp)
            let y0 = L.videoY, h = L.videoH
            var br = Path()
            let dir: CGFloat = d.edge.side == .start ? 1 : -1
            br.move(to: CGPoint(x: bx + 6 * dir, y: y0 + 1)); br.addLine(to: CGPoint(x: bx, y: y0 + 1))
            br.addLine(to: CGPoint(x: bx, y: y0 + h - 1)); br.addLine(to: CGPoint(x: bx + 6 * dir, y: y0 + h - 1))
            ctx.stroke(br, with: .color(.yellow), lineWidth: 3)
            // the frame at the new edge
            let ang = Schedule.angle(at: d.current, clip: d.original, auto: model.auto, project: p)
            let src = ang < model.sources.count ? model.sources[ang] : nil
            let ph = h - 10, pw = ph * 16 / 9
            let px = d.edge.side == .start ? bx + 8 : bx - 8 - pw
            let pr = CGRect(x: min(max(2, px), W - pw - 2), y: y0 + 5, width: pw, height: ph)
            if let img = thumbs.image(angle: ang, sourceTime: d.current + (ang < p.angles.count ? p.angles[ang].offset : 0), step: 0.25, loaded: src) {
                ctx.draw(Image(decorative: img, scale: 1), in: pr)
            }
            ctx.stroke(Path(pr), with: .color(.yellow), lineWidth: 1)
            let delta = (d.current - d.edgeMaster) * (d.edge.side == .end ? 1 : -1)
            let label = String(format: "%@%.2f s", delta >= 0 ? "+" : "−", abs(delta))
            ctx.draw(Text(label).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundColor(.yellow),
                     at: CGPoint(x: pr.midX, y: pr.maxY - 2), anchor: .bottom)
        }

        if L.capsMode { drawCaptions(ctx, L) } else {
        // words
        let ws = model.tlWords()
        var lo = 0, hi = ws.count - 1
        while lo <= hi { let mid = (lo + hi) / 2; if ws[mid].end < L.start { lo = mid + 1 } else { hi = mid - 1 } }
        var k = lo
        let cur = model.currentWord
        let editing = model.editingWords
        var drawnText = 0
        while k < ws.count && ws[k].start <= end {
            let w = ws[k]
            let xa = L.x(w.start), xb = L.x(w.end)
            let r = CGRect(x: xa + 0.5, y: L.wordsY + 2, width: max(1, xb - xa - 1), height: TLLayout.wordsH - 4)
            let spk = speakerColors[(w.index < p.words.count ? p.words[w.index].speaker : 0) % speakerColors.count]
            let isCur = w.index == cur
            let isEdit = editing?.contains(w.index) ?? false
            if w.hidden && !isEdit && !isCur {
                // hidden from the transcript / captions: just a dashed outline (the sound is still there)
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3), with: .color(.secondary.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else {
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(isEdit ? .yellow.opacity(0.7) : isCur ? Color(nsColor: spk).opacity(0.55) : Color(nsColor: spk).opacity(0.22)))
            }
            if r.width > CGFloat(min(w.text.count, 4)) * 5 + 6 && drawnText < 250 {
                var wctx = ctx; wctx.clip(to: Path(r.insetBy(dx: 2, dy: 0)))
                wctx.draw(Text(w.text).font(.system(size: 10)).foregroundColor(w.hidden ? .secondary : .primary).strikethrough(w.hidden), at: CGPoint(x: r.minX + 3, y: r.midY), anchor: .leading)
                drawnText += 1
            }
            k += 1
        }
        }

        // sound
        let laneH = L.audioH / CGFloat(max(1, lanes.count))
        let colW = W / CGFloat(columns)
        for (li, lane) in lanes.enumerated() {
            let y0 = L.audioY + laneH * CGFloat(li)
            let mid = y0 + laneH / 2, amp = laneH * 0.46
            if li > 0 { ctx.fill(Path(CGRect(x: 0, y: y0, width: W, height: 1)), with: .color(.primary.opacity(0.08))) }
            for c in 0..<min(columns, lane.values.count) {
                let h = max(0.5, CGFloat(lane.values[c]) * amp)
                let color = lane.color.count == 1 ? lane.color[0] : lane.color[c]
                ctx.fill(Path(CGRect(x: CGFloat(c) * colW, y: mid - h, width: max(1, colW - 0.5), height: 2 * h)),
                         with: .color(color.opacity(lane.heard[c] ? 0.9 : 0.25)))
            }
            if !lane.name.isEmpty {
                ctx.draw(Text(lane.name).font(.system(size: 9, weight: .bold)).foregroundColor(.primary.opacity(0.8)),
                         at: CGPoint(x: 4, y: y0 + 2), anchor: .topLeading)
            }
        }
        if !each {
            let segsS: [(Double, Double, [Bool])] = {
                if let c = clip {
                    return c.soundSegments().map { (c.outputTimeClamped(forMaster: $0.start), c.outputTimeClamped(forMaster: $0.end), $0.on) }
                }
                return [(0, model.tlDuration, model.fullMix.on)]
            }()
            for (a, b, on) in segsS where b > L.start && a < end {
                let xa = L.x(max(a, L.start)), w = L.x(min(b, end)) - xa
                if a > L.start { ctx.fill(Path(CGRect(x: L.x(a) - 0.5, y: L.audioY, width: 1, height: L.audioH)), with: .color(.primary.opacity(0.5))) }
                let label = soundLabel(p, on)
                if w > CGFloat(label.count) * 6 + 8 {
                    ctx.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.primary.opacity(0.85)),
                             at: CGPoint(x: xa + 4, y: L.audioY + 2), anchor: .topLeading)
                }
            }
        }
        // cut points through the sound too
        if clip != nil {
            for (i, s) in segs.enumerated() where i + 1 < segs.count && !s.splitAfter && s.outEnd >= L.start && s.outEnd <= end {
                ctx.fill(Path(CGRect(x: L.x(s.outEnd) - 0.5, y: L.wordsY, width: 1, height: L.audioY + L.audioH - L.wordsY)), with: .color(.red.opacity(0.6)))
            }
        }

        // markers
        for (mk, o) in model.markersOnTimeline() where o >= L.start - L.spp * 10 && o <= end {
            let px = L.x(o)
            var flag = Path()
            flag.move(to: CGPoint(x: px - 5, y: 4)); flag.addLine(to: CGPoint(x: px + 5, y: 4))
            flag.addLine(to: CGPoint(x: px + 5, y: 12)); flag.addLine(to: CGPoint(x: px, y: 17)); flag.addLine(to: CGPoint(x: px - 5, y: 12))
            flag.closeSubpath()
            ctx.fill(flag, with: .color(.orange))
            ctx.fill(Path(CGRect(x: px - 0.5, y: L.videoY, width: 1, height: L.videoH)), with: .color(.orange.opacity(0.8)))
            if !mk.name.isEmpty {
                ctx.draw(Text(mk.name).font(.system(size: 9, weight: .semibold)).foregroundColor(.orange),
                         at: CGPoint(x: px + 7, y: 11), anchor: .leading)
            }
        }

        // range selection
        if !model.tlSegmentSelected, let sel = model.tlSel, sel.upperBound > L.start, sel.lowerBound < end {
            let xa = L.x(max(sel.lowerBound, L.start)), xb = L.x(min(sel.upperBound, end))
            let r = CGRect(x: xa, y: TLLayout.rulerH, width: max(1, xb - xa), height: L.audioY + L.audioH - TLLayout.rulerH)
            ctx.fill(Path(r), with: .color(Brand.green.opacity(0.18)))
            ctx.stroke(Path(r), with: .color(Color.yellow.opacity(0.9)), lineWidth: 1.5)
            // range handles on the ruler
            ctx.fill(Path(CGRect(x: xa, y: TLLayout.rulerH - 4, width: max(1, xb - xa), height: 4)), with: .color(.yellow.opacity(0.8)))
        }

        // overview / scroller
        let d = model.tlDuration
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: L.scrollY + 2, width: W, height: TLLayout.scrollH - 4), cornerRadius: 4), with: .color(.primary.opacity(0.08)))
        for s in segs {
            ctx.fill(Path(CGRect(x: CGFloat(s.outStart / d) * W, y: L.scrollY + 4, width: max(1, CGFloat(s.master.duration / d) * W - 1), height: TLLayout.scrollH - 8)),
                     with: .color(.primary.opacity(0.12)))
        }
        let ta = CGFloat(L.start / d) * W, tb = CGFloat((L.start + L.vd) / d) * W
        ctx.fill(Path(roundedRect: CGRect(x: ta, y: L.scrollY + 2, width: max(8, tb - ta), height: TLLayout.scrollH - 4), cornerRadius: 4),
                 with: .color(.primary.opacity(model.tlZoom > 1.001 ? 0.35 : 0.15)))
    }
}

extension TimelinePanel {
    /// The captions lane: one block per caption, like Final Cut's caption lane.
    func drawCaptions(_ ctx: GraphicsContext, _ L: TLLayout) {
        let end = L.start + L.vd
        let on = model.selectedClip?.captions ?? true
        let r0 = CGRect(x: 0, y: L.wordsY, width: L.width, height: L.wordsLaneH)
        ctx.fill(Path(r0), with: .color(Color.purple.opacity(0.05)))
        var drawn = 0
        for it in model.captionItems where it.end > L.start && it.start < end {
            let xa = L.x(it.start), xb = L.x(it.end)
            let r = CGRect(x: xa + 0.5, y: L.wordsY + 2, width: max(2, xb - xa - 1), height: L.wordsLaneH - 4)
            let sel = it.id == model.selectedCaption
            let col = Color(red: 0.62, green: 0.38, blue: 0.95)
            if it.text.isEmpty {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4), with: .color(.secondary.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(col.opacity(on ? (sel ? 0.8 : 0.5) : 0.2)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(col.opacity(on ? 1 : 0.4)), lineWidth: 1)
            }
            if sel { ctx.stroke(Path(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 4), with: .color(.yellow), lineWidth: 2) }
            if r.width > 14 && drawn < 200 {
                var tctx = ctx; tctx.clip(to: Path(r.insetBy(dx: 4, dy: 0)))
                let label = it.text.isEmpty ? "no caption" : it.text
                tctx.draw(Text(label).font(.system(size: 10.5, weight: it.text.isEmpty ? .regular : .semibold))
                            .foregroundColor(it.text.isEmpty ? .secondary : (on ? .white : .secondary)).italic(it.text.isEmpty),
                          at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
                drawn += 1
            }
            if it.isHand && r.width > 30 {
                // a small mark on captions edited by hand
                ctx.fill(Path(ellipseIn: CGRect(x: r.maxX - 7, y: r.minY + 3, width: 4, height: 4)), with: .color(.white.opacity(0.8)))
            }
        }
        if !on {
            ctx.draw(Text("Captions are off for this clip").font(.system(size: 9.5, weight: .semibold)).foregroundColor(.secondary),
                     at: CGPoint(x: L.width - 6, y: L.wordsY + L.wordsLaneH / 2), anchor: .trailing)
        }
    }
}

// MARK: - Playhead & skimmer (redrawn on their own, so playback doesn't redraw the filmstrip)

struct PlayheadOverlay: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var hover: TLHover
    var L: TLLayout

    var body: some View {
        Canvas { ctx, size in
            if let hx = hover.x, model.trimDrag == nil, hx >= 0, hx <= L.width {
                ctx.fill(Path(CGRect(x: hx - 0.5, y: 0, width: 1, height: L.scrollY)), with: .color(model.skimming ? .pink.opacity(0.9) : .primary.opacity(0.25)))
                if model.skimming {
                    let t = L.t(hx)
                    ctx.draw(Text(fmtTime(t, frac: true)).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundColor(.pink),
                             at: CGPoint(x: min(hx + 4, L.width - 40), y: TLLayout.rulerH + 1), anchor: .topLeading)
                }
            }
            let t = engine.time
            guard t >= L.start - 0.001, t <= L.start + L.vd + 0.001 else { return }
            let px = L.x(t)
            ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: L.scrollY)), with: .color(.red))
            var head = Path()
            head.move(to: CGPoint(x: px - 6, y: 0)); head.addLine(to: CGPoint(x: px + 6, y: 0)); head.addLine(to: CGPoint(x: px, y: 8))
            ctx.fill(head, with: .color(.red))
        }
        .onChange(of: engine.time) { _, t in
            // keep the playhead in view while playing
            if engine.isPlaying && model.tlZoom > 1 && (t < L.start || t > L.start + L.vd * 0.97) {
                model.tlStart = t - L.vd * 0.05
                model.clampTimeline()
            }
        }
    }
}

// MARK: - Toolbar

struct TimelineToolbar: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @AppStorage("waveEachSource") var each = false

    var body: some View {
        HStack(spacing: 10) {
            Text("\(fmtTime(engine.time, frac: true))")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .frame(minWidth: 64, alignment: .leading)
            Text("/ \(fmtTime(model.tlDuration, frac: true))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { model.bladeAtPlayhead() } label: { Image(systemName: "scissors") }
                .help("Blade: split the clip at the playhead (B or ⌘B). Then click a block and press Delete to remove it.")
                .disabled(model.selectedClip == nil)
            Button { model.addMarker() } label: { Image(systemName: "bookmark") }
                .help("Add a marker at the playhead (M). Double-click a marker to name it; right-click to delete.")
            Button { model.setRangeIn() } label: { Text("I").font(.callout.weight(.bold).monospaced()) }
                .help("Range starts at the playhead (I)")
            Button { model.setRangeOut() } label: { Text("O").font(.callout.weight(.bold).monospaced()) }
                .help("Range ends at the playhead (O)")
            Divider().frame(height: 16)
            toggle("Snapping", "arrow.left.and.line.vertical.and.arrow.right", model.snapping, "Snapping (N): edges and selections snap to words, edit points, markers and the playhead") { model.snapping.toggle() }
            toggle("Skimming", "cursorarrow.motionlines", model.skimming, "Skimming (S): hover over the timeline to preview that moment in the viewer") { model.skimming.toggle() }
            toggle("Each source", "waveform", each, "Show a waveform for each sound source (dim = not heard)") { each.toggle() }
            if model.selectedClip == nil && !model.project.speakers.isEmpty && model.tlSel == nil {
                Divider().frame(height: 16)
                Button { model.showSpeakers = true } label: {
                    HStack(spacing: 10) {
                        ForEach(model.project.speakers.indices, id: \.self) { i in
                            HStack(spacing: 4) {
                                Circle().fill(Color(nsColor: speakerColors[i % speakerColors.count])).frame(width: 8, height: 8)
                                Text(model.project.speakers[i].name).font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Who's talking, by colour — the bar under the picture and the transcript use these colours. Click to rename them or choose their cameras.")
            }
            Spacer(minLength: 8)
            if let sel = model.tlSel {
                Text("\(fmtSpan(sel.upperBound - sel.lowerBound)) \(model.tlSegmentSelected ? "block" : "range")")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                if model.selectedClip != nil {
                    Button { model.cutTimelineSelection() } label: { Label(model.tlSegmentSelected ? "Delete block" : "Cut", systemImage: "scissors") }
                        .help("Remove it from the clip; everything after slides up (Delete)")
                } else {
                    Button { model.timelineSelectionToClip() } label: { Label("Make clip", systemImage: "plus.rectangle") }
                        .help("Make a clip from the selected range (C)")
                }
                Button { model.tlSel = nil } label: { Image(systemName: "xmark.circle.fill") }.help("Clear (Esc)")
                Divider().frame(height: 16)
            }
            Button { model.zoomTimeline(by: 1 / 1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.tlZoom <= 1.001).help("Zoom out (−)")
            Slider(value: Binding(get: { log(max(1, model.tlZoom)) },
                                  set: { v in model.zoomTimeline(by: exp(v) / max(1, model.tlZoom)) }),
                   in: 0...max(0.01, log(max(1.01, model.tlDuration / 0.4))))
                .frame(width: 110).controlSize(.mini)
                .help("Zoom the timeline (or pinch on the trackpad)")
            Button { model.zoomTimeline(by: 1.6) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in (=)")
            Button("Fit") { model.fitTimeline() }.disabled(model.tlZoom <= 1.001).help("Show everything (⇧Z)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    func toggle(_ title: String, _ icon: String, _ on: Bool, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(on ? Brand.green : Color.secondary)
                .padding(3)
                .background(on ? Brand.green.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .help(help + (on ? " — on" : " — off"))
        .accessibilityLabel(title)
    }
}

func fmtSpan(_ s: Double) -> String {
    s < 10 ? String(format: "%.2f s", s) : s < 60 ? String(format: "%.1f s", s) : fmtTime(s)
}

// MARK: - Right-click menus with closures

final class ClosureMenu: NSMenu {
    private final class Item: NSMenuItem {
        var run: () -> Void = {}
        @objc func fire() { run() }
    }
    func add(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) {
        let i = Item(title: title, action: #selector(Item.fire), keyEquivalent: "")
        i.target = i
        i.run = run
        i.state = checked ? .on : .off
        addItem(i)
    }
    func addSeparator() { if let last = items.last, !last.isSeparatorItem { addItem(.separator()) } }
}

// MARK: - Mouse / trackpad handling

/// A transparent AppKit view over the timeline: clicks, drags, hover, scroll, pinch, right-click, cursors.
struct TimelineMouse: NSViewRepresentable {
    var onDown: (CGPoint, NSEvent) -> Void
    var onDrag: (CGPoint) -> Void
    var onUp: (CGPoint, NSEvent) -> Void
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void
    var onScroll: (NSEvent, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onMenu: (CGPoint) -> NSMenu?
    var cursor: (CGPoint) -> NSCursor

    func makeNSView(context: Context) -> MouseView { MouseView() }
    func updateNSView(_ v: MouseView, context: Context) {
        v.onDown = onDown; v.onDrag = onDrag; v.onUp = onUp; v.onMove = onMove; v.onExit = onExit
        v.onScroll = onScroll; v.onMagnify = onMagnify; v.onMenu = onMenu; v.cursorFor = cursor
    }

    final class MouseView: NSView {
        var onDown: ((CGPoint, NSEvent) -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onUp: ((CGPoint, NSEvent) -> Void)?
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        var onScroll: ((NSEvent, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onMenu: ((CGPoint) -> NSMenu?)?
        var cursorFor: ((CGPoint) -> NSCursor)?
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        func pt(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t); tracking = t
        }
        override func mouseDown(with e: NSEvent) { onDown?(pt(e), e); cursorFor?(pt(e)).set() }
        override func mouseDragged(with e: NSEvent) { onDrag?(pt(e)) }
        override func mouseUp(with e: NSEvent) { onUp?(pt(e), e); cursorFor?(pt(e)).set() }
        override func mouseMoved(with e: NSEvent) { onMove?(pt(e)); cursorFor?(pt(e)).set() }
        override func mouseExited(with e: NSEvent) { onExit?(); NSCursor.arrow.set() }
        override func scrollWheel(with e: NSEvent) { onScroll?(e, pt(e)) }
        override func magnify(with e: NSEvent) { onMagnify?(e.magnification, pt(e)) }
        override func menu(for e: NSEvent) -> NSMenu? { onMenu?(pt(e)) }
    }
}
