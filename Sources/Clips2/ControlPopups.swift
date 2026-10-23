import Foundation

/// Brands and follow popups, for Claude.
extension Control {

    static func brandSummary(_ b: ChannelBrand) -> [String: Any] {
        var d: [String: Any] = ["id": b.id.uuidString, "name": b.name, "handle": b.displayHandle, "color": hex(b.color),
                                "buttonTextColor": hex(b.buttonText), "youtubeCard": b.dark ? "dark" : "white",
                                "words": ["circle": [b.follow, b.following], "youtube": [b.subscribe, b.subscribed]],
                                "picture": b.pictureURL?.path ?? "none",
                                "captionLook": b.captionStyle == nil ? "none (leaves captions alone)" : (b.captionLookName ?? "saved look"),
                                "thumbnailLook": b.thumbnailStyle == nil ? "none" : "saved look"]
        if let c2 = b.color2 { d["color2"] = hex(c2) }
        if let s = b.subtitle { d["secondLine"] = s }
        if BrandStore.load().defaultID == b.id { d["newProjectsStartWithIt"] = true }
        return d
    }

    static func findBrand(_ v: Any?) throws -> ChannelBrand {
        guard let s = v as? String, let b = BrandStore.find(s) else {
            let names = BrandStore.all.map { $0.name }
            throw ControlError("No brand \"\(v.map { "\($0)" } ?? "")\". " + (names.isEmpty ? "There are none yet: make one with brand.set." : "Brands: " + names.joined(separator: ", ")))
        }
        return b
    }

    static func popupInfo(_ m: ProjectModel, _ c: Clip) -> [[String: Any]] {
        (c.popups ?? []).enumerated().map { k, p in
            let b = Popups.brand(for: p, project: m.project)
            let sp = Popups.span(p, clip: c)
            let w = Popups.words(p, b)
            var d: [String: Any] = ["number": k + 1, "id": p.id.uuidString, "kind": p.kind == .circle ? "circle" : "youtube",
                                    "start": r3(sp.start), "end": r3(sp.end), "recordingTime": r3(p.time),
                                    "brand": p.brandID == nil ? "project's (\(b.name))" : b.name,
                                    "button": w.before, "afterTap": w.after, "x": r3(p.x), "y": r3(p.y), "size": r3(p.size),
                                    "tap": p.taps, "hand": p.showsHand]
            if let t = Popups.tapTime(p, start: sp.start, end: sp.end) {
                d["tapsAt"] = r3(t)
                if p.kind == .bar { d["bellAt"] = r3(t + Popups.bellDelay) }
            } else if p.taps { d["note"] = "too short for the tap (needs \(p.kind == .circle ? "2.2" : "3") s)" }
            return d
        }
    }

    static func findPopup(_ c: Clip, _ v: Any?) throws -> FollowPopup {
        let ps = c.popups ?? []
        guard !ps.isEmpty else { throw ControlError("Clip \"\(c.title)\" has no popups. Add one with popup.add.") }
        if v == nil, ps.count == 1 { return ps[0] }
        if let n = v as? NSNumber, n.intValue >= 1, n.intValue <= ps.count { return ps[n.intValue - 1] }
        if let s = v as? String {
            if let i = Int(s), i >= 1, i <= ps.count { return ps[i - 1] }
            let low = s.lowercased()
            if let p = ps.first(where: { $0.id.uuidString.lowercased() == low || (low.count >= 4 && $0.id.uuidString.lowercased().hasPrefix(low)) }) { return p }
        }
        throw ControlError("Say which popup: {\"popup\": number (1–\(ps.count)) or id} (see clip_inspect popups).")
    }

    static let popupParams = "kind?: \"circle\" (profile picture in a ring + Follow pill) | \"youtube\" (bar with picture, name, Subscribe and bell); seconds?: when it appears, seconds into the finished clip; length?: seconds on screen (1–20, default 4); brand?: brand name/id or \"project\" (the project's brand); button?: its own button word (\"reset\" = the brand's); position?: topLeft|top|topRight|left|middle|right|bottomLeft|bottom|bottomRight; x?, y?: centre as fractions of the frame (0,0 = top left); size?: 0.5–2 (1 = normal); tap?: the button gets tapped (Follow → Following; on youtube Subscribe → Subscribed then the bell rings); hand?: a hand does the tapping"

