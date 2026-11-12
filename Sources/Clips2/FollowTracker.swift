import Foundation
import AVFoundation
import CoreImage
import Vision
import simd

/// Follows a point through one camera file by lining up the picture around it frame by frame (Vision registration).
/// Forwards it streams frames; backwards it reads short chunks forwards, keeps small copies and walks them in reverse.
enum FollowTracker {
    /// Frames are shrunk to this long side before tracking (Vision works on small pictures anyway; this keeps it fast).
    static let workSide: CGFloat = 960

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        private var _progress = 0.0
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
        var progress: Double { lock.lock(); defer { lock.unlock() }; return _progress }
        func set(_ p: Double) { lock.lock(); _progress = p; lock.unlock() }
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// Tracks `box` (camera picture, 0…1, top-left origin) from master time `t0` forwards to `forwardTo`
    /// and backwards to `backTo`. `offset`: source time = master + offset.
    static func run(angle l: LoadedAngle, offset: Double, box: CGRect, at t0: Double,
                    forwardTo t1: Double, backTo tb: Double, allowFace: Bool = true, control: Control) throws -> FollowRun {
        guard l.video != nil else { throw ClipsError("That camera has no picture.") }
        let fwdLen = max(0, t1 - t0), backLen = max(0, t0 - tb)
        let total = max(0.001, fwdLen + backLen)
        var run = FollowRun(pick: FollowPick(time: t0, rect: box), samples: [])

        // forwards (this also finds the box in the frame you picked)
        let fwd = try forward(l, offset: offset, box: box, from: t0, to: t1, allowFace: allowFace, control: control) { done in
            control.set(min(fwdLen, max(0, done)) / total)
        }
        run.samples = fwd.samples
        run.lostAt = fwd.lostAt
        run.kind = fwd.kind
        if control.cancelled { throw CancellationError() }

        // backwards to where the stretch (or the previous pick) begins
        if backLen > 0.02 {
            let back = try backward(l, offset: offset, box: box, from: t0, to: tb, allowFace: fwd.kind != "scene", control: control) { done in
                control.set((fwdLen + min(backLen, done)) / total)
            }
            run.samples = back.samples.reversed() + run.samples.filter { s in !back.samples.contains { abs($0.t - s.t) < 0.001 } }
            run.lostBackAt = back.lostAt
        }
        control.set(1)
        return run
    }

    // MARK: - Frames

    /// The picture upright (the file's rotation applied) and shrunk to `workSide`, origin at 0,0.
    static func workImage(_ pb: CVPixelBuffer, _ l: LoadedAngle) -> CIImage {
        let raw = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let rect = CGRect(origin: .zero, size: raw).applying(l.transform)
        let norm = l.transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let up = CGSize(width: abs(rect.width), height: abs(rect.height))
        let k = min(1, workSide / max(1, max(up.width, up.height)))
        let t = norm.concatenating(CGAffineTransform(scaleX: k, y: k))
        var img = CIImage(cvPixelBuffer: pb).transformed(by: FramingCompositor.ciTransform(t, raw: raw, renderHeight: up.height * k))
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        return img.cropped(to: CGRect(x: 0, y: 0, width: (up.width * k).rounded(), height: (up.height * k).rounded()))
    }

