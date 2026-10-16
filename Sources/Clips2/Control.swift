import Foundation
import AppKit

/// Everything Claude (or any other outside tool) can ask the running app: read-only queries
/// (project_inspect, clip_inspect, transcript_read…) and named commands (command_run "clip.select" …).
/// Commands call the same ProjectModel functions as the menus and buttons, so they share Undo.

struct Args {
    let d: [String: Any]
    init(_ any: Any?) { d = any as? [String: Any] ?? [:] }
    func has(_ k: String) -> Bool { if let v = d[k] { return !(v is NSNull) } else { return false } }
    func num(_ k: String) -> Double? {
        if let n = d[k] as? NSNumber { return n.doubleValue }
        if let s = d[k] as? String { return parseTime(s) }
        return nil
    }
    func str(_ k: String) -> String? {
        if let s = d[k] as? String { return s }
        if let n = d[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let s = d[k] as? String { return ["true", "yes", "1", "on"].contains(s.lowercased()) }
        if let n = d[k] as? NSNumber { return n.boolValue }
        return nil
    }
}

@MainActor
struct ControlCommand {
    let id: String
    let label: String
    var menu: String? = nil          // where it is in the app
    var key: String? = nil           // keyboard shortcut
    var changesProject = false       // true = an Undo step
    var params: String = ""          // what to pass
    let enabled: @MainActor (AppState) -> Bool
    let run: @MainActor (AppState, Args) async throws -> Any?
}

func r3(_ x: Double) -> Double { x.isFinite ? (x * 1000).rounded() / 1000 : 0 }

@MainActor
enum Control {

    // MARK: Dispatch

    static func handle(_ method: String, _ params: Any?) async -> [String: Any] {
        guard let app = AppState.shared else { return ["ok": false, "error": "Winnow is still starting up. Try again in a moment."] }
        let a = Args(params)
        do {
            let r: Any
            switch method {
            case "hello": r = appInfo()
            case "project_list": r = projectList()
            case "project_inspect": r = inspect(app)
            case "clip_inspect":
                let m = try model(app)
                let pick: Clip? = try a.has("clip") ? findClip(m, a.d["clip"]) : m.selectedClip
                guard let c = pick else {
                    throw ControlError("No clip is showing. Pass {\"clip\": number, id or title}.")
                }
                r = clipDetail(m, c)
            case "transcript_read": r = try transcript(app, a)
            case "command_list": r = listCommands(app, a)
            case "command_run": r = try await runCommand(app, a.str("id") ?? "", Args(a.d["params"]))
            case "command_batch": r = try await batch(app, a)
            case "render_frame": return try await renderFrame(app, a)
            default: throw ControlError("Winnow doesn't know \"\(method)\".")
            }
            if let s = r as? String { return ["ok": true, "text": s] }
            let t = tidy(r)
            guard JSONSerialization.isValidJSONObject(t),
                  let d = try? JSONSerialization.data(withJSONObject: t, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: d, encoding: .utf8) else { throw ControlError("Winnow couldn't turn its answer into JSON.") }
            return ["ok": true, "text": s]
        } catch {
            Log.write("control: \(method) failed: \(error)")
            return ["ok": false, "error": "\(error)"]
        }
    }

