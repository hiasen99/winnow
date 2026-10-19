import Foundation
import AVFoundation
import AppKit
import QuartzCore

// MARK: - A still frame, exactly as the export draws it

extension Exporter {
    /// One frame of a clip (or the full recording) as an image. With captions it goes through the same
    /// Core Animation path as the export (a fraction of a second rendered to a temp file), so what you see is what you'll get.
    static func frame(project p: Project, clip: Clip?, auto: [AngleSegment], loaded: [LoadedAngle?],
                      at t: Double, captions: Bool, maxSide: CGFloat) async throws -> CGImage {
        let built = try CompositionBuilder.build(project: p, clip: clip, auto: auto, loaded: loaded, format: clip?.format)
        let tt = max(0, min(t, built.duration - 0.05))
        let size = CGSize(width: maxSide, height: maxSide)
        if let clip, captions {
            let vc = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
            let track = Captions.track(for: clip, project: p, renderSize: built.renderSize)
            let layer = Captions.makeLayer(track, style: p.captionStyle, renderSize: built.renderSize, total: built.duration)
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: built.renderSize)
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            parent.addSublayer(Captions.container(layer, size: built.renderSize))
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("clips2-frame-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            guard let s = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ClipsError("Couldn't render the frame.")
            }
            s.videoComposition = vc
            s.timeRange = CompositionBuilder.range(tt, min(built.duration, tt + 0.2))
            try await s.export(to: url, as: .mov)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            gen.maximumSize = size
            return try await gen.image(at: .zero).image
        }
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = size
        return try await gen.image(at: CompositionBuilder.t(tt)).image
    }
}

extension Control {

    // MARK: render_frame