    /// Reads source [s0, s1] (seconds in the file). Every `stride`-th frame is handed over with its time.
    static func read(_ l: LoadedAngle, from s0: Double, to s1: Double, control: Control,
                     _ body: (Double, CVPixelBuffer) throws -> Bool) throws {
        guard let track = l.video else { return }
        let reader = try AVAssetReader(asset: l.asset)
        let a = max(0, s0 - 0.5 / max(1, l.fps)), b = max(a + 0.001, s1 + 0.5 / max(1, l.fps))
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 60000), end: CMTime(seconds: b, preferredTimescale: 60000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw ClipsError("Can't read that camera's picture.") }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ClipsError("Can't read that camera's picture.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while let sb = out.copyNextSampleBuffer() {
            if control.cancelled { throw CancellationError() }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard pts.isFinite, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            if pts < s0 - 0.25 / max(1, l.fps) { continue }
            if pts > s1 + 0.25 / max(1, l.fps) { break }
            if try !body(pts, pb) { break }
        }
        if reader.status == .failed { throw reader.error ?? ClipsError("Reading the camera failed.") }
    }

    /// At most ~30 tracked frames a second (every other frame of 50/60 fps footage).
    static func stride(_ l: LoadedAngle) -> Int { l.fps > 40 ? 2 : 1 }

    // MARK: - Tracking

    private struct Pass { var samples: [FollowSample] = []; var lostAt: Double? = nil; var kind: String? = nil }

    /// Vision boxes have a bottom-left origin.
    static func toVision(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
    static func fromVision(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    /// How Vision's homography maps between the two pictures (pixels, Vision's bottom-left origin):
    /// the warp takes the new frame onto the reference one, so the point in the new frame is warp⁻¹(point in the reference).
    nonisolated(unsafe) static var debug = ProcessInfo.processInfo.environment["WINNOW_FOLLOWDEBUG"] != nil
    nonisolated(unsafe) static var debugCount = 0
    nonisolated(unsafe) static var convention = Int(ProcessInfo.processInfo.environment["WINNOW_HCONV"] ?? "") ?? 0     // 0 checked on test footage

    /// Follows a point that sits still in the scene while the camera moves: every frame, the patch around it
    /// is lined up with a reference frame (a homography over that patch), which gives where the point went and
    /// how much bigger or smaller things got. The reference moves on when the picture has changed a lot.
    private final class Tracker {
        let boxW: Double, boxH: Double
        var key: CGImage? = nil
        var keyPt = CGPoint.zero
        var keyScale = 1.0
        var prev: (img: CGImage, pt: CGPoint, scale: Double)? = nil
        var pt: CGPoint
        var scale = 1.0
        var steps = 0
        var fails = 0
        var firstFail: Double? = nil
        var sinceKey = 0
        var lastOffset = 0.0
        let pickSize: Double

        init(_ box: CGRect) {
            let b = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)).isNull ? box : box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            boxW = Double(b.width); boxH = Double(b.height)
            pt = CGPoint(x: b.midX, y: b.midY)
            pickSize = Double((b.width * b.height).squareRoot())
        }

        /// false = lost for good
        func step(_ img: CGImage, at t: Double, into pass: inout Pass) -> Bool {
            steps += 1
            guard let k = key else {
                key = img; keyPt = pt; keyScale = 1
                prev = (img, pt, 1)
                // the frame you picked in: the point is exactly where you put it
                pass.samples.append(FollowSample(t: t, x: Double(pt.x), y: Double(pt.y), s: pickSize))
                return true
            }
            var r = locate(img, from: k, keyPt: keyPt, keyScale: keyScale)
            if r == nil, let p = prev, p.img !== k {
                // the picture changed too much since the reference: start again from the last good frame
                key = p.img; keyPt = p.pt; keyScale = p.scale; sinceKey = 0
                r = locate(img, from: p.img, keyPt: p.pt, keyScale: p.scale)
            }
            guard let found = r else {
                fails += 1
                if firstFail == nil { firstFail = t }
                if fails >= 3 { pass.lostAt = firstFail; return false }
                return true
            }
            fails = 0; firstFail = nil
            pt = found.pt; scale = found.scale
            prev = (img, pt, scale)
            pass.samples.append(FollowSample(t: t, x: Double(pt.x), y: Double(pt.y), s: pickSize * scale))
            // move the reference on when things have shifted or changed size a lot
            sinceKey += 1
            if sinceKey >= 45 || abs(log(scale / keyScale)) > 0.15 || lastOffset > 0.12 {
                key = img; keyPt = pt; keyScale = scale; sinceKey = 0
            }
            if pt.x < -0.01 || pt.x > 1.01 || pt.y < -0.01 || pt.y > 1.01 { pass.lostAt = t; return false }
            return true
        }

        /// Where the reference's point is in `img`, and the size change. nil = couldn't line them up.
        /// Vision can't register just part of a picture, so both are cropped: around the point in the reference,
        /// and around where it was last seen in the new frame.
        private func locate(_ img: CGImage, from ref: CGImage, keyPt: CGPoint, keyScale: Double) -> (pt: CGPoint, scale: Double)? {
            let W = Double(ref.width), H = Double(ref.height)
            // a patch a few times the box, at least a fifth of the picture's width, square in pixels
            // both crops stay centred on the point (near the edge they get smaller rather than sliding over:
            // a crop pushed off-centre stops seeing the motion)
            func room(_ c: CGPoint) -> Double {
                2 * min(Double(c.x) * W, (1 - Double(c.x)) * W, Double(c.y) * H, (1 - Double(c.y)) * H)
            }
            let side = min(min(W, H), max(0.2 * W, 3 * max(boxW * W, boxH * H) * min(2.5, keyScale)), room(keyPt), room(pt)).rounded(.down)
            guard side >= 40 else { return nil }
            func crop(_ c: CGPoint) -> CGRect {
                CGRect(x: (Double(c.x) * W - side / 2).rounded(), y: (Double(c.y) * H - side / 2).rounded(), width: side, height: side)
            }
            let rk = crop(keyPt), rc = crop(pt)
            guard let kc = ref.cropping(to: rk), let cc = img.cropping(to: rc) else { return nil }
            let req = VNHomographicImageRegistrationRequest(targetedCGImage: cc, options: [:])
            do { try VNImageRequestHandler(cgImage: kc, options: [:]).perform([req]) } catch {
                if FollowTracker.debug { print("DEBUG register threw \(error)") }
                return nil
            }
            guard let o = req.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
            let m = o.warpTransform
            func apply(_ a: simd_float3x3, _ x: Double, _ y: Double) -> (Double, Double)? {
                let v = a * SIMD3<Float>(Float(x), Float(y), 1)
                guard abs(v.z) > 1e-6 else { return nil }
                return (Double(v.x / v.z), Double(v.y / v.z))
            }
            let conv = FollowTracker.convention
            let useInverse = conv % 2 == 0
            let topLeft = conv >= 2
            let mm = useInverse ? m.inverse : m
            let h = Double(rk.height)
            // the point in the reference crop
            let lx = Double(keyPt.x) * W - Double(rk.minX), ly = Double(keyPt.y) * H - Double(rk.minY)
            guard let q = apply(mm, lx, topLeft ? ly : h - ly) else { return nil }
            let qx = q.0, qy = topLeft ? q.1 : h - q.1
            let nx = (qx + Double(rc.minX)) / W, ny = (qy + Double(rc.minY)) / H
            let det = Double(m.columns.0.x * m.columns.1.y - m.columns.1.x * m.columns.0.y)
            if FollowTracker.debug && FollowTracker.debugCount < 12 {
                FollowTracker.debugCount += 1
                print(String(format: "DEBUG H t %.1f %.1f  a %.3f %.3f %.3f %.3f  det %.3f  key %.3f,%.3f -> %.4f,%.4f", m.columns.2.x, m.columns.2.y,
                             m.columns.0.x, m.columns.1.x, m.columns.0.y, m.columns.1.y, det, keyPt.x, keyPt.y, nx, ny))
            }
            guard det.isFinite, det > 0.3, det < 3.5 else { return nil }
            let k = useInverse ? 1 / det.squareRoot() : det.squareRoot()
            // sanity: a camera moving, turning a little or zooming looks like a similarity; a bad match shears or jumps
            let a = Double(m.columns.0.x), b = Double(m.columns.1.x), c = Double(m.columns.0.y), d = Double(m.columns.1.y)
            let shear = ((a - d) * (a - d) + (b + c) * (b + c)).squareRoot() / max(0.1, det.squareRoot())
            guard shear < 0.12 else { return nil }
            guard hypot(nx - Double(pt.x), (ny - Double(pt.y)) * H / W) < 0.12 else { return nil }
            guard abs(log(keyScale * k / scale)) < 0.08 else { return nil }
            // how far the point sits from where it sat in the reference crop: far = little overlap, move the reference on soon
            let dl = hypot(qx - lx, qy - ly) / side
            lastOffset = dl
            return (CGPoint(x: nx, y: ny), keyScale * k)
        }
    }

    /// A point on a face: the face's landmarks are found in every frame (nothing builds up over time),
    /// and the point keeps its place among them (a best-fit move + turn + zoom of all the landmarks).
    private final class FaceTracker {
        var refPts: [CGPoint]           // landmarks in the pick frame, pixels, top-left origin
        let pickPx: CGPoint
        var lastCenter: CGPoint
        var lastSize: Double
        let pickSize: Double
        var fails = 0
        var firstFail: Double? = nil

        init(refPts: [CGPoint], pickPx: CGPoint, face: CGRect, pickSize: Double) {
            self.refPts = refPts; self.pickPx = pickPx
            lastCenter = CGPoint(x: face.midX, y: face.midY); lastSize = Double(max(face.width, face.height))
            self.pickSize = pickSize
        }

        struct Face { var box: CGRect; var pts: [CGPoint] }     // box in pixels, top-left origin
        static func faces(_ img: CGImage) -> [Face] {
            let W = CGFloat(img.width), H = CGFloat(img.height)
            let req = VNDetectFaceLandmarksRequest()
            req.constellation = .constellation76Points
            do { try VNImageRequestHandler(cgImage: img, options: [:]).perform([req]) } catch { return [] }
            return (req.results ?? []).compactMap { f in
                guard let all = f.landmarks?.allPoints, all.pointCount >= 20 else { return nil }
                let pts = all.pointsInImage(imageSize: CGSize(width: W, height: H)).map { CGPoint(x: $0.x, y: H - $0.y) }
                let b = f.boundingBox
                return Face(box: CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H), pts: pts)
            }
        }

        /// A face under the picked point (its box grown a little, for hair and chin), or nil.
        static func start(_ img: CGImage, box: CGRect) -> FaceTracker? {
            let W = CGFloat(img.width), H = CGFloat(img.height)
            let p = CGPoint(x: box.midX * W, y: box.midY * H)
            let hits = faces(img).filter { $0.box.insetBy(dx: -$0.box.width * 0.15, dy: -$0.box.height * 0.25).contains(p) }
            guard let f = hits.min(by: { hypot($0.box.midX - p.x, $0.box.midY - p.y) < hypot($1.box.midX - p.x, $1.box.midY - p.y) }) else { return nil }
            return FaceTracker(refPts: f.pts, pickPx: p, face: f.box, pickSize: Double((box.width * box.height).squareRoot()))
        }

        func step(_ img: CGImage, at t: Double, into pass: inout Pass) -> Bool {
            let W = Double(img.width), H = Double(img.height)
            let all = Self.faces(img).filter { $0.pts.count == refPts.count }
            // the face nearest to where it was, about the same size
            let f = all.min { hypot($0.box.midX - lastCenter.x, $0.box.midY - lastCenter.y) < hypot($1.box.midX - lastCenter.x, $1.box.midY - lastCenter.y) }
            // after it's been gone a while (a hand over the face, turned away), take it back wherever it shows up again
            let reach = fails >= 15 ? (all.count == 1 ? 10 * W : 1.5 * lastSize + 0.15 * W) : 0.6 * lastSize + 0.05 * W
            guard let f, hypot(Double(f.box.midX - lastCenter.x), Double(f.box.midY - lastCenter.y)) < reach,
                  let fit = FaceTracker.similarity(from: refPts, to: f.pts) else {
                fails += 1
                if firstFail == nil { firstFail = t }
                return true                // keep looking: the face model doesn't drift, so it can pick up again later
            }
            fails = 0; firstFail = nil
            lastCenter = CGPoint(x: f.box.midX, y: f.box.midY); lastSize = Double(max(f.box.width, f.box.height))
            let q = fit.map(pickPx)
            pass.samples.append(FollowSample(t: t, x: Double(q.x) / W, y: Double(q.y) / H, s: pickSize * fit.scale))
            return true
        }

        struct Similarity {
            var ma: CGPoint, mb: CGPoint, scale: Double, cos: Double, sin: Double
            func map(_ p: CGPoint) -> CGPoint {
                let x = Double(p.x - ma.x), y = Double(p.y - ma.y)
                return CGPoint(x: Double(mb.x) + scale * (cos * x - sin * y), y: Double(mb.y) + scale * (sin * x + cos * y))
            }
        }
        /// Least-squares move + turn + zoom taking points `a` onto `b`.
        static func similarity(from a: [CGPoint], to b: [CGPoint]) -> Similarity? {
            guard a.count == b.count, a.count >= 3 else { return nil }
            let n = Double(a.count)
            let ma = CGPoint(x: a.map { Double($0.x) }.reduce(0, +) / n, y: a.map { Double($0.y) }.reduce(0, +) / n)
            let mb = CGPoint(x: b.map { Double($0.x) }.reduce(0, +) / n, y: b.map { Double($0.y) }.reduce(0, +) / n)
            var sxx = 0.0, sxy = 0.0, va = 0.0
            for i in a.indices {
                let ax = Double(a[i].x - ma.x), ay = Double(a[i].y - ma.y)
                let bx = Double(b[i].x - mb.x), by = Double(b[i].y - mb.y)
                sxx += ax * bx + ay * by
                sxy += ax * by - ay * bx
                va += ax * ax + ay * ay
            }
            guard va > 1e-6 else { return nil }
            let c = sxx / va, s = sxy / va
            let k = hypot(c, s)
            guard k > 0.2, k < 5 else { return nil }
            return Similarity(ma: ma, mb: mb, scale: k, cos: c / k, sin: s / k)
        }
    }

    /// Picks the way to follow on the first frame: a face if the point is on one, otherwise the scene around it.
    private final class AnyTracker {
        let box: CGRect
        let allowFace: Bool
        var face: FaceTracker? = nil
        var scene: Tracker? = nil
        var kind: String? { face != nil ? "face" : scene != nil ? "scene" : nil }
        /// a face that went and never came back before the end
        func finish(_ pass: inout Pass) {
            if let f = face, f.fails > 0, let ff = f.firstFail, pass.lostAt == nil { pass.lostAt = ff }
        }
        init(_ box: CGRect, allowFace: Bool) { self.box = box; self.allowFace = allowFace }
        func step(_ img: CGImage, at t: Double, into pass: inout Pass) -> Bool {
            if face == nil && scene == nil {
                if allowFace, let f = FaceTracker.start(img, box: box) {
                    face = f
                    pass.samples.append(FollowSample(t: t, x: Double(box.midX), y: Double(box.midY), s: f.pickSize))
                    return true
                }
                scene = Tracker(box)
            }
            if let f = face { return f.step(img, at: t, into: &pass) }
            return scene!.step(img, at: t, into: &pass)
        }
    }

    private static func forward(_ l: LoadedAngle, offset: Double, box: CGRect, from t0: Double, to t1: Double, allowFace: Bool,
                                control: Control, progress: (Double) -> Void) throws -> Pass {
        var pass = Pass()
        let tracker = AnyTracker(box, allowFace: allowFace)
        let st = stride(l)
        var n = 0
        try read(l, from: t0 + offset, to: t1 + offset, control: control) { pts, pb in
            defer { n += 1 }
            guard n % st == 0 else { return true }
            let t = pts - offset
            let going = autoreleasepool { () -> Bool in
                let img = workImage(pb, l)
                guard let cg = context.createCGImage(img, from: img.extent) else { return true }
                return tracker.step(cg, at: t, into: &pass)
            }
            progress(t - t0)
            return going
        }
        tracker.finish(&pass)
        pass.kind = tracker.kind
        return pass
    }

    /// Backwards in 2-second chunks: each chunk is read forwards into small pictures, then tracked in reverse.
    private static func backward(_ l: LoadedAngle, offset: Double, box: CGRect, from t0: Double, to tb: Double, allowFace: Bool,
                                 control: Control, progress: (Double) -> Void) throws -> Pass {
        var pass = Pass()
        let tracker = AnyTracker(box, allowFace: allowFace)
        let st = stride(l)
        let chunk = 2.0
        var hi = t0
        var first = true
        outer: while hi > tb + 0.001 {
            let lo = max(tb, hi - chunk)
            var frames: [(Double, CGImage)] = []
            var n = 0
            try read(l, from: lo + offset, to: hi + offset, control: control) { pts, pb in
                defer { n += 1 }
                let t = pts - offset
                guard t <= hi + 0.0005, n % st == 0 else { return true }
                autoreleasepool {
                    let img = workImage(pb, l)
                    if let cg = context.createCGImage(img, from: img.extent) { frames.append((t, cg)) }
                }
                return true
            }
            if frames.isEmpty { break }
            for (t, cg) in frames.reversed() {
                if control.cancelled { throw CancellationError() }
                // the frame at the pick itself was already tracked going forwards; start it again here so the tracker settles
                if !first && t >= hi - 0.0005 { continue }
                let going = tracker.step(cg, at: t, into: &pass)
                progress(t0 - t)
                if !going { break outer }
            }
            first = false
            hi = lo
        }
        tracker.finish(&pass)
        pass.kind = tracker.kind
        return pass
    }
}
