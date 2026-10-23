import Foundation
import AppKit

/// Caption commands for Claude: retype, split, join, re-time, delete, reset, fix a word everywhere,
/// style and presets. Caption times are seconds into the finished clip (as clip_inspect shows them).
extension Control {

    // MARK: Helpers

    /// The clip's captions as the captions panel lists them (with the same ids).
    static func captionList(_ m: ProjectModel, _ c: Clip) -> [CaptionItem] {
        let t = Captions.track(for: c, project: m.project)
        let ids = m.captionIDs(t, clip: c)
        return t.pages.enumerated().map { k, p in
            CaptionItem(id: ids[k], start: p.start, end: p.end,
                        text: p.wordIndexes.map { t.words[$0].raw.isEmpty ? t.words[$0].text : t.words[$0].raw }.joined(separator: " "),
                        isHand: p.blockID != nil)
        }
    }

    static func findCaption(_ items: [CaptionItem], _ v: Any?) throws -> Int {
        guard !items.isEmpty else { throw ControlError("This clip has no captions.") }
        if let n = v as? NSNumber {
            let k = n.intValue - 1
            guard items.indices.contains(k) else { throw ControlError("Captions in this clip are numbered 1–\(items.count).") }
            return k
        }
        guard let s0 = v as? String, !s0.isEmpty else { throw ControlError("Say which caption: {\"caption\": number from clip_inspect (1 = first), id, or some of its text}.") }
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(s) {
            guard items.indices.contains(n - 1) else { throw ControlError("Captions in this clip are numbered 1–\(items.count).") }
            return n - 1
        }
        let low = s.lowercased()
        if let k = items.firstIndex(where: { $0.id.uuidString.lowercased() == low }) { return k }
        if low.count >= 6, let k = items.firstIndex(where: { $0.id.uuidString.lowercased().hasPrefix(low) }) { return k }
        let hits = items.indices.filter { items[$0].text.lowercased().contains(low) }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 { throw ControlError("\(hits.count) captions contain \"\(s)\" (numbers \(hits.prefix(8).map { String($0 + 1) }.joined(separator: ", "))). Use the number.") }
        throw ControlError("No caption matches \"\(s)\".")
    }

    /// Edits a clip's captions as hand-edited blocks (one Undo step), shown or not.
    static func changeCaptions(_ m: ProjectModel, _ c: Clip, _ f: (inout [CaptionBlock]) throws -> Void) rethrows {
        var blocks = m.handBlocks(c)
        try f(&blocks)
        blocks.sort { $0.start < $1.start }
        change(m, c.id) { $0.captionBlocks = blocks }
    }

    static func retype(_ blocks: inout [CaptionBlock], _ id: UUID, _ text: String, clip c: Clip) {
        guard let k = blocks.firstIndex(where: { $0.id == id }) else { return }
        let toks = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let b = blocks[k]
        if toks.isEmpty { blocks[k].words = [] }
        else if b.words.isEmpty { blocks[k].words = ProjectModel.respell(toks, over: [Word(text: "", start: b.start, end: b.end)], clip: c) }
        else { blocks[k].words = ProjectModel.respell(toks, over: b.words, clip: c) }
    }

    static func captionsResult(_ m: ProjectModel, _ id: UUID, around: UUID? = nil) -> [String: Any] {
        guard let c = m.project.clips.first(where: { $0.id == id }) else { return [:] }
        let items = captionList(m, c)
        var out: [String: Any] = ["clip": clipRef(m, id), "captionCount": items.count]
        if let a = around, let k = items.firstIndex(where: { $0.id == a }) {
            out["nearby"] = items.indices.filter { abs($0 - k) <= 1 }.map { captionDict(items, $0) }
        }
        return out
    }

    static func captionDict(_ items: [CaptionItem], _ k: Int) -> [String: Any] {
        let it = items[k]
        var d: [String: Any] = ["number": k + 1, "id": it.id.uuidString, "start": r3(it.start), "end": r3(it.end), "text": it.text]
        if it.isHand { d["handEdited"] = true }
        if it.text.isEmpty { d["noCaption"] = true }
        return d
    }

