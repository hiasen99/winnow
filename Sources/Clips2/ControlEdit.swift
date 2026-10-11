import Foundation

/// Editing commands for Claude: clips, trims, camera, sound, framing, speakers.
/// Each is one Undo step. Times are seconds in the full recording unless a parameter says otherwise.
/// They work on any clip (the "clip" parameter, default: the one showing) without changing what's on screen.
extension Control {

    // MARK: Helpers

    static func targetClip(_ m: ProjectModel, _ a: Args) throws -> Clip {
        if a.has("clip") { return try findClip(m, a.d["clip"]) }
        guard let c = m.selectedClip else { throw ControlError("Say which clip: {\"clip\": number, id or title} (no clip is showing).") }
        return c
    }

    /// One Undo step that changes one clip.
    static func change(_ m: ProjectModel, _ id: UUID, rebuild: Bool = true, _ f: (inout Clip) -> Void) {
        guard let i = m.project.clips.firstIndex(where: { $0.id == id }) else { return }
        m.edit(rebuild: rebuild && m.selectedClipID == id) { p in
            f(&p.clips[i])
            p.clips[i].normalizeRanges()
        }
    }

    static func clipRef(_ m: ProjectModel, _ id: UUID) -> [String: Any] {
        guard let i = m.project.clips.firstIndex(where: { $0.id == id }) else { return ["id": id.uuidString] }
        let c = m.project.clips[i]
        return ["number": i + 1, "id": c.id.uuidString, "title": c.title, "start": r3(c.start), "end": r3(c.end),
                "length": r3(c.outputDuration), "blocks": c.segments.count]
    }

    /// Start of the nearest word (within 1 s), with the same small lead-in the app uses.
    static func snapStart(_ t: Double, _ ws: [Word]) -> Double {
        guard let i = ws.indices.filter({ abs(ws[$0].start - t) <= 1.0 }).min(by: { abs(ws[$0].start - t) < abs(ws[$1].start - t) }) else { return t }
        let prevEnd = i > 0 ? ws[i - 1].end : 0
        return max(prevEnd, ws[i].start - 0.12)
    }
    /// End of the nearest word (within 1 s), plus a short tail.
    static func snapEnd(_ t: Double, _ ws: [Word]) -> Double {
        guard let i = ws.indices.filter({ abs(ws[$0].end - t) <= 1.0 }).min(by: { abs(ws[$0].end - t) < abs(ws[$1].end - t) }) else { return t }
        let nextStart = i + 1 < ws.count ? ws[i + 1].start : ws[i].end + 1
        return min(nextStart, ws[i].end + 0.25)
    }

    static func titleFor(_ p: Project, _ s: Double, _ e: Double) -> String {
        let t = p.words.filter { !$0.isHidden && $0.start >= s - 0.05 && $0.end <= e + 0.05 }.prefix(8).map { $0.text }.joined(separator: " ")
        let tt = t.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–— "))
        return tt.isEmpty ? "Clip at \(fmtTime(s))" : tt
    }

    static func parseFormat(_ s: String) throws -> ClipFormat {
        switch s.lowercased().replacingOccurrences(of: " ", with: "") {
        case "9:16", "vertical", "portrait", "reel", "reels", "short", "shorts", "tiktok": return .vertical
        case "1:1", "square": return .square
        case "16:9", "horizontal", "landscape", "wide", "youtube": return .horizontal
        default: throw ControlError("Format is \"9:16\", \"1:1\" or \"16:9\".")
        }
    }

    private static func key(_ s: String) -> String {
        var k = s.lowercased().replacingOccurrences(of: " ", with: "")
        for pre in ["camera", "angle", "cam"] where k.hasPrefix(pre) && k.count > pre.count { k = String(k.dropFirst(pre.count)); break }
        return k
    }
    /// A source by its name: "A", "Angle B", "camera c", "Mic 1", "mic2".
    static func sourceIndex(_ p: Project, _ s: String) -> Int? {
        let k = key(s)
        return p.angles.indices.first { key(p.angles[$0].shortName) == k || key(p.angles[$0].name) == k }
    }
    static func sourceNames(_ p: Project, video: Bool? = nil) -> String {
        p.angles.filter { video == nil || $0.isVideo == video! }.map { $0.shortName }.joined(separator: ", ")
    }

