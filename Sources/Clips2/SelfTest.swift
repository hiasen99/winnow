import Foundation
import AVFoundation
import QuartzCore

/// Headless end-to-end check:  Clips2 --selftest <outdir> <cameraA> <cameraB>
@MainActor
enum SelfTest {
    static func log(_ s: String) { print(s); fflush(stdout) }

    /// Clips2 --synctest <project folder>: pairwise sync report from the cached envelopes.
    static func syncReport(folder: URL) -> Int32 {
        guard let p = try? Store.load(folder) else { log("can't load"); return 1 }
        let envs = p.angles.indices.map { Store.loadEnvelope(folder: folder, angle: $0) }
        for (i, a) in p.angles.enumerated() { log("[\(i)] \(a.name) \(a.isVideo ? "video" : "audio") dur \(Int(a.duration)) env \(envs[i]?.count ?? 0) current offset \(String(format: "%.3f", a.offset))") }
        for i in p.angles.indices { for j in p.angles.indices where j > i {
            if let a = envs[i], let b = envs[j], let c = AudioAnalysis.coarse(a, b) {
                let d = AudioAnalysis.drift(a, b, offset: c.offset)
                log(String(format: "pair %d-%d  rel %+.2f s  conf %.2f  drift %.2f s", i, j, c.offset, c.confidence, d))
            }
        }}
        let root = p.videoIndices.first { envs[$0] != nil } ?? 0
        let plan = AudioAnalysis.solve(envelopes: envs, root: root)
        for i in p.angles.indices {
            log("plan [\(i)] offset \(plan.offsets[i].map { String(format: "%.3f", $0) } ?? "—") via \(plan.partner[i].map(String.init) ?? "-") conf \(plan.confidence[i].map { String(format: "%.2f", $0) } ?? "-")")
        }
        return 0
    }

    /// Clips2 --resynctest <project folder COPY>: runs Re-sync on it and prints the result.
    static func resyncTest(folder: URL) async -> Int32 {
        do {
            let m = try ProjectModel(folder: folder)
            await m.open()
            let t0 = Date()
            await m.resync()
            if let e = m.errorText { log("ERROR: \(e)"); return 1 }
            log("resync took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            for a in m.project.angles {
                log("\(a.name): offset \(String(format: "%.3f", a.offset)) with \(a.syncedWith ?? "(reference)") score \(a.syncScore.map { String(format: "%.1f", $0) } ?? "-") drift \(a.syncDrift.map { String(format: "%.3f", $0) } ?? "-") failed \(a.syncFailed)")
            }
            log("notice: \(m.notice ?? "")")
            log("words \(m.project.words.count) speakers \(m.project.speakers.map { "\($0.name)->\(m.project.angles[$0.angle].name)" })")
            var line = "", spk = -1, lines = 0
            for w in m.project.words {
                if w.speaker != spk {
                    if !line.isEmpty { log(String(line.prefix(140))); lines += 1; if lines > 14 { break } }
                    spk = w.speaker; line = "[S\(spk + 1) \(fmtTime(w.start))] "
                }
                line += w.text + " "
            }
            return 0
        } catch { log("FAILED \(error)"); return 1 }
    }

