import SwiftUI
import AVFoundation
import AppKit

struct ProjectView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ProjectModel
    @State private var showFinder = false
    @State private var showStyle = false
    @AppStorage("transcriptFont") var transcriptFont: Double = 15
    @State private var keys = KeyMonitor()

    @AppStorage("timelineHeight") var timelineHeight: Double = 290

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // left: the clip list on top, this clip's settings under it
                VStack(spacing: 0) {
                    ClipsSidebar(model: model)
                        .frame(maxHeight: .infinity)
                    Divider()
                    ClipInspector(model: model).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
                // middle: the viewer gets all the room
                ZStack {
                    Color.black
                    PlayerView(engine: model.engine, guides: model.showGuides && model.selectedClip?.format == .vertical, model: model)
                    if let b = model.busy { BusyOverlay(text: b, progress: model.progress) }
                }
                .frame(minWidth: 420, idealWidth: 640, minHeight: 200, maxHeight: .infinity)
                ZStack {
                    Group {
                        if model.selectedClip != nil {
                            // inside a clip: its captions (the video is edited on the timeline, not by text)
                            CaptionsPanel(model: model, showStyle: $showStyle)
                        } else {
                            // the full recording: the transcript, to read through and find moments
                            VStack(spacing: 0) {
                                TranscriptHeader(model: model, fontSize: $transcriptFont)
                                Divider()
                                TranscriptView(model: model, fontSize: CGFloat(transcriptFont))
                            }
                        }
                    }
                    .opacity(showStyle && model.selectedClip != nil ? 0 : 1)
                    if showStyle && model.selectedClip != nil {
                        CaptionStyleSheet(model: model, onDone: { showStyle = false })
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
                .frame(minWidth: 300, idealWidth: 400)
            }
            .frame(maxHeight: .infinity)
            // the timeline runs the full width of the window, under all three columns
            SplitHandle(height: $timelineHeight)
            // play controls centred above the timeline, camera on the left, sound on the right
            TransportBar(model: model, engine: model.engine)
            Divider()
            TimelinePanel(model: model, thumbs: model.thumbs)
                .frame(height: CGFloat(timelineHeight))
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { app.close() } label: { Label("Projects", systemImage: "chevron.left") }
                    .help("Back to your projects")
            }
            ToolbarItem(placement: .principal) {
                Breadcrumb(model: model)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
                Button { model.chooseFilesToAdd() } label: { Label("Add Files", systemImage: "plus.rectangle.on.rectangle") }
                    .help("Add another camera angle or a separate audio recording (or just drop the files on this window)")
                    .disabled(model.busy != nil)
                Button { model.showSpeakers = true } label: { Label("Speakers & Sync", systemImage: "person.2.wave.2") }
                    .help("Who's who, which camera to show for each person, and how the angles line up")
                Button { showFinder = true } label: { Label { Text("Find Clips") } icon: { Image(systemName: "sparkles").foregroundStyle(Brand.gold) } }
                    .help("Find clips with Claude: let Claude pick the best moments. (Or drag across the timeline and press C.)")
                    .disabled(!model.isReady)
                ExportToolbarButton(model: model)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings: your Claude API key, transcript language and other preferences")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addFiles(urls) }
            return true
        }
        .onAppear { keys.install(model) }
        .onDisappear { keys.remove() }
        .sheet(isPresented: $showFinder) { FindClipsSheet(model: model) }
        .sheet(isPresented: $model.showSpeakers) { SpeakersSheet(model: model) }

        .alert("Something went wrong", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) {
            Button("OK") { model.errorText = nil }
        } message: { Text(model.errorText ?? "") }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                HStack(spacing: 10) {
                    Text(n).font(.callout)
                    if model.lastExport != nil, n.hasPrefix("Saved") { Button("Show") { model.revealLastExport() } }
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
                .task(id: n) { try? await Task.sleep(nanoseconds: 9_000_000_000); if model.notice == n { model.notice = nil } }
            }
        }
    }
}