    static func applyPopup(_ p: inout FollowPopup, _ a: Args, clip c: Clip) throws {
        if let k = a.str("kind")?.lowercased() {
            switch k {
            case "circle", "follow", "ring": p.kind = .circle
            case "youtube", "bar", "subscribe", "yt": p.kind = .bar
            default: throw ControlError("kind is \"circle\" or \"youtube\".")
            }
        }
        if a.has("brand") {
            let s = a.str("brand") ?? ""
            if ["project", "default", "none", ""].contains(s.lowercased()) { p.brandID = nil } else { p.brandID = try findBrand(s).id }
        }
        if let s = a.str("button") { p.button = (s.lowercased() == "reset" || s.trimmingCharacters(in: .whitespaces).isEmpty) ? nil : s }
        if let t = a.bool("tap") { p.tap = t ? nil : false }
        if let h = a.bool("hand") { p.hand = h ? nil : false }
        if let s = a.num("size") { let v = min(FollowPopup.maxSize, max(FollowPopup.minSize, s)); p.scale = abs(v - 1) < 0.01 ? nil : v }
        if let pos = a.str("position") {
            guard let sp = PopupSpot.parse(pos) else { throw ControlError("position is one of: " + PopupSpot.allCases.map { $0.rawValue }.joined(separator: ", ")) }
            (p.x, p.y) = sp.xy
        }
        if let x = a.num("x") { p.x = min(1, max(0, x)) }
        if let y = a.num("y") { p.y = min(1, max(0, y)) }
        let total = c.outputDuration
        let curStart = Popups.span(p, clip: c).start
        let start = max(0, min(a.num("seconds") ?? curStart, max(0, total - FollowPopup.minLength)))
        if a.has("seconds") { p.time = c.masterTime(forOutput: start) }
        if let l = a.num("length") { p.length = min(FollowPopup.maxLength, max(FollowPopup.minLength, l)) }
        p.length = min(p.length, max(FollowPopup.minLength, total - start))
    }

    static func savePopups(_ m: ProjectModel, _ c: Clip, _ f: (inout [FollowPopup]) -> Void) {
        change(m, c.id, rebuild: false) { cl in
            var list = cl.popups ?? []
            f(&list)
            cl.popups = list.isEmpty ? nil : list
        }
        if m.selectedClipID == c.id { m.refreshPopups() }
    }

