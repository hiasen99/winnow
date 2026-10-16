import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore

/// An opened camera file.
struct LoadedAngle {
    var asset: AVURLAsset
    var video: AVAssetTrack?
    var audio: AVAssetTrack?
    var naturalSize: CGSize          // after rotation
    var rawSize: CGSize              // as stored in the file
    var transform: CGAffineTransform // preferredTransform
    var duration: Double
    var fps: Double
}

enum MediaLoader {
    static func load(_ a: AngleSource) async throws -> LoadedAngle {
        let asset = AVURLAsset(url: a.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = try await asset.loadTracks(withMediaType: .video).first
        let au = try await asset.loadTracks(withMediaType: .audio).first
        let dur = try await asset.load(.duration).seconds
        var size = CGSize(width: 1920, height: 1080)
        var tf = CGAffineTransform.identity
        var raw = size
        var fps = 30.0
        if let v {
            let (ns, t, r) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            tf = t
            raw = ns
            let rect = CGRect(origin: .zero, size: ns).applying(t)
            size = CGSize(width: abs(rect.width), height: abs(rect.height))
            if r > 1 { fps = Double(r) }
        }
        return LoadedAngle(asset: asset, video: v, audio: au, naturalSize: size, rawSize: raw, transform: tf, duration: dur, fps: fps)
    }
}

struct BuiltEdit {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioTracks: [Int: AVMutableCompositionTrack]   // angle -> track
    let pieces: [EditPiece]
    let renderSize: CGSize
    let duration: Double
}

enum CompositionBuilder {
    static let ts: CMTimeScale = 48_000
    static func t(_ s: Double) -> CMTime { CMTime(value: CMTimeValue((s * Double(ts)).rounded()), timescale: ts) }
    static func range(_ a: Double, _ b: Double) -> CMTimeRange {
        let s = t(a), e = t(b)
        return CMTimeRange(start: s, end: e)
    }

