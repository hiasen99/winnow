import Foundation
import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectModel: ObservableObject {
    let folder: URL
    @Published var project: Project
    @Published var loaded: [LoadedAngle?] = []
    /// Bumped whenever the words or who-said-what change, so the transcript view redraws.
    @Published var transcriptVersion = 0
    /// Why the last word alignment was skipped (nil = it ran, or wasn't needed).
    var alignProblem: String? = nil
    /// Opened files matching the project's sources (undo can leave extra entries in `loaded`).
    var sources: [LoadedAngle?] {
        (0..<project.angles.count).map { $0 < loaded.count ? loaded[$0] : nil }
    }
    @Published var auto: [AngleSegment] = []
    @Published var selectedClipID: UUID? = nil
    @Published var busy: String? = nil
    @Published var progress: Double = 0
    @Published var errorText: String? = nil
    @Published var notice: String? = nil
    @Published var selection: ClosedRange<Int>? = nil {    // selected words (indexes into project.words)
        didSet { if selection != nil && tlSel != nil { tlSel = nil } }
    }
    // timeline: zoom (1 = whole clip), first visible second, selected stretch (output time)
    @Published var tlZoom: Double = 1
    @Published var tlStart: Double = 0
    @Published var tlSel: ClosedRange<Double>? = nil {
        didSet {
            if tlSel != nil && selection != nil { selection = nil }
            if tlSel != nil && selectedCaption != nil { selectedCaption = nil }
            if tlSegmentSelected { tlSegmentSelected = false }
        }
    }
    /// true when tlSel is a whole block picked with a click (drawn with a yellow outline, like Final Cut)
    @Published var tlSegmentSelected = false
    /// words being corrected in the transcript (the edit bar shows over the transcript)
    @Published var editingWords: ClosedRange<Int>? = nil
    /// a timeline edge being dragged
    @Published var trimDrag: TrimDrag? = nil
    @Published var snapping: Bool = UserDefaults.standard.object(forKey: "tlSnapping") as? Bool ?? true {
        didSet { UserDefaults.standard.set(snapping, forKey: "tlSnapping") }
    }
    /// Show hidden words in the transcript (faded, struck through) so they can be un-hidden.
    @Published var showHiddenWords: Bool = UserDefaults.standard.bool(forKey: "showHiddenWords") {
        didSet { UserDefaults.standard.set(showHiddenWords, forKey: "showHiddenWords") }
    }
    @Published var skimming: Bool = UserDefaults.standard.object(forKey: "tlSkimming") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skimming, forKey: "tlSkimming"); if !skimming { engine.endSkim() } }
    }
    let thumbs = ThumbCache()
    var tlWordsCache: (key: String, words: [TLWord])? = nil
    @Published var currentWord: Int? = nil
    @Published var fullViewAngle: Int? = nil              // full recording: nil = auto
    @Published var fullMix: AudioMix
    @Published var exporting: [UUID: Double] = [:]
    @Published var showGuides = true
    @Published var showSpeakers = false
    /// The caption picked on the timeline or in the captions panel.
    @Published var selectedCaption: UUID? = nil
    /// Set to start typing in a caption's row in the captions panel.
    @Published var editingCaption: UUID? = nil
    /// A caption being moved / re-timed on the timeline.
    @Published var captionDrag: CaptionDrag? = nil
    var captionCache: (key: String, items: [CaptionItem])? = nil
    /// What framing changes apply to: every shot from the camera, or just the shot at the playhead.
    enum FrameScope: String { case camera, shot }
    @Published var frameScope: FrameScope = .camera
    /// The "Adjust framing" pop-over (also opened from the timeline's right-click menu).
    @Published var showFraming = false
    /// How many windows show this project. With none (Claude working on it in the background) it stays silent.
    var viewers = 0 { didSet { engine.player.isMuted = viewers <= 0 } }

    let engine = PlayerEngine()
    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var saveTask: Task<Void, Never>?
    private(set) var envelopes: [[Float]?] = []
    private var waveCache: (key: String, lanes: [WaveLane])? = nil

    init(folder: URL) throws {
        self.folder = folder
        let p = try Store.load(folder)
        self.project = p
        self.fullMix = p.defaultMix
        engine.onTick = { [weak self] t in self?.tick(t) }
        engine.player.isMuted = true      // until a window shows it
    }

    var selectedClip: Clip? {
        get { project.clips.first { $0.id == selectedClipID } }
    }
    var clipIndex: Int? { project.clips.firstIndex { $0.id == selectedClipID } }
    var isReady: Bool { project.stage == .transcribed }

    // MARK: - Opening

    func open() async {
        do {
            Log.write("open \(project.name) stage=\(project.stage.rawValue)")
            busy = "Opening the camera files…  (if your Mac asks to let Winnow read the drive, click Allow)"
            progress = 0
            loaded = []
            for a in project.angles {
                do { loaded.append(try await MediaLoader.load(a)); Log.write("loaded \(a.path)") }
                catch { loaded.append(nil); Log.write("FAILED to load \(a.path): \(error)") }
            }
            if loaded.contains(where: { $0 == nil }) {
                errorText = "Some camera files couldn't be opened. Were they moved or is the drive unplugged?\n" +
                    project.angles.enumerated().filter { loaded[$0.offset] == nil }.map { $0.element.path }.joined(separator: "\n")
            }
            envelopes = project.angles.indices.map { Store.loadEnvelope(folder: folder, angle: $0) }
            busy = nil
            if project.stage != .transcribed {
                await analyze()
            } else {
                recomputeAuto()
                rebuild(at: 0)
            }
        }
    }

    // MARK: - Analysis pipeline

    func analyze() async {
        guard busy == nil else { return }
        do {
            busy = "Reading the files…"; progress = 0
            var p = project
            // media facts
            for i in p.angles.indices {
                if i >= loaded.count || loaded[i] == nil {
                    let l = try await MediaLoader.load(p.angles[i])
                    if i < loaded.count { loaded[i] = l } else { loaded.append(l) }
                }
                let l = loaded[i]!
                p.angles[i].duration = l.duration
                p.angles[i].width = l.naturalSize.width
                p.angles[i].height = l.naturalSize.height
                p.angles[i].fps = l.fps
                p.angles[i].hasAudio = l.audio != nil
                if p.angles[i].isVideo && l.video == nil { p.angles[i].isVideo = false }
            }
            guard !p.videoIndices.isEmpty else { throw ClipsError("None of the files has any picture. Add at least one camera file.") }
            // audio
            let cache = Store.cacheDir(folder)
            var audio: [AngleAudio?] = Array(repeating: nil, count: p.angles.count)
            let n = Double(p.angles.count)
            for i in p.angles.indices where p.angles[i].hasAudio {
                busy = "Listening to \(p.angles[i].name)…"
                let base = Double(i) / n
                audio[i] = try await AudioAnalysis.analyze(url: p.angles[i].url,
                                                           rawOut: cache.appendingPathComponent("raw-\(i).f32")) { [weak self] f in
                    Task { @MainActor in self?.progress = (base + f / n) * 0.35 }
                }
                p.angles[i].gainDB = AudioAnalysis.levelMatchGain(audio[i]!.envelope)
                Store.saveEnvelope(audio[i]!.envelope, folder: folder, angle: i)
            }
            // line everything up from the sound
            busy = "Lining everything up…"
            let syncWarnings = try await syncSources(&p, envelopes: audio.map { $0?.envelope }, fixed: [:]) { i in
                guard let a = audio[i] else { throw ClipsError("missing audio") }
                return a
            }
            // the timeline starts when the first camera starts
            let shift = p.videoIndices.map { p.angles[$0].masterStart }.min() ?? 0
            for i in p.angles.indices { p.angles[i].offset += shift }
            p.stage = .synced
            project = p
            save()
            progress = 0.4

            envelopes = audio.map { $0?.envelope }
            try await makeTranscript(&p, audio: audio, keepSpeakers: false)
            p.stage = .transcribed
            project = p
            transcriptVersion += 1
            save()
            // tidy big temporary files
            for i in p.angles.indices { try? FileManager.default.removeItem(at: cache.appendingPathComponent("raw-\(i).f32")) }
            progress = 1
            busy = nil
            recomputeAuto()
            rebuild(at: 0)
            if !syncWarnings.isEmpty { notice = syncWarnings.joined(separator: " ") + " See Speakers & Sync." }
        } catch {
            busy = nil
            errorText = error.localizedDescription
            Log.write("analyze failed: \(error)")
        }
    }

    /// Envelopes of the sources used for speech (the separate mics if any), others blanked.
    func speechEnvelopes(_ p: Project) -> [[Float]?] {
        let use = Set(p.speechIndices)
        return envelopes.enumerated().map { use.contains($0.offset) ? $0.element : nil }
    }

    /// Speaker N is shown on camera N by default (Speakers & Sync can change it).
    func defaultSpeakers(_ count: Int, _ p: Project) -> [Speaker] {
        let vids = p.videoIndices
        return (0..<count).map { k in
            Speaker(name: "Speaker \(k + 1)", angle: vids.isEmpty ? 0 : vids[min(k, vids.count - 1)])
        }
    }

    func redetectSpeakers() {
        guard envelopes.contains(where: { $0 != nil }) else { notice = "Run the analysis again to re-detect speakers."; return }
        edit { p in
            var w = p.words
            let count = AudioAnalysis.assignSpeakers(words: &w, angles: p.angles, envelopes: self.speechEnvelopes(p))
            p.words = w
            let old = p.speakers
            let fresh = self.defaultSpeakers(count, p)
            p.speakers = (0..<count).map { i in i < old.count ? old[i] : fresh[i] }
        }
        transcriptVersion += 1
    }



    // MARK: - Sync & transcript helpers

    /// Places sources on the timeline from their sound. Uses the best-matching pairs (so isolated
    /// tracks connect through a shared or combined file), then refines each to the sample.
    /// Sources in `fixed` keep their offsets. Returns plain-English warnings.
    func syncSources(_ p: inout Project, envelopes envs: [[Float]?], fixed: [Int: Double],
                     raw: (Int) async throws -> AngleAudio) async throws -> [String] {
        var warnings: [String] = []
        let live = p.angles.indices.filter { $0 < envs.count && envs[$0] != nil }
        guard live.count > 1 || !fixed.isEmpty else { return [] }
        let root = p.videoIndices.first { live.contains($0) } ?? live.first ?? 0
        let plan = AudioAnalysis.solve(envelopes: envs, root: root, fixed: fixed)
        var offs = plan.offsets
        for j in plan.order {
            guard let i = plan.partner[j], let oi = offs[i], let oj = offs[j] else { continue }
            let a = try await raw(i), b = try await raw(j)
            let rel = try AudioAnalysis.fine(a: a, b: b, coarse: oj - oi)
            offs[j] = oi + rel
            p.angles[j].offset = oi + rel
            p.angles[j].syncScore = plan.confidence[j]
            p.angles[j].syncDrift = AudioAnalysis.drift(a.envelope, b.envelope, offset: rel)
            p.angles[j].syncedWith = p.angles[i].name
            p.angles[j].syncFailed = false
            if let d = p.angles[j].syncDrift, d > 0.1 {
                warnings.append("\(p.angles[j].name) drifts by up to \(String(format: "%.2f", d)) s against \(p.angles[i].name) (different clocks, or one file was edited).")
            }
        }
        if fixed.isEmpty {
            p.angles[root].offset = offs[root] ?? 0
            p.angles[root].syncScore = nil; p.angles[root].syncedWith = nil; p.angles[root].syncDrift = nil
            p.angles[root].syncFailed = false
        }
        for j in p.angles.indices where fixed[j] == nil && j != (fixed.isEmpty ? root : -1) && offs[j] == nil {
            p.angles[j].syncFailed = true
            p.angles[j].syncScore = nil; p.angles[j].syncedWith = nil
            warnings.append(p.angles[j].hasAudio
                ? "\(p.angles[j].name) didn't match any other file's sound, so it isn't lined up. Set its offset by hand in Speakers & Sync."
                : "\(p.angles[j].name) has no sound to line up with. Set its offset by hand in Speakers & Sync.")
        }
        p.syncConfidence = plan.confidence.compactMap { $0 }.min()
        return warnings
    }

    /// Transcribes the speech sources (mics if any, else cameras) and works out who's talking.
    func makeTranscript(_ p: inout Project, audio: [AngleAudio?], keepSpeakers: Bool) async throws {
        let cache = Store.cacheDir(folder)
        busy = "Mixing the audio for the transcript…"
        let mixURL = cache.appendingPathComponent("mix.wav")
        let speech = Set(p.speechIndices)
        let speechAudio = audio.enumerated().map { speech.contains($0.offset) ? $0.element : nil }
        try AudioAnalysis.writeMix(angles: p.angles, audio: speechAudio, total: p.masterDuration, to: mixURL)
        defer { try? FileManager.default.removeItem(at: mixURL) }
        busy = "Transcribing (on this Mac)…"
        var words = try await Transcriber.transcribe(audioFile: mixURL, language: p.language,
            progress: { [weak self] f in Task { @MainActor in self?.progress = 0.45 + f * 0.4 } },
            status: { [weak self] s in Task { @MainActor in self?.busy = s } })
        let aligned: Bool
        (words, aligned) = await alignWords(words, mix: mixURL, language: p.language, from: 0.85, to: 0.95)
        busy = "Working out who's talking…"
        let speechEnv = speechEnvelopes(p)
        AudioAnalysis.tighten(words: &words, angles: p.angles, envelopes: speechEnv, starts: !aligned)
        let count = AudioAnalysis.assignSpeakers(words: &words, angles: p.angles, envelopes: speechEnv)
        p.words = words
        var fresh = defaultSpeakers(count, p)
        if let cams = camerasForSpeakers(count, p) { for k in 0..<count { fresh[k].angle = cams[k] } }
        if keepSpeakers {
            let old = p.speakers
            p.speakers = (0..<count).map { i in i < old.count ? old[i] : fresh[i] }
            if p.speakerCamerasByHand != true {
                for k in 0..<count { p.speakers[k].angle = fresh[k].angle }
            }
        } else {
            p.speakers = fresh
        }
    }

    /// Puts every word where it's actually spoken (see Aligner). On any problem the words come back unchanged.
    func alignWords(_ words: [Word], mix: URL, language: String, from p0: Double, to p1: Double) async -> ([Word], Bool) {
        guard Aligner.supports(language: language), !words.isEmpty else { return (words, false) }
        do {
            try await Aligner.ensureModel(
                status: { [weak self] s in Task { @MainActor in self?.busy = s } },
                progress: { [weak self] f in Task { @MainActor in self?.progress = p0 + f * (p1 - p0) * 0.5 } })
            busy = "Lining each word up with the sound…"
            let (aligned, _) = try await Aligner.align(words: words, audioFile: mix,
                progress: { [weak self] f in Task { @MainActor in self?.progress = p0 + (p1 - p0) * (0.5 + f * 0.5) } })
            return (aligned, true)
        } catch {
            Log.write("aligner skipped: \(error)")
            alignProblem = error.localizedDescription
            return (words, false)
        }
    }

    /// Re-times the existing transcript against the sound, keeping every fix, hidden word and speaker.
    /// One undo step. Hand-made captions keep the words they were made from.
    func retimeWords() async {
        guard busy == nil, isReady, !project.words.isEmpty else { return }
        guard Aligner.supports(language: project.language) else {
            notice = "Re-timing words works for English recordings only."
            return
        }
        engine.pause()
        let before = project
        let cache = Store.cacheDir(folder)
        let speech = project.speechIndices.filter { project.angles[$0].hasAudio }
        var raws: [URL] = []
        let mixURL = cache.appendingPathComponent("align-mix.wav")
        defer {
            for u in raws { try? FileManager.default.removeItem(at: u) }
            try? FileManager.default.removeItem(at: mixURL)
        }
        alignProblem = nil
        do {
            var audio: [AngleAudio?] = Array(repeating: nil, count: project.angles.count)
            for (k, i) in speech.enumerated() {
                busy = "Listening to \(project.angles[i].name)…"
                let raw = cache.appendingPathComponent("raw-\(i).f32"); raws.append(raw)
                let base = Double(k) / Double(max(1, speech.count))
                audio[i] = try await AudioAnalysis.analyze(url: project.angles[i].url, rawOut: raw) { [weak self, n = speech.count] f in
                    Task { @MainActor in self?.progress = (base + f / Double(max(1, n))) * 0.3 }
                }
            }
            busy = "Mixing the audio…"
            try AudioAnalysis.writeMix(angles: project.angles, audio: audio, total: project.masterDuration, to: mixURL)
            progress = 0.35
            let old = project.words
            var (words, ok) = await alignWords(old, mix: mixURL, language: project.language, from: 0.35, to: 0.95)
            if !ok { throw ClipsError(alignProblem ?? "The words couldn't be lined up.") }
            AudioAnalysis.tighten(words: &words, angles: project.angles, envelopes: speechEnvelopes(project), starts: false)
            var p = project
            p.words = words
            // hand-made captions: ones still sitting on their words move with them; ones dragged by hand
            // stay put but keep owning the same words
            let warp = TimeWarp(old: old, new: words)
            for c in p.clips.indices {
                guard var blocks = p.clips[c].captionBlocks, !blocks.isEmpty else { continue }
                for b in blocks.indices {
                    let owned = old.indices.filter { blocks[b].owns(old[$0]) }
                    guard let f = owned.first, let l = owned.last else { continue }
                    if abs(blocks[b].start - old[f].start) < 0.06 {
                        blocks[b].start = warp.map(blocks[b].start)
                        blocks[b].end = max(blocks[b].start + 0.1, warp.map(blocks[b].end))
                        for k in blocks[b].words.indices {
                            blocks[b].words[k].start = warp.map(blocks[b].words[k].start)
                            blocks[b].words[k].end = warp.map(blocks[b].words[k].end)
                        }
                        if let cv = blocks[b].covers { blocks[b].covers = TimeRange(start: warp.map(cv.start), end: warp.map(cv.end)) }
                    } else {
                        blocks[b].covers = TimeRange(start: words[f].start, end: words[l].end)
                    }
                }
                // a word a hand caption held before must still be held (or it would pop up as its own caption)
                let before0 = p.clips[c].captionBlocks ?? []
                for i in old.indices {
                    guard let b = before0.firstIndex(where: { $0.owns(old[i]) }), b < blocks.count,
                          !blocks.contains(where: { $0.owns(words[i]) }) else { continue }
                    let cv = blocks[b].covers ?? TimeRange(start: blocks[b].start, end: blocks[b].end)
                    blocks[b].covers = TimeRange(start: min(cv.start, words[i].start), end: max(cv.end, words[i].end + 0.001))
                }
                p.clips[c].captionBlocks = blocks
            }
            let moved = zip(old, words).filter { abs($0.start - $1.start) > 0.1 }.count
            undoStack.append(before); redoStack.removeAll()
            project = p
            transcriptVersion += 1
            save()
            busy = nil; progress = 1
            recomputeAuto(); rebuild()
            notice = "Re-timed \(words.count) words to the sound; \(moved) moved by more than a tenth of a second. Undo puts them back."
            Log.write("retime done: \(moved)/\(words.count) moved >0.1 s")
        } catch {
            busy = nil
            errorText = "Re-timing words failed: \(error.localizedDescription)"
            Log.write("retime failed: \(error)")
        }
    }

    /// With separate mics: each speaker gets the camera whose sound matches their mic and not the
    /// other mics (so a combined/side-by-side file isn't picked as anyone's close-up).
    func camerasForSpeakers(_ count: Int, _ p: Project) -> [Int]? {
        let mics = p.micIndices
        guard !mics.isEmpty, count == p.speechIndices.count, count > 1 else { return nil }
        let speech = p.speechIndices
        let vids = p.videoIndices.filter { $0 < envelopes.count && envelopes[$0] != nil }
        guard !vids.isEmpty else { return nil }
        var conf: [Int: [Int: Double]] = [:]   // mic -> video -> confidence
        for m in speech {
            guard m < envelopes.count, let em = envelopes[m] else { return nil }
            for v in vids { conf[m, default: [:]][v] = AudioAnalysis.coarse(em, envelopes[v]!)?.confidence ?? 1 }
        }
        var result: [Int] = []
        var used = Set<Int>()
        for k in 0..<count {
            let m = speech[k]
            var best: (v: Int, score: Double)? = nil
            for v in vids {
                let mine = conf[m]?[v] ?? 1
                let others = speech.filter { $0 != m }.map { conf[$0]?[v] ?? 1 }.max() ?? 1
                let score = mine / max(others, 1) - (used.contains(v) ? 100 : 0)
                if best == nil || score > best!.score { best = (v, score) }
            }
            guard let b = best, b.score > 1.5 else { return nil }
            result.append(b.v); used.insert(b.v)
        }
        Log.write("speaker cameras: \(result)")
        return result
    }

    /// Re-lines-up every file from its sound and re-makes the transcript.
    /// Clip times stay put: the first camera keeps its place on the timeline.
    func resync() async {
        guard busy == nil, !project.angles.isEmpty else { return }
        engine.pause()
        let before = project
        let cache = Store.cacheDir(folder)
        do {
            var p = project
            var audio: [AngleAudio?] = Array(repeating: nil, count: p.angles.count)
            let live = p.angles.indices.filter { p.angles[$0].hasAudio }
            for (k, i) in live.enumerated() {
                busy = "Listening to \(p.angles[i].name)…"
                let base = Double(k) / Double(live.count)
                audio[i] = try await AudioAnalysis.analyze(url: p.angles[i].url, rawOut: cache.appendingPathComponent("raw-\(i).f32")) { [weak self] f in
                    Task { @MainActor in self?.progress = (base + f / Double(live.count)) * 0.35 }
                }
                p.angles[i].gainDB = AudioAnalysis.levelMatchGain(audio[i]!.envelope)
                Store.saveEnvelope(audio[i]!.envelope, folder: folder, angle: i)
            }
            envelopes = audio.map { $0?.envelope }
            busy = "Lining everything up…"
            let root = p.videoIndices.first { audio[$0] != nil } ?? live.first ?? 0
            let oldRoot = p.angles[root].offset
            let warnings = try await syncSources(&p, envelopes: envelopes, fixed: [:]) { i in
                guard let a = audio[i] else { throw ClipsError("missing audio") }
                return a
            }
            // keep clip times valid: the reference camera stays where it was
            let delta = oldRoot - p.angles[root].offset
            for i in p.angles.indices where !p.angles[i].syncFailed { p.angles[i].offset += delta }
            if p.clips.isEmpty {
                let shift = p.videoIndices.map { p.angles[$0].masterStart }.min() ?? 0
                for i in p.angles.indices { p.angles[i].offset += shift }
            }
            progress = 0.4
            try await makeTranscript(&p, audio: audio, keepSpeakers: true)
            p.stage = .transcribed
            undoStack.append(before); redoStack.removeAll()
            project = p
            transcriptVersion += 1
            save()
            for i in live { try? FileManager.default.removeItem(at: cache.appendingPathComponent("raw-\(i).f32")) }
            busy = nil; progress = 1
            recomputeAuto(); rebuild()
            notice = "Re-synced \(p.angles.count) files from their sound and re-made the transcript." + (warnings.isEmpty ? "" : " " + warnings.joined(separator: " "))
            Log.write("resync done: " + p.angles.map { "\($0.name)=\(String(format: "%.3f", $0.offset))" }.joined(separator: " "))
        } catch {
            busy = nil
            errorText = "Re-sync failed: \(error.localizedDescription)"
            Log.write("resync failed: \(error)")
        }
    }

    /// Manual offset for one source (seconds; positive = that file started earlier).
    func setOffset(_ i: Int, _ value: Double) {
        edit { $0.angles[i].offset = value; $0.angles[i].syncedWith = "set by hand"; $0.angles[i].syncFailed = false }
    }

    // MARK: - Adding files to an existing project

    /// Adds cameras and/or audio recordings later. Existing clips keep their timing.
    /// New mics: the transcript and speakers are re-made from them (clips are unaffected).
    func addFiles(_ urls: [URL]) async {
        guard busy == nil else { notice = "Wait for the current job to finish, then add the files."; return }
        let before = project
        let existing = Set(before.angles.map { $0.path })
        let vids = urls.filter { Store.videoExts.contains($0.pathExtension.lowercased()) && !existing.contains($0.path) }
        let auds = urls.filter { Store.audioExts.contains($0.pathExtension.lowercased()) && !existing.contains($0.path) }
        var p = before
        var added: [Int] = []
        let letters = ["A", "B", "C", "D"]
        for u in vids where p.videoIndices.count < 4 {
            p.angles.append(AngleSource(name: "Angle \(letters[p.videoIndices.count])", path: u.path))
            added.append(p.angles.count - 1)
        }
        for u in auds where p.angles.filter({ !$0.isVideo }).count < 4 {
            p.angles.append(AngleSource(name: "Mic \(p.angles.filter { !$0.isVideo }.count + 1)", path: u.path, isVideo: false))
            added.append(p.angles.count - 1)
        }
        guard !added.isEmpty else {
            notice = urls.isEmpty ? "Nothing to add." : "Those files are already in the project, aren't video/audio, or the project is full (4 cameras + 4 mics)."
            return
        }
        Log.write("adding \(added.map { p.angles[$0].path })")
        engine.pause()
        // a project that never finished analysing just starts over with everything
        guard before.stage == .transcribed else {
            project = p; save()
            await analyze()
            return
        }
        do {
            busy = "Adding \(added.count) file\(added.count == 1 ? "" : "s")…"; progress = 0
            for i in added {
                let l = try await MediaLoader.load(p.angles[i])
                while loaded.count <= i { loaded.append(nil) }
                loaded[i] = l
                p.angles[i].duration = l.duration
                p.angles[i].width = l.naturalSize.width
                p.angles[i].height = l.naturalSize.height
                p.angles[i].fps = l.fps
                p.angles[i].hasAudio = l.audio != nil
                if p.angles[i].isVideo && l.video == nil { p.angles[i].isVideo = false }
            }
            let cache = Store.cacheDir(folder)
            var raws: [Int: AngleAudio] = [:]
            let srcNames = p.angles.map { $0.name }, srcURLs = p.angles.map { $0.url }
            func decode(_ i: Int) async throws -> AngleAudio {
                if let a = raws[i] { return a }
                busy = "Listening to \(srcNames[i])…"
                let a = try await AudioAnalysis.analyze(url: srcURLs[i], rawOut: cache.appendingPathComponent("raw-\(i).f32"))
                raws[i] = a
                return a
            }
            for i in added where p.angles[i].hasAudio {
                let a = try await decode(i)
                p.angles[i].gainDB = AudioAnalysis.levelMatchGain(a.envelope)
                Store.saveEnvelope(a.envelope, folder: folder, angle: i)
                while envelopes.count <= i { envelopes.append(nil) }
                envelopes[i] = a.envelope
            }
            // line the new files up against whichever existing file shares their sound best
            busy = "Lining up the new files…"
            var fixed: [Int: Double] = [:]
            for i in before.angles.indices where before.angles[i].hasAudio && !before.angles[i].syncFailed { fixed[i] = before.angles[i].offset }
            while envelopes.count < p.angles.count { envelopes.append(nil) }
            let syncWarnings = try await syncSources(&p, envelopes: envelopes, fixed: fixed, raw: decode)
            progress = 0.35

            // new mics → better transcript and speaker detection from them
            let newMics = added.filter { !p.angles[$0].isVideo && p.angles[$0].hasAudio }
            var remade = false
            if !newMics.isEmpty {
                var audio: [AngleAudio?] = Array(repeating: nil, count: p.angles.count)
                for i in p.speechIndices { audio[i] = try await decode(i) }
                try await makeTranscript(&p, audio: audio, keepSpeakers: true)
                remade = true
            }
            // clips still on the old default sound move to the new default (e.g. the mics)
            let oldDefault = before.defaultMix.on, newDefault = p.defaultMix.on
            for k in p.clips.indices {
                var on = p.clips[k].audio.on
                while on.count < before.angles.count { on.append(false) }
                if Array(on.prefix(before.angles.count)) == oldDefault {
                    var m = p.clips[k].audio; m.ensure(p.angles.count); m.on = newDefault
                    p.clips[k].audio = m
                }
                while p.clips[k].framing.count < p.angles.count { p.clips[k].framing.append(Framing()) }
            }
            var fm = fullMix; fm.ensure(p.angles.count)
            if Array(fm.on.prefix(before.angles.count)) == oldDefault { fm.on = newDefault }
            fullMix = fm

            undoStack.append(before); redoStack.removeAll()
            project = p
            transcriptVersion += 1
            save()
            for i in raws.keys { try? FileManager.default.removeItem(at: cache.appendingPathComponent("raw-\(i).f32")) }
            busy = nil; progress = 1
            recomputeAuto()
            rebuild()
            let names = added.map { p.angles[$0].name }.joined(separator: ", ")
            notice = "Added \(names)." + (remade ? " The transcript and speakers were re-made from the mics." : "")
                + (syncWarnings.isEmpty ? "" : " " + syncWarnings.joined(separator: " "))
        } catch {
            busy = nil
            errorText = "Couldn't add the files: \(error.localizedDescription)"
            Log.write("add failed: \(error)")
        }
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.message = "Add camera angles or separate audio recordings to this project"
        if panel.runModal() == .OK { let urls = panel.urls; Task { await addFiles(urls) } }
    }



    // MARK: - Timeline zoom & selection

    /// Length of what the timeline shows (follows live trims before the player is rebuilt).
    var tlDuration: Double { max(0.001, selectedClip?.outputDuration ?? project.masterDuration) }
    var tlVisible: Double { tlDuration / max(1, tlZoom) }

    func clampTimeline() {
        tlZoom = max(1, min(tlZoom, max(1, tlDuration / 0.4)))
        tlStart = max(0, min(tlStart, tlDuration - tlVisible))
    }

    /// Zoom keeping time `t` (default: the playhead) at the same spot on screen.
    func zoomTimeline(by factor: Double, around t: Double? = nil) {
        let anchor = t ?? engine.time
        let frac = tlVisible > 0 ? (anchor - tlStart) / tlVisible : 0.5
        tlZoom = max(1, min(tlZoom * factor, max(1, tlDuration / 0.4)))
        tlStart = anchor - (frac.isFinite ? max(0, min(1, frac)) : 0.5) * tlVisible
        clampTimeline()
    }
    func fitTimeline() { tlZoom = 1; tlStart = 0 }
    func panTimeline(seconds: Double) { tlStart += seconds; clampTimeline() }

    /// Output-time range -> pieces of master time (skipping parts already cut).
    func masterSegments(_ c: Clip, _ o1: Double, _ o2: Double) -> [(Double, Double)] {
        var acc = 0.0
        var out: [(Double, Double)] = []
        for r in c.ranges {
            let rs = acc, re = acc + r.duration
            let a = max(o1, rs), b = min(o2, re)
            if b > a + 0.001 { out.append((r.start + a - rs, r.start + b - rs)) }
            acc = re
        }
        return out
    }

    /// Cut the timeline selection out of the clip (or, on the full recording, make it a clip).
    func cutTimelineSelection() {
        guard let sel = tlSel else { return }
        if let c = selectedClip {
            let segs = masterSegments(c, sel.lowerBound, sel.upperBound)
            guard !segs.isEmpty else { return }
            if segs.reduce(0, { $0 + $1.1 - $1.0 }) >= c.outputDuration - 0.05 { notice = "That would cut the whole clip."; return }
            updateClip { clip in for (a, b) in segs { clip.cut(a, b) } }
            tlSel = nil
            engine.seek(min(sel.lowerBound, engine.duration))
        } else {
            timelineSelectionToClip()
        }
    }

    func timelineSelectionToClip() {
        guard let sel = tlSel, selectedClip == nil, sel.upperBound - sel.lowerBound > 0.3 else { return }
        let first = project.words.firstIndex { $0.end > sel.lowerBound }
        let last = project.words.lastIndex { $0.start < sel.upperBound }
        var title = "Clip at \(fmtTime(sel.lowerBound))"
        if let f = first, let l = last, l >= f { title = self.title(from: f, l) }
        let c = project.newClip(title: title, start: sel.lowerBound, end: sel.upperBound)
        edit(rebuild: false) { $0.clips.append(c) }
        tlSel = nil
        select(clip: c.id)
    }

    /// Shortens every pause between words in the clip that's longer than `over` down to `keep`.
    func shortenPauses(over: Double, keep: Double) {
        guard let c = selectedClip else { return }
        let ws = project.words.filter { $0.end > c.start && $0.start < c.end }
        var cuts: [(Double, Double)] = []
        for i in 0..<max(0, ws.count - 1) {
            let a = ws[i].end, b = ws[i + 1].start
            if b - a > over {
                let s = a + keep / 2, e = b - keep / 2
                if e > s + 0.02 { cuts.append((s, e)) }
            }
        }
        guard !cuts.isEmpty else { notice = "No pauses longer than \(String(format: "%.1f", over)) s in this clip."; return }
        let before = c.outputDuration
        updateClip { clip in for (a, b) in cuts { clip.cut(a, b) } }
        let after = selectedClip?.outputDuration ?? before
        notice = "Shortened \(cuts.count) pause\(cuts.count == 1 ? "" : "s") (\(String(format: "%.1f", before - after)) s shorter)."
    }

    // MARK: - Waveform

    /// Waveform columns for the strip under the player. `each` = one lane per source with sound,
    /// otherwise one lane of what you actually hear. Values 0...1 (from dB, -60 dB = 0).
    func waveform(columns: Int, each: Bool, from: Double = 0, to: Double? = nil) -> [WaveLane] {
        let p = project
        let clip = selectedClip
        let full = max(0.001, clip?.outputDuration ?? p.masterDuration)
        let to = to ?? full
        let d = max(0.001, to - from)
        let key = "\(columns)|\(each)|\(Int(from * 1000))|\(Int(to * 1000))|\(clip?.id.uuidString ?? "full")|\(clip?.ranges ?? [])|\(clip?.audio ?? fullMix)|\(clip?.audioSwitches ?? [])|\(fullMix)|\(p.angles.map { $0.offset })|\(envelopes.count)"
        if let c = waveCache, c.key == key { return c.lanes }
        let audioIdx = p.angles.indices.filter { p.angles[$0].hasAudio && $0 < envelopes.count && envelopes[$0] != nil }
        let span = d / Double(max(1, columns))
        func level(_ i: Int, _ m: Double) -> Float {
            guard let e = envelopes[i] else { return 0 }
            let c = (m + p.angles[i].offset) * AudioAnalysis.envRate
            let half = max(1, Int(span * AudioAnalysis.envRate / 2))
            let i0 = max(0, Int(c) - half), i1 = min(e.count, Int(c) + half + 1)
            guard i1 > i0 else { return 0 }
            var mx: Float = -120
            for k in i0..<i1 where e[k] > mx { mx = e[k] }
            let db = mx + Float(p.angles[i].gainDB)
            return max(0, min(1, (db + 60) / 60))
        }
        var lanes: [WaveLane] = []
        let masters: [Double] = (0..<columns).map { c in
            let o = from + (Double(c) + 0.5) * span
            return clip?.masterTime(forOutput: o) ?? o
        }
        if each {
            for i in audioIdx {
                var vals = [Float](repeating: 0, count: columns), heard = [Bool](repeating: false, count: columns)
                for c in 0..<columns {
                    vals[c] = level(i, masters[c])
                    let on = clip?.soundOn(at: masters[c]) ?? fullMix.on
                    heard[c] = i < on.count && on[i]
                }
                lanes.append(WaveLane(source: i, name: p.angles[i].shortName, values: vals, heard: heard, color: [sourceColor(p, i)]))
            }
        } else {
            var vals = [Float](repeating: 0, count: columns)
            var colors = [Color](repeating: .gray, count: columns)
            for c in 0..<columns {
                let on = clip?.soundOn(at: masters[c]) ?? fullMix.on
                var v: Float = 0
                for i in audioIdx where i < on.count && on[i] { v = max(v, level(i, masters[c])) }
                vals[c] = v
                colors[c] = soundColor(p, on)
            }
            lanes.append(WaveLane(source: nil, name: "", values: vals, heard: Array(repeating: true, count: columns), color: colors))
        }
        waveCache = (key, lanes)
        return lanes
    }

    // MARK: - Playback

    func recomputeAuto() { auto = Schedule.auto(project: project) }

    /// Output time of the player -> master time.
    func masterTime(_ out: Double) -> Double {
        if let c = selectedClip { return c.masterTime(forOutput: out) }
        return out
    }
    func outputTime(_ master: Double) -> Double? {
        if let c = selectedClip { return c.outputTime(forMaster: master) }
        return master
    }

    func rebuild(at outTime: Double? = nil, play: Bool? = nil) {
        guard !loaded.isEmpty, project.masterDuration > 0 else { return }
        let keepMaster = masterTime(engine.time)
        do {
            var clip = selectedClip
            if clip == nil, let a = fullViewAngle {
                // full recording with a fixed angle: fake a clip-free override
                var c = project.newClip(title: "", start: 0, end: project.masterDuration)
                c.switches = [AngleSwitch(time: 0, angle: a)]
                clip = c
                let b = try CompositionBuilder.build(project: project, clip: clip, auto: auto, loaded: sources, format: nil,
                                                     audible: audibleSources(nil))
                engine.load(b, mix: CompositionBuilder.audioMix(b, mix: fullMix, angles: project.angles), captions: nil,
                            at: outTime ?? keepMaster, play: play)
                return
            }
            let b = try CompositionBuilder.build(project: project, clip: clip, auto: auto, loaded: sources, format: clip?.format,
                                                 audible: audibleSources(clip))
            var captions: CALayer? = nil
            // captions always show in the viewer; "Burn in" only decides what the export gets
            if let c = clip {
                let track = Captions.track(for: c, project: project, renderSize: b.renderSize)
                captions = Captions.makeLayer(track, style: project.captionStyle, renderSize: b.renderSize, total: b.duration)
            }
            let mix = CompositionBuilder.audioMix(b, mix: clip?.audio ?? fullMix, angles: project.angles, clip: clip)
            let t = outTime ?? (outputTime(keepMaster) ?? 0)
            engine.load(b, mix: mix, captions: captions, at: t, play: play)
        } catch {
            errorText = "Couldn't build the preview: \(error.localizedDescription)"
            Log.write("rebuild failed: \(error)")
        }
    }

    /// Sources heard anywhere in this edit (the preview only carries these).
    func audibleSources(_ clip: Clip?) -> Set<Int> {
        guard let c = clip else { return Set(fullMix.on.indices.filter { fullMix.on[$0] }) }
        var s = Set<Int>()
        for sg in c.soundSegments() { for i in sg.on.indices where sg.on[i] { s.insert(i) } }
        return s
    }

    func applyMix() {
        guard let b = engine.built else { return }
        // a source switched on or off: rebuild so playback carries exactly the sources you hear
        if Set(b.audioTracks.keys) != audibleSources(selectedClip).filter({ $0 < sources.count && sources[$0]?.audio != nil }) {
            rebuild(play: engine.isPlaying); return
        }
        engine.setMix(CompositionBuilder.audioMix(b, mix: selectedClip?.audio ?? fullMix, angles: project.angles, clip: selectedClip))
    }

    private func tick(_ t: Double) {
        let m = masterTime(t)
        let w = wordIndex(at: m)
        if w != currentWord { currentWord = w }
    }

    func wordIndex(at m: Double) -> Int? {
        let ws = project.words
        guard !ws.isEmpty else { return nil }
        var lo = 0, hi = ws.count - 1, ans: Int? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ws[mid].start <= m { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if let a = ans, m <= ws[a].end + 0.3 { return a }
        return nil
    }

    func seekMaster(_ m: Double) {
        if let c = selectedClip {
            if let o = c.outputTime(forMaster: m) { engine.seek(o) }
            else if m < c.start { engine.seek(0) } else if m > c.end { engine.seek(engine.duration) }
            else {
                // inside a removed part: jump to the next kept moment
                if let r = c.ranges.first(where: { $0.start > m }), let o = c.outputTime(forMaster: r.start) { engine.seek(o) }
            }
        } else { engine.seek(m) }
    }

    func select(clip id: UUID?) {
        engine.pause()
        let m = masterTime(engine.time)
        selectedClipID = id
        selection = nil
        editingWords = nil
        selectedCaption = nil; editingCaption = nil; captionDrag = nil
        tlZoom = 1; tlStart = 0; tlSel = nil
        if let c = selectedClip {
            rebuild(at: (m >= c.start && m <= c.end) ? (c.outputTime(forMaster: m) ?? 0) : 0, play: false)
        } else {
            rebuild(at: m, play: false)
        }
    }

    // MARK: - Editing with undo

    func edit(rebuild doRebuild: Bool = true, _ change: (inout Project) -> Void) {
        undoStack.append(project)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        var p = project
        change(&p)
        project = p
        save()
        recomputeAuto()
        if doRebuild { rebuild() }
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        project = prev
        transcriptVersion += 1
        if selectedClip == nil && selectedClipID != nil { selectedClipID = nil }
        save(); recomputeAuto(); rebuild()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        transcriptVersion += 1
        save(); recomputeAuto(); rebuild()
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func save() {
        saveTask?.cancel()
        let p = project, f = folder
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            try? Store.save(p, to: f)
        }
    }
    func saveNow() { saveTask?.cancel(); try? Store.save(project, to: folder) }

    func updateClip(rebuild doRebuild: Bool = true, _ change: (inout Clip) -> Void) {
        guard let i = clipIndex else { return }
        edit(rebuild: doRebuild) { p in
            change(&p.clips[i])
            p.clips[i].normalizeRanges()
        }
    }

    /// For sliders: one undo step per gesture instead of one per tick.
    private var lastLive = Date.distantPast
    private var gestureActive = false
    private var gestureNeedsUndo = false
    /// A mouse gesture (trim drag, framing drag) is one undo step however long it takes.
    func beginGesture() { gestureActive = true; gestureNeedsUndo = true }
    func endGesture() { gestureActive = false; gestureNeedsUndo = false; lastLive = .distantPast }
    func liveEdit(_ change: (inout Project) -> Void) {
        if gestureActive {
            if gestureNeedsUndo { undoStack.append(project); redoStack.removeAll(); gestureNeedsUndo = false }
        } else if Date().timeIntervalSince(lastLive) > 1.0 {
            undoStack.append(project); redoStack.removeAll()
        }
        lastLive = Date()
        var p = project; change(&p); project = p
        save()
    }
    func updateClipLive(_ change: (inout Clip) -> Void) {
        guard let i = clipIndex else { return }
        liveEdit { change(&$0.clips[i]) }
        rebuild()
    }
    func setCaptionStyle(_ st: CaptionStyle) {
        liveEdit { $0.captionStyle = st }
        if selectedClip != nil { rebuild() }
    }
    func renameSpeaker(_ i: Int, _ name: String) {
        liveEdit { $0.speakers[i].name = name }
    }
    func setAutoParams(minShot: Double? = nil, lead: Double? = nil) {
        liveEdit { p in
            if let m = minShot { p.minShot = m }
            if let l = lead { p.switchLead = l }
        }
        recomputeAuto(); rebuild()
    }
    func nudgeSync(_ i: Int, _ delta: Double) {
        edit { $0.angles[i].offset += delta }
    }

    // MARK: - Clips

    func snapRange(_ first: Int, _ last: Int) -> (Double, Double) {
        let ws = project.words
        let prevEnd = first > 0 ? ws[first - 1].end : 0
        let nextStart = last + 1 < ws.count ? ws[last + 1].start : ws[last].end + 1
        return (max(prevEnd, ws[first].start - 0.12), min(nextStart, ws[last].end + 0.25))
    }

    func title(from first: Int, _ last: Int) -> String {
        let t = project.words[first...min(last, first + 7)].map { $0.text }.joined(separator: " ")
        return t.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:-–— "))
    }

    func makeClipFromSelection() {
        guard let sel = selection, !project.words.isEmpty else { return }
        let (s, e) = snapRange(sel.lowerBound, sel.upperBound)
        let c = project.newClip(title: title(from: sel.lowerBound, sel.upperBound), start: s, end: e)
        edit(rebuild: false) { $0.clips.append(c) }
        select(clip: c.id)
    }

    func addIdeas(_ ideas: [ClipIdea]) -> Int {
        guard !ideas.isEmpty else { return 0 }
        var added: [Clip] = []
        for idea in ideas {
            let (s, e) = ClipFinder.snap(idea, words: project.words)
            guard e > s + 0.5, s < project.masterDuration else { continue }
            var c = project.newClip(title: idea.title, start: s, end: min(e, project.masterDuration))
            c.note = idea.why
            c.score = idea.score
            added.append(c)
        }
        edit(rebuild: false) { $0.clips.append(contentsOf: added) }
        if let first = added.first { select(clip: first.id) }
        return added.count
    }

    func deleteClip(_ id: UUID) {
        if selectedClipID == id { selectedClipID = nil }
        edit { $0.clips.removeAll { $0.id == id } }
    }

    func renameClip(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = project.clips.firstIndex(where: { $0.id == id }), project.clips[i].title != t else { return }
        edit(rebuild: false) { $0.clips[i].title = t }
    }

    func duplicateClip(_ id: UUID) {
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        var d = c; d.id = UUID(); d.title += " (copy)"; d.created = Date()
        edit(rebuild: false) { $0.clips.append(d) }
        select(clip: d.id)
    }

    /// Delete the selected words from the clip (Descript-style).
    func cutSelection() {
        guard let sel = selection, let c = selectedClip else { return }
        let ws = project.words
        let a = sel.lowerBound == 0 ? c.start : max(c.start, ws[sel.lowerBound].start - 0.02)
        let b = sel.upperBound + 1 < ws.count ? min(c.end, ws[sel.upperBound + 1].start - 0.02) : c.end
        guard b > a else { return }
        updateClip { $0.cut(a, b) }
        selection = nil
    }

    func restoreSelection() {
        guard let sel = selection, let c = selectedClip else { return }
        let ws = project.words
        let a = max(c.start, sel.lowerBound > 0 ? ws[sel.lowerBound - 1].end : ws[sel.lowerBound].start)
        let b = min(c.end, sel.upperBound + 1 < ws.count ? ws[sel.upperBound + 1].start : ws[sel.upperBound].end)
        updateClip { $0.restore(a, b) }
    }

    func restoreAll() {
        guard let c = selectedClip else { return }
        updateClip { $0.ranges = [TimeRange(start: c.start, end: c.end)] }
    }

    func setStart(toWord i: Int) {
        guard let c = selectedClip else { return }
        let (s, _) = snapRange(i, i)
        guard s < c.end - 0.3 else { return }
        updateClip { clip in
            clip.ranges = clip.ranges.compactMap { r in
                if r.end <= s { return nil }
                return TimeRange(start: max(r.start, s), end: r.end)
            }
            if s < clip.start || clip.ranges.isEmpty {
                clip.ranges.insert(TimeRange(start: s, end: clip.ranges.first?.start ?? c.end), at: 0)
            }
        }
    }

    func setEnd(toWord i: Int) {
        guard let c = selectedClip else { return }
        let (_, e) = snapRange(i, i)
        guard e > c.start + 0.3 else { return }
        updateClip { clip in
            clip.ranges = clip.ranges.compactMap { r in
                if r.start >= e { return nil }
                return TimeRange(start: r.start, end: min(r.end, e))
            }
            if e > clip.end || clip.ranges.isEmpty {
                clip.ranges.append(TimeRange(start: clip.ranges.last?.end ?? c.start, end: e))
            }
        }
    }

    func nudge(start delta: Double) {
        updateClip { c in
            guard !c.ranges.isEmpty else { return }
            c.ranges[0].start = max(0, min(c.ranges[0].end - 0.2, c.ranges[0].start + delta))
        }
    }
    func nudge(end delta: Double) {
        let maxT = project.masterDuration
        updateClip { c in
            guard !c.ranges.isEmpty else { return }
            let i = c.ranges.count - 1
            c.ranges[i].end = min(maxT, max(c.ranges[i].start + 0.2, c.ranges[i].end + delta))
        }
    }

    // MARK: - Angles & audio

    /// The stretches (master time) a camera or sound choice applies to: the timeline selection, or the selected words.
    /// nil = no selection (then a choice applies from the playhead on).
    func choiceRanges() -> [(Double, Double)]? {
        guard let c = selectedClip else { return nil }
        if let sel = tlSel {
            // one stretch from the first kept moment to the last: parts already cut out in between are never seen or heard,
            // so covering them keeps it to a single change in and a single change out
            let segs = masterSegments(c, sel.lowerBound, sel.upperBound)
            guard let a = segs.first?.0, let b = segs.last?.1 else { return nil }
            return [(a, b)]
        }
        let ws = project.words
        if let sel = selection, sel.upperBound < ws.count {
            let a = max(c.start, ws[sel.lowerBound].start - 0.05), b = min(c.end, ws[sel.upperBound].end + 0.05)
            if b > a { return [(a, b)] }
        }
        return nil
    }

    /// Cut to an angle at the playhead (nil = back to automatic). Works live while playing.
    /// With a stretch selected on the timeline (or words selected), only that stretch changes.
    func cutTo(angle: Int?) {
        if selectedClip == nil {
            fullViewAngle = angle
            rebuild()
            return
        }
        if let ranges = choiceRanges() {
            updateClip { c in for (a, b) in ranges { c.setCamera(angle, from: a, to: b) } }
            let name = angle.map { project.angles[$0].shortName } ?? "automatic"
            notice = "Camera \(name) for the selected \(fmtSpan(ranges.reduce(0) { $0 + $1.1 - $1.0 }))."
            return
        }
        let m = masterTime(engine.time)
        updateClip { c in
            c.switches.removeAll { abs($0.time - m) < 0.08 }
            c.switches.append(AngleSwitch(time: m, angle: angle))
            // drop switches that change nothing
            c.switches.sort { $0.time < $1.time }
            var cleaned: [AngleSwitch] = []
            for s in c.switches where cleaned.last?.angle != s.angle || cleaned.isEmpty { cleaned.append(s) }
            if cleaned.first?.angle == nil { cleaned.removeFirst() }
            c.switches = cleaned
        }
    }

    func clearSwitches() { updateClip { $0.switches = [] } }

    /// Click = hear only this source. Shift-click = add/remove it. nil = the default mix.
    /// In a clip: with words selected it changes the sound for just those words, otherwise
    /// from the playhead on (at the very start of the clip: the whole clip).
    func audioPreset(_ which: Int?, adding: Bool = false) {
        let n = project.angles.count
        var on = currentMix.on
        while on.count < n { on.append(false) }
        if let w = which {
            if adding { on[w].toggle() } else { for i in 0..<n { on[i] = (i == w) } }
        } else {
            on = project.defaultMix.on
        }
        for (i, a) in project.angles.enumerated() where !a.hasAudio { on[i] = false }
        applySound(on)
    }

    func applySound(_ on: [Bool]) {
        guard selectedClip != nil else {
            var m = fullMix; m.ensure(project.angles.count); m.on = on; fullMix = m; applyMix(); return
        }
        let n = project.angles.count
        if let ranges = choiceRanges() {
            updateClip(rebuild: false) { c in c.audio.ensure(n); c.setSound(on, ranges: ranges) }
            applyMix()
            notice = "Sound: \(soundLabel(project, on)) for the selected \(fmtSpan(ranges.reduce(0) { $0 + $1.1 - $1.0 }))."
            return
        }
        let m = masterTime(engine.time)
        updateClip(rebuild: false) { c in
            c.audio.ensure(n)
            var sw = c.soundChanges
            if m <= c.start + 0.1 {
                c.audio.on = on
                sw.removeAll { $0.time <= c.start + 0.1 }
            } else {
                sw.removeAll { abs($0.time - m) < 0.08 }
                sw.append(AudioSwitch(time: m, on: on))
            }
            // tidy: inside the clip, sorted, no change that changes nothing
            sw = sw.filter { $0.time > c.start + 0.01 && $0.time < c.end - 0.01 }.sorted { $0.time < $1.time }
            var cleaned: [AudioSwitch] = []
            var cur = c.audio.on
            for s in sw {
                let next = s.on ?? c.audio.on
                if next != cur { cleaned.append(AudioSwitch(time: s.time, on: next)); cur = next }
            }
            c.audioSwitches = cleaned.isEmpty ? nil : cleaned
        }
        applyMix()
    }

    func clearSoundChanges() {
        updateClip(rebuild: false) { $0.audioSwitches = nil }
        applyMix()
    }

    /// Gains / base sound from the mixer popover.
    func setAudio(_ mix: AudioMix) {
        if selectedClip == nil { fullMix = mix; applyMix(); return }
        updateClip(rebuild: false) { $0.audio.gainDB = mix.gainDB }
        applySound(mix.on)
    }

    /// What's heard at the playhead.
    var currentMix: AudioMix {
        guard let c = selectedClip else { return fullMix }
        var m = c.audio
        m.on = c.soundOn(at: masterTime(engine.time))
        return m
    }

    // MARK: - Clip finder

    func copyPrompt(count: Int, minLen: Int, maxLen: Int, guidance: String) {
        let text = ClipFinder.prompt(project, count: count, minLen: minLen, maxLen: maxLen, guidance: guidance)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func askClaude(count: Int, minLen: Int, maxLen: Int, guidance: String, model: String) async {
        busy = "Asking Claude for clip ideas…"; progress = 0
        defer { busy = nil }
        do {
            let text = try await ClipFinder.askClaude(
                prompt: ClipFinder.prompt(project, count: count, minLen: minLen, maxLen: maxLen, guidance: guidance), model: model)
            let ideas = ClipFinder.parse(text)
            if ideas.isEmpty { errorText = "Claude answered, but no clips could be read from it:\n\n" + String(text.prefix(600)); return }
            let n = addIdeas(ideas)
            notice = "Added \(n) clip ideas."
        } catch { errorText = error.localizedDescription }
    }

    // MARK: - Export

    /// Where the save panel opens: this project's last export folder, else the last one used anywhere.
    var exportFolder: URL {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "exportDir.\(project.id.uuidString)"), FileManager.default.fileExists(atPath: s) { return URL(fileURLWithPath: s) }
        if let s = d.string(forKey: "lastExportDir"), FileManager.default.fileExists(atPath: s) { return URL(fileURLWithPath: s) }
        let def = Store.exportDir.appendingPathComponent(Exporter.safeName(project.name), isDirectory: true)
        try? FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
        return def
    }

    /// Asks where to save (remembering the folder), then exports.
    func exportAsking(_ id: UUID) async {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        engine.pause()
        let ep = ExportPanel(title: "Export “\(clip.title)”", baseName: Exporter.safeName(clip.title), folder: exportFolder,
                             burnIn: clip.captions)
        guard let url = ep.run() else { return }
        if ep.kind == .video, ep.burnIn != clip.captions, let i = project.clips.firstIndex(where: { $0.id == id }) {
            liveEdit { $0.clips[i].captions = ep.burnIn }    // remembered for this clip's next export
        }
        let dir = url.deletingLastPathComponent()
        UserDefaults.standard.set(dir.path, forKey: "exportDir.\(project.id.uuidString)")
        UserDefaults.standard.set(dir.path, forKey: "lastExportDir")
        await export(id, to: url, kind: ep.kind, alsoSRT: ep.alsoSRT)
    }

    func export(_ id: UUID, to url: URL, kind: ExportKind = .video, alsoSRT: Bool = true) async {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let srt = Captions.srt(Captions.track(for: clip, project: project))
        exporting[id] = 0
        defer { exporting[id] = nil }
        let progress: @Sendable (Double) -> Void = { [weak self] f in
            Task { @MainActor in if self?.exporting[id] != nil { self?.exporting[id] = f } }
        }
        do {
            switch kind {
            case .video:
                try await Exporter.export(project: project, clip: clip, auto: auto, loaded: sources, to: url, progress: progress)
                if alsoSRT { try? srt.write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8) }
            case .audioM4A, .audioWAV:
                try await Exporter.exportAudio(project: project, clip: clip, auto: auto, loaded: sources, to: url,
                                               wav: kind == .audioWAV, progress: progress)
            case .captions:
                try srt.write(to: url, atomically: true, encoding: .utf8)
            }
            notice = "Saved “\(url.lastPathComponent)” in \(dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
            lastExport = url
        } catch {
            errorText = "Export failed: \(error.localizedDescription)"
            Log.write("export failed: \(error)")
        }
    }

    /// Export without asking (used by the self-test).
    func export(_ id: UUID) async {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        await export(id, to: exportFolder.appendingPathComponent(Exporter.safeName(clip.title) + ".mp4"))
    }
    @Published var lastExport: URL? = nil

    func revealLastExport() {
        if let u = lastExport { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        else { NSWorkspace.shared.open(Store.exportDir) }
    }
}

struct WaveLane {
    var source: Int?
    var name: String
    var values: [Float]
    var heard: [Bool]
    var color: [Color]     // one colour, or one per column
}

/// Maps times on the old word timing to the new one (piecewise linear through every word's start and end).
struct TimeWarp {
    private var xs: [Double] = [], ys: [Double] = []
    init(old: [Word], new: [Word]) {
        for (a, b) in zip(old, new) {
            for (x, y) in [(a.start, b.start), (a.end, b.end)] {
                if let lx = xs.last, let ly = ys.last {
                    if x == lx { ys[ys.count - 1] = max(ly, y); continue }   // one word ends where the next starts
                    if x < lx || y < ly { continue }
                }
                xs.append(x); ys.append(y)
            }
        }
    }
    func map(_ t: Double) -> Double {
        guard let fx = xs.first, let lx = xs.last else { return t }
        if t <= fx { return t + (ys[0] - fx) }
        if t >= lx { return t + (ys[ys.count - 1] - lx) }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if xs[m] <= t { lo = m } else { hi = m } }
        let f = (t - xs[lo]) / (xs[hi] - xs[lo])
        return ys[lo] + f * (ys[hi] - ys[lo])
    }
}