    // MARK: Style

    static func hex(_ c: RGBA) -> String {
        func b(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        let s = String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
        return c.a < 0.999 ? s + String(format: "%02X", b(c.a)) : s
    }

    static func color(_ v: Any?) throws -> RGBA? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s0 = v as? String else { throw ControlError("Colours are hex strings like \"#FFD400\" or \"#00000099\".") }
        let s = s0.trimmingCharacters(in: .whitespaces).lowercased()
        let named: [String: String] = ["white": "ffffff", "black": "000000", "yellow": "ffd400", "red": "ff3b30", "green": "34c759",
                                       "blue": "0a84ff", "orange": "ff9500", "pink": "ff2d55", "purple": "af52de", "clear": "00000000"]
        var h = named[s] ?? (s.hasPrefix("#") ? String(s.dropFirst()) : s)
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let n = UInt64(h, radix: 16) else { throw ControlError("\"\(s0)\" isn't a colour. Use hex like \"#FFD400\" (add two digits for see-through, e.g. \"#00000099\").") }
        if h.count == 6 { return RGBA(r: Double((n >> 16) & 255) / 255, g: Double((n >> 8) & 255) / 255, b: Double(n & 255) / 255) }
        return RGBA(r: Double((n >> 24) & 255) / 255, g: Double((n >> 16) & 255) / 255, b: Double((n >> 8) & 255) / 255, a: Double(n & 255) / 255)
    }

    static func styleSummary(_ s: CaptionStyle) -> [String: Any] {
        var d: [String: Any] = [
            "font": s.fontName, "fontSize": r3(s.fontSize), "mode": s.mode.rawValue, "uppercase": s.uppercase,
            "textColor": hex(s.textColor), "highlightColor": hex(s.activeColor),
            "outline": r3(s.strokeWidth), "outlineColor": hex(s.strokeColor), "shadow": s.shadow,
            "box": s.box, "boxColor": hex(s.boxColor),
            "wordBox": s.wordBoxOn, "wordBoxColor": hex(s.wordBoxRGBA), "wordBoxRound": r3(s.wordBoxRoundness), "wordBoxGlide": s.wordBoxGlides,
            "maxCharsPerLine": s.maxCharsPerLine, "maxLines": s.maxLines, "position": r3(s.positionY),
            "lineSpacing": r3(s.lineSpacing), "sideMargin": r3(s.sideMargin), "pauseBreak": r3(s.pauseBreak),
        ]
        d["modeMeans"] = s.mode.label
        if let fam = FontCatalog.family(of: s.fontName) {
            d["fontFamily"] = fam
            let ms = FontCatalog.members(fam)
            if let m = FontCatalog.member(s.fontName) { d["fontStyle"] = m.style }
            d["weights"] = ms.map { $0.style }
        }
        if let ax = FontCatalog.weightAxis(s.fontName) {
            d["weightAxis"] = [r3(ax.min), r3(ax.max)]
            d["weight"] = r3(s.fontWeight ?? FontCatalog.baseWeight(s.fontName) ?? ax.def)
        }
        return d
    }