/// Top of the window: "Project › Clip" so it's always clear what you're looking at.
/// On a clip, clicking the project name goes back to the full recording; on the full recording the name can be edited.
struct Breadcrumb: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        HStack(spacing: 6) {
            if let clip = model.selectedClip {
                Button { model.select(clip: nil) } label: {
                    Text(model.project.name).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(maxWidth: 220)
                .fixedSize(horizontal: true, vertical: false)
                .help("Back to the full recording")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                Text(clip.title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .help(clip.title + "\nRight-click the clip in the list > Rename… to change it")
            } else {
                // sized to the name, so the "›" sits right after it
                Text(model.project.name.isEmpty ? "Project name" : model.project.name)
                    .font(.headline).lineLimit(1).padding(.horizontal, 6).hidden()
                    .frame(minWidth: 60, maxWidth: 260)
                    .overlay(
                        TextField("Project name", text: Binding(get: { model.project.name }, set: { v in
                            model.liveEdit { $0.name = v }
                        }))
                        .textFieldStyle(.plain).font(.headline).multilineTextAlignment(.trailing)
                    )
                .help("Project name — click to rename it (it's also the folder your exports go in)")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                Text("Full recording").font(.headline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 560)
    }
}

struct BusyOverlay: View {
    var text: String
    var progress: Double
    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress > 0 ? progress : nil).frame(width: 260)
            Text(text).foregroundStyle(.white)
            Text("You can leave this running. Everything stays on your Mac.").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Top-right Export button: saves the selected clip (the file name starts as the clip's title).
struct ExportToolbarButton: View {
    @ObservedObject var model: ProjectModel
    var body: some View {
        if let id = model.selectedClipID, let p = model.exporting[id] {
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                .help("Exporting… \(Int(p * 100))%")
        } else {
            Button { if let id = model.selectedClipID { Task { await model.exportAsking(id) } } } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedClip == nil || model.busy != nil)
            .help(model.selectedClip == nil ? "Pick a clip to export" : "Export this clip (⌘E)")
        }
    }
}

// MARK: - Sidebar

struct ClipsSidebar: View {
    @ObservedObject var model: ProjectModel
    @AppStorage("clipFilter") var filter = "all"
    @State private var renaming: UUID? = nil

    static let filters: [(String, String)] = [("all", "All"), ("unmarked", "To review"), ("used", "Used"), ("rejected", "Rejected")]

    func shown(_ c: Clip) -> Bool { ProjectModel.clipShown(c, filter: filter) }

    var header: some View {
        let cs = model.project.clips
        let used = cs.filter { $0.status == .used }.count, rej = cs.filter { $0.status == .rejected }.count
        let left = cs.count - used - rej
        return HStack(spacing: 6) {
            Text("Clips (\(cs.count))")
            if used > 0 { Text("✓\(used)").foregroundStyle(.green).help("\(used) used") }
            if rej > 0 { Text("✕\(rej)").foregroundStyle(.red).help("\(rej) rejected") }
            Spacer()
            if left > 0 && left < cs.count { Text("\(left) to review").foregroundStyle(.secondary) }
        }
    }

    var filterBar: some View {
        Picker("Show", selection: Binding(get: { Self.filters.contains { $0.0 == filter } ? filter : "all" }, set: { filter = $0 })) {
            ForEach(Self.filters, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .help("Show every clip, only the ones you haven't marked yet, or only used / rejected ones. U / X marks a clip and moves on to the next.")
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            List(selection: Binding(get: { model.selectedClipID ?? fullID }, set: { id in
                model.select(clip: id == fullID ? nil : id)
            })) {
                Label("Full recording", systemImage: "film").tag(fullID)
                    .font(.body.weight(.medium))
                Section(header: header) {
                    ForEach(model.project.clips.filter(shown)) { c in
                        ClipRow(model: model, clip: c, renaming: $renaming).tag(c.id)
                            .contextMenu {
                                Button("Rename…") { renaming = c.id }
                                Divider()
                                Button(c.status == .used ? "✓ Used" : "Mark as Used  (U)") { model.toggleStatus(.used, for: c.id) }
                                Button(c.status == .rejected ? "✕ Rejected" : "Mark as Rejected  (X)") { model.toggleStatus(.rejected, for: c.id) }
                                if c.status != nil { Button("Clear Mark") { model.setStatus(nil, for: c.id) } }
                                if !c.switches.isEmpty {
                                    Button("Camera Back to All-Automatic") { model.select(clip: c.id); model.clearSwitches() }
                                }
                                if !c.soundChanges.isEmpty {
                                    Button("Same Sound for the Whole Clip") { model.select(clip: c.id); model.clearSoundChanges() }
                                }
                                Divider()
                                Button("Export") { Task { await model.exportAsking(c.id) } }
                                Button("Duplicate") { model.duplicateClip(c.id) }
                                Divider()
                                Button("Delete", role: .destructive) { model.deleteClip(c.id) }
                            }
                    }
                    if filter != "all" && model.project.clips.contains(where: { !shown($0) }) {
                        Button("Showing \(Self.filters.first { $0.0 == filter }?.1.lowercased() ?? filter) · show all") { filter = "all" }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
    let fullID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

struct ClipRow: View {
    @ObservedObject var model: ProjectModel
    var clip: Clip
    @Binding var renaming: UUID?
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            statusIcon
        VStack(alignment: .leading, spacing: 3) {
            if renaming == clip.id {
                TextField("Clip name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onAppear { draft = clip.title; DispatchQueue.main.async { focused = true } }
                    .onChange(of: focused) { _, f in if !f && renaming == clip.id { commitRename() } }
                    .help("Type the new name. Return saves, Esc cancels. Exports start with this name.")
            } else {
                Text(clip.title).lineLimit(2).font(.body)
                    .strikethrough(clip.status == .rejected, color: .secondary)
                    .foregroundStyle(clip.status == .rejected ? .secondary : .primary)
            }
            HStack(spacing: 5) {
                Text("starts \(fmtTime(clip.start))").monospacedDigit()
                Text("·")
                Text(String(format: "%.0f s long", clip.outputDuration)).monospacedDigit()
                if let s = clip.score { Text("·"); Text("score \(Int(s))") }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let p = model.exporting[clip.id] { ProgressView(value: p).controlSize(.small) }
        }
        }
        .padding(.vertical, 2)
        .opacity(clip.status == .rejected ? 0.55 : 1)
        .help(rowHelp)
    }

    var rowHelp: String {
        var parts: [String] = []
        if !clip.note.isEmpty { parts.append(clip.note) }
        if let s = clip.score { parts.append("Claude's score: \(Int(s)) out of 10.") }
        parts.append("Starts \(fmtTime(clip.start)) into the recording, \(String(format: "%.0f", clip.outputDuration)) seconds long, \(clip.format.label).")
        return parts.joined(separator: "\n")
    }

    func commitRename() {
        model.renameClip(clip.id, to: draft)
        renaming = nil
    }

    @ViewBuilder var statusIcon: some View {
        switch clip.status {
        case .used: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.gold).help("Used")
        case .rejected: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Rejected")
        case nil: Image(systemName: "circle").foregroundStyle(.tertiary).help("Not marked yet. U = used, X = rejected")
        }
    }
}

// MARK: - Transport

/// The row above the timeline: camera on the left, play controls in the middle, sound on the right.
struct TransportBar: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                AngleButtons(model: model, engine: engine)
                Spacer(minLength: 150)
                AudioButtons(model: model, engine: engine)
            }
            HStack(spacing: 18) {
                Button { engine.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Back one frame (←). J jumps back 3 seconds.")
                Button { engine.toggle() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 28, height: 24)
                }
                .help(engine.isPlaying ? "Pause (space)" : "Play (space)")
                Button { engine.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Forward one frame (→). L jumps ahead 3 seconds.")
            }
            .font(.callout)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 5)
    }
}

/// Camera: Auto / A / B / C as one control. The chosen one is filled in its camera colour;
/// while on Auto, the camera Auto is showing right now gets a coloured outline.
struct AngleButtons: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        let now = currentAngle
        let auto = isAuto
        let inClip = model.selectedClip != nil
        HStack(spacing: 8) {
            Text("Camera").font(.caption).foregroundStyle(.secondary).fixedSize()
            HStack(spacing: 2) {
                seg("Auto", selected: auto, live: false, color: Brand.green,
                    help: inClip ? "From the playhead on, follow whoever is talking (0)" : "Follow whoever is talking (0)") {
                    model.cutTo(angle: nil)
                }
                ForEach(Array(model.project.videoIndices.enumerated()), id: \.element) { k, i in
                    let a = model.project.angles[i]
                    let showing = now == i
                    seg(a.shortName, selected: !auto && showing, live: auto && showing, color: angleColors[i % angleColors.count],
                        help: (inClip ? "Cut to \(a.name) at the playhead (\(k + 1)). Works while playing."
                                      : "Watch \(a.name) (\(k + 1))") + (auto && showing ? "\nAuto is showing this camera right now." : "")) {
                        model.cutTo(angle: i)
                    }
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    func seg(_ title: String, selected: Bool, live: Bool, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected || live ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : (live ? color : Color.primary))
                .frame(minWidth: title.count > 1 ? 40 : 26)
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? color : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(live ? color : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    var isAuto: Bool {
        if let c = model.selectedClip {
            let m = model.masterTime(engine.time)
            return c.switches.last(where: { $0.time <= m + 1e-6 })?.angle == nil
        }
        return model.fullViewAngle == nil
    }
    var currentAngle: Int? {
        guard let pieces = engine.built?.pieces else { return nil }
        return pieces.last(where: { $0.outStart <= engine.time + 1e-4 })?.angle
    }
}

/// Sound: one menu showing what you hear (with its colour), plus the level mixer.
struct AudioButtons: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @State private var showMixer = false

    var body: some View {
        let p = model.project
        let mix = model.currentMix
        let sources = p.angles.indices.filter { p.angles[$0].hasAudio }
        let lit = sources.filter { mix.isOn($0) }
        let isDefault = mix.on == p.defaultMix.on
        let inClip = model.selectedClip != nil
        HStack(spacing: 8) {
            Text("Sound").font(.caption).foregroundStyle(.secondary).fixedSize()
            Circle().fill(lit.isEmpty ? Color.red : (isDefault && lit.count > 1 ? Brand.green : soundColor(p, mix.on)))
                .frame(width: 8, height: 8)
            Menu {
                if sources.count > 1 {
                    Toggle(defaultName, isOn: Binding(get: { isDefault }, set: { _ in model.audioPreset(nil) }))
                    Divider()
                }
                Section("Hear only") {
                    ForEach(sources, id: \.self) { i in
                        Toggle(p.angles[i].name, isOn: Binding(get: { lit == [i] }, set: { _ in model.audioPreset(i, adding: false) }))
                    }
                }
                let off = sources.filter { !mix.isOn($0) }
                if !off.isEmpty && !lit.isEmpty {
                    Section("Add to what's playing") {
                        ForEach(off, id: \.self) { i in
                            Button("+ " + p.angles[i].name) { model.audioPreset(i, adding: true) }
                        }
                    }
                }
            } label: {
                Text(label(p, lit: lit, isDefault: isDefault))
            }
            .fixedSize()
            .controlSize(.small)
            .help(inClip ? "What you hear. In a clip, a change applies to the selected words, or from the playhead on." : "What you hear")
            Button { showMixer.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Fine-tune each source's level")
                .popover(isPresented: $showMixer) { MixerPopover(model: model).padding(16).frame(width: 300) }
        }
    }

    var defaultName: String {
        let p = model.project
        let sources = p.angles.indices.filter { p.angles[$0].hasAudio }
        if p.micIndices.isEmpty { return sources.count == 2 ? "Both cameras" : "All cameras" }
        return p.micIndices.count == 2 ? "Both mics" : "All mics"
    }

    func label(_ p: Project, lit: [Int], isDefault: Bool) -> String {
        if lit.isEmpty { return "Silent" }
        if isDefault && lit.count > 1 { return defaultName }
        return lit.map { p.angles[$0].shortName }.joined(separator: " + ")
    }
}

struct MixerPopover: View {
    @ObservedObject var model: ProjectModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedClip == nil ? "Sound for the full recording" : "Sound for this clip").font(.headline)
            ForEach(model.project.angles.indices, id: \.self) { i in
                let mix = model.currentMix
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(model.project.angles[i].name, isOn: Binding(get: { mix.isOn(i) }, set: { v in
                        var m = model.currentMix; m.ensure(model.project.angles.count); m.on[i] = v; model.setAudio(m)
                    }))
                    .disabled(!model.project.angles[i].hasAudio)
                    HStack {
                        Slider(value: Binding(get: { mix.gain(i) }, set: { v in
                            var m = model.currentMix; m.ensure(model.project.angles.count); m.gainDB[i] = v; model.setAudio(m)
                        }), in: -24...0)
                        Text(String(format: "%.0f dB", mix.gain(i))).monospacedDigit().frame(width: 48)
                    }
                }
            }
            Text("Levels are already matched between the cameras when the project is analysed.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Transcript header

struct TranscriptHeader: View {
    @ObservedObject var model: ProjectModel
    @Binding var fontSize: Double

    var body: some View {
        if let r = model.editingWords {
            FixTextBar(model: model, range: r)
        } else {
            normal
        }
    }

    var normal: some View {
        HStack(spacing: 8) {
            if let sel = model.selection {
                let ws = model.project.words
                Text("\(sel.count) word\(sel.count == 1 ? "" : "s") · \(String(format: "%.1fs", ws[sel.upperBound].end - ws[sel.lowerBound].start))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fix text") { model.beginEditingText() }
                    .help("Correct what the transcript says for these words (E, or double-click a word)")
                Button(model.allHidden(sel) ? "Unhide" : "Hide") { model.toggleHiddenSelection() }
                    .help("Leave these words out of the transcript and captions without cutting the video (H)")
                Button("Make clip") { model.makeClipFromSelection() }
                    .help("Make a new clip from the selected words (C)")
                if model.selectedClip != nil {
                    Button("Remove") { model.cutSelection() }.help("Cut these words out of the clip (Delete)")
                    Button("Restore") { model.restoreSelection() }.help("Put cut words back (R)")
                    Button("Start here") { model.setStart(toWord: sel.lowerBound) }.help("Clip starts at the first selected word ([)")
                    Button("End here") { model.setEnd(toWord: sel.upperBound) }.help("Clip ends at the last selected word (])")
                }
            } else {
                Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .help("Click a word to jump there. Drag across words to make a clip (C). Double-click a word to fix its text.")
                Spacer()
                let hiddenCount = model.hiddenWordCount
                if hiddenCount > 0 {
                    Button { model.showHiddenWords.toggle() } label: {
                        Label("\(hiddenCount)", systemImage: model.showHiddenWords ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .help(model.showHiddenWords
                          ? "Hidden words are showing (faded). Click to leave them out of the transcript."
                          : "\(hiddenCount) hidden word\(hiddenCount == 1 ? "" : "s"). Click to show them so you can un-hide them.")
                }
                Button { fontSize = max(11, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }.buttonStyle(.borderless)
                    .help("Smaller transcript text")
                Button { fontSize = min(26, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }.buttonStyle(.borderless)
                    .help("Larger transcript text")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Keyboard

/// Single-key shortcuts (space, 1/2, 0, C, Delete…) that work anywhere except while typing in a text box.
final class KeyMonitor {
    private var token: Any?
    func install(_ model: ProjectModel) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
            guard let model else { return e }
            if let tv = e.window?.firstResponder as? NSTextView, tv.isEditable { return e }   // typing
            if e.window?.attachedSheet != nil || NSApp.modalWindow != nil { return e }
            if e.window?.isSheet == true { return e }
            return MainActor.assumeIsolated { handleKey(model, e) } ? nil : e
        }
    }
    func remove() { if let t = token { NSEvent.removeMonitor(t) }; token = nil }
}

@MainActor
func handleKey(_ model: ProjectModel, _ e: NSEvent) -> Bool {
    let mods = e.modifierFlags.intersection([.command, .option, .control])
    let chars0 = e.charactersIgnoringModifiers ?? ""
    // ⌥[ / ⌥] : trim the clip's start / end to the playhead (Final Cut)
    if mods == [.option] {
        if e.keyCode == 33 || chars0 == "[" || chars0 == "“" { model.trimStartToPlayhead(); return true }
        if e.keyCode == 30 || chars0 == "]" || chars0 == "‘" { model.trimEndToPlayhead(); return true }
        return false
    }
    if !mods.isEmpty { return false }
    let shift = e.modifierFlags.contains(.shift)
    switch e.keyCode {
    case 49: model.engine.toggle(); return true                                   // space
    case 51, 117:                                                                  // delete
        if model.tlSel != nil { model.cutTimelineSelection(); return true }
        if model.selectedClip != nil, let id = model.selectedCaption { model.deleteCaption(id); return true }
        if model.selectedClip != nil, model.selection != nil { model.cutSelection(); return true }
        return false
    case 53:                                                                       // escape
        if model.editingWords != nil { model.editingWords = nil; return true }
        if model.selectedCaption != nil { model.selectedCaption = nil; return true }
        if model.tlSel != nil { model.tlSel = nil; return true }
        if model.selection != nil { model.selection = nil; return true }
        return false
    case 36, 76:                                                                   // return
        if model.selectedClip != nil, let id = model.selectedCaption { model.editingCaption = id; return true }
        if model.selection != nil { model.beginEditingText(); return true }
        return false
    case 125, 126:                                                                 // down / up: next / previous edit point
        if e.window?.firstResponder is NSTableView { return false }               // (the clip list uses arrows)
        model.jumpEditPoint(next: e.keyCode == 125); return true
    case 123: model.engine.step(frames: shift ? -10 : -1); return true             // left
    case 124: model.engine.step(frames: shift ? 10 : 1); return true               // right
    default: break
    }
    let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
    switch chars {
    case "1", "2", "3", "4":
        let k = Int(chars)! - 1
        let vids = model.project.videoIndices
        if k < vids.count { model.cutTo(angle: vids[k]) }
        return true
    case "0", "`": model.cutTo(angle: nil); return true
    case "c":
        if model.selection != nil { model.makeClipFromSelection(); return true }
        if model.selectedClip == nil, model.tlSel != nil { model.timelineSelectionToClip(); return true }
        return false
    case "e":
        if model.selectedClip != nil, let id = model.selectedCaption { model.editingCaption = id; return true }
        if model.selection != nil { model.beginEditingText(); return true }; return false
    case "h": if model.selection != nil { model.toggleHiddenSelection(); return true }; return false
    case "b": model.bladeAtPlayhead(); return true
    case "m": model.addMarker(); return true
    case "n": model.snapping.toggle(); return true
    case "s": model.skimming.toggle(); return true
    case "i": model.setRangeIn(); return true
    case "o": model.setRangeOut(); return true
    case "u": if model.selectedClip != nil { model.markAndAdvance(.used); return true }; return false
    case "x": if model.selectedClip != nil { model.markAndAdvance(.rejected); return true }; return false
    case "z": if shift { model.fitTimeline(); return true }; return false
    case "[": if let s = model.selection { model.setStart(toWord: s.lowerBound); return true }; return false
    case "]": if let s = model.selection { model.setEnd(toWord: s.upperBound); return true }; return false
    case "r": if model.selection != nil { model.restoreSelection(); return true }; return false
    case "=", "+": model.zoomTimeline(by: 1.6); return true
    case "-", "_": model.zoomTimeline(by: 1 / 1.6); return true
    case "j": model.engine.seek(max(0, model.engine.time - 3)); return true
    case "l": model.engine.seek(model.engine.time + 3); return true
    case "k": model.engine.pause(); return true
    default: return false
    }
}

// MARK: - Sound colours / labels

func sourceColor(_ p: Project, _ i: Int) -> Color {
    if i < p.angles.count, p.angles[i].isVideo { return angleColors[i % angleColors.count] }
    let mics = p.angles.indices.filter { !p.angles[$0].isVideo }
    let k = mics.firstIndex(of: i) ?? 0
    return [Color(nsColor: .systemCyan), Color(nsColor: .systemIndigo), Color(nsColor: .systemBrown), Color(nsColor: .systemGray)][k % 4]
}

func soundColor(_ p: Project, _ on: [Bool]) -> Color {
    let lit = p.angles.indices.filter { $0 < on.count && on[$0] }
    if lit.count == 1 { return sourceColor(p, lit[0]) }
    return lit.isEmpty ? Color.red : Color.gray
}

func soundLabel(_ p: Project, _ on: [Bool]) -> String {
    let lit = p.angles.indices.filter { $0 < on.count && on[$0] }
    if lit.isEmpty { return "silent" }
    if on == p.defaultMix.on && lit.count > 1 { return p.micIndices.isEmpty ? "all" : "both mics" }
    return lit.map { p.angles[$0].shortName }.joined(separator: " + ")
}


// MARK: - Fixing the transcript

/// Shown over the transcript while correcting words: type the right text, Return to save.
struct FixTextBar: View {
    @ObservedObject var model: ProjectModel
    var range: ClosedRange<Int>
    @State private var text = ""
    @State private var everywhere = false
    @FocusState private var focused: Bool

    var body: some View {
        let original = model.text(of: range)
        let count = model.occurrences(of: range).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "character.cursor.ibeam").foregroundStyle(.secondary)
                Text("Fix the transcript").font(.caption.weight(.semibold))
                if range.upperBound < model.project.words.count {
                    Text("at \(fmtTime(model.project.words[range.lowerBound].start, frac: true))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("heard: “\(original)”").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                TextField("What was actually said", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { save() }
                    .onExitCommand { model.editingWords = nil }
                Button("Save") { save() }.buttonStyle(.borderedProminent)
                Button("Cancel") { model.editingWords = nil }
            }
            if count > 1 {
                Toggle("Fix all \(count) places it heard “\(original)”", isOn: $everywhere)
                    .font(.caption).toggleStyle(.checkbox)
            }
            Text(text.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Leave it empty to remove these words from the transcript (and the captions)."
                 : "Fixes the transcript and the captions. The words keep their place in time. ⌘Z undoes.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
        .onAppear { text = original; everywhere = false; DispatchQueue.main.async { focused = true } }
        .onChange(of: range) { _, r in text = model.text(of: r); everywhere = false; focused = true }
    }

    func save() { model.correctWords(range, to: text, everywhere: everywhere) }
}


/// The bar above the timeline: drag it up or down to give the timeline more or less room.
struct SplitHandle: View {
    @Binding var height: Double
    /// true: the panel above the handle is the one being sized (drag down = bigger)
    var topPanel = false
    var minHeight: Double = 160
    /// room to leave for everything else in the window
    var roomBelow: Double = 330
    @State private var startHeight: Double? = nil

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 36, height: 3)
        }
        .frame(height: 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let h0 = startHeight ?? height
                if startHeight == nil { startHeight = h0 }
                let maxH = Double(NSApp.keyWindow?.frame.height ?? 900) - roomBelow
                let dy = Double(v.translation.height)
                height = max(minHeight, min(max(minHeight, maxH), topPanel ? h0 + dy : h0 - dy))
            }
            .onEnded { _ in startHeight = nil })
        .help(topPanel ? "Drag to give the clip list or the clip settings more room" : "Drag to make the timeline taller or shorter")
    }
}
