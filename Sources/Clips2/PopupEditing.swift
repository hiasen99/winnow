import Foundation
import AppKit
import QuartzCore

/// A popup being moved / re-timed on the timeline.
struct PopupDrag {
    var id: UUID
    var mode: CaptionDrag.Mode
    var start: Double       // output time when the drag began
    var end: Double
    var anchor: Double      // output time where the mouse went down
}

extension ProjectModel {

    var clipPopups: [FollowPopup] { selectedClip?.popups ?? [] }
    func popup(_ id: UUID?) -> FollowPopup? { id.flatMap { i in clipPopups.first { $0.id == i } } }
    var projectBrand: ChannelBrand? { BrandStore.brand(project.brandID) }

    /// Start / end of a popup in the clip showing (output time).
    func popupSpan(_ p: FollowPopup) -> (start: Double, end: Double) {
        guard let c = selectedClip else { return (0, 0) }
        return Popups.span(p, clip: c)
    }

    // MARK: adding, changing, removing

    /// A new popup at the playhead (or `at`, seconds into the clip). Returns its id.
    @discardableResult
    func addPopup(_ kind: PopupKind, at out: Double? = nil, length: Double = 4) -> UUID? {
        guard let c = selectedClip else { return nil }
        let total = c.outputDuration
        let len = max(FollowPopup.minLength, min(length, total))
        let start = max(0, min(out ?? engine.time, total - len))
        var p = FollowPopup(kind: kind, time: c.masterTime(forOutput: start))
        p.length = len
        let spot = FollowPopup.defaultSpot(kind, c.format)
        p.x = spot.x; p.y = spot.y
        updateClip(rebuild: false) { $0.popups = ($0.popups ?? []) + [p] }
        refreshPopups()
        selectPopup(p.id, show: true)
        return p.id
    }

    func updatePopup(_ id: UUID, live: Bool = false, _ change: (inout FollowPopup) -> Void) {
        guard let i = clipIndex, let k = project.clips[i].popups?.firstIndex(where: { $0.id == id }) else { return }
        if live { liveEdit { change(&$0.clips[i].popups![k]) } }
        else { edit(rebuild: false) { change(&$0.clips[i].popups![k]) } }
        refreshPopups()
    }

    func removePopup(_ id: UUID) {
        guard let i = clipIndex else { return }
        if selectedPopup == id { selectedPopup = nil }
        edit(rebuild: false) { p in
            p.clips[i].popups?.removeAll { $0.id == id }
            if p.clips[i].popups?.isEmpty == true { p.clips[i].popups = nil }
        }
        refreshPopups()
    }

    func duplicatePopup(_ id: UUID) {
        guard let c = selectedClip, var p = popup(id) else { return }
        let sp = Popups.span(p, clip: c)
        p.id = UUID()
        let start = min(sp.end + 0.5, max(0, c.outputDuration - p.length))
        p.time = c.masterTime(forOutput: start)
        updateClip(rebuild: false) { $0.popups = ($0.popups ?? []) + [p] }
        refreshPopups()
        selectPopup(p.id, show: true)
    }

    /// Starts the popup at the playhead.
    func movePopupToPlayhead(_ id: UUID) {
        guard let c = selectedClip, let p = popup(id) else { return }
        let start = max(0, min(engine.time, c.outputDuration - FollowPopup.minLength))
        updatePopup(id) { $0.time = c.masterTime(forOutput: start); $0.length = min(p.length, c.outputDuration - start) }
    }

    func setPopupStart(_ id: UUID, out: Double) {
        guard let c = selectedClip, let p = popup(id) else { return }
        let start = max(0, min(out, c.outputDuration - FollowPopup.minLength))
        updatePopup(id) { $0.time = c.masterTime(forOutput: start); $0.length = min(p.length, c.outputDuration - start) }
    }

    /// Picks a popup: its settings show on the right and the viewer goes to it (once it has popped in).
    func selectPopup(_ id: UUID?, show: Bool = false) {
        selectedPopup = id
        guard let id else { return }
        showThumbnail = false
        selectedCaption = nil
        if show, let p = popup(id) {
            let sp = popupSpan(p)
            if engine.time < sp.start + 0.05 || engine.time > sp.end - 0.05 {
                engine.pause()
                engine.seek(min(sp.start + 0.8, sp.end - 0.05))
            }
        }
    }

    // MARK: the viewer