    static func applyWeight(_ s0: CaptionStyle, _ a: Args) throws -> CaptionStyle {
        var s = s0
        guard let raw = a.str("weight")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return s }
        let fam = FontCatalog.family(of: s.fontName) ?? s.fontName
        let members = FontCatalog.members(fam)
        let axis = FontCatalog.weightAxis(s.fontName)
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if ["reset", "default", "style"].contains(key) { s.fontWeight = nil; return s }
        // a style name the family has ("Black", "ExtraBold Italic")
        if let m = members.first(where: { $0.style.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") == key }) {
            s.fontName = m.postScript; s.fontWeight = nil; return s
        }
        guard let css = Double(raw) ?? FontCatalog.cssWords[key] else {
            throw ControlError("weight \"\(raw)\" isn't a weight of \(fam). It has: " + members.map { $0.style }.joined(separator: ", ")
                               + (axis != nil ? ", or any number on its weight axis." : ". Or use 100–900 (400 regular, 700 bold, 900 black)."))
        }
        if let ax = axis {
            // variable font: a number on its own axis (most use 100–900; a few like Skia use ~0.5–3)
            var v = css
            if ax.max <= 20, css >= 100 { v = ax.min + (ax.max - ax.min) * (min(1000, max(100, css)) - 100) / 800 }
            s.fontWeight = min(ax.max, max(ax.min, v))
            return s
        }
        guard !members.isEmpty else { throw ControlError("Couldn't list the weights of \(fam).") }
        let target = FontCatalog.managerWeight(css: css)
        let italic = FontCatalog.member(s.fontName)?.italic ?? false
        let pick = members.min { x, y in
            (abs(x.weight - target) * 2 + (x.italic != italic ? 20 : 0)) < (abs(y.weight - target) * 2 + (y.italic != italic ? 20 : 0))
        }!
        s.fontName = pick.postScript; s.fontWeight = nil
        return s
    }

    static let styleHelp = "{font? (family name, e.g. \"Noto Sans\", keeps the current weight; or a PostScript name for one exact style), weight? (a style the family has like \"Black\" / \"Bold Italic\", a word thin…regular…bold…black, a number 100–900, or \"reset\"; on a variable font any value on its weight axis), fontSize? (fraction of frame width, 0.075 = default), mode? \"reveal\" (word by word) | \"highlight\" (spoken word coloured) | \"revealHighlight\" | \"line\", uppercase?, textColor?, highlightColor?, outline? (fraction of font size, 0 = none, 0.12 = thick), outlineColor?, shadow?, box? (box behind the lines), boxColor?, wordBox? (box behind the spoken word), wordBoxColor?, wordBoxRound? (0 square–1 pill), wordBoxGlide? (true = the box springs from word to word, false = it jumps), maxCharsPerLine?, maxLines?, position? (0 top–1 bottom, centre of the captions), lineSpacing?, sideMargin?, pauseBreak? (seconds of silence that start a new caption)}. Colours are hex \"#RRGGBB\" or \"#RRGGBBAA\". Applies to every clip in the project."

    static func applyStyle(_ s0: CaptionStyle, _ a: Args) throws -> CaptionStyle {
        var s = s0
        if let f = a.str("font") {
            guard NSFont(name: f, size: 12) != nil || !(NSFontManager.shared.availableMembers(ofFontFamily: f) ?? []).isEmpty else {
                let ok = CaptionStyleSheet.fonts.filter { NSFont(name: $0, size: 12) != nil }
                throw ControlError("No font \"\(f)\" on this Mac. Some that are: " + ok.joined(separator: ", ") + ".")
            }
            let lower = f.lowercased()
            if let fam = FontCatalog.families.first(where: { $0.lowercased() == lower }),
               let m = FontCatalog.closestMember(in: fam, to: s0.fontName) {
                s.fontName = m.postScript            // a family name: keep the current weight as near as it has
            } else {
                s.fontName = NSFont(name: f, size: 12) != nil ? f : (NSFontManager.shared.availableMembers(ofFontFamily: f)?.first?.first as? String ?? f)
            }
            s.fontWeight = nil
        }
        if a.has("weight") { s = try applyWeight(s, a) }
        if let v = a.num("fontSize") { s.fontSize = min(0.2, max(0.02, v > 1 ? v / 100 : v)) }
        if let m = a.str("mode") {
            let k = m.lowercased().replacingOccurrences(of: " ", with: "")
            switch k {
            case "reveal", "wordbyword": s.mode = .reveal
            case "highlight", "karaoke": s.mode = .highlight
            case "revealhighlight", "wordbyword+highlight": s.mode = .revealHighlight
            case "line", "wholeline": s.mode = .line
            default: throw ControlError("mode is reveal, highlight, revealHighlight or line.")
            }
        }
        if let v = a.bool("uppercase") { s.uppercase = v }
        if let c = try color(a.d["textColor"]) { s.textColor = c }
        if let c = try color(a.d["highlightColor"] ?? a.d["activeColor"]) { s.activeColor = c }
        if let v = a.num("outline") { s.strokeWidth = min(0.4, max(0, v)) }
        if let c = try color(a.d["outlineColor"]) { s.strokeColor = c }
        if let v = a.bool("shadow") { s.shadow = v }
        if let v = a.bool("box") { s.box = v }
        if let c = try color(a.d["boxColor"]) { s.boxColor = c }
        if let v = a.bool("wordBox") { s.wordBox = v }
        if let c = try color(a.d["wordBoxColor"]) { s.wordBoxColor = c }
        if let v = a.num("wordBoxRound") { s.wordBoxRound = min(1, max(0, v)) }
        if let v = a.bool("wordBoxGlide") { s.wordBoxGlide = v }
        if let v = a.num("maxCharsPerLine") { s.maxCharsPerLine = min(60, max(4, Int(v.rounded()))) }
        if let v = a.num("maxLines") { s.maxLines = min(4, max(1, Int(v.rounded()))) }
        if let v = a.num("position") { s.positionY = min(0.95, max(0.05, v)) }
        if let v = a.num("lineSpacing") { s.lineSpacing = min(2.5, max(0.8, v)) }
        if let v = a.num("sideMargin") { s.sideMargin = min(0.3, max(0, v)) }
        if let v = a.num("pauseBreak") { s.pauseBreak = min(5, max(0.1, v)) }
        return s
    }