    /// {clip?: number/id/title or "full", seconds?: into the clip (default the playhead if it's showing, else 0),
    ///  recording?: true = seconds are recording time, captions?: default true, max_side?: default 960}
    static func renderFrame(_ app: AppState, _ a: Args) async throws -> [String: Any] {
        let m = try model(app)
        let p = m.project
        var clip: Clip? = nil
        let full = (a.str("clip")?.lowercased()).map { $0 == "full" || $0 == "full recording" } ?? false
        if a.has("clip") && !full { clip = try findClip(m, a.d["clip"]) }
        else if !a.has("clip") { clip = m.selectedClip }
        let showing = clip?.id == m.selectedClipID
        var t: Double
        if let s = a.num("seconds") {
            if a.bool("recording") == true, let c = clip { t = c.outputTimeClamped(forMaster: s) } else { t = s }
        } else { t = showing ? m.engine.time : 0 }
        let length = clip?.outputDuration ?? p.masterDuration
        t = max(0, min(t, max(0, length - 0.05)))
        let caps = a.bool("captions") ?? true
        let side = CGFloat(min(2048, max(256, a.num("max_side") ?? 960)))
        if a.bool("thumbnail") == true {
            guard let c = clip else { throw ControlError("Thumbnails belong to clips: pass {\"clip\": …, \"thumbnail\": true}.") }
            let full = try await m.thumbnailImage(c)
            let k = min(1, side / CGFloat(max(full.width, full.height)))
            let img = k < 1 ? (Stills.scaled(full, width: Int((CGFloat(full.width) * k).rounded())) ?? full) : full
            let rep = NSBitmapImageRep(cgImage: img)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw ControlError("Couldn't encode the thumbnail.") }
            var info = thumbInfo(m, c)
            info["clip"] = clipRef(m, c.id); info["imageSize"] = "\(img.width)×\(img.height)"; info["fullSize"] = "\(full.width)×\(full.height)"
            let text = (try? JSONSerialization.data(withJSONObject: tidy(info), options: [.sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ["ok": true, "text": text, "image": data.base64EncodedString(), "mime": "image/jpeg"]
        }
        let img = try await Exporter.frame(project: p, clip: clip, auto: m.auto, loaded: m.sources, at: t, captions: caps, maxSide: side)
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw ControlError("Couldn't encode the frame.")
        }
        var info: [String: Any] = ["seconds": r3(t), "imageSize": "\(img.width)×\(img.height)"]
        if let c = clip {
            info["clip"] = clipRef(m, c.id)
            info["format"] = c.format.label
            info["recordingTime"] = r3(c.masterTime(forOutput: t))
            info["burnInCaptions"] = c.captions
            let items = captionList(m, c)
            if let k = items.firstIndex(where: { t >= $0.start && t < $0.end }) { info["captionOnScreen"] = captionDict(items, k) }
            else { info["captionOnScreen"] = NSNull() }
        } else {
            info["view"] = "full recording (automatic camera, no captions)"
        }
        let tdy = tidy(info)
        let text = (try? JSONSerialization.data(withJSONObject: tdy, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ["ok": true, "text": text, "image": data.base64EncodedString(), "mime": "image/jpeg"]
    }

    // MARK: Exports (run in the background, one after another)

    static var exportTask: Task<Void, Never>? = nil
    static var exportQueued = 0
    static var exportLog: [[String: Any]] = []

    static func clipsFor(_ m: ProjectModel, _ a: Args) throws -> [Clip] {
        if let v = a.d["clips"] {
            if let s = v as? String {
                switch s.lowercased() {
                case "used", "use": return m.project.clips.filter { $0.status == .used }
                case "all": return m.project.clips
                case "unmarked", "to review": return m.project.clips.filter { $0.status == nil }
                default: return [try findClip(m, s)]
                }
            }
            if let arr = v as? [Any] { return try arr.map { try findClip(m, $0) } }
        }
        return [try targetClip(m, a)]
    }

    static func exportURL(_ m: ProjectModel, _ c: Clip, _ a: Args, ext: String, many: Bool) throws -> URL {
        var folder = m.exportFolder
        if let p = a.str("path")?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if !u.pathExtension.isEmpty {
                guard !many else { throw ControlError("With several clips, \"path\" has to be a folder.") }
                return u.deletingPathExtension().appendingPathExtension(ext)
            }
            folder = u
        }
        let base = Exporter.safeName(c.title)
        var url = folder.appendingPathComponent(base + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return url
    }

    static func queueExports(_ m: ProjectModel, _ jobs: [(id: UUID, title: String, url: URL, kind: ExportKind, srt: Bool)], wait: Double) async -> [String: Any] {
        let prev = exportTask
        exportQueued += jobs.count
        exportTask = Task { @MainActor in
            await prev?.value
            for j in jobs {
                m.errorText = nil
                let t0 = Date()
                await m.export(j.id, to: j.url, kind: j.kind, alsoSRT: j.srt)
                let ok = m.errorText == nil && FileManager.default.fileExists(atPath: j.url.path)
                var e: [String: Any] = ["clip": j.title, "file": j.url.path, "ok": ok, "seconds": r3(Date().timeIntervalSince(t0))]
                if !ok { e["error"] = m.errorText ?? "The file wasn't written." }
                exportLog.append(e)
                if exportLog.count > 50 { exportLog.removeFirst(exportLog.count - 50) }
                exportQueued -= 1
            }
        }
        let names = jobs.map { ["clip": $0.title, "file": $0.url.path] }
        if wait > 0, let task = exportTask {
            let deadline = Date().addingTimeInterval(min(wait, 150))
            while exportQueued > 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
            if exportQueued == 0 { _ = task; return ["finished": Array(exportLog.suffix(jobs.count))] }
        }
        return ["started": names, "note": "Exporting in the background; export.status shows progress and results."]
    }

    static func exportStatus(_ m: ProjectModel?) -> [String: Any] {
        var out: [String: Any] = ["waiting": exportQueued, "finished": Array(exportLog.suffix(20))]
        if let m {
            out["inProgress"] = m.exporting.map { id, f -> [String: Any] in
                ["clip": m.project.clips.first { $0.id == id }?.title ?? id.uuidString, "progress": r3(f)]
            }
        }
        return out
    }

    static let renderCommands: [ControlCommand] = [
        ControlCommand(id: "export.video", label: "Export Video", menu: "Toolbar ▸ Export / Clip ▸ Export Clip…", key: "⌘E",
                       params: "{clip? | clips?: [numbers/ids/titles] | \"use\" (every clip marked Use) | \"all\"; path?: folder (or a .mp4 file for one clip; default the project's export folder, never overwrites); burnIn?: true/false (default: the clip's setting); srt?: also save captions as .srt (default true); wait?: seconds to wait for it to finish (max 150, default 0 = return at once)}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let clips = try clipsFor(m, a)
            guard !clips.isEmpty else { throw ControlError("No clips match.") }
            if let b = a.bool("burnIn") {
                for c in clips where c.captions != b { change(m, c.id, rebuild: false) { $0.captions = b } }
            }
            let srt = a.bool("srt") ?? true
            let jobs = try clips.map { c in (id: c.id, title: c.title, url: try exportURL(m, c, a, ext: "mp4", many: clips.count > 1), kind: ExportKind.video, srt: srt) }
            return await queueExports(m, jobs, wait: a.num("wait") ?? 0)
        }),
        ControlCommand(id: "export.audio", label: "Export Audio Only", menu: "Export window ▸ Audio only",
                       params: "{clip? | clips?, format?: \"m4a\" (default) | \"wav\", path?, wait?}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let clips = try clipsFor(m, a)
            guard !clips.isEmpty else { throw ControlError("No clips match.") }
            let wav = (a.str("format") ?? "m4a").lowercased() == "wav"
            let jobs = try clips.map { c in (id: c.id, title: c.title, url: try exportURL(m, c, a, ext: wav ? "wav" : "m4a", many: clips.count > 1),
                                             kind: wav ? ExportKind.audioWAV : ExportKind.audioM4A, srt: false) }
            return await queueExports(m, jobs, wait: a.num("wait") ?? 0)
        }),
        ControlCommand(id: "export.srt", label: "Export Captions (.srt)", menu: "Export window ▸ Captions only",
                       params: "{clip? | clips?, path?}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let clips = try clipsFor(m, a)
            guard !clips.isEmpty else { throw ControlError("No clips match.") }
            let jobs = try clips.map { c in (id: c.id, title: c.title, url: try exportURL(m, c, a, ext: "srt", many: clips.count > 1), kind: ExportKind.captions, srt: false) }
            return await queueExports(m, jobs, wait: 30)
        }),
        ControlCommand(id: "export.status", label: "Export Progress", menu: "Toolbar ▸ Export (progress ring)",
                       enabled: { _ in true },
                       run: { app, _ in exportStatus(app.claude) }),
        ControlCommand(id: "export.reveal", label: "Show Last Export in Finder", menu: "Notice ▸ Show in Finder",
                       enabled: { $0.claude != nil },
                       run: { app, _ in
            let m = try model(app)
            m.revealLastExport()
            return m.lastExport.map { "Showing \($0.path) in Finder." } ?? "Opened the exports folder."
        }),
    ]
}