    static let popupCommands: [ControlCommand] = [
        ControlCommand(id: "brand.list", label: "List Brands", menu: "Clip ▸ Brands…",
                       enabled: { _ in true },
                       run: { app, _ in
            var d: [String: Any] = ["brands": BrandStore.all.map { brandSummary($0) }]
            if let m = app.claude { d["projectBrand"] = m.projectBrand?.name ?? "none" }
            d["note"] = "Brands are shared by every project. A project's brand is who its follow popups are for; picking it (brand.use) also applies its caption / thumbnail looks."
            return d
        }),
        ControlCommand(id: "brand.set", label: "Make or Change a Brand", menu: "Clip ▸ Brands…",
                       params: "{brand?: name or id of the one to change (omit to make a new one), name?, handle? (\"@name\"), secondLine? (YouTube bar's second line, e.g. \"12K subscribers\"; \"\" = the handle), picture?: full path to an image (square-cropped) or \"none\", color?: ring + button hex, color2?: second ring colour (fade) or \"none\", buttonTextColor?, card?: \"white\" | \"dark\" (YouTube bar), followWord?, followingWord?, subscribeWord?, subscribedWord?, captionLook?: \"project\" (the open project's caption style) | a caption preset name | \"none\", thumbnailLook?: \"project\" | \"none\", newProjects?: true/false (new projects start with it), use?: true (also make it the open project's brand), delete?: true}",
                       enabled: { _ in true },
                       run: { app, a in
            var b: ChannelBrand
            if let s = a.str("brand"), s.lowercased() != "new" { b = try findBrand(s) }
            else { b = ChannelBrand(name: a.str("name") ?? "My Channel") }
            if a.bool("delete") == true {
                BrandStore.remove(b.id); BrandLibrary.shared.reload()
                app.claude?.refreshPopups()
                return ["deleted": b.name]
            }
            if let s = a.str("name"), !s.trimmingCharacters(in: .whitespaces).isEmpty { b.name = s }
            if let s = a.str("handle") { b.handle = s }
            if let s = a.str("secondLine") ?? a.str("subtitle") { b.subtitle = s.isEmpty ? nil : s }
            if let c = try color(a.d["color"]) { b.color = c }
            if a.has("color2") {
                if a.str("color2")?.lowercased() == "none" { b.color2 = nil } else { b.color2 = try color(a.d["color2"]) }
            }
            if let c = try color(a.d["buttonTextColor"]) { b.buttonTextColor = c }
            if let s = a.str("card")?.lowercased() { b.darkCard = s == "dark" ? true : nil }
            for (k, kp) in [("followWord", \ChannelBrand.followWord), ("followingWord", \.followingWord),
                            ("subscribeWord", \.subscribeWord), ("subscribedWord", \.subscribedWord)] {
                if let s = a.str(k) { b[keyPath: kp] = s.isEmpty ? nil : s }
            }
            if let p = a.str("picture") {
                if p.lowercased() == "none" {
                    if let old = b.pictureURL { try? FileManager.default.removeItem(at: old) }
                    b.picture = nil
                } else {
                    let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                    guard FileManager.default.fileExists(atPath: u.path) else { throw ControlError("No picture at \(u.path).") }
                    let name = try BrandStore.importPicture(u, for: b.id)
                    if let old = b.pictureURL { try? FileManager.default.removeItem(at: old) }
                    b.picture = name
                }
            }
            if let s = a.str("captionLook") {
                let low = s.lowercased()
                if low == "none" { b.captionStyle = nil; b.captionLookName = nil }
                else if low == "project" {
                    let m = try model(app)
                    b.captionStyle = m.project.captionStyle; b.captionLookName = "From “\(m.project.name)”"
                } else {
                    let all = allPresets()
                    guard let pr = all.first(where: { $0.name.lowercased() == low }) ?? all.first(where: { $0.name.lowercased().contains(low) }) else {
                        throw ControlError("No caption preset \"\(s)\". Presets: " + all.map { $0.name }.joined(separator: ", "))
                    }
                    b.captionStyle = pr.style; b.captionLookName = pr.name
                }
            }
            if let s = a.str("thumbnailLook")?.lowercased() {
                if s == "none" { b.thumbnailStyle = nil } else { b.thumbnailStyle = try model(app).thumbnailStyle }
            }
            BrandStore.upsert(b)
            if let n = a.bool("newProjects") {
                var f = BrandStore.load()
                if n { f.defaultID = b.id } else if f.defaultID == b.id { f.defaultID = nil }
                BrandStore.save(f)
            }
            BrandLibrary.shared.reload()
            if a.bool("use") == true { try model(app).applyBrand(b.id) }
            app.claude?.refreshPopups()
            return brandSummary(BrandStore.brand(b.id) ?? b)
        }),
        ControlCommand(id: "brand.use", label: "Use a Brand for This Project", menu: "Captions panel ▸ Brand", changesProject: true,
                       params: "{brand: name or id, or \"none\"} — popups without their own brand use it, and its caption / thumbnail looks (if it has them) are applied",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let s = a.str("brand") ?? ""
            if s.lowercased() == "none" { m.applyBrand(nil); return ["projectBrand": "none"] }
            let b = try findBrand(s)
            m.applyBrand(b.id)
            return ["projectBrand": b.name, "appliedCaptionLook": b.captionStyle != nil, "appliedThumbnailLook": b.thumbnailStyle != nil]
        }),
        ControlCommand(id: "popup.add", label: "Add Follow Popup", menu: "Clip settings ▸ Follow popups ▸ Add at Playhead", changesProject: true,
                       params: "{clip?, " + popupParams + "}. Default: at the playhead (or 1 s in), 4 s long, the project's brand, its usual spot for the clip's shape.",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let showing = c.id == m.selectedClipID
            var p = FollowPopup(time: c.start)
            if let k = a.str("kind") { try applyPopup(&p, Args(["kind": k]), clip: c) }
            let spot = FollowPopup.defaultSpot(p.kind, c.format)
            p.x = spot.x; p.y = spot.y
            var ad = a.d
            if !a.has("seconds") { ad["seconds"] = showing ? m.engine.time : min(1, c.outputDuration / 4) }
            try applyPopup(&p, Args(ad), clip: c)
            savePopups(m, c) { $0.append(p) }
            let fresh = m.project.clips.first { $0.id == c.id } ?? c
            return ["added": (fresh.popups?.count ?? 1), "popups": popupInfo(m, fresh)]
        }),
        ControlCommand(id: "popup.set", label: "Change a Follow Popup", menu: "Click a popup (timeline or viewer) ▸ its settings", changesProject: true,
                       params: "{clip?, popup: number (1 = first) or id, " + popupParams + "}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            var p = try findPopup(c, a.d["popup"])
            try applyPopup(&p, a, clip: c)
            savePopups(m, c) { list in if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } }
            let fresh = m.project.clips.first { $0.id == c.id } ?? c
            return ["popups": popupInfo(m, fresh)]
        }),
        ControlCommand(id: "popup.remove", label: "Delete Follow Popup", menu: "Select a popup ▸ Delete", key: "Delete", changesProject: true,
                       params: "{clip?, popup: number or id | all: true}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            if a.bool("all") == true {
                let n = c.popups?.count ?? 0
                savePopups(m, c) { $0.removeAll() }
                return ["removed": n]
            }
            let p = try findPopup(c, a.d["popup"])
            if m.selectedPopup == p.id { m.selectedPopup = nil }
            savePopups(m, c) { $0.removeAll { $0.id == p.id } }
            return ["removed": 1, "left": (c.popups?.count ?? 1) - 1]
        }),
    ]
}
