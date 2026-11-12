import Foundation
import CoreGraphics

/// Clips2 --followtest <video> <t0> <t1> <x> <y> <w> <h> [lock]
/// Tracks the box forwards (and back to 0), prints the track as CSV, then checks the follow path keeps the
/// point at the same place in a 9:16 frame.
@MainActor
enum FollowTest {
    static func run(video: URL, t0: Double, t1: Double, box: CGRect, lockSize: Bool) async -> Int32 {
        do {
            let l = try await MediaLoader.load(url: video)
            print("video \(Int(l.naturalSize.width))x\(Int(l.naturalSize.height)) \(String(format: "%.2f", l.fps)) fps \(String(format: "%.2f", l.duration)) s")
            let ctl = FollowTracker.Control()
            let start = Date()
            let run = try await Task.detached { try FollowTracker.run(angle: l, offset: 0, box: box, at: t0, forwardTo: t1, backTo: 0, allowFace: ProcessInfo.processInfo.environment["WINNOW_NOFACE"] == nil, control: ctl) }.value
            let secs = Date().timeIntervalSince(start)
            print("kind \(run.kind ?? "-")")
            print(String(format: "tracked %d frames %.3f–%.3f in %.1f s (%.0f frames/s) lost %@ backLost %@", run.samples.count, run.first, run.last, secs,
                         Double(run.samples.count) / max(0.01, secs), run.lostAt.map { String(format: "%.3f", $0) } ?? "-", run.lostBackAt.map { String(format: "%.3f", $0) } ?? "-"))
            print("CSV t,x,y,s")
            for s in run.samples { print(String(format: "CSV %.4f,%.5f,%.5f,%.5f", s.t, s.x, s.y, s.s)) }
            // the path in a vertical frame
            var tr = FollowTrack(angle: 0, start: 0, end: t1)
            tr.runs = [run]
            tr.lockSize = lockSize
            let render = ClipFormat.vertical.renderSize
            let zr = CompositionBuilder.minZoom(source: l.naturalSize, render: render)...CompositionBuilder.maxZoom
            for smooth in [0.0, 0.1, 0.6] {
                tr.smoothing = smooth
                let p = Follow.path(tr, base: Framing(), from: 0, to: t1, source: l.naturalSize, render: render, zoomRange: zr)
                var ref: CGPoint? = nil
                var worst = 0.0, worstT = 0.0
                // where the raw tracked point lands in the finished frame (smoothing leaves a little wobble on purpose)
                for s in run.samples {
                    guard let f = p.at(s.t), !f.held else { continue }
                    let pp = CompositionBuilder.placementParts(natural: l.naturalSize, render: render, framing: f.framing)
                    let o = CGPoint(x: s.x * l.naturalSize.width * pp.s + pp.tx, y: s.y * l.naturalSize.height * pp.s + pp.ty)
                    if ref == nil { ref = o }
                    let d = hypot(o.x - ref!.x, o.y - ref!.y)
                    if d > worst { worst = d; worstT = f.t }
                }
                let zooms = p.frames.map { $0.framing.zoom }
                print(String(format: "path smoothing %.1f: %d frames, extra zoom %.3f, zoom %.3f–%.3f, point moves at most %.1f px (at %.2f s) in 1080x1920, held %d, edges %d",
                             smooth, p.frames.count, p.boost, zooms.min() ?? 0, zooms.max() ?? 0, worst, worstT, p.held.count, p.edges.count))
            }
            return 0
        } catch { print("FAILED \(error)"); return 1 }
    }
}
