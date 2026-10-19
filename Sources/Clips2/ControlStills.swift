import Foundation
import AppKit

/// Frames as pictures, grabbed frames, and clip thumbnails, for Claude.
extension Control {

    /// {clip?: number/id/title or "full" (default: what's showing)} → the clip (nil = full recording)
    static func stillTarget(_ m: ProjectModel, _ a: Args) throws -> Clip? {
        if let s = a.str("clip")?.lowercased(), s == "full" || s == "full recording" { return nil }
        if a.has("clip") { return try findClip(m, a.d["clip"]) }
        return m.selectedClip
    }

    /// {seconds?: into the clip (or the recording on "full"), recording?: true = recording seconds} → time in the view
    static func stillTime(_ m: ProjectModel, _ c: Clip?, _ a: Args) -> Double {
        let showing = c?.id == m.selectedClipID
        var t: Double
        if let s = a.num("seconds") {
            if a.bool("recording") == true, let c { t = c.outputTimeClamped(forMaster: s) } else { t = s }
        } else { t = showing ? m.engine.time : 0 }
        let len = c?.outputDuration ?? m.project.masterDuration
        return max(0, min(t, max(0, len - 0.02)))
    }

    static func grabList(_ m: ProjectModel, _ c: Clip?) -> [[String: Any]] {
        m.grabs(in: c).map { ["out": r3($0.out), "recording": r3($0.master)] }
    }

    static func thumbInfo(_ m: ProjectModel, _ c: Clip) -> [String: Any] {
        var d: [String: Any] = ["frame": r3(m.thumbnailOutTime(c)), "framePicked": c.thumbnail?.time != nil,
                                "title": m.thumbnailTitle(c), "ownTitle": c.thumbnail?.title != nil]
        if let t = c.thumbnail?.time { d["recordingTime"] = r3(t) }
        d["from"] = (c.thumbnail?.source ?? .clip).rawValue
        if c.thumbnail?.fromRecording == true {
            d["camera"] = c.thumbnail?.angle.map { angleName($0, m.project) } ?? "auto"
            if let t = c.thumbnail?.time { d["insideClip"] = t >= c.start && t <= c.end }
        }
        if let p = c.thumbnail?.imagePath { d["image"] = p }
        d["lookFollowsCaptions"] = m.thumbnailStyleIsCaptions
        return d
    }

    static func thumbStyleSummary(_ s: ThumbnailStyle) -> [String: Any] {
        var d: [String: Any] = [
            "showTitle": s.showTitle, "font": s.fontName, "size": r3(s.textSize), "textColor": hex(s.textColor),
            "uppercase": s.uppercase, "align": s.alignLeft ? "left" : "center", "height": r3(s.titleY), "width": r3(s.textWidth),
            "outline": r3(s.outline), "outlineColor": hex(s.outlineColor), "shadow": s.shadow,
            "shade": r3(s.shade), "shadeColor": hex(s.shadeColor),
            "logo": s.logoPath ?? "none", "logoSize": r3(s.logoSize), "logoCorner": ["topLeft", "topRight", "bottomLeft", "bottomRight"][max(0, min(3, s.logoCorner))],
            "brightness": r3(s.brightness), "contrast": r3(s.contrast), "saturation": r3(s.saturation),
            "withExport": s.withExport, "format": s.png ? "png" : "jpeg",
        ]
        if let fam = FontCatalog.family(of: s.fontName) { d["fontFamily"] = fam; if let m = FontCatalog.member(s.fontName) { d["fontStyle"] = m.style } }
        if let w = s.fontWeight { d["weight"] = r3(w) }
        return d
    }

    static let thumbStyleHelp = "{showTitle?, font? (family or PostScript name), weight? (style name, thin…black, 100–900, \"reset\"), size? (fraction of the picture's shorter side, 0.1 = default), textColor?, uppercase?, align? \"center\" | \"left\", height? (centre of the title: 0 top – 1 bottom, 0.8 = default), width? (0.4–0.96 of the picture), outline? (fraction of font size, 0 = none, 0.1 = thick), outlineColor?, shadow?, shade? (dark fade behind the title, 0–0.95), shadeColor?, logo? (full path to an image, or \"none\"), logoSize? (fraction of width), logoCorner? topLeft|topRight|bottomLeft|bottomRight, brightness? (-0.3–0.3), contrast? (0.6–1.6), saturation? (0–2), withExport? (save a thumbnail beside every exported video), format? \"jpeg\" | \"png\", preset? (a built-in or saved preset name), matchCaptions?: true (title look back to the caption style), reset?: true}. Until changed, the look follows the caption style. Colours are hex. Applies to every clip in the project."

