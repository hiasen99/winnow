import Foundation
import CoreGraphics

/// The tracking that's running now (one at a time per project).
final class FollowJob: Identifiable {
    let id = UUID()
    let clipID: UUID
    let angle: Int
    /// master time of the pick
    let time: Double
    let control = FollowTracker.Control()
    let started = Date()
    init(clipID: UUID, angle: Int, time: Double) { self.clipID = clipID; self.angle = angle; self.time = time }
}

extension ProjectModel {

    // MARK: - What's followed

    func followIndex(for pc: EditPiece) -> Int? {
        selectedClip?.followIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle)
    }
    func follow(for pc: EditPiece) -> FollowTrack? { followIndex(for: pc).flatMap { selectedClip?.follows?[$0] } }

    /// The shot's follow path (nil = it doesn't follow anything).
    func followPath(for pc: EditPiece, in clip: Clip? = nil) -> FollowPath? {
        guard let c = clip ?? selectedClip, pc.angle < sources.count, let l = sources[pc.angle] else { return nil }
        let base = c.framing(forShotFrom: pc.masterStart, to: pc.masterStart + pc.duration, angle: pc.angle)
        return CompositionBuilder.followPath(c, piece: pc, l: l, render: c.format.renderSize, base: base)
    }

    /// How the shot is framed at master time t, following included.
    func framingNow(_ pc: EditPiece, at t: Double) -> Framing {
        if let p = followPath(for: pc), let f = p.at(t) { return f.framing }
        return framing(of: pc)
    }

    // MARK: - Picking

    /// Draw a box (or click) in the viewer around the thing to follow.
    func startFollowPick() {
        guard selectedClip != nil, shotAtPlayhead != nil else { notice = "Open a clip and put the playhead on the shot first."; return }
        guard followJob == nil else { notice = "Still following the last point — wait for it, or stop it."; return }
        engine.pause()
        showFraming = false
        followPicking = true
    }

    /// The box drawn in the viewer, in pixels of the finished frame (top-left origin). A click gives a zero-size box.
    func pickFollow(renderRect r: CGRect) {
        followPicking = false
        guard let c = selectedClip, let pc = shotAtPlayhead, pc.angle < sources.count, let l = sources[pc.angle] else { return }
        let t = min(pc.masterStart + pc.duration - 0.001, max(pc.masterStart, masterTime(engine.time)))
        let f = framingNow(pc, at: t)
        let (s, tx, ty) = CompositionBuilder.placementParts(natural: l.naturalSize, render: c.format.renderSize, framing: f)
        let W = max(1, l.naturalSize.width), H = max(1, l.naturalSize.height)
        // frame pixels → camera picture 0…1
        var box = CGRect(x: (r.minX - tx) / s / W, y: (r.minY - ty) / s / H, width: r.width / s / W, height: r.height / s / H)
        if r.width < 6 || r.height < 6 {
            // a click: a square around it, about 8% of the picture's height
            let side = 0.08 * min(W, H)
            box = CGRect(x: box.midX - side / 2 / W, y: box.midY - side / 2 / H, width: side / W, height: side / H)
        }
        box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0.004, box.height > 0.004 else { notice = "That's outside the camera picture — pick something in it."; return }
        startFollow(clipID: c.id, angle: pc.angle, at: t, box: box, wholeClip: followWholeClip)
    }

    /// Track `box` (camera picture 0…1) from master time t. If the shot already follows something, this re-picks
    /// from t onwards (keeping what came before); otherwise it makes a new follow for the shot (or the whole clip).
    @discardableResult
    func startFollow(clipID: UUID, angle: Int, at t: Double, box: CGRect, wholeClip: Bool) -> String {
        guard followJob == nil else { return "Already following a point; wait for it to finish (or follow.stop)." }
        guard let c = project.clips.first(where: { $0.id == clipID }) else { return "No such clip." }
        guard angle < sources.count, let l = sources[angle], l.video != nil else { return "That camera isn't loaded." }
        let pcs = Schedule.pieces(project: project, clip: c, auto: auto)
        guard let pc = pcs.first(where: { $0.angle == angle && t >= $0.masterStart - 1e-4 && t <= $0.masterStart + $0.duration + 1e-4 })
                ?? pcs.first(where: { $0.angle == angle }) else { return "Camera \(project.angles[angle].shortName) isn't on screen in that clip." }

        // re-pick inside an existing follow, or a new one
        let existing = c.followIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: angle)
        var track: FollowTrack
        if let k = existing, let tr = c.follows?[k], tr.contains(t), !(wholeClip && tr.end - tr.start < c.end - c.start - 0.05) {
            track = tr
            track.runs = tr.runs.filter { $0.pick.time < t - 0.01 }
            if var last = track.runs.popLast() {
                last.samples = last.samples.filter { $0.t < t - 0.0005 }
                if let lost = last.lostAt, lost >= t { last.lostAt = nil }
                if !last.samples.isEmpty || last.pick.time < t { track.runs.append(last) }
            }
        } else {
            let range = wholeClip ? (c.start, c.end) : (pc.masterStart, pc.masterStart + pc.duration)
            track = FollowTrack(angle: angle, start: range.0, end: range.1)
        }
        let back = track.runs.last.map { max(track.start, $0.last) } ?? track.start
        let fwd = track.end
        let off = project.angles[angle].offset
        let job = FollowJob(clipID: clipID, angle: angle, time: t)
        followJob = job
        followProgress = 0
        let base = track
        let cam = project.angles[angle].shortName
        Log.write("follow: camera \(cam) at \(String(format: "%.3f", t)) box \(box) range \(String(format: "%.2f–%.2f", back, fwd))")
        Task { @MainActor [weak self] in
            while let self, self.followJob?.id == job.id {
                self.followProgress = job.control.progress
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<FollowRun, Error>
            do { result = .success(try FollowTracker.run(angle: l, offset: off, box: box, at: t, forwardTo: fwd, backTo: back, control: job.control)) }
            catch { result = .failure(error) }
            await MainActor.run { self?.finishFollow(job, base: base, result: result) }
        }
        return "Following a point in camera \(cam) from \(fmtTime(t, frac: true)): tracking \(fmtTime(back))–\(fmtTime(fwd))."
    }

    private func finishFollow(_ job: FollowJob, base: FollowTrack, result: Result<FollowRun, Error>) {
        guard followJob?.id == job.id else { return }
        followJob = nil
        followProgress = 0
        switch result {
        case .failure(let e):
            if e is CancellationError { notice = "Stopped following."; return }
            errorText = "Couldn't follow that point: \(e.localizedDescription)"
            Log.write("follow failed: \(e)")
        case .success(let run):
            guard !run.samples.isEmpty else {
                notice = "The tracker couldn't lock on to that. Try a bigger box around something with clear detail."
                return
            }
            var tr = base
            tr.runs.append(run)
            tr.runs.sort { $0.first < $1.first }
            let secs = String(format: "%.1f", Date().timeIntervalSince(job.started))
            Log.write("follow: \(run.samples.count) frames \(String(format: "%.2f–%.2f", run.first, run.last)) lost \(run.lostAt.map { String(format: "%.2f", $0) } ?? "-") back-lost \(run.lostBackAt.map { String(format: "%.2f", $0) } ?? "-") in \(secs) s")
            guard let ci = project.clips.firstIndex(where: { $0.id == job.clipID }) else { return }
            let track = tr
            edit { p in
                var list = p.clips[ci].follows ?? []
                if let k = list.firstIndex(where: { $0.id == track.id }) {
                    list[k] = track
                } else {
                    // a new follow replaces older ones of the same camera it overlaps
                    list.removeAll { $0.angle == track.angle && $0.start < track.end - 0.01 && $0.end > track.start + 0.01 }
                    list.append(track)
                }
                p.clips[ci].follows = list
            }
            if let lost = run.lostAt {
                notice = "Lost it at \(fmtRec(lost, job.clipID)) — the framing holds still from there. Move there and pick it again."
            } else if let lost = run.lostBackAt {
                notice = "Following. Before \(fmtRec(lost, job.clipID)) it couldn't be seen, so the framing holds still there."
            } else {
                notice = "Following it through the shot."
            }
        }
    }

    /// A master time as a time in the clip (what the person sees on the timeline).
    func fmtRec(_ m: Double, _ clipID: UUID) -> String {
        if let c = project.clips.first(where: { $0.id == clipID }) { return fmtTime(c.outputTimeClamped(forMaster: m), frac: true) }
        return fmtTime(m, frac: true)
    }

    func stopFollowJob() { followJob?.control.cancel() }

    // MARK: - Settings

    func setFollow(_ id: UUID, live: Bool = true, _ change: (inout FollowTrack) -> Void) {
        let apply: (inout Clip) -> Void = { c in
            guard let k = c.follows?.firstIndex(where: { $0.id == id }) else { return }
            change(&c.follows![k])
        }
        if live { updateClipLive(apply) } else { updateClip(apply) }
    }

    func removeFollow(_ id: UUID) {
        updateClip { c in
            c.follows?.removeAll { $0.id == id }
            if c.follows?.isEmpty == true { c.follows = nil }
        }
        notice = "Stopped following; the shot uses its normal framing again."
    }

    /// Where the followed thing is at the playhead, as a box in the finished frame (pixels, top-left origin).
    func followMarker() -> (rect: CGRect, held: Bool, edge: Bool)? {
        guard let c = selectedClip, let pc = shotAtPlayhead, let tr = follow(for: pc),
              pc.angle < sources.count, let l = sources[pc.angle],
              let p = followPath(for: pc), let fr = p.at(masterTime(engine.time)) else { return nil }
        let pp = CompositionBuilder.placementParts(natural: l.naturalSize, render: c.format.renderSize, framing: fr.framing)
        let W = Double(l.naturalSize.width), H = Double(l.naturalSize.height)
        let s = Double(pp.s), tx = Double(pp.tx), ty = Double(pp.ty)
        // the box keeps the shape of the pick; its size follows the tracked size
        let pick = (tr.runs.last { $0.first <= masterTime(engine.time) } ?? tr.runs.first)?.pick.rect ?? CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let aspect = max(0.05, Double(pick.width) * W / max(1, Double(pick.height) * H))       // in pixels
        let side = fr.size * (W * H).squareRoot()                                       // √(w·h) in pixels, roughly
        let wpx = side * aspect.squareRoot(), hpx = side / aspect.squareRoot()
        let cx = Double(fr.feature.x) * W, cy = Double(fr.feature.y) * H
        let rect = CGRect(x: (cx - wpx / 2) * s + tx, y: (cy - hpx / 2) * s + ty, width: wpx * s, height: hpx * s)
        return (rect, fr.held, fr.edge)
    }
}