    /// nil = automatic (follow the speaker). Also accepts a speaker's name: that speaker's camera.
    static func cameraIndex(_ p: Project, _ v: Any?) throws -> Int? {
        guard let s = (v as? String) ?? (v as? NSNumber)?.stringValue, !s.isEmpty else {
            throw ControlError("Pass {\"camera\": \(sourceNames(p, video: true).split(separator: ",").map { "\"\($0.trimmingCharacters(in: .whitespaces))\"" }.joined(separator: ", ")) or \"auto\"}.")
        }
        if ["auto", "automatic", "speaker", "follow"].contains(s.lowercased()) { return nil }
        if let i = sourceIndex(p, s), p.angles[i].isVideo { return i }
        if let sp = p.speakers.first(where: { $0.name.lowercased() == s.lowercased() }) { return sp.angle }
        throw ControlError("No camera called \"\(s)\". Cameras: \(sourceNames(p, video: true)), or \"auto\".")
    }

    static func soundList(_ p: Project, _ v: Any?) throws -> [Bool] {
        let n = p.angles.count
        var names: [String] = []
        if let arr = v as? [Any] {
            names = arr.map { "\($0)" }
        } else if let s = v as? String {
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "default", "auto", "normal": return p.defaultMix.on
            case "silent", "none", "mute", "nothing": return Array(repeating: false, count: n)
            case "all", "everything": return p.angles.map { $0.hasAudio }
            default: names = s.split(whereSeparator: { $0 == "," || $0 == "+" || $0 == "&" }).map { String($0) }
            }
        } else {
            throw ControlError("Pass {\"hear\": [\"Mic 1\", \"Mic 2\"]} or \"default\" / \"silent\" / \"all\". Sources: \(sourceNames(p)).")
        }
        var on = Array(repeating: false, count: n)
        for nm in names {
            guard let i = sourceIndex(p, nm.trimmingCharacters(in: .whitespaces)) else {
                throw ControlError("No source called \"\(nm)\". Sources: \(sourceNames(p)).")
            }
            guard p.angles[i].hasAudio else { throw ControlError("\(p.angles[i].shortName) has no sound.") }
            on[i] = true
        }
        return on
    }

    static func angleAt(_ c: Clip, _ t: Double) -> Int? {
        if let s = c.switches.sorted(by: { $0.time < $1.time }).last(where: { $0.time <= t + 1e-6 }) { return s.angle }
        return nil
    }

    static func speakerIndex(_ p: Project, _ v: Any?) throws -> Int {
        if let n = v as? NSNumber {
            let i = n.intValue - 1
            guard p.speakers.indices.contains(i) else { throw ControlError("Speakers are numbered 1–\(p.speakers.count).") }
            return i
        }
        if let s = v as? String {
            if let n = Int(s), p.speakers.indices.contains(n - 1) { return n - 1 }
            if let i = p.speakers.firstIndex(where: { $0.name.lowercased() == s.lowercased() }) { return i }
        }
        throw ControlError("Say which speaker: number (1 = first) or current name. Speakers: " + p.speakers.map { $0.name }.joined(separator: ", ") + ".")
    }

    static func newClip(_ m: ProjectModel, _ a: Args) throws -> Clip {
        let p = m.project
        guard let s0 = a.num("start"), let e0 = a.num("end"), e0 > s0 else {
            throw ControlError("Each clip needs start and end in seconds of the recording, start before end.")
        }
        var s = s0, e = e0
        if a.bool("snap") ?? true { s = snapStart(s0, p.words); e = snapEnd(e0, p.words) }
        s = max(0, s); e = min(p.masterDuration, e)
        guard e > s + 0.5 else { throw ControlError("That clip would be shorter than half a second.") }
        let title = a.str("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = p.newClip(title: (title?.isEmpty == false ? title! : titleFor(p, s, e)), start: s, end: e)
        if let n = a.str("note") ?? a.str("why") { c.note = n }
        if let sc = a.num("score") { c.score = sc }
        if let f = a.str("format") { c.format = try parseFormat(f) }
        return c
    }

    // MARK: Commands

    static let editCommands: [ControlCommand] = [

        // Clips

        ControlCommand(id: "clip.create", label: "New Clip", menu: "Clip ▸ Make Clip from Selection", key: "⌘K / C", changesProject: true,
                       params: "{start, end: seconds in the recording (snapped to the nearest word start/end unless snap:false); title?; note?; score? (1–10); format? \"9:16\"|\"1:1\"|\"16:9\" (default 9:16); show?: true to open it}",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try newClip(m, a)
            m.edit(rebuild: false) { $0.clips.append(c) }
            if a.bool("show") == true { m.select(clip: c.id) }
            return clipRef(m, c.id)
        }),
        ControlCommand(id: "clip.createMany", label: "Add Clips (clip finder)", menu: "Toolbar ✦ Find Clips", changesProject: true,
                       params: "{clips: [{start, end, title, note?, score?, format?}, …]; snap?: false to keep exact times}. One Undo step for all. To find clips: read transcript_read, pick complete standalone moments, then add them here.",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            guard let list = a.d["clips"] as? [[String: Any]], !list.isEmpty else { throw ControlError("Pass {\"clips\": [{\"start\":…, \"end\":…, \"title\":…}, …]}.") }
            var made: [Clip] = []
            var problems: [String] = []
            for (k, item) in list.enumerated() {
                var d = item
                if d["snap"] == nil, let sn = a.d["snap"] { d["snap"] = sn }
                do { made.append(try newClip(m, Args(d))) } catch { problems.append("#\(k + 1): \(error)") }
            }
            guard !made.isEmpty else { throw ControlError("No clips added. " + problems.joined(separator: " ")) }
            m.edit(rebuild: false) { $0.clips.append(contentsOf: made) }
            var out: [String: Any] = ["added": made.map { clipRef(m, $0.id) }]
            if !problems.isEmpty { out["skipped"] = problems }
            return out
        }),
        ControlCommand(id: "clip.rename", label: "Rename Clip", menu: "Clip list ▸ right-click ▸ Rename…", changesProject: true,
                       params: "{clip?, title}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            guard let t = a.str("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { throw ControlError("Pass {\"title\": \"…\"}.") }
            m.renameClip(c.id, to: t)
            return clipRef(m, c.id)
        }),
        ControlCommand(id: "clip.mark", label: "Mark Clip Used / Rejected", menu: "Clip ▸ Mark as Used / Rejected", key: "U / X", changesProject: true,
                       params: "{clip?, mark: \"used\" | \"rejected\" | \"none\"}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let s: ClipStatus?
            switch (a.str("mark") ?? "").lowercased() {
            case "used", "use", "keep", "favorite", "favourite": s = .used
            case "rejected", "reject", "no": s = .rejected
            case "none", "clear", "unmarked", "": s = nil
            default: throw ControlError("mark is \"used\", \"rejected\" or \"none\".")
            }
            m.setStatus(s, for: c.id)
            return "Clip \"\(c.title)\" is now \(s?.rawValue ?? "unmarked")."
        }),
        ControlCommand(id: "clip.note", label: "Clip Note / Score", menu: "Clip inspector", changesProject: true,
                       params: "{clip?, note?, score?: 1–10 (or null to clear)}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            change(m, c.id, rebuild: false) { clip in
                if let n = a.str("note") { clip.note = n }
                if a.d["score"] is NSNull { clip.score = nil } else if let sc = a.num("score") { clip.score = sc }
            }
            return clipRef(m, c.id)
        }),
        ControlCommand(id: "clip.delete", label: "Delete Clip", menu: "Clip list ▸ right-click ▸ Delete", changesProject: true,
                       params: "{clip}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            guard a.has("clip") else { throw ControlError("Say which clip to delete: {\"clip\": number, id or title}.") }
            let c = try findClip(m, a.d["clip"])
            m.deleteClip(c.id)
            return "Deleted \"\(c.title)\". edit.undo brings it back."
        }),
        ControlCommand(id: "clip.duplicate", label: "Duplicate Clip", menu: "Clip list ▸ right-click ▸ Duplicate", changesProject: true,
                       params: "{clip?, title?}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            var d = c; d.id = UUID(); d.created = Date()
            d.title = a.str("title") ?? (c.title + " (copy)")
            let at = (m.project.clips.firstIndex { $0.id == c.id } ?? (m.project.clips.count - 1)) + 1
            m.edit(rebuild: false) { $0.clips.insert(d, at: min(at, $0.clips.count)) }
            return clipRef(m, d.id)
        }),
        ControlCommand(id: "clip.trim", label: "Trim Clip Start / End", menu: "Timeline (drag the clip's ends)", key: "⌥[ / ⌥]", changesProject: true,
                       params: "{clip?, start?, end?: new seconds in the recording (snapped to words unless snap:false); or startBy?, endBy?: seconds to move each end (negative = earlier)}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let ws = m.project.words, snap = a.bool("snap") ?? true
            var s: Double? = a.num("start") ?? a.num("startBy").map { c.start + $0 }
            var e: Double? = a.num("end") ?? a.num("endBy").map { c.end + $0 }
            guard s != nil || e != nil else { throw ControlError("Pass start and/or end (or startBy / endBy).") }
            if snap { s = s.map { snapStart($0, ws) }; e = e.map { snapEnd($0, ws) } }
            s = s.map { max(0, $0) }; e = e.map { min(m.project.masterDuration, $0) }
            guard (e ?? c.end) > (s ?? c.start) + 0.3 else { throw ControlError("The start has to stay before the end.") }
            change(m, c.id) { clip in
                if let s {
                    let old = clip.start
                    clip.ranges = clip.ranges.compactMap { r in r.end <= s ? nil : TimeRange(start: max(r.start, s), end: r.end) }
                    if s < old || clip.ranges.isEmpty { clip.ranges.insert(TimeRange(start: s, end: clip.ranges.first?.start ?? (e ?? c.end)), at: 0) }
                }
                if let e {
                    let old = clip.end
                    clip.ranges = clip.ranges.compactMap { r in r.start >= e ? nil : TimeRange(start: r.start, end: min(r.end, e)) }
                    if e > old || clip.ranges.isEmpty { clip.ranges.append(TimeRange(start: clip.ranges.last?.end ?? (s ?? c.start), end: e)) }
                }
            }
            return clipRef(m, c.id)
        }),
        ControlCommand(id: "clip.cut", label: "Cut a Stretch Out of a Clip", menu: "Timeline (select a block, Delete)", changesProject: true,
                       params: "{clip?, from, to: seconds in the recording, inside the clip (snapped to words unless snap:false)}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            guard var f = a.num("from"), var t = a.num("to"), t > f else { throw ControlError("Pass {\"from\": …, \"to\": …} in recording seconds.") }
            if a.bool("snap") ?? true {
                // cut from just before a word to just before the next kept word
                let ws = m.project.words
                if let i = ws.indices.filter({ abs(ws[$0].start - f) <= 1.0 }).min(by: { abs(ws[$0].start - f) < abs(ws[$1].start - f) }) { f = max(i > 0 ? ws[i - 1].end : 0, ws[i].start - 0.02) }
                if let i = ws.indices.filter({ abs(ws[$0].end - t) <= 1.0 }).min(by: { abs(ws[$0].end - t) < abs(ws[$1].end - t) }) { t = i + 1 < ws.count ? max(ws[i].end, ws[i + 1].start - 0.02) : ws[i].end }
            }
            f = max(c.start, f); t = min(c.end, t)
            guard t > f + 0.02 else { throw ControlError("That stretch isn't inside the clip.") }
            var test = c; test.cut(f, t)
            guard test.outputDuration > 0.3 else { throw ControlError("That would cut the whole clip.") }
            change(m, c.id) { $0.cut(f, t) }
            return clipRef(m, c.id)
        }),
        ControlCommand(id: "clip.restore", label: "Put Cut Parts Back", menu: "Clip ▸ Restore", changesProject: true,
                       params: "{clip?, from?, to?: recording seconds; omit both to restore everything between the clip's start and end}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let f = max(c.start, a.num("from") ?? c.start), t = min(c.end, a.num("to") ?? c.end)
            change(m, c.id) { $0.restore(f, t) }
            return clipRef(m, c.id)
        }),
        ControlCommand(id: "clip.format", label: "Clip Shape", menu: "Clip inspector ▸ shape", changesProject: true,
                       params: "{clip?, format: \"9:16\" | \"1:1\" | \"16:9\"}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let f = try parseFormat(a.str("format") ?? "")
            change(m, c.id) { $0.format = f }
            return "\"\(c.title)\" is now \(f.label)."
        }),

        // Camera

        ControlCommand(id: "camera.set", label: "Use a Camera", menu: "Transport ▸ Camera (Auto / A / B / C)", key: "⌘1 / ⌘2 / ⌘0", changesProject: true,
                       params: "{clip?, camera: \"A\" | \"B\" | … | \"auto\" (or a speaker's name = their camera); from?, to?: recording seconds. Without from/to it's the whole clip. With them, only that stretch changes and the camera before 'to' carries on after it.}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let cam = try cameraIndex(m.project, a.d["camera"])
            let from = a.num("from").map { max(c.start, $0) }, to = a.num("to").map { min(c.end, $0) }
            if let f = from, let t = to, t <= f { throw ControlError("'to' has to be after 'from'.") }
            change(m, c.id) { clip in
                var sw = clip.switches.sorted { $0.time < $1.time }
                if from == nil && to == nil {
                    sw = cam.map { [AngleSwitch(time: clip.start, angle: $0)] } ?? []
                } else {
                    let f = from ?? clip.start, t = to ?? clip.end
                    let after = angleAt(clip, t)
                    sw.removeAll { $0.time >= f - 0.02 && $0.time <= t + 0.02 }
                    sw.append(AngleSwitch(time: f, angle: cam))
                    if t < clip.end - 0.05 { sw.append(AngleSwitch(time: t, angle: after)) }
                }
                sw.sort { $0.time < $1.time }
                var cleaned: [AngleSwitch] = []
                for s in sw where cleaned.isEmpty || cleaned.last!.angle != s.angle { cleaned.append(s) }
                while let first = cleaned.first, first.angle == nil { cleaned.removeFirst() }
                clip.switches = cleaned
            }
            return ["clip": clipRef(m, c.id),
                    "cameraSwitches": (m.project.clips.first { $0.id == c.id }?.switches ?? []).map { s -> [String: Any] in
                        ["time": r3(s.time), "camera": s.angle.map { angleName($0, m.project) } ?? "auto"] }] as [String: Any]
        }),
        ControlCommand(id: "camera.auto", label: "Camera Back to All-Automatic", menu: "Clip list ▸ right-click", changesProject: true,
                       params: "{clip?}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            change(m, c.id) { $0.switches = [] }
            return "\"\(c.title)\" follows the speaker again."
        }),
        ControlCommand(id: "camera.fullRecording", label: "Camera for the Full Recording View", menu: "Transport ▸ Camera", changesProject: false,
                       params: "{camera: \"A\" | \"B\" | … | \"auto\"} (only changes what you see on the full recording)",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let cam = try cameraIndex(m.project, a.d["camera"])
            m.fullViewAngle = cam
            if m.selectedClip == nil { m.rebuild() }
            return "Full recording shows \(cam.map { angleName($0, m.project) } ?? "the speaker (auto)")."
        }),

        // Sound

        ControlCommand(id: "sound.set", label: "Choose What You Hear", menu: "Transport ▸ Sound menu", changesProject: true,
                       params: "{clip?, hear: [\"Mic 1\", \"Mic 2\"] | \"Mic 1 + A\" | \"default\" | \"silent\" | \"all\"; from?, to?: recording seconds (without them: the whole clip)}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let on = try soundList(m.project, a.d["hear"])
            let n = m.project.angles.count
            let from = a.num("from").map { max(c.start, $0) }, to = a.num("to").map { min(c.end, $0) }
            if let f = from, let t = to, t <= f { throw ControlError("'to' has to be after 'from'.") }
            change(m, c.id) { clip in
                clip.audio.ensure(n)
                if from == nil && to == nil { clip.audio.on = on; clip.audioSwitches = nil; return }
                let f = from ?? clip.start, t = to ?? clip.end
                let after = clip.soundOn(at: t)
                var sw = clip.soundChanges
                sw.removeAll { $0.time >= f - 0.02 && $0.time <= t + 0.02 }
                if f <= clip.start + 0.05 { clip.audio.on = on } else { sw.append(AudioSwitch(time: f, on: on)) }
                if t < clip.end - 0.05 { sw.append(AudioSwitch(time: t, on: after)) }
                sw = sw.filter { $0.time > clip.start + 0.01 && $0.time < clip.end - 0.01 }.sorted { $0.time < $1.time }
                var cleaned: [AudioSwitch] = []
                var cur = clip.audio.on
                for s in sw {
                    let next = s.on ?? clip.audio.on
                    if next != cur { cleaned.append(AudioSwitch(time: s.time, on: next)); cur = next }
                }
                clip.audioSwitches = cleaned.isEmpty ? nil : cleaned
            }
            let cl = m.project.clips.first { $0.id == c.id } ?? c
            return ["clip": clipRef(m, c.id), "sound": heard(cl.audio.on, m.project),
                    "soundChanges": cl.soundChanges.map { s -> [String: Any] in ["time": r3(s.time), "hear": heard(s.on ?? cl.audio.on, m.project)] }] as [String: Any]
        }),
        ControlCommand(id: "sound.reset", label: "Same Sound for the Whole Clip", menu: "Clip list ▸ right-click", changesProject: true,
                       params: "{clip?} (back to the project's default: the mics if there are any)",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let d = m.project.defaultMix.on
            change(m, c.id) { clip in clip.audio.ensure(d.count); clip.audio.on = d; clip.audioSwitches = nil }
            return "\"\(c.title)\" uses the default sound: " + heard(d, m.project).joined(separator: " + ") + "."
        }),

        // Framing

        ControlCommand(id: "framing.set", label: "Adjust Framing", menu: "Clip inspector ▸ Adjust framing…", changesProject: true,
                       params: "{clip?, camera: \"A\"…, leftRight?: 0…1 (0 = Left end of the slider, 0.5 centred, 1 = Right: the picture moves right), downUp?: 0…1 (1 = picture moves up), zoom?: 1…2.5, reset?: true}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            guard let i = try cameraIndex(m.project, a.d["camera"]) else { throw ControlError("Pick one camera for framing.") }
            var f = a.bool("reset") == true ? Framing() : c.framing(for: i)
            if let z = a.num("zoom") { f.zoom = min(2.5, max(1, z)) }
            let lim = m.framingLimits(angle: i, format: c.format, zoom: f.zoom)
            if let u = a.num("leftRight") { f.x = lim.x.upperBound - min(1, max(0, u)) * (lim.x.upperBound - lim.x.lowerBound) }
            if let u = a.num("downUp") { f.y = lim.y.lowerBound + min(1, max(0, u)) * (lim.y.upperBound - lim.y.lowerBound) }
            f.x = min(lim.x.upperBound, max(lim.x.lowerBound, f.x)); f.y = min(lim.y.upperBound, max(lim.y.lowerBound, f.y))
            let set = f
            change(m, c.id) { clip in
                while clip.framing.count <= i { clip.framing.append(Framing()) }
                clip.framing[i] = set
            }
            var note = ""
            if a.has("leftRight") && lim.x.upperBound - lim.x.lowerBound < 0.001 { note += " No room left/right at this zoom (zoom in first)." }
            if a.has("downUp") && lim.y.upperBound - lim.y.lowerBound < 0.001 { note += " No room up/down at this zoom (zoom in first)." }
            return "Camera \(angleName(i, m.project)) in \"\(c.title)\": zoom \(String(format: "%.2f", set.zoom))×, centre x \(String(format: "%.2f", set.x)) y \(String(format: "%.2f", set.y))." + note
        }),
        ControlCommand(id: "framing.copyToAll", label: "Copy Framing to All Clips of This Shape", menu: "Adjust framing… ▸ More", changesProject: true,
                       params: "{clip?}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let n = m.project.clips.filter { $0.id != c.id && $0.format == c.format }.count
            m.edit(rebuild: false) { p in
                for k in p.clips.indices where p.clips[k].id != c.id && p.clips[k].format == c.format { p.clips[k].framing = c.framing }
            }
            return "Copied the framing to \(n) other \(c.format.label) clip\(n == 1 ? "" : "s")."
        }),

        // Speakers

        ControlCommand(id: "speaker.rename", label: "Rename Speaker", menu: "Speakers & Sync", changesProject: true,
                       params: "{speaker: number (1 = first) or current name, name}",
                       enabled: { !($0.current?.project.speakers.isEmpty ?? true) },
                       run: { app, a in
            let m = try model(app)
            let i = try speakerIndex(m.project, a.d["speaker"])
            guard let n = a.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { throw ControlError("Pass {\"name\": \"…\"}.") }
            m.edit(rebuild: false) { $0.speakers[i].name = n }
            m.transcriptVersion += 1
            return "Speaker \(i + 1) is now \"\(n)\"."
        }),
        ControlCommand(id: "speaker.camera", label: "Speaker's Camera", menu: "Speakers & Sync", changesProject: true,
                       params: "{speaker: number or name, camera: \"A\"…} (the camera automatic switching cuts to when this person talks)",
                       enabled: { !($0.current?.project.speakers.isEmpty ?? true) },
                       run: { app, a in
            let m = try model(app)
            let i = try speakerIndex(m.project, a.d["speaker"])
            guard let cam = try cameraIndex(m.project, a.d["camera"]) else { throw ControlError("Pick one camera, not auto.") }
            m.edit { $0.speakers[i].angle = cam; $0.speakerCamerasByHand = true }
            return "\(m.project.speakers[i].name) → camera \(angleName(cam, m.project))."
        }),
    ]
}