    static func allPresets() -> [CaptionPreset] {
        Store.loadPresets().presets + CaptionStyleSheet.builtIns
    }

    // MARK: Fix a word everywhere

    /// Same words (ignoring case and punctuation) → new words, keeping each place's own outer punctuation.
    static func replaceRuns(_ words: [Word], key: [String], with core: [String], spreadOver: ([String], [Word]) -> [Word]) -> (words: [Word], count: Int) {
        let n = key.count
        guard n > 0, words.count >= n else { return (words, 0) }
        let normed = words.map { ProjectModel.norm($0.text) }
        var out: [Word] = []
        var i = 0, count = 0
        while i < words.count {
            if i + n <= words.count, Array(normed[i..<(i + n)]) == key {
                let old = Array(words[i..<(i + n)])
                var toks = core
                if !toks.isEmpty {
                    toks[0] = ProjectModel.splitPunct(old.first!.text).lead + toks[0]
                    toks[toks.count - 1] += ProjectModel.splitPunct(old.last!.text).trail
                }
                out += toks.isEmpty ? [] : spreadOver(toks, old)
                i += n; count += 1
            } else { out.append(words[i]); i += 1 }
        }
        return (out, count)
    }

    // MARK: Commands

    static let captionCommands: [ControlCommand] = [
        ControlCommand(id: "caption.setText", label: "Retype a Caption", menu: "Captions panel (type in a row)", key: "Return / E", changesProject: true,
                       params: "{clip?, caption: number from clip_inspect | id | some of its text, text}. Same number of words keeps each word's timing; empty text = no caption there.",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let items = captionList(m, c)
            let k = try findCaption(items, a.d["caption"])
            guard let text = a.str("text") else { throw ControlError("Pass {\"text\": \"…\"}.") }
            let id = items[k].id
            changeCaptions(m, c) { retype(&$0, id, text, clip: c) }
            return captionsResult(m, c.id, around: id)
        }),
        ControlCommand(id: "caption.setTexts", label: "Retype Several Captions", menu: "Captions panel", changesProject: true,
                       params: "{clip?, captions: [{caption, text}, …]} — one Undo step. Numbers refer to the list before the change.",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            guard let list = a.d["captions"] as? [[String: Any]], !list.isEmpty else { throw ControlError("Pass {\"captions\": [{\"caption\": 3, \"text\": \"…\"}, …]}.") }
            let items = captionList(m, c)
            var plan: [(UUID, String)] = []
            for item in list {
                let k = try findCaption(items, item["caption"])
                guard let t = item["text"] as? String else { throw ControlError("Each entry needs \"text\".") }
                plan.append((items[k].id, t))
            }
            changeCaptions(m, c) { blocks in for (id, t) in plan { retype(&blocks, id, t, clip: c) } }
            return ["changed": plan.count, "clip": clipRef(m, c.id)] as [String: Any]
        }),
        ControlCommand(id: "caption.delete", label: "Delete a Caption", menu: "Timeline ▸ caption ▸ right-click ▸ Delete", key: "Delete", changesProject: true,
                       params: "{clip?, caption} (leaves no caption at that moment)",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let items = captionList(m, c)
            let k = try findCaption(items, a.d["caption"])
            let id = items[k].id
            changeCaptions(m, c) { retype(&$0, id, "", clip: c) }
            return captionsResult(m, c.id, around: id)
        }),
        ControlCommand(id: "caption.split", label: "Split a Caption", menu: "Timeline ▸ caption ▸ right-click ▸ Split", changesProject: true,
                       params: "{clip?, caption, afterWord: n (split after its nth word) | at: seconds into the clip}",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let items = captionList(m, c)
            let k = try findCaption(items, a.d["caption"])
            let id = items[k].id
            try changeCaptions(m, c) { blocks in
                guard let bk = blocks.firstIndex(where: { $0.id == id }) else { throw ControlError("Couldn't find that caption.") }
                let b = blocks[bk]
                let ws = b.words.sorted { $0.start < $1.start }
                let mid: Double
                if let n0 = a.num("afterWord") {
                    let n = Int(n0)
                    guard n >= 1, n < ws.count else { throw ControlError("That caption has \(ws.count) words; afterWord runs 1–\(max(1, ws.count - 1)).") }
                    mid = (ws[n - 1].end + ws[n].start) / 2
                } else if let t = a.num("at") {
                    mid = c.masterTime(forOutput: t)
                } else { throw ControlError("Pass afterWord (e.g. 3) or at (seconds into the clip).") }
                guard mid > b.start + 0.05, mid < b.end - 0.05 else { throw ControlError("That point isn't inside the caption.") }
                var left = b, right = b
                left.words = b.words.filter { ($0.start + $0.end) / 2 < mid }
                right.words = b.words.filter { ($0.start + $0.end) / 2 >= mid }
                left.end = mid; right.start = mid
                right.id = UUID()
                if let cv = b.covers {
                    left.covers = TimeRange(start: cv.start, end: min(cv.end, mid))
                    right.covers = TimeRange(start: max(cv.start, mid), end: cv.end)
                }
                blocks[bk] = left
                blocks.insert(right, at: bk + 1)
            }
            return captionsResult(m, c.id, around: id)
        }),
        ControlCommand(id: "caption.join", label: "Join a Caption with the Next", menu: "Timeline ▸ caption ▸ right-click ▸ Join", changesProject: true,
                       params: "{clip?, caption} (joins it with the caption after it)",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let items = captionList(m, c)
            let k = try findCaption(items, a.d["caption"])
            guard k + 1 < items.count else { throw ControlError("That's the last caption; there's nothing after it to join.") }
            let id = items[k].id, nextID = items[k + 1].id
            changeCaptions(m, c) { blocks in
                guard let x = blocks.firstIndex(where: { $0.id == id }), let y = blocks.firstIndex(where: { $0.id == nextID }) else { return }
                blocks[x].words += blocks[y].words
                blocks[x].end = max(blocks[x].end, blocks[y].end)
                if let ca = blocks[x].covers, let cb = blocks[y].covers {
                    blocks[x].covers = TimeRange(start: min(ca.start, cb.start), end: max(ca.end, cb.end))
                } else { blocks[x].covers = blocks[x].covers ?? blocks[y].covers }
                blocks.remove(at: y)
            }
            return captionsResult(m, c.id, around: id)
        }),
        ControlCommand(id: "caption.retime", label: "Move / Re-time a Caption", menu: "Timeline (drag a caption or its edges)", changesProject: true,
                       params: "{clip?, caption, start?, end?: seconds into the clip; or by?: seconds to move it (negative = earlier)}. Neighbours give way down to 0.3 s.",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            let items = captionList(m, c)
            let k = try findCaption(items, a.d["caption"])
            let id = items[k].id
            guard a.has("start") || a.has("end") || a.has("by") else { throw ControlError("Pass start and/or end (seconds into the clip), or by.") }
            try changeCaptions(m, c) { blocks in
                guard let bk = blocks.firstIndex(where: { $0.id == id }) else { throw ControlError("Couldn't find that caption.") }
                func out(_ x: Double) -> Double { c.outputTimeClamped(forMaster: x) }
                let b = blocks[bk]
                let os = out(b.start), oe = out(b.end), by = a.num("by") ?? 0
                var ns = a.num("start") ?? (os + by), ne = a.num("end") ?? (oe + by)
                let prev = bk > 0 ? blocks[bk - 1] : nil
                let next = bk + 1 < blocks.count ? blocks[bk + 1] : nil
                let lo = prev.map { min(os, out($0.start) + 0.3) } ?? 0
                let hi = next.map { max(oe, out($0.end) - 0.3) } ?? max(oe, c.outputDuration)
                ns = max(lo, ns); ne = min(hi, ne)
                guard ne > ns + 0.2 else { throw ControlError("That leaves the caption too short (or it runs into its neighbours).") }
                blocks[bk] = ProjectModel.remap(b, clip: c, toOutput: ns, ne)
                if let p = prev, ns < out(p.end) - 1e-6 { blocks[bk - 1] = ProjectModel.remap(p, clip: c, toOutput: out(p.start), ns) }
                if let n = next, ne > out(n.start) + 1e-6 { blocks[bk + 1] = ProjectModel.remap(n, clip: c, toOutput: ne, out(n.end)) }
            }
            return captionsResult(m, c.id, around: id)
        }),
        ControlCommand(id: "caption.reset", label: "Reset Captions to the Transcript", menu: "Captions panel ▸ ··· ▸ Reset", changesProject: true,
                       params: "{clip?} (drops every hand edit in this clip's captions)",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            guard c.captionBlocks != nil else { return "\"\(c.title)\" already has automatic captions." }
            change(m, c.id) { $0.captionBlocks = nil }
            return "\"\(c.title)\" has automatic captions again (edit.undo brings the edits back)."
        }),
        ControlCommand(id: "text.replace", label: "Fix a Word Everywhere", menu: "Transcript ▸ Fix Transcript Text… (everywhere)", changesProject: true,
                       params: "{find: \"you tube\", replace: \"YouTube\"} — fixes every place in the transcript (so every automatic caption) and in every hand-edited caption, ignoring case and punctuation. One Undo step.",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            guard let find = a.str("find"), let rep = a.str("replace") else { throw ControlError("Pass {\"find\": …, \"replace\": …}.") }
            let key = find.split(whereSeparator: { $0.isWhitespace }).map { ProjectModel.norm(String($0)) }.filter { !$0.isEmpty }
            guard !key.isEmpty else { throw ControlError("Nothing to find.") }
            var core = rep.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if !core.isEmpty {
                let p0 = ProjectModel.splitPunct(core[0])
                core[0] = core.count == 1 ? p0.core : p0.core + p0.trail
                if core.count > 1 { let pl = ProjectModel.splitPunct(core[core.count - 1]); core[core.count - 1] = pl.lead + pl.core }
                core = core.filter { !$0.isEmpty }
            }
            let t = replaceRuns(m.project.words, key: key, with: core, spreadOver: { ProjectModel.spread($0, over: $1) })
            var blockCount = 0
            var newClips = m.project.clips
            for ci in newClips.indices {
                guard var blocks = newClips[ci].captionBlocks else { continue }
                let clip = newClips[ci]
                for bi in blocks.indices {
                    let r = replaceRuns(blocks[bi].words, key: key, with: core, spreadOver: { ProjectModel.respell($0, over: $1, clip: clip) })
                    if r.count > 0 { blocks[bi].words = r.words; blockCount += r.count }
                }
                newClips[ci].captionBlocks = blocks
            }
            guard t.count + blockCount > 0 else { throw ControlError("\"\(find)\" isn't in the transcript or any caption.") }
            m.edit { p in
                p.words = t.words
                p.clips = newClips
            }
            m.transcriptVersion += 1
            return "Fixed \(t.count) place\(t.count == 1 ? "" : "s") in the transcript and \(blockCount) in hand-edited captions."
        }),
        ControlCommand(id: "caption.burnIn", label: "Burn Captions into the Video", menu: "Export window ▸ checkbox", changesProject: true,
                       params: "{clip?, on: true | false} (captions always show in the viewer; this decides the exported video)",
                       enabled: { hasClips($0) },
                       run: { app, a in
            let m = try model(app)
            let c = try targetClip(m, a)
            guard let on = a.bool("on") else { throw ControlError("Pass {\"on\": true} or false.") }
            change(m, c.id, rebuild: false) { $0.captions = on }
            return "\"\(c.title)\": captions \(on ? "will" : "won't") be burned into the export."
        }),
        ControlCommand(id: "caption.style", label: "Caption Style", menu: "Captions panel ▸ Style…", changesProject: true,
                       params: styleHelp,
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let s = try applyStyle(m.project.captionStyle, a)
            m.edit { $0.captionStyle = s }
            return ["style": styleSummary(s)] as [String: Any]
        }),
        ControlCommand(id: "caption.presets", label: "List Caption Presets", menu: "Captions panel ▸ Look",
                       enabled: { _ in true },
                       run: { _, _ in
            let f = Store.loadPresets()
            return ["yours": f.presets.map { $0.name }, "builtIn": CaptionStyleSheet.builtIns.map { $0.name },
                    "defaultForNewProjects": f.defaultName ?? "built-in default"] as [String: Any]
        }),
        ControlCommand(id: "caption.applyPreset", label: "Use a Caption Preset", menu: "Captions panel ▸ Look", changesProject: true,
                       params: "{name} (see caption.presets)",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            let n = (a.str("name") ?? "").lowercased()
            let all = allPresets()
            let hits = all.filter { $0.name.lowercased().contains(n) }
            let pick: CaptionPreset? = all.first(where: { $0.name.lowercased() == n }) ?? (hits.count == 1 ? hits[0] : nil)
            guard !n.isEmpty, let p = pick else { throw ControlError("No preset \"\(a.str("name") ?? "")\". Presets: " + allPresets().map { $0.name }.joined(separator: ", ")) }
            m.edit { $0.captionStyle = p.style }
            return ["applied": p.name, "style": styleSummary(p.style)] as [String: Any]
        }),
        ControlCommand(id: "caption.savePreset", label: "Save Caption Preset", menu: "Style… ▸ Save as Preset", changesProject: false,
                       params: "{name, makeDefault?: true = new projects start with it} (saves the open project's current style; shared by all projects)",
                       enabled: { hasProject($0) },
                       run: { app, a in
            let m = try model(app)
            guard let n = a.str("name")?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { throw ControlError("Pass {\"name\": \"…\"}.") }
            var f = Store.loadPresets()
            f.presets.removeAll { $0.name == n }
            f.presets.append(CaptionPreset(name: n, style: m.project.captionStyle))
            f.presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if a.bool("makeDefault") == true { f.defaultName = n }
            Store.savePresets(f)
            return "Saved preset \"\(n)\"" + (a.bool("makeDefault") == true ? " and made it the default for new projects." : ".")
        }),
    ]
}