    /// Swaps just the popups in the viewer (no reload of the picture). Falls back to a full rebuild.
    func refreshPopups() {
        guard let c = selectedClip else { return }
        guard let root = engine.captionLayer, let b = engine.built else { rebuild(); return }
        let new = Popups.layer(clip: c, project: project, renderSize: b.renderSize, total: b.duration)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let old = root.sublayers?.first(where: { $0.name == "popups" }) { root.replaceSublayer(old, with: new) }
        else { root.addSublayer(new) }
        CATransaction.commit()
        engine.overlayChanged()
    }

    /// The popup under a point in the viewer (render pixels, top-left origin), the picked one first.
    func popupAt(render pt: CGPoint) -> UUID? {
        guard let c = selectedClip else { return nil }
        let vis = Popups.visible(clip: c, project: project, renderSize: engine.renderSize, at: engine.time)
        if let s = selectedPopup, let hit = vis.first(where: { $0.id == s }), hit.rect.insetBy(dx: -8, dy: -8).contains(pt) { return s }
        return vis.last { $0.rect.insetBy(dx: -8, dy: -8).contains(pt) }?.id
    }

    /// The picked popup's box in the viewer right now (render pixels), if it's on screen.
    var selectedPopupRect: CGRect? {
        guard let s = selectedPopup, let c = selectedClip else { return nil }
        return Popups.visible(clip: c, project: project, renderSize: engine.renderSize, at: engine.time).first { $0.id == s }?.rect
    }

    /// Dragged in the viewer by (dx, dy) render pixels (y down): one undo step.
    func movePopup(_ id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let c = selectedClip, let p = popup(id) else { return }
        let R = engine.renderSize
        let L = Popups.layout(p, brand: Popups.brand(for: p, project: project), renderSize: R)
        let box = Popups.frame(p, layout: L, renderSize: R)
        var q = p
        q.x = Double((box.midX + dx) / R.width); q.y = Double((box.midY + dy) / R.height)
        let nb = Popups.frame(q, layout: L, renderSize: R)       // kept inside the frame
        _ = c
        updatePopup(id) { $0.x = Double(nb.midX / R.width); $0.y = Double(nb.midY / R.height) }
    }

    func placePopup(_ id: UUID, at spot: PopupSpot) {
        let (x, y) = spot.xy
        updatePopup(id) { $0.x = x; $0.y = y }
    }

    // MARK: the timeline

    func beginPopupDrag(_ id: UUID, mode: CaptionDrag.Mode, atOutput t: Double) {
        guard let p = popup(id) else { return }
        let sp = popupSpan(p)
        popupDrag = PopupDrag(id: id, mode: mode, start: sp.start, end: sp.end, anchor: t)
        beginGesture()
        selectPopup(id)
        engine.pause()
    }

    func updatePopupDrag(toOutput t: Double, spp: Double) {
        guard let d = popupDrag, let c = selectedClip else { return }
        let total = c.outputDuration
        let tol = 8 * spp
        var s = d.start, e = d.end
        switch d.mode {
        case .move:
            let len = d.end - d.start
            s = d.start + (t - d.anchor)
            let snapped = snapOutput(s, tol: tol)
            if snapped != s { s = snapped } else {
                let se = snapOutput(s + len, tol: tol); s = se - len
            }
            s = max(0, min(s, total - len)); e = s + len
        case .start:
            s = max(0, min(snapOutput(t, tol: tol), d.end - FollowPopup.minLength))
        case .end:
            e = min(total, max(snapOutput(t, tol: tol), d.start + FollowPopup.minLength))
        }
        let master = c.masterTime(forOutput: s)
        updatePopup(d.id, live: true) { $0.time = master; $0.length = e - s }
        engine.seek(d.mode == .end ? max(s, e - 0.05) : min(s + 0.8, e - 0.05))
    }

    func endPopupDrag() {
        popupDrag = nil
        endGesture()
    }

    // MARK: brands

    /// Uses a brand for this project: its caption and thumbnail looks (if it has them) and the default for popups.
    func applyBrand(_ id: UUID?) {
        let b = BrandStore.brand(id)
        edit(rebuild: false) { p in
            p.brandID = id
            if let cs = b?.captionStyle { p.captionStyle = cs }
            if let ts = b?.thumbnailStyle { p.thumbnailStyle = ts }
        }
        if selectedClip != nil { rebuild() }
        if let b {
            var what: [String] = []
            if b.captionStyle != nil { what.append("caption look") }
            if b.thumbnailStyle != nil { what.append("thumbnail look") }
            notice = "This project now uses \(b.name)" + (what.isEmpty ? "." : " (and its \(what.joined(separator: " and "))).")
        }
    }
}