    static func applyThumbStyle(_ s0: ThumbnailStyle, _ a: Args) throws -> ThumbnailStyle {
        var s = s0
        if a.bool("reset") == true { s = ThumbnailStyle(); s.logoPath = s0.logoPath }
        if a.bool("matchCaptions") == true, let cs = a.d["_captionStyle"] as? CaptionStyle { s = ThumbnailStyle.matching(cs, keeping: s) }
        if let p = a.str("preset") {
            let all = Store.loadThumbPresets().presets + ThumbnailStyle.builtIns
            guard let hit = all.first(where: { $0.name.lowercased() == p.lowercased() }) ?? all.first(where: { $0.name.lowercased().contains(p.lowercased()) }) else {
                throw ControlError("No thumbnail preset \"\(p)\". There are: " + all.map { $0.name }.joined(separator: ", "))
            }
            let logo = s.logoPath, size = s.logoSize, with = s.withExport
            s = hit.style
            if s.logoPath == nil { s.logoPath = logo; s.logoSize = size }
            s.withExport = with
        }
        if a.has("font") || a.has("weight") {
            var cs = CaptionStyle(); cs.fontName = s.fontName; cs.fontWeight = s.fontWeight
            var fa: [String: Any] = [:]
            if let f = a.d["font"] { fa["font"] = f }
            if let w = a.d["weight"] { fa["weight"] = w }
            cs = try applyStyle(cs, Args(fa))
            s.fontName = cs.fontName; s.fontWeight = cs.fontWeight
        }
        if let v = a.bool("showTitle") { s.showTitle = v }
        if let v = a.num("size") { s.textSize = min(0.25, max(0.03, v > 1 ? v / 100 : v)) }
        if let c = try color(a.d["textColor"]) { s.textColor = c }
        if let v = a.bool("uppercase") { s.uppercase = v }
        if let v = a.str("align") { s.alignLeft = v.lowercased().hasPrefix("l") }
        if let v = a.num("height") { s.titleY = min(0.95, max(0.05, v)) }
        if let v = a.num("width") { s.textWidth = min(0.96, max(0.4, v)) }
        if let v = a.num("outline") { s.outline = min(0.3, max(0, v)) }
        if let c = try color(a.d["outlineColor"]) { s.outlineColor = c }
        if let v = a.bool("shadow") { s.shadow = v }
        if let v = a.num("shade") { s.shade = min(0.95, max(0, v)) }
        if let c = try color(a.d["shadeColor"]) { s.shadeColor = c }
        if let l = a.str("logo") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if ["none", "", "remove", "off"].contains(t.lowercased()) { s.logoPath = nil }
            else {
                let path = (t as NSString).expandingTildeInPath
                guard NSImage(contentsOfFile: path) != nil else { throw ControlError("Couldn't read a picture at \(path).") }
                s.logoPath = path
            }
        }
        if let v = a.num("logoSize") { s.logoSize = min(0.5, max(0.04, v)) }
        if let v = a.str("logoCorner") {
            let k = v.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            guard let i = ["topleft", "topright", "bottomleft", "bottomright"].firstIndex(of: k) else {
                throw ControlError("logoCorner is topLeft, topRight, bottomLeft or bottomRight.")
            }
            s.logoCorner = i
        }
        if let v = a.num("brightness") { s.brightness = min(0.3, max(-0.3, v)) }
        if let v = a.num("contrast") { s.contrast = min(1.6, max(0.6, v)) }
        if let v = a.num("saturation") { s.saturation = min(2, max(0, v)) }
        if let v = a.bool("withExport") { s.withExport = v }
        if let f = a.str("format") { s.png = f.lowercased() == "png" }
        return s
    }

    /// A file for a picture: `path` can be a file (with extension) or a folder; default the project's export folder.
    static func stillURL(_ m: ProjectModel, _ a: Args, base: String, ext: String, subfolder: String? = nil) -> URL {
        var folder = m.exportFolder
        if let sub = subfolder { folder = folder.appendingPathComponent(sub, isDirectory: true) }
        if let p = a.str("path")?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if !u.pathExtension.isEmpty { return u.deletingPathExtension().appendingPathExtension(ext) }
            folder = u
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Stills.freeURL(folder, base, ext)
    }

    static let stillCommands: [ControlCommand] = [
        ControlCommand(id: "frame.save", label: "Save Frame as a Picture", menu: "Clip ▸ Save Frame… / timeline toolbar", key: "⇧⌘S",
                       params: "{clip? (number/id/title, or \"full\" for the full recording; default what's showing), seconds? (into the clip; default the playhead if it's showing, else 0), recording?: true = seconds are recording time, captions?: draw the captions (default false), format?: \"png\" (default) | \"jpeg\" | \"small\" (JPEG 1280 wide), path?: file or folder (default the project's export folder; never overwrites)}. In a clip it's the frame as the clip exports (shape, framing, camera) at full size; on the full recording it's the camera's own full-size frame.",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try stillTarget(m, a)
            let t = stillTime(m, c, a)
            let f = StillFormat.parse(a.str("format")) ?? .png
            let url = stillURL(m, a, base: Exporter.safeName(c?.title ?? m.project.name) + " " + Stills.stamp(t), ext: f.ext)
            guard await m.saveFrame(clip: c, at: t, to: url, format: f, captions: a.bool("captions") ?? false) else {
                throw ControlError(m.errorText ?? "Couldn't save the frame.")
            }
            return ["file": url.path, "seconds": r3(t)]
        }),
        ControlCommand(id: "frame.grab", label: "Grab Frame (mark to save)", menu: "G / timeline toolbar camera", key: "G", changesProject: true,
                       params: "{clip? (or \"full\"), seconds? | recording?, remove?: true = un-grab that frame, clear?: true = un-grab all}. Grabbed frames show as gold cameras on the ruler; frame.saveGrabs saves them.",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try stillTarget(m, a)
            if a.bool("clear") == true {
                if let c { change(m, c.id, rebuild: false) { $0.grabs = nil } } else { m.edit(rebuild: false) { $0.grabs = nil } }
                return ["grabs": [] as [Any]]
            }
            let out = stillTime(m, c, a)
            let master = c.map { $0.masterTime(forOutput: out) } ?? out
            let remove = a.bool("remove") == true
            func apply(_ list: [Double]?) -> [Double]? {
                var g = (list ?? []).filter { abs($0 - master) >= ProjectModel.grabTolerance }
                if !remove { g.append(master); g.sort() }
                return g.isEmpty ? nil : g
            }
            if let c { change(m, c.id, rebuild: false) { $0.grabs = apply($0.grabs) } }
            else { m.edit(rebuild: false) { $0.grabs = apply($0.grabs) } }
            let now = c.flatMap { cc in m.project.clips.first { $0.id == cc.id } }
            return ["grabs": grabList(m, now)]
        }),
        ControlCommand(id: "frame.saveGrabs", label: "Save Grabbed Frames", menu: "Clip settings ▸ Save N Grabbed Frames…",
                       params: "{clip? (or \"full\"), format?: \"png\" | \"jpeg\" | \"small\", captions?: false, path?: folder (default: \"Frame Grabs\" in the project's export folder)}",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try stillTarget(m, a)
            let outs = m.grabs(in: c).map { $0.out }
            guard !outs.isEmpty else { throw ControlError("No grabbed frames on \(c.map { "\"\($0.title)\"" } ?? "the full recording"). frame.grab adds some.") }
            var dir = m.exportFolder.appendingPathComponent("Frame Grabs", isDirectory: true)
            if let p = a.str("path")?.trimmingCharacters(in: .whitespaces), !p.isEmpty { dir = URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
            let f = StillFormat.parse(a.str("format")) ?? .png
            let files = await m.saveGrabs(clip: c, outs: outs, to: dir, format: f, captions: a.bool("captions") ?? false)
            if files.count < outs.count { throw ControlError(m.errorText ?? "Only \(files.count) of \(outs.count) frames were saved.") }
            return ["files": files.map { $0.path }]
        }),
        ControlCommand(id: "thumbnail.set", label: "Set a Clip's Thumbnail", menu: "T / clip settings ▸ Thumbnail", key: "T", changesProject: true,
                       params: "{clip?; the picture, one of: seconds? (a frame inside the clip, seconds into it), recordingTime? (seconds anywhere in the full recording, also outside the clip) with camera? (\"A\", \"B\"… or \"auto\" = whoever is talking), image? (full path to a picture file, or \"none\"); title?: its own text (\"\" = the clip's title; \\n for a new line); resetFrame?: true = back to one second in}. Check it with render_frame {thumbnail: true}.",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            if a.bool("resetFrame") == true { m.changeThumbnail(c.id) { $0.time = nil; $0.fromRecording = nil; $0.angle = nil; $0.imagePath = nil } }
            else if a.has("seconds") { m.setThumbnailClipTime(c.id, out: stillTime(m, c, a)) }
            if let r = a.num("recordingTime") {
                guard r >= 0, r <= m.project.masterDuration else { throw ControlError("recordingTime runs 0–\(r3(m.project.masterDuration)) s.") }
                m.setThumbnailRecordingTime(c.id, master: r)
            }
            if let cam = a.str("camera") {
                let k = cam.lowercased().trimmingCharacters(in: .whitespaces)
                if k == "auto" || k == "automatic" { m.setThumbnailAngle(c.id, nil) }
                else {
                    guard let i = m.project.videoIndices.first(where: { m.project.angles[$0].shortName.lowercased() == k }) else {
                        throw ControlError("No camera \"\(cam)\". Cameras: " + m.project.videoIndices.map { m.project.angles[$0].shortName }.joined(separator: ", ") + ", or auto.")
                    }
                    m.setThumbnailAngle(c.id, i)
                }
                if m.project.clips.first(where: { $0.id == c.id })?.thumbnail?.fromRecording != true {
                    m.setThumbnailRecordingTime(c.id, master: m.thumbnailMasterTime(m.project.clips.first { $0.id == c.id } ?? c))
                }
            }
            if let img = a.str("image") {
                let t = img.trimmingCharacters(in: .whitespaces)
                if ["none", "", "off", "remove"].contains(t.lowercased()) { m.setThumbnailImage(c.id, nil) }
                else {
                    let path = (t as NSString).expandingTildeInPath
                    guard NSImage(contentsOfFile: path) != nil else { throw ControlError("Couldn't read a picture at \(path).") }
                    m.setThumbnailImage(c.id, path)
                }
            }
            if a.has("title") {
                let i = m.project.clips.firstIndex { $0.id == c.id }!
                let v = a.str("title").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                m.edit(rebuild: false) { p in
                    var t = p.clips[i].thumbnail ?? ClipThumbnail(); t.title = v
                    p.clips[i].thumbnail = t.isEmpty ? nil : t
                }
            }
            let now = m.project.clips.first { $0.id == c.id } ?? c
            return thumbInfo(m, now)
        }),
        ControlCommand(id: "thumbnail.style", label: "Thumbnail Look", menu: "Clip settings ▸ Thumbnail ▸ Edit…", changesProject: true,
                       params: thumbStyleHelp,
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            var ad = a.d; ad["_captionStyle"] = m.project.captionStyle
            let s = try applyThumbStyle(m.thumbnailStyle, Args(ad))
            m.edit(rebuild: false) { $0.thumbnailStyle = s }
            var d = thumbStyleSummary(s)
            d["presets"] = (Store.loadThumbPresets().presets + ThumbnailStyle.builtIns).map { $0.name }
            return d
        }),
        ControlCommand(id: "thumbnail.save", label: "Save Thumbnail", menu: "Thumbnail ▸ Save Thumbnail…",
                       params: "{clip? | clips?: [numbers/ids/titles] | \"use\" | \"all\", path?: file (one clip) or folder (default the project's export folder; never overwrites)}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let clips = try clipsFor(m, a)
            let ext = m.thumbnailStyle.ext
            var files: [String] = []
            for c in clips {
                var aa = a.d
                if clips.count > 1, let p = a.str("path"), !URL(fileURLWithPath: p).pathExtension.isEmpty { aa["path"] = URL(fileURLWithPath: p).deletingLastPathComponent().path }
                let url = stillURL(m, Args(aa), base: Exporter.safeName(c.title) + " thumbnail", ext: ext)
                guard await m.saveThumbnail(c, to: url, quiet: true) else { throw ControlError("Couldn't save the thumbnail of \"\(c.title)\" (the log has details).") }
                files.append(url.path)
            }
            return ["files": files]
        }),
    ]
}