    /// Short, readable numbers in the JSON (81.96, not 81.959999999999994).
    static func tidy(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.mapValues { tidy($0) } }
        if let a = v as? [Any] { return a.map { tidy($0) } }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" || n is NSDecimalNumber {
                let x = n.doubleValue
                return x.isFinite ? NSDecimalNumber(string: String(format: "%.4f", x)) : NSDecimalNumber(value: 0)
            }
        }
        return v
    }

    // MARK: Lookups

    static func model(_ app: AppState) throws -> ProjectModel {
        guard let m = app.claude else {
            let w = app.current.map { " (Samuel's window has \"\($0.project.name)\" open; opening that one shares it live, opening another keeps your work separate from his)" } ?? ""
            throw ControlError("You don't have a project open. Run command project.open with {\"project\": name or number from project_list}" + w + ".")
        }
        return m
    }

    static func findClip(_ m: ProjectModel, _ v: Any?) throws -> Clip {
        let clips = m.project.clips
        guard !clips.isEmpty else { throw ControlError("This project has no clips yet.") }
        if let n = v as? NSNumber {
            let i = n.intValue
            guard i >= 1, i <= clips.count else { throw ControlError("There are \(clips.count) clips; clip numbers run 1–\(clips.count).") }
            return clips[i - 1]
        }
        guard let s0 = v as? String else { throw ControlError("Say which clip: its number in the list (1 = first), its id, or its title.") }
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = Int(s) {
            guard i >= 1, i <= clips.count else { throw ControlError("There are \(clips.count) clips; clip numbers run 1–\(clips.count).") }
            return clips[i - 1]
        }
        let low = s.lowercased()
        if let c = clips.first(where: { $0.id.uuidString.lowercased() == low }) { return c }
        if low.count >= 4, let c = clips.first(where: { $0.id.uuidString.lowercased().hasPrefix(low) }) { return c }
        if let c = clips.first(where: { $0.title.lowercased() == low }) { return c }
        let hits = clips.filter { $0.title.lowercased().contains(low) }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            throw ControlError("\(hits.count) clips match \"\(s)\": " + hits.prefix(6).map { "\"\($0.title)\"" }.joined(separator: ", ") + ". Use the clip's number or id.")
        }
        throw ControlError("No clip matches \"\(s)\".")
    }

    static func angleName(_ i: Int, _ p: Project) -> String {
        p.angles.indices.contains(i) ? p.angles[i].shortName : "?"
    }
    static func heard(_ on: [Bool], _ p: Project) -> [String] {
        p.angles.indices.filter { $0 < on.count && on[$0] && p.angles[$0].hasAudio }.map { angleName($0, p) }
    }
    static func jsonObject<T: Encodable>(_ v: T) -> Any {
        guard let d = try? Store.encoder.encode(v), let o = try? JSONSerialization.jsonObject(with: d) else { return NSNull() }
        return o
    }

    // MARK: Read-only queries

    static func appInfo() -> [String: Any] {
        var d: [String: Any] = ["app": "Winnow", "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"]
        let app = AppState.shared
        d["projectOpen"] = app?.claude?.project.name ?? "none"
        d["windowProject"] = app?.current?.project.name ?? "none (home screen)"
        if let c = app?.claude { d["sharedWithWindow"] = c === app?.current }
        d["window"] = !Background.primaryWindows.isEmpty ? "showing" : "none (command app.show opens it)"
        d["claudeWindow"] = Background.claudeWindowShowing
        d["dockIcon"] = !Background.isBackground
        return d
    }

    static func projectList() -> [[String: Any]] {
        let open = AppState.shared?.claude?.folder
        let inWindow = AppState.shared?.current?.folder
        let iso = ISO8601DateFormatter()
        return Store.list().enumerated().map { i, s -> [String: Any] in
            ["number": i + 1, "id": s.folder.lastPathComponent, "name": s.name, "clips": s.clips,
             "length": r3(s.duration), "stage": s.stage.rawValue, "created": iso.string(from: s.created),
             "open": s.folder == open, "inSamuelsWindow": s.folder == inWindow]
        }
    }

    static func clipSummary(_ c: Clip, index: Int) -> [String: Any] {
        var d: [String: Any] = [
            "number": index + 1, "id": c.id.uuidString, "title": c.title,
            "status": c.status?.rawValue ?? "unmarked",
            "start": r3(c.start), "end": r3(c.end), "length": r3(c.outputDuration),
            "format": c.format.label, "blocks": c.segments.count, "burnInCaptions": c.captions,
        ]
        if let s = c.score { d["score"] = r3(s) }
        if !c.note.isEmpty { d["note"] = c.note }
        if let b = c.captionBlocks, !b.isEmpty { d["handEditedCaptions"] = b.count }
        return d
    }

    static func state(_ m: ProjectModel) -> [String: Any] {
        var d: [String: Any] = [
            "view": m.selectedClip == nil ? "full recording" : "clip",
            "playhead": r3(m.engine.time),
            "playheadInRecording": r3(m.masterTime(m.engine.time)),
            "viewLength": r3(m.engine.duration),
            "playing": m.engine.isPlaying,
            "canUndo": m.canUndo, "canRedo": m.canRedo,
        ]
        if let c = m.selectedClip, let i = m.clipIndex { d["clip"] = ["number": i + 1, "id": c.id.uuidString, "title": c.title] as [String: Any] }
        else { d["fullRecordingCamera"] = m.fullViewAngle.map { angleName($0, m.project) } ?? "auto" }
        if let b = m.busy { d["busy"] = b; d["progress"] = r3(m.progress) }
        if let n = m.notice { d["notice"] = n }
        if let e = m.errorText { d["error"] = e }
        if let s = m.tlSel { d["timelineSelection"] = [r3(s.lowerBound), r3(s.upperBound)] }
        if let s = m.selectedCaption { d["selectedCaption"] = s.uuidString }
        return d
    }

    static func inspect(_ app: AppState) -> [String: Any] {
        var out: [String: Any] = ["app": appInfo()]
        guard let m = app.claude else {
            out["open"] = false
            out["projects"] = projectList()
            out["hint"] = "You don't have a project open. Run command project.open with {\"project\": name or number}. It opens in the background: Samuel's window doesn't change (if it's the project in his window, you share it live)."
            return out
        }
        let p = m.project
        let sources: [[String: Any]] = p.angles.enumerated().map { i, a in
            var d: [String: Any] = ["name": a.shortName, "kind": a.isVideo ? "camera" : "mic",
                                    "file": a.url.lastPathComponent, "offset": r3(a.offset), "duration": r3(a.duration),
                                    "hasSound": a.hasAudio, "opened": i < m.sources.count && m.sources[i] != nil]
            if a.isVideo { d["size"] = "\(Int(a.width))×\(Int(a.height))"; d["fps"] = r3(a.fps) }
            if let s = a.syncScore { d["syncScore"] = r3(s) }
            if a.syncFailed { d["syncFailed"] = true }
            if let w = a.syncedWith { d["syncedWith"] = w }
            if a.gainDB != 0 { d["gainDB"] = r3(a.gainDB) }
            return d
        }
        out["open"] = true
        out["timeNote"] = "Clip start/end are seconds in the full synced recording; 'length' is the finished clip's length. state.playhead is in the current view (clip time when a clip is showing)."
        out["project"] = [
            "id": m.folder.lastPathComponent, "name": p.name, "stage": p.stage.rawValue,
            "length": r3(p.masterDuration), "language": p.language,
            "words": p.words.filter { !$0.isHidden }.count,
            "sources": sources,
            "speakers": p.speakers.map { ["name": $0.name, "camera": angleName($0.angle, p)] },
            "markers": (p.markers ?? []).map { mk -> [String: Any] in ["time": r3(mk.time), "name": mk.name] },
            "autoCamera": ["minShot": r3(p.minShot), "switchLead": r3(p.switchLead)],
            "captionStyle": styleSummary(p.captionStyle),
        ] as [String: Any]
        out["clips"] = p.clips.enumerated().map { clipSummary($1, index: $0) }
        out["state"] = state(m)
        return out
    }

    static func clipDetail(_ m: ProjectModel, _ c: Clip) -> [String: Any] {
        let p = m.project
        let idx = p.clips.firstIndex { $0.id == c.id } ?? 0
        var d = clipSummary(c, index: idx)
        d["timeNote"] = "start/end/kept/blocks/switch times are seconds in the full recording; 'out' and caption times are seconds into the finished clip."
        d["kept"] = c.ranges.map { [r3($0.start), r3($0.end)] }
        d["timelineBlocks"] = c.segments.map { ["start": r3($0.master.start), "end": r3($0.master.end), "out": r3($0.outStart)] }
        d["cameraSwitches"] = c.switches.map { s -> [String: Any] in
            ["time": r3(s.time), "out": r3(c.outputTimeClamped(forMaster: s.time)), "camera": s.angle.map { angleName($0, p) } ?? "auto"]
        }
        d["sound"] = heard(c.audio.on, p)
        d["soundChanges"] = c.soundChanges.map { s -> [String: Any] in
            ["time": r3(s.time), "hear": s.on.map { heard($0, p) as Any } ?? "the clip's own sound"]
        }
        d["shotsNote"] = "Shots: each stretch of one camera between cuts (start/end in the recording, out = in the finished clip). 'ownFraming' = framed on its own (framing.set with shot)."
        d["shots"] = Schedule.pieces(project: p, clip: c, auto: m.auto).map { pc -> [String: Any] in
            var e: [String: Any] = ["start": r3(pc.masterStart), "end": r3(pc.masterStart + pc.duration), "out": r3(pc.outStart),
                                    "camera": angleName(pc.angle, p)]
            if let k = c.shotFramingIndex(start: pc.masterStart, end: pc.masterStart + pc.duration, angle: pc.angle), let s = c.shotFraming?[k] {
                e["ownFraming"] = ["x": r3(s.x), "y": r3(s.y), "zoom": r3(s.zoom)]
            }
            return e
        }
        d["framing"] = p.videoIndices.map { i -> [String: Any] in
            let f = c.framing(for: i)
            var e: [String: Any] = ["camera": angleName(i, p), "x": r3(f.x), "y": r3(f.y), "zoom": r3(f.zoom)]
            e["captionHeight"] = f.captionY.map { r3($0) as Any } ?? "caption style"
            return e
        }
        let track = Captions.track(for: c, project: p)
        let ids = m.captionIDs(track, clip: c)
        d["captionsNote"] = "Captions: number (use it in caption.* commands), start/end in seconds into the finished clip, text with \" / \" where a new line starts."
        d["captions"] = track.pages.enumerated().map { k, pg -> [String: Any] in
            let text = pg.lines.map { line in
                line.map { i -> String in let w = track.words[i]; return w.raw.isEmpty ? w.text : w.raw }.joined(separator: " ")
            }.joined(separator: " / ")
            var e: [String: Any] = ["number": k + 1, "id": ids[k].uuidString, "start": r3(pg.start), "end": r3(pg.end), "text": text]
            if pg.blockID != nil { e["handEdited"] = true }
            if let y = pg.positionY { e["height"] = r3(y) }
            if pg.wordIndexes.isEmpty { e["noCaption"] = true }
            return e
        }
        return d
    }

    static func transcript(_ app: AppState, _ a: Args) throws -> String {
        let m = try model(app)
        let p = m.project
        guard !p.words.isEmpty else {
            throw ControlError(p.stage == .transcribed ? "The transcript is empty." : "This project hasn't been transcribed yet\(m.busy.map { " (working: \($0))" } ?? "").")
        }
        var from = a.num("from") ?? 0, to = a.num("to") ?? .infinity
        var head = ""
        if a.has("clip") {
            let c = try findClip(m, a.d["clip"])
            from = max(from, c.start - 0.05); to = min(to, c.end + 0.05)
            head = "Clip \"\(c.title)\" (\(fmtTime(c.start, frac: true))–\(fmtTime(c.end, frac: true)) in the recording; parts cut out of the clip are still listed).\n"
        }
        let body = ClipFinder.transcriptLines(p, from: from, to: to)
        return head + "Each line: [start–end seconds in the full recording] Speaker: words\n\n" + (body.isEmpty ? "(no words in that stretch)\n" : body)
    }

    // MARK: Commands

    static func listCommands(_ app: AppState, _ a: Args) -> [[String: Any]] {
        let f = a.str("filter")?.lowercased() ?? ""
        let only = a.bool("enabled_only") ?? false
        return commands.compactMap { c in
            if !f.isEmpty && !c.id.lowercased().contains(f) && !c.label.lowercased().contains(f) { return nil }
            let on = c.enabled(app)
            if only && !on { return nil }
            var d: [String: Any] = ["id": c.id, "label": c.label, "enabledNow": on, "changesProject": c.changesProject]
            if let m = c.menu { d["menu"] = m }
            if let k = c.key { d["key"] = k }
            if !c.params.isEmpty { d["params"] = c.params }
            return d
        }
    }

    static func runCommand(_ app: AppState, _ id: String, _ a: Args) async throws -> [String: Any] {
        guard let c = commands.first(where: { $0.id == id }) else {
            let near = commands.filter { $0.id.contains(id.split(separator: ".").first.map(String.init) ?? id) }.map { $0.id }
            throw ControlError("No command \"\(id)\"." + (near.isEmpty ? " command_list shows them all." : " Did you mean: " + near.joined(separator: ", ") + "?"))
        }
        guard c.enabled(app) else {
            throw ControlError("\(c.id) can't run right now" + (app.claude == nil ? " (you don't have a project open: project.open)." : "."))
        }
        Log.write("control: run \(id)")
        let r = try await c.run(app, a)
        var out: [String: Any] = ["command": id, "result": r ?? "done"]
        if let m = app.claude { out["state"] = state(m) }
        return out
    }

    static func batch(_ app: AppState, _ a: Args) async throws -> [[String: Any]] {
        guard let list = a.d["commands"] as? [[String: Any]], !list.isEmpty else {
            throw ControlError("Pass {\"commands\": [{\"id\": …, \"params\": {…}}, …]}.")
        }
        let stop = a.bool("stop_on_error") ?? true
        var out: [[String: Any]] = []
        for item in list {
            let id = item["id"] as? String ?? ""
            do {
                var r = try await runCommand(app, id, Args(item["params"]))
                r["ok"] = true
                out.append(r)
            } catch {
                out.append(["command": id, "ok": false, "error": "\(error)"])
                if stop { break }
            }
        }
        return out
    }

    static func hasProject(_ app: AppState) -> Bool { app.claude != nil }
    static func hasClips(_ app: AppState) -> Bool { !(app.claude?.project.clips.isEmpty ?? true) }

    static let commands: [ControlCommand] = baseCommands + editCommands + captionCommands + renderCommands

    static let baseCommands: [ControlCommand] = [
        ControlCommand(id: "app.show", label: "Show Winnow Window", menu: "Open Winnow (Dock, Finder, Spotlight)",
                       params: "{which?: \"claude\" (default: your project's window when it's a different project from Samuel's, else his main window) | \"main\"}",
                       enabled: { _ in true },
                       run: { app, a in
            let separate = app.claude != nil && app.claude !== app.current
            let which = a.str("which")?.lowercased() ?? (separate ? "claude" : "main")
            if which == "claude" {
                guard separate else { Background.show(); return "You're working on the project in Samuel's main window; showed that window." }
                Background.showClaude()
                for _ in 0..<30 where !Background.claudeWindowShowing { try await Task.sleep(nanoseconds: 100_000_000) }
                return Background.claudeWindowShowing ? "Your project is showing in the \"\(ClaudeWindowRoot.title)\" window (Samuel's window is unchanged)."
                    : "Asked for the \"\(ClaudeWindowRoot.title)\" window; it should appear in a moment."
            }
            Background.show()
            for _ in 0..<30 where Background.primaryWindows.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
            return !Background.primaryWindows.isEmpty ? "The Winnow window is showing." : "Asked for the window; it should appear in a moment."
        }),
        ControlCommand(id: "app.hide", label: "Hide Winnow Windows (keep running)", menu: "Close the window",
                       enabled: { _ in true },
                       run: { _, _ in
            Background.hide()
            return "Closed the windows. Winnow keeps running in the background; your project stays open."
        }),
        ControlCommand(id: "project.open", label: "Open Project", menu: "Home screen",
                       params: "{project: name, number from project_list, or id}",
                       enabled: { _ in true },
                       run: { app, a in
            let list = Store.list()
            guard let s = a.str("project")?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else {
                throw ControlError("Say which project: {\"project\": name or number}.")
            }
            var hit: ProjectSummary? = nil
            if let n = Int(s), n >= 1, n <= list.count { hit = list[n - 1] }
            else if let p = list.first(where: { $0.folder.lastPathComponent.lowercased() == s || $0.name.lowercased() == s }) { hit = p }
            else {
                let hits = list.filter { $0.name.lowercased().contains(s) }
                if hits.count == 1 { hit = hits[0] }
                else if hits.count > 1 { throw ControlError("Several projects match \"\(s)\": " + hits.map { "\"\($0.name)\"" }.joined(separator: ", ")) }
            }
            guard let pr = hit else { throw ControlError("No project matches \"\(s)\". project_list shows them.") }
            if app.claude?.folder == pr.folder { return "\"\(pr.name)\" is already open." }
            let m: ProjectModel
            do { m = try app.openForClaude(pr.folder) } catch { throw ControlError("Couldn't open it: \(error.localizedDescription)") }
            for _ in 0..<300 {
                if !m.loaded.isEmpty && m.busy == nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let where_ = m === app.current ? " It's the project in Samuel's window, so you're sharing it: he sees your edits as you make them (avoid clip.select / playhead.seek / transport, they move his view)."
                : " It's open in the background; Samuel's window doesn't change."
            return "Opened \"\(pr.name)\"." + where_ + (m.busy.map { " Still working: \($0)" } ?? "")
        }),
        ControlCommand(id: "project.close", label: "Close Project", menu: "Breadcrumb ▸ back to projects",
                       enabled: { hasProject($0) },
                       run: { app, _ in
            let n = app.claude?.project.name ?? ""
            let shared = app.claude === app.current
            app.closeClaude()
            return "Closed \"\(n)\"." + (shared ? " (It stays open in Samuel's window.)" : "")
        }),
        ControlCommand(id: "project.create", label: "New Project from Files", menu: "Home screen ▸ Choose Files… / drop files",
                       params: "{files: [full paths: up to 4 videos + up to 4 audio files], name?: project name}",
                       enabled: { _ in true },
                       run: { app, a in
            var paths: [String] = []
            if let list = a.d["files"] as? [Any] { paths = list.compactMap { $0 as? String } }
            else if let one = a.str("files") { paths = [one] }
            paths = paths.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !paths.isEmpty else { throw ControlError("Pass {\"files\": [\"/full/path/camera.mov\", \"/full/path/mic.wav\"]}.") }
            let fm = FileManager.default
            let missing = paths.filter { !fm.fileExists(atPath: $0) }
            if !missing.isEmpty { throw ControlError("Can't find: " + missing.joined(separator: ", ")) }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            let videos = urls.filter { Store.videoExts.contains($0.pathExtension.lowercased()) }
            let audios = urls.filter { Store.audioExts.contains($0.pathExtension.lowercased()) }
            guard !videos.isEmpty else { throw ControlError("At least one video file (.mov or .mp4) is needed.") }
            if videos.count > 4 || audios.count > 4 { throw ControlError("Up to four videos and four audio files.") }
            let odd = urls.filter { !videos.contains($0) && !audios.contains($0) }
            if !odd.isEmpty { throw ControlError("Not a video or audio file: " + odd.map { $0.lastPathComponent }.joined(separator: ", ")) }
            let n = a.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (n?.isEmpty == false) ? n! : defaultProjectName(videos[0])
            let folder = try Store.create(name: name, files: videos + audios)
            app.refresh()
            let m: ProjectModel
            do { m = try app.openForClaude(folder) } catch { throw ControlError("Created it but couldn't open it: \(error.localizedDescription)") }
            for _ in 0..<50 {
                if !m.loaded.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return "Created and opened \"\(name)\" with \(videos.count) video and \(audios.count) audio file(s)."
                + (m.busy.map { " Working: \($0) (check project_inspect for progress)." } ?? "")
        }),
        ControlCommand(id: "project.rename", label: "Rename Project", menu: "Breadcrumb (project name)",
                       params: "{name}",
                       enabled: { hasProject($0) },
                       run: { app, a in
            guard let m = app.claude else { throw ControlError("No project is open.") }
            guard let n = a.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else {
                throw ControlError("Pass {\"name\": \"new name\"}.")
            }
            let old = m.project.name
            app.rename(m.folder, to: n)
            return "Renamed \"\(old)\" to \"\(n)\"."
        }),
        ControlCommand(id: "transcript.retime", label: "Re-time Words to the Sound", menu: "Clip ▸ Re-time Words to the Sound", changesProject: true,
                       params: "{} — re-times every transcript word against the audio (forced alignment, English). Keeps text fixes, hidden words and speakers. One undo step. Takes about a minute for a 30-minute recording (first run also downloads the model).",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            guard m.busy == nil else { throw ControlError("Busy: \(m.busy!)") }
            guard m.isReady else { throw ControlError("This project hasn't been transcribed yet.") }
            m.notice = nil; m.errorText = nil
            await m.retimeWords()
            if let e = m.errorText { throw ControlError(e) }
            return m.notice ?? "Done."
        }),
        ControlCommand(id: "clip.select", label: "Show Clip", menu: "Clip list (click a clip)",
                       params: "{clip: number in the list (1 = first), id or title; omit, or \"full\", for the full recording}",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let s = a.str("clip")?.lowercased() ?? ""
            if s.isEmpty || s == "full" || s == "full recording" {
                m.select(clip: nil)
                return "Showing the full recording."
            }
            let c = try findClip(m, a.d["clip"])
            m.select(clip: c.id)
            return "Showing clip \((m.clipIndex ?? 0) + 1): \"\(c.title)\"."
        }),
        ControlCommand(id: "clip.next", label: "Next Clip", menu: "Clip ▸ Next Clip", key: "⌘↓",
                       enabled: { hasClips($0) },
                       run: { app, _ in
            let m = try model(app)
            m.selectAdjacentClip(next: true)
            return m.selectedClip.map { "Showing clip \((m.clipIndex ?? 0) + 1): \"\($0.title)\"." } ?? "Showing the full recording."
        }),
        ControlCommand(id: "clip.previous", label: "Previous Clip", menu: "Clip ▸ Previous Clip", key: "⌘↑",
                       enabled: { hasClips($0) },
                       run: { app, _ in
            let m = try model(app)
            m.selectAdjacentClip(next: false)
            return m.selectedClip.map { "Showing clip \((m.clipIndex ?? 0) + 1): \"\($0.title)\"." } ?? "Showing the full recording."
        }),
        ControlCommand(id: "playhead.seek", label: "Move Playhead", menu: "Timeline (click the ruler)",
                       params: "{seconds: number or \"m:ss\" in the current view; recording: true to give a time in the full recording instead}",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            guard let t = a.num("seconds") else { throw ControlError("Pass {\"seconds\": 12.5}.") }
            if a.bool("recording") == true { m.seekMaster(t) } else { m.engine.seek(t) }
            return "Playhead moved."
        }),
        ControlCommand(id: "transport.play", label: "Play", menu: "Transport ▶", key: "Space",
                       enabled: { hasProject($0) },
                       run: { app, _ in try model(app).engine.play(); return "Playing." }),
        ControlCommand(id: "transport.pause", label: "Pause", menu: "Transport ▶", key: "Space",
                       enabled: { hasProject($0) },
                       run: { app, _ in try model(app).engine.pause(); return "Paused." }),
        ControlCommand(id: "timeline.fit", label: "Fit Timeline", menu: "Clip ▸ Fit Timeline", key: "⌥⌘0 / ⇧Z",
                       enabled: { hasProject($0) },
                       run: { app, _ in try model(app).fitTimeline(); return "Timeline fits the window." }),
        ControlCommand(id: "timeline.zoom", label: "Zoom Timeline", menu: "Clip ▸ Zoom Timeline In / Out", key: "⌘= / ⌘-",
                       params: "{factor: above 1 zooms in, below 1 zooms out (e.g. 1.6 or 0.625)}",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            m.zoomTimeline(by: max(0.05, min(20, a.num("factor") ?? 1.6)))
            return "Timeline zoom \(String(format: "%.1f", m.tlZoom))×."
        }),
        ControlCommand(id: "edit.undo", label: "Undo", menu: "Edit ▸ Undo", key: "⌘Z", changesProject: true,
                       enabled: { $0.claude?.canUndo ?? false },
                       run: { app, _ in try model(app).undo(); return "Undone." }),
        ControlCommand(id: "edit.redo", label: "Redo", menu: "Edit ▸ Redo", key: "⇧⌘Z", changesProject: true,
                       enabled: { $0.claude?.canRedo ?? false },
                       run: { app, _ in try model(app).redo(); return "Redone." }),
    ]
}