    static func run(files: [URL]) async -> Int32 {
        guard files.count >= 2 else { log("usage: --selftest outdir files…"); return 2 }
        let outDir = files[0]
        let all = Array(files.dropFirst())
        let plusAt = all.firstIndex { $0.lastPathComponent == "+" }
        let media = plusAt.map { Array(all[..<$0]) } ?? all
        let later = plusAt.map { Array(all[($0 + 1)...]) } ?? []
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        do {
            let t0 = Date()
            let folder = try Store.create(name: "selftest", files: media)
            let m = try ProjectModel(folder: folder)
            await m.open()
            if let e = m.errorText { log("ERROR: \(e)"); return 1 }
            if !later.isEmpty {
                log("before adding: speakers \(m.project.speakers.count), words \(m.project.words.count)")
                // a clip made before adding, to check it survives
                _ = m.addIdeas([ClipIdea(title: "early", start: 12, end: 19)])
                await m.addFiles(later)
                if let e = m.errorText { log("ERROR adding: \(e)"); return 1 }
                log("after adding: \(m.notice ?? "")")
                log("early clip audio: \(m.project.clips[0].audio.on)  ranges \(m.project.clips[0].ranges)")
            }
            let p = m.project
            log("analysis took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            for a in p.angles {
                log("source \(a.name) video=\(a.isVideo): dur \(String(format: "%.2f", a.duration)) offset \(String(format: "%.4f", a.offset)) size \(Int(a.width))x\(Int(a.height)) fps \(a.fps) audio \(a.hasAudio) gain \(String(format: "%.1f", a.gainDB))")
            }
            log("sync confidence: \(p.syncConfidence.map { String(format: "%.2f", $0) } ?? "-")")
            log("words: \(p.words.count), speakers: \(p.speakers.count)")
            var line = "", spk = -1
            for w in p.words {
                if w.speaker != spk { if !line.isEmpty { log(line) }; spk = w.speaker; line = "[S\(spk + 1) \(String(format: "%.2f", w.start))] " }
                line += w.text + " "
            }
            log(line)
            log("auto schedule:")
            for s in m.auto { log(String(format: "  %.2f–%.2f  angle %d", s.start, s.end, s.angle)) }

            // a clip with a removed word, a manual cut, captions, 9:16
            guard p.words.count > 20 else { log("too few words"); return 1 }
            let ideas = ClipFinder.parse("""
            {"clips":[{"title":"Selftest clip","start":\(p.words[0].start),"end":\(p.words[min(p.words.count - 1, 45)].end),"why":"test","score":7}]}
            """)
            log("parsed ideas: \(ideas.count)")
            let added = m.addIdeas(ideas)
            log("added clips: \(added)")
            m.selection = 3...4
            m.cutSelection()
            // a sound change partway through: Mic/source 2 only for words 10..20
            if m.project.angles.filter({ $0.hasAudio }).count > 1 {
                m.selection = 10...20
                m.audioPreset(m.project.speechIndices.last ?? 1)
                m.selection = nil
                let sc = m.selectedClip!
                log("sound segments: " + sc.soundSegments().map { String(format: "%.2f–%.2f ", $0.start, $0.end) + soundLabel(m.project, $0.on) }.joined(separator: " | "))
            }
            let c = m.selectedClip!
            log("clip ranges: \(c.ranges.map { String(format: "%.2f–%.2f", $0.start, $0.end) })  output \(String(format: "%.2f", c.outputDuration))s")
            let pieces = Schedule.pieces(project: m.project, clip: c, auto: m.auto)
            for pc in pieces { log(String(format: "  piece out %.2f  master %.2f  dur %.2f  angle %d", pc.outStart, pc.masterStart, pc.duration, pc.angle)) }
            log("player duration: \(String(format: "%.2f", m.engine.duration))")

            let lines = ClipFinder.parseLines("0:05 - 0:20 First idea\n1:02.5 – 1:30 Second one")
            log("timestamp lines parsed: \(lines.map { "\($0.start)-\($0.end) \($0.title)" })")
            for idea in ClipFinder.parseLines("0:12 - 0:19 a\n0:28.4 - 0:32.3 b\n0:20 - 0:27 c") {
                let (a, b) = ClipFinder.snap(idea, words: m.project.words)
                let ws = m.project.words.filter { $0.start >= a && $0.end <= b }
                log(String(format: "snap %.1f-%.1f -> %.2f-%.2f  ", idea.start, idea.end, a, b) + "\(ws.first?.text ?? "") … \(ws.last?.text ?? "")")
            }
            let prompt = ClipFinder.prompt(m.project, count: 3, minLen: 10, maxLen: 40, guidance: "")
            try prompt.write(to: outDir.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)

            let url = outDir.appendingPathComponent("selftest-clip.mp4")
            let t1 = Date()
            try await Exporter.export(project: m.project, clip: c, auto: m.auto, loaded: m.loaded, to: url) { _ in }
            log("export took \(String(format: "%.1f", Date().timeIntervalSince(t1)))s -> \(url.path)")
            var bs = m.project.captionStyle; bs.wordBox = true; bs.wordBoxColor = RGBA(r: 1, g: 0.83, b: 0); bs.activeColor = .black; bs.mode = .highlight
            m.setCaptionStyle(bs)
            var h = c; h.format = .horizontal; h.captions = true; h.switches = [AngleSwitch(time: c.start + 4, angle: 1)]
            try await Exporter.export(project: m.project, clip: h, auto: m.auto, loaded: m.loaded,
                                      to: outDir.appendingPathComponent("selftest-169.mp4")) { _ in }
            log("exported 16:9 version")
            try await Exporter.exportAudio(project: m.project, clip: c, auto: m.auto, loaded: m.loaded,
                                           to: outDir.appendingPathComponent("selftest-audio.m4a"), wav: false) { _ in }
            try await Exporter.exportAudio(project: m.project, clip: c, auto: m.auto, loaded: m.loaded,
                                           to: outDir.appendingPathComponent("selftest-audio.wav"), wav: true) { _ in }
            log("exported audio m4a + wav")
            // timeline selection cut + pause shortening
            let d0 = m.selectedClip!.outputDuration
            m.tlSel = 1.0...1.5
            m.cutTimelineSelection()
            let d1 = m.selectedClip!.outputDuration
            m.shortenPauses(over: 0.4, keep: 0.15)
            let d2 = m.selectedClip!.outputDuration
            log(String(format: "timeline cut: %.2f -> %.2f (−0.5 expected), pauses: -> %.2f  [%@]", d0, d1, d2, m.notice ?? ""))
            // --- new editing features ---
            do {
                let cc = m.selectedClip!
                let segs = cc.segments
                log("segments: \(segs.count) ranges: \(cc.ranges.count)")
                // drag the end of the first block 0.3 s later (into the cut) and the start of the last block 0.2 s later
                let ext = m.trimmed(cc, segments: segs, edge: TrimEdge(segment: 0, side: .end), to: segs[0].master.end + 0.3)
                log(String(format: "trim first block end +0.3: %.2f -> %.2f", cc.outputDuration, ext.outputDuration))
                let shr = m.trimmed(cc, segments: segs, edge: TrimEdge(segment: segs.count - 1, side: .start), to: segs[segs.count - 1].master.start + 0.2)
                log(String(format: "trim last block start +0.2: %.2f -> %.2f", cc.outputDuration, shr.outputDuration))
                // pull the clip end out past its end (extend)
                let ext2 = m.trimmed(cc, segments: segs, edge: TrimEdge(segment: segs.count - 1, side: .end), to: cc.end + 1.0)
                log(String(format: "extend clip end +1.0: %.2f -> %.2f", cc.outputDuration, ext2.outputDuration))
                // blade at 2 s, then delete the block after it
                m.engine.seek(2.0)
                m.bladeAtPlayhead()
                let bc = m.selectedClip!
                log("after blade: segments \(bc.segments.count) splits \(bc.splits ?? [])")
                let d3 = bc.outputDuration
                m.selectSegment(atOutput: 2.5)
                let blk = m.tlSel
                m.cutTimelineSelection()
                log(String(format: "deleted block %@: %.2f -> %.2f", blk.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "nil", d3, m.selectedClip!.outputDuration))
                m.undo()
                log(String(format: "undo: %.2f", m.selectedClip!.outputDuration))
                // live trim through the gesture API = one undo step
                let before = m.selectedClip!.outputDuration
                let ks = m.selectedClip!.segments
                m.beginTrim(TrimEdge(segment: ks.count - 1, side: .end), x: 100, secondsPerPixel: 0.01)
                m.updateTrim(x: 80); m.updateTrim(x: 60); m.updateTrim(x: 50)
                m.endTrim()
                let after = m.selectedClip!.outputDuration
                m.undo()
                log(String(format: "gesture trim: %.2f -> %.2f, one undo -> %.2f", before, after, m.selectedClip!.outputDuration))
                // transcript fixes
                let w5 = m.project.words[5].text
                let n5 = m.occurrences(of: 5...5).count
                m.correctWords(5...5, to: "FIXED", everywhere: false)
                log("fix one word: '\(w5)' -> '\(m.project.words[5].text)' (heard \(n5)x)")
                m.undo()
                let wc = m.project.words.count
                m.correctWords(7...7, to: "two words", everywhere: false)
                log("split word: count \(wc) -> \(m.project.words.count), '\(m.project.words[7].text)' '\(m.project.words[8].text)' \(String(format: "%.2f-%.2f %.2f-%.2f", m.project.words[7].start, m.project.words[7].end, m.project.words[8].start, m.project.words[8].end))")
                m.undo()
                let the = m.project.words.firstIndex { ProjectModel.norm($0.text) == "the" } ?? 0
                let nThe = m.occurrences(of: the...the).count
                m.correctWords(the...the, to: "THEE", everywhere: true)
                log("replace everywhere: \(nThe) places, now \(m.project.words.filter { ProjectModel.norm($0.text) == "thee" }.count) THEE; notice \(m.notice ?? "")")
                m.undo()
                // hiding words: the clip keeps its length, captions lose the word, survives a save / load
                let hc = m.selectedClip!
                let capBefore = Captions.words(for: hc, project: m.project, uppercase: false).count
                let hi = m.project.words.firstIndex { hc.outputTime(forMaster: ($0.start + $0.end) / 2) != nil } ?? 0
                m.setHidden(hi...hi, true)
                let capAfter = Captions.words(for: m.selectedClip!, project: m.project, uppercase: false).count
                let hback = try Store.decoder.decode(Project.self, from: Store.encoder.encode(m.project))
                log(String(format: "hide word '%@': captions %d -> %d, clip %.2f -> %.2f, hidden after reload %@, finder text has it %@",
                           m.project.words[hi].text, capBefore, capAfter, hc.outputDuration, m.selectedClip!.outputDuration,
                           hback.words[hi].isHidden ? "yes" : "no",
                           ClipFinder.transcriptLines(m.project).contains(m.project.words[hi].text) ? "maybe (same word elsewhere)" : "no"))
                m.setHidden(hi...hi, false)
                log("unhide: hidden count \(m.hiddenWordCount), captions \(Captions.words(for: m.selectedClip!, project: m.project, uppercase: false).count)")
                m.undo(); m.undo()
                let theH = m.project.words.firstIndex { ProjectModel.norm($0.text) == "the" } ?? 0
                m.setHidden(theH...theH, true, everywhere: true)
                log("hide everywhere: \(m.hiddenWordCount) hidden, \(m.project.words.count) words kept; notice \(m.notice ?? "")")
                m.undo()
                log("after undo: \(m.hiddenWordCount) hidden")
                // review marks + markers survive a save / load
                m.toggleStatus(.used)
                m.addMarker()
                let data = try Store.encoder.encode(m.project)
                let back = try Store.decoder.decode(Project.self, from: data)
                log("status after reload: \(back.clips.first { $0.id == m.selectedClipID }?.status?.rawValue ?? "nil"), markers \(back.markers?.count ?? 0)")
                // an old project file (no new keys) still loads
                var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                obj["markers"] = nil
                if var cl = obj["clips"] as? [[String: Any]] { for k in cl.indices { cl[k]["status"] = nil; cl[k]["splits"] = nil }; obj["clips"] = cl }
                let old = try Store.decoder.decode(Project.self, from: JSONSerialization.data(withJSONObject: obj))
                log("old-format project loads: \(old.clips.count) clips")
                m.toggleStatus(.used)
                let lim = m.framingLimits(angle: 0, format: .vertical, zoom: 1)
                log(String(format: "framing limits 9:16 zoom 1: x %.3f-%.3f y %.3f-%.3f", lim.x.lowerBound, lim.x.upperBound, lim.y.lowerBound, lim.y.upperBound))
                // --- captions edited by hand ---
                do {
                    func capLine(_ tag: String) {
                        let its = m.captionItems
                        let ids = Set(its.map { $0.id })
                        log("\(tag): \(its.count) captions (unique ids \(ids.count == its.count ? "yes" : "NO")), hand \(its.filter { $0.isHand }.count), blocks \(m.selectedClip?.captionBlocks?.count ?? 0)")
                    }
                    capLine("captions auto")
                    let items0 = m.captionItems
                    guard items0.count >= 2 else { throw ClipsError("selftest: need 2+ captions, got \(items0.count)") }
                    let first = items0[0]
                    // retype the first caption: becomes hand-made, the others keep their text and ids
                    m.setCaptionText(first.id, "Hello there friend")
                    let a1 = m.captionItems
                    log("retype: '\(a1.first { $0.id == first.id }?.text ?? "?")', second same id+text \(a1.count > 1 && a1[1].id == items0[1].id && a1[1].text == items0[1].text ? "yes" : "no")")
                    capLine("after retype")
                    // the preview + .srt use it
                    let srt1 = Captions.srt(Captions.track(for: m.selectedClip!, project: m.project))
                    log("srt has new text: \(srt1.contains("Hello there friend") ? "yes" : "no")")
                    // split it at its middle, join it back
                    let it1 = m.captionItems.first { $0.id == first.id }!
                    m.splitCaption(first.id, atOutput: (it1.start + it1.end) / 2)
                    capLine("after split")
                    m.joinCaptionWithNext(first.id)
                    capLine("after join")
                    log("joined text: '\(m.captionItems.first { $0.id == first.id }?.text ?? "?")'")
                    // move the second caption later by 0.2 s with a drag (one undo step); its words don't get an extra caption
                    let second = m.captionItems[1]
                    let n0 = m.captionItems.count
                    let wasSnapping = m.snapping; m.snapping = false
                    m.beginCaptionDrag(second.id, mode: .move, atOutput: second.start + 0.05)
                    m.updateCaptionDrag(toOutput: second.start + 0.15, spp: 0.01)
                    m.updateCaptionDrag(toOutput: second.start + 0.25, spp: 0.01)
                    m.endCaptionDrag()
                    let moved = m.captionItems.first { $0.id == second.id }
                    log(String(format: "move: %.2f -> %.2f (+0.2 expected unless blocked by the next caption), captions %d -> %d", second.start, moved?.start ?? -1, n0, m.captionItems.count))
                    // drag its end edge 0.3 s earlier
                    let mv = m.captionItems.first { $0.id == second.id }!
                    m.beginCaptionDrag(second.id, mode: .end, atOutput: mv.end)
                    m.updateCaptionDrag(toOutput: mv.end - 0.3, spp: 0.01)
                    m.endCaptionDrag()
                    let tr = m.captionItems.first { $0.id == second.id }!
                    log(String(format: "trim end: %.2f -> %.2f", mv.end, tr.end))
                    m.undo()
                    log(String(format: "undo trim: end %.2f", m.captionItems.first { $0.id == second.id }?.end ?? -1))
                    m.snapping = wasSnapping
                    // delete a caption: it stays as an empty "no caption" block, the transcript doesn't fill it back in
                    m.deleteCaption(second.id)
                    let del = m.captionItems.first { $0.id == second.id }
                    let srt2 = Captions.srt(Captions.track(for: m.selectedClip!, project: m.project))
                    log("delete: text '\(del?.text ?? "gone")', srt entries \(srt2.components(separatedBy: " --> ").count - 1) of \(m.captionItems.count) captions")
                    // make the clip longer: the new words get automatic captions
                    let before = m.captionItems.count
                    let segsL = m.selectedClip!.segments
                    let longer = m.trimmed(m.selectedClip!, segments: segsL, edge: TrimEdge(segment: segsL.count - 1, side: .end), to: m.selectedClip!.end + 3)
                    m.updateClip { $0 = longer }
                    capLine("clip 3 s longer (was \(before))")
                    // survives save / load
                    let back = try Store.decoder.decode(Project.self, from: Store.encoder.encode(m.project))
                    log("caption blocks after reload: \(back.clips.first { $0.id == m.selectedClipID }?.captionBlocks?.count ?? 0)")
                    // reset to automatic, then undo brings the edits back
                    m.resetCaptions()
                    capLine("reset")
                    m.undo()
                    capLine("undo reset")
                    // export with hand-made captions
                    let lay = Captions.makeLayer(Captions.track(for: m.selectedClip!, project: m.project), style: m.project.captionStyle,
                                                 renderSize: m.selectedClip!.format.renderSize, total: m.selectedClip!.outputDuration)
                    log("caption layer pages: \(lay.sublayers?.count ?? 0)")
                    // a camera with its own caption height
                    let ang = m.project.videoIndices.first ?? 0
                    m.updateClip { c in
                        while c.framing.count <= ang { c.framing.append(Framing()) }
                        c.framing[ang].captionY = 0.3
                    }
                    let trc = Captions.track(for: m.selectedClip!, project: m.project)
                    let pcs = Schedule.pieces(project: m.project, clip: m.selectedClip!, auto: m.auto)
                    log("camera caption height: \(trc.pages.filter { $0.positionY == 0.3 }.count) of \(trc.pages.count) captions at 0.3; cameras \(Set(pcs.map { $0.angle }).sorted())")
                    let back2 = try Store.decoder.decode(Project.self, from: Store.encoder.encode(m.project))
                    log("caption height after reload: \(back2.clips.first { $0.id == m.selectedClipID }?.framing(for: ang).captionY ?? -1)")
                    m.undo()
                    log("after undo: \(Captions.track(for: m.selectedClip!, project: m.project).pages.filter { $0.positionY != nil }.count) captions with a camera height")
                    m.undo(); m.undo(); m.undo(); m.undo(); m.undo(); m.undo()
                }
                // --- 1.2: camera / sound for a selected stretch, shots framed on their own, ↑ / ↓ to cuts ---
                do {
                    let c0 = m.selectedClip!
                    let vids = m.project.videoIndices
                    let L = c0.outputDuration
                    func ang(_ c: Clip, _ o: Double) -> Int { Schedule.angle(at: c.masterTime(forOutput: o), clip: c, auto: m.auto, project: m.project) }
                    let camB = vids.count > 1 ? vids[1] : vids[0]
                    let afterWas = ang(c0, L * 0.75)
                    m.tlSel = (L * 0.3)...(L * 0.5)
                    m.cutTo(angle: camB)
                    let c1 = m.selectedClip!
                    log("camera for selection: inside \(ang(c1, L * 0.4)) (want \(camB)), after \(ang(c1, L * 0.75)) (was \(afterWas)), before \(ang(c1, L * 0.1)) (was \(ang(c0, L * 0.1))), switches \(c1.switches.map { String(format: "%.2f:%@", $0.time, $0.angle.map(String.init) ?? "auto") })")
                    let snd = m.project.angles.indices.first { m.project.angles[$0].hasAudio } ?? 0
                    let sndAfterWas = c1.soundOn(at: c1.masterTime(forOutput: L * 0.75))
                    m.audioPreset(snd)
                    let c2 = m.selectedClip!
                    log("sound for selection: inside \(c2.soundOn(at: c2.masterTime(forOutput: L * 0.4))) after \(c2.soundOn(at: c2.masterTime(forOutput: L * 0.75))) (was \(sndAfterWas)), before \(c2.soundOn(at: c2.masterTime(forOutput: L * 0.1)))")
                    m.tlSel = nil
                    let shots = m.tlPieces
                    log("shots: " + shots.map { String(format: "%@ %.2f-%.2f", m.project.angles[$0.angle].shortName, $0.outStart, $0.outStart + $0.duration) }.joined(separator: ", "))
                    m.engine.seek(0.01); m.jumpEditPoint(next: true); let j1 = m.engine.time
                    m.jumpEditPoint(next: true); let j2 = m.engine.time
                    m.jumpEditPoint(next: false)
                    log(String(format: "down arrow: %.2f then %.2f, up back to %.2f; cuts %@", j1, j2, m.engine.time, m.editPoints().map { String(format: "%.2f", $0) }.joined(separator: " ")))
                    if let pc = shots.first {
                        m.engine.seek(pc.outStart + pc.duration / 2)
                        m.frameScope = .shot
                        var f = m.framing(of: pc); f.zoom = 1.8; f.x = 0.3
                        m.setShotFraming(pc, f)
                        let c3 = m.selectedClip!
                        let other = Schedule.pieces(project: m.project, clip: c3, auto: m.auto).first { $0.angle == pc.angle && $0.outStart > pc.outStart + 0.01 }
                        log(String(format: "shot framing: this shot zoom %.2f, camera zoom %.2f, later same-camera shot %@", m.framing(of: pc).zoom, c3.framing(for: pc.angle).zoom,
                                   other.map { String(format: "zoom %.2f", c3.framing(forShotFrom: $0.masterStart, to: $0.masterStart + $0.duration, angle: $0.angle).zoom) } ?? "none"))
                        let b = try CompositionBuilder.build(project: m.project, clip: c3, auto: m.auto, loaded: m.sources, format: c3.format)
                        log("composition: \(b.videoComposition.instructions.count) instructions, \(b.pieces.count) shots")
                        m.engine.seek(pc.outStart + pc.duration * 0.5)
                        m.bladeAtPlayhead()
                        let halves = m.tlPieces.filter { $0.angle == pc.angle && $0.outStart >= pc.outStart - 0.001 && $0.outStart < pc.outStart + pc.duration - 0.01 }
                        log("blade inside the shot: \(halves.count) shots, own framing \(halves.map { m.shotHasOwnFraming($0) })")
                        let back = try Store.decoder.decode(Project.self, from: Store.encoder.encode(m.project))
                        log("shot framing after reload: \(back.clips.first { $0.id == m.selectedClipID }?.shotFraming?.count ?? 0)")
                        m.frameScope = .camera
                        m.undo(); m.undo()
                        log("after undo: shot framing \(m.selectedClip?.shotFraming?.count ?? 0)")
                    }
                    m.undo(); m.undo()
                    log("after undo: switches \(m.selectedClip?.switches.count ?? -1), sound changes \(m.selectedClip?.soundChanges.count ?? -1)")
                }
            }
            m.zoomTimeline(by: 4, around: 2)
            log(String(format: "zoom %.1f start %.2f visible %.2f", m.tlZoom, m.tlStart, m.tlVisible))
            let words = Captions.words(for: c, project: m.project, uppercase: false)
            try Captions.srt(words: words, style: m.project.captionStyle, renderSize: c.format.renderSize, total: c.outputDuration)
                .write(to: outDir.appendingPathComponent("selftest-clip.srt"), atomically: true, encoding: .utf8)
            try Store.encoder.encode(m.project).write(to: outDir.appendingPathComponent("project.json"))
            Store.delete(folder)
            log("SELFTEST OK")
            return 0
        } catch {
            log("SELFTEST FAILED: \(error)")
            return 1
        }
    }
}
