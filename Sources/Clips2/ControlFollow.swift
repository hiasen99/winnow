import Foundation
import CoreGraphics

/// framing.follow: follow a point picked in the picture (the framing moves so it stays put).
extension Control {

    static func followInfo(_ m: ProjectModel, _ c: Clip) -> [[String: Any]] {
        let p = m.project
        let pcs = Schedule.pieces(project: p, clip: c, auto: m.auto)
        return (c.follows ?? []).map { tr -> [String: Any] in
            var e: [String: Any] = ["camera": angleName(tr.angle, p), "start": r3(tr.start), "end": r3(tr.end),
                                    "lockSize": tr.locksSize, "autoZoom": tr.zoomsToFit, "smoothing": r3(tr.smooth)]
            e["picks"] = tr.runs.map { r -> [String: Any] in
                var d: [String: Any] = ["time": r3(r.pick.time), "box": r.pick.box.map(r3), "tracked": [r3(r.first), r3(r.last)], "frames": r.samples.count]
                if let l = r.lostAt { d["lostAt"] = r3(l) }
                if let l = r.lostBackAt { d["lostGoingBackAt"] = r3(l) }
                return d
            }
            var shots: [[String: Any]] = []
            for pc in pcs where pc.angle == tr.angle && c.followIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle).map({ c.follows?[$0].id == tr.id }) == true {
                guard pc.angle < m.sources.count, let l = m.sources[pc.angle] else { continue }
                let base = c.framing(forShotFrom: pc.masterStart, to: pc.masterStart + pc.duration, angle: pc.angle)
                guard let path = CompositionBuilder.followPath(c, piece: pc, l: l, render: c.format.renderSize, base: base) else { continue }
                var s: [String: Any] = ["start": r3(pc.masterStart), "end": r3(pc.masterStart + pc.duration), "extraZoom": r3(path.boost)]
                if !path.held.isEmpty { s["notSeen"] = path.held.map { [r3($0.lowerBound), r3($0.upperBound)] } }
                if !path.edges.isEmpty { s["runsOffPicture"] = path.edges.map { [r3($0.lowerBound), r3($0.upperBound)] } }
                shots.append(s)
            }
            e["shots"] = shots
            return e
        }
    }

    static let followCommands: [ControlCommand] = [
        ControlCommand(id: "framing.follow", label: "Follow a Point", menu: "Framing… ▸ Follow a point", changesProject: true,
                       params: "{clip?, time: recording seconds of the frame to pick in (also picks the shot); where it is — either frameX, frameY: 0…1 in the finished frame as render_frame shows it at that moment (0,0 = top-left), or x, y: 0…1 in the whole camera picture; width?, height?: box size in the same units (default a square about 8% of the picture's height — use a box that covers something with clear detail); camera? (default: the one on screen then); wholeClip?: true = that camera follows it in every shot of the clip (default: just that shot). Picking again inside a followed shot re-tracks from that time on (what came before stays). Options, with or without a pick: lockSize?: true keeps it the same size when the camera zooms; autoZoom?: false lets the frame run off the picture instead of zooming in just enough (default true); smoothing?: 0 locked … 1 loose (default 0.1). remove?: true (with time) stops following in that shot; stop?: true cancels tracking that's running; wait?: false returns right away (default: waits up to 100 s for the tracking). clip_inspect 'follows' shows what was tracked, where it was lost (notSeen) or ran off the picture, and the extra zoom.}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            if a.bool("stop") == true {
                guard m.followJob != nil else { return "Nothing is being tracked." }
                m.stopFollowJob()
                return "Stopping the tracking."
            }
            let c = try targetClip(m, a)
            let t = a.num("time") ?? a.num("shot")
            // the shot it's about
            var pc: EditPiece? = nil
            if let t { pc = try shot(m, c, at: t) }

            if a.bool("remove") == true {
                guard let pc, let k = c.followIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle), let tr = c.follows?[k] else {
                    throw ControlError("No followed shot at that time (give time inside a followed shot; clip_inspect 'follows').")
                }
                change(m, c.id) { clip in clip.follows?.removeAll { $0.id == tr.id }; if clip.follows?.isEmpty == true { clip.follows = nil } }
                return "Stopped following in camera \(angleName(tr.angle, m.project)) (\(fmtTime(tr.start, frac: true))–\(fmtTime(tr.end, frac: true)))."
            }

            let picking = a.has("x") || a.has("frameX")
            var msg: [String] = []

            if !picking {
                guard let pc, let k = c.followIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle), let tr = c.follows?[k] else {
                    throw ControlError("To follow something give time plus frameX/frameY (or x/y). To change options give time inside a followed shot.")
                }
                if applyFollowOptions(m, c.id, a, tr.id) { msg.append("Options set.") }
                return msg.joined(separator: " ") + " " + summary(m, c.id, tr.id)
            }

            guard let t, var pcx = pc else { throw ControlError("Give time: the moment (recording seconds) to pick the point in.") }
            if a.has("camera"), let cam = try cameraIndex(m.project, a.d["camera"]), cam != pcx.angle {
                let pcs = Schedule.pieces(project: m.project, clip: c, auto: m.auto)
                guard let other = pcs.first(where: { $0.angle == cam }) else { throw ControlError("Camera \(angleName(cam, m.project)) isn't on screen in that clip.") }
                pcx = other
            }
            let sh = pcx
            guard sh.angle < m.sources.count, let l = m.sources[sh.angle] else { throw ControlError("That camera isn't loaded.") }
            let W = Double(l.naturalSize.width), H = Double(l.naturalSize.height)
            var box: CGRect
            let defW = 0.08 * min(W, H) / W, defH = 0.08 * min(W, H) / H
            if let fx = a.num("frameX"), let fy = a.num("frameY") {
                // finished frame → camera picture, through the framing at that moment
                let render = c.format.renderSize
                let base = c.framing(forShotFrom: sh.masterStart, to: sh.masterStart + sh.duration, angle: sh.angle)
                let f = CompositionBuilder.followPath(c, piece: sh, l: l, render: render, base: base)?.at(t)?.framing ?? base
                let pp = CompositionBuilder.placementParts(natural: l.naturalSize, render: render, framing: f)
                let s = Double(pp.s)
                let cx = (fx * Double(render.width) - Double(pp.tx)) / s / W
                let cy = (fy * Double(render.height) - Double(pp.ty)) / s / H
                let bw = a.num("width").map { $0 * Double(render.width) / s / W } ?? defW
                let bh = a.num("height").map { $0 * Double(render.height) / s / H } ?? defH
                box = CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)
            } else {
                let cx = a.num("x") ?? 0.5, cy = a.num("y") ?? 0.5
                let bw = a.num("width") ?? defW, bh = a.num("height") ?? defH
                box = CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)
            }
            box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isNull, box.width > 0.004, box.height > 0.004 else { throw ControlError("That point is outside the camera picture.") }
            let started = m.startFollow(clipID: c.id, angle: sh.angle, at: min(sh.masterStart + sh.duration - 0.001, max(sh.masterStart, t)),
                                        box: box, wholeClip: a.bool("wholeClip") ?? false)
            guard let job = m.followJob else { return started }
            if a.bool("wait") == false { return started + " Running in the background: clip_inspect shows it when done." }
            let t0 = Date()
            while m.followJob?.id == job.id && Date().timeIntervalSince(t0) < 100 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if m.followJob?.id == job.id { return started + " Still tracking after 100 s; clip_inspect shows it when done." }
            guard let now = m.project.clips.first(where: { $0.id == c.id }),
                  let tr = now.follows?.last(where: { $0.angle == sh.angle && $0.contains(t) }) else {
                return "Tracking ended without a result: \(m.errorText ?? m.notice ?? "the tracker couldn't lock on")."
            }
            if applyFollowOptions(m, c.id, a, tr.id) { msg.append("Options set.") }
            return (msg + [m.notice ?? ""]).joined(separator: " ") + " " + summary(m, c.id, tr.id)
        }),
    ]

    static func applyFollowOptions(_ m: ProjectModel, _ clipID: UUID, _ a: Args, _ id: UUID) -> Bool {
        guard a.has("lockSize") || a.has("autoZoom") || a.has("smoothing") else { return false }
        change(m, clipID) { clip in
            guard let k = clip.follows?.firstIndex(where: { $0.id == id }) else { return }
            if let v = a.bool("lockSize") { clip.follows![k].lockSize = v }
            if let v = a.bool("autoZoom") { clip.follows![k].autoZoom = v }
            if let v = a.num("smoothing") { clip.follows![k].smoothing = min(1, max(0, v)) }
        }
        return true
    }

    static func summary(_ m: ProjectModel, _ clipID: UUID, _ id: UUID) -> String {
        guard let c = m.project.clips.first(where: { $0.id == clipID }), let tr = c.follows?.first(where: { $0.id == id }) else { return "" }
        let info = followInfo(m, c).first { ($0["start"] as? Double) == r3(tr.start) && ($0["camera"] as? String) == angleName(tr.angle, m.project) }
        guard let info, let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return "Follow: " + s
    }
}