    /// Builds a playable edit. No rendering happens here: it only describes which pieces of
    /// which files to play, so it's instant and AVPlayer plays the original camera files.
    static func build(project p: Project, clip: Clip?, auto: [AngleSegment],
                      loaded: [LoadedAngle?], format: ClipFormat?, audible: Set<Int>? = nil) throws -> BuiltEdit {
        let comp = AVMutableComposition()
        let pieces = Schedule.pieces(project: p, clip: clip, auto: auto)
        let total = pieces.last.map { $0.outStart + $0.duration } ?? 0

        // video: one composition track per angle
        var vTracks: [Int: AVMutableCompositionTrack] = [:]
        for (i, l) in loaded.enumerated() where l?.video != nil {
            vTracks[i] = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        // which output ranges each angle is visible in
        var visible: [(CMTimeRange, EditPiece)] = []
        for piece in pieces {
            guard let l = loaded[piece.angle], let src = l.video, let track = vTracks[piece.angle] else { continue }
            let a = p.angles[piece.angle]
            let s0 = max(0, piece.masterStart + a.offset)
            let s1 = min(l.duration, piece.masterStart + piece.duration + a.offset)
            guard s1 > s0 + 0.001 else { continue }
            let outAt = piece.outStart + (s0 - (piece.masterStart + a.offset))
            try track.insertTimeRange(range(s0, s1), of: src, at: t(outAt))
            visible.append((range(piece.outStart, piece.outStart + piece.duration), piece))
        }

        // audio: every angle's sound runs the whole clip; the mix decides what you hear
        var aTracks: [Int: AVMutableCompositionTrack] = [:]
        let ranges = clip?.ranges ?? [TimeRange(start: 0, end: p.masterDuration)]
        for (i, l) in loaded.enumerated() {
            guard let l, let src = l.audio else { continue }
            // preview: leave out sources you can't hear, so a muted one can never leak into playback
            if let audible, !audible.contains(i) { continue }
            let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            aTracks[i] = track
            let a = p.angles[i]
            var outPos = 0.0
            for r in ranges {
                let s0 = max(0, r.start + a.offset), s1 = min(l.duration, r.end + a.offset)
                if s1 > s0 + 0.001 {
                    let at = outPos + (s0 - (r.start + a.offset))
                    try track.insertTimeRange(range(s0, s1), of: src, at: t(at))
                }
                outPos += r.duration
            }
        }

        // how the picture is placed in the frame
        let fmt = format
        let base = loaded.compactMap { $0 }.first?.naturalSize ?? CGSize(width: 1920, height: 1080)
        let render: CGSize = fmt?.renderSize ?? fitted(base)
        let vc = AVMutableVideoComposition()
        vc.renderSize = render
        let fps = min(60, max(24, loaded.compactMap { $0?.fps }.max() ?? 30))
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (r, piece) in visible {
            let angle = piece.angle
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = r
            ins.backgroundColor = CGColor(gray: 0, alpha: 1)
            if let track = vTracks[angle], let l = loaded[angle] {
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                // the shot's own framing if it has one, else the camera's
                let framing = clip?.framing(forShotFrom: piece.masterStart, to: piece.masterStart + piece.duration, angle: angle) ?? Framing()
                li.setTransform(placement(l, render: render, framing: fmt == nil ? Framing() : framing), at: r.start)
                ins.layerInstructions = [li]
            }
            instructions.append(ins)
        }
        // instructions must cover the whole timeline with no gaps
        instructions = fillGaps(instructions, total: t(total))
        vc.instructions = instructions
        return BuiltEdit(composition: comp, videoComposition: vc, audioTracks: aTracks,
                         pieces: pieces, renderSize: render, duration: total)
    }

    static func fitted(_ s: CGSize) -> CGSize {
        // keep previews light: at most 1920 wide, even numbers
        let k = min(1, 1920 / max(1, s.width))
        return CGSize(width: (s.width * k / 2).rounded() * 2, height: (s.height * k / 2).rounded() * 2)
    }

    static func fillGaps(_ list: [AVMutableVideoCompositionInstruction], total: CMTime) -> [AVMutableVideoCompositionInstruction] {
        var out: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        for ins in list.sorted(by: { $0.timeRange.start < $1.timeRange.start }) {
            if ins.timeRange.start > cursor {
                let g = AVMutableVideoCompositionInstruction()
                g.timeRange = CMTimeRange(start: cursor, end: ins.timeRange.start)
                g.backgroundColor = CGColor(gray: 0, alpha: 1)
                out.append(g)
            } else if ins.timeRange.start < cursor {
                ins.timeRange = CMTimeRange(start: cursor, end: max(cursor, ins.timeRange.end))
                if ins.timeRange.duration <= .zero { continue }
            }
            out.append(ins)
            cursor = ins.timeRange.end
        }
        if cursor < total {
            let g = AVMutableVideoCompositionInstruction()
            g.timeRange = CMTimeRange(start: cursor, end: total)
            g.backgroundColor = CGColor(gray: 0, alpha: 1)
            out.append(g)
        }
        return out
    }

    /// Scale-to-fill the frame, then slide/zoom according to framing.
    static func placement(_ l: LoadedAngle, render: CGSize, framing: Framing) -> CGAffineTransform {
        let W = l.naturalSize.width, H = l.naturalSize.height
        let s = max(render.width / W, render.height / H) * CGFloat(max(1, framing.zoom))
        let sw = W * s, sh = H * s
        var tx = render.width / 2 - CGFloat(framing.x) * sw
        var ty = render.height / 2 - CGFloat(framing.y) * sh
        tx = min(0, max(render.width - sw, tx))
        ty = min(0, max(render.height - sh, ty))
        // preferredTransform may move the picture off-origin when it rotates; normalise first
        let rect = CGRect(origin: .zero, size: l.rawSize).applying(l.transform)
        let norm = l.transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return norm.concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    /// Volume per source over the edit. With a clip, the sound can change partway through
    /// (short 40 ms fades at each change); changing it never needs a rebuild.
    static func audioMix(_ built: BuiltEdit, mix: AudioMix, angles: [AngleSource], clip: Clip? = nil) -> AVAudioMix {
        let m = AVMutableAudioMix()
        func gain(_ i: Int) -> Float {
            let db = mix.gain(i) + (i < angles.count ? angles[i].gainDB : 0)
            return powf(10, Float(db) / 20)
        }
        func isOn(_ on: [Bool], _ i: Int) -> Bool { i < on.count ? on[i] : false }
        // stretches of constant sound in output time
        var segs: [(out: Double, on: [Bool])] = [(0, mix.on)]
        if let clip {
            segs = clip.soundSegments().map { (clip.outputTimeClamped(forMaster: $0.start), $0.on) }
        }
        // AVAudioMix volumes top out at 1.0; keep the balance by scaling the loudest to 1
        var peak: Float = 0
        for sg in segs { for (i, _) in built.audioTracks where isOn(sg.on, i) { peak = max(peak, gain(i)) } }
        let k: Float = peak > 1 ? 1 / peak : 1
        let fade = 0.02
        var params: [AVMutableAudioMixInputParameters] = []
        for (i, track) in built.audioTracks {
            let p = AVMutableAudioMixInputParameters(track: track)
            var prev = isOn(segs[0].on, i) ? gain(i) * k : 0
            p.setVolume(prev, at: .zero)
            var lastEnd = 0.001
            for sg in segs.dropFirst() {
                let v = isOn(sg.on, i) ? gain(i) * k : 0
                if v != prev {
                    let a = max(lastEnd, sg.out - fade), b = sg.out + fade
                    if b > a + 0.001 {
                        p.setVolumeRamp(fromStartVolume: prev, toEndVolume: v, timeRange: range(a, b))
                        lastEnd = b
                    } else {
                        // changes closer together than a fade: a step, never inside the previous ramp
                        let at = max(sg.out, lastEnd + 0.001)
                        p.setVolume(v, at: t(at))
                        lastEnd = at + 0.001
                    }
                    prev = v
                }
            }
            params.append(p)
        }
        m.inputParameters = params
        return m
    }
}
