import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - In the clip settings (left column)

/// Under the framing controls: where the clip's thumbnail comes from, with buttons to pick the playhead frame or edit it.
struct ThumbnailRow: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    let clip: Clip

    var body: some View {
        let t = model.thumbnailOutTime(clip)
        let th = clip.thumbnail
        let src = th?.source ?? .clip
        let picked = th?.time != nil || src == .file
        let here = src == .clip && th?.time != nil && abs(engine.time - t) < 0.02
        HStack(spacing: 6) {
            Image(systemName: "photo").foregroundStyle(picked ? Brand.green : .secondary)
            Button {
                if src == .clip { engine.pause(); engine.seek(t) } else { model.showThumbnail = true }
            } label: {
                Text(label(src, t)).font(.caption).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(src == .clip ? (picked ? "Click to go to the thumbnail's frame" : "No frame picked yet, so the thumbnail uses the frame one second in. Go to a better frame and press T.")
                  : "Click to see the thumbnail")
            Spacer(minLength: 4)
            Button(here ? "✓ This frame" : "Use This Frame") { model.useFrameAsThumbnail() }
                .controlSize(.mini).disabled(here)
                .help("Use the frame under the playhead as this clip's thumbnail (T)")
            Button("Edit…") { model.showThumbnail = true }
                .controlSize(.mini)
                .help("Pick the frame (from the clip, anywhere in the recording, or a picture file), the title, shade, logo and picture, and save it")
        }
    }

    func label(_ s: ThumbSource, _ t: Double) -> String {
        switch s {
        case .file: return "Thumbnail: picture file"
        case .recording: return "Thumbnail: recording \(fmtTime(clip.thumbnail?.time ?? 0, frac: true))"
        case .clip: return clip.thumbnail?.time != nil ? "Thumbnail at \(fmtTime(t, frac: true))" : "Thumbnail: 1 s in"
        }
    }
}

/// Frames grabbed with G in what's showing: how many, save them, clear them.
struct GrabsRow: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        let n = model.grabsInView.count
        if n > 0 {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill").foregroundStyle(Brand.gold)
                Button { Task { await model.saveGrabsAsking() } } label: {
                    Text("Save \(n) Grabbed Frame\(n == 1 ? "" : "s")…")
                }
                .controlSize(.small)
                .help("Save every frame you grabbed with G as a picture, into a Frame Grabs folder")
                Spacer(minLength: 4)
                Button { model.clearGrabs() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Un-grab all \(n) (⌘Z undoes)")
            }
        }
    }
}

// MARK: - The preview (in place of the video while the thumbnail editor is open)

struct ThumbnailPreview: View {
    @ObservedObject var model: ProjectModel
    @State private var preview: NSImage? = nil
    @State private var shownFor: UUID? = nil
    @State private var rendering = false
    @State private var problem: String? = nil

    var body: some View {
        if let clip = model.selectedClip {
            let size = clip.format.renderSize
            VStack(spacing: 8) {
                ZStack {
                    if let img = preview, shownFor == clip.id {
                        Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color(white: 0.12)).aspectRatio(size.width / size.height, contentMode: .fit)
                    }
                    if rendering && (preview == nil || shownFor != clip.id) { ProgressView().controlSize(.small) }
                    if let p = problem {
                        Text(p).font(.callout).foregroundStyle(.white).padding(8)
                            .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(Brand.green)
                    Text("Thumbnail · \(Int(size.width))×\(Int(size.height))").font(.caption.weight(.semibold))
                    Text("· \(sourceText(clip))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if rendering && preview != nil { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(.white)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .task(id: renderKey(clip)) { await render(clip) }
        }
    }

    func sourceText(_ c: Clip) -> String {
        switch c.thumbnail?.source ?? .clip {
        case .file: return URL(fileURLWithPath: c.thumbnail?.imagePath ?? "").lastPathComponent
        case .recording:
            let cam = c.thumbnail?.angle.map { model.project.angles.indices.contains($0) ? "camera \(model.project.angles[$0].shortName)" : "" } ?? "automatic camera"
            return "recording \(fmtTime(c.thumbnail?.time ?? 0, frac: true)), \(cam)"
        case .clip: return "clip \(fmtTime(model.thumbnailOutTime(c), frac: true))"
        }
    }

    func renderKey(_ c: Clip) -> String { "\(c.hashValue)|\(model.thumbnailStyle.hashValue)|\(model.project.angles.hashValue)" }

    func render(_ c: Clip) async {
        rendering = true
        defer { rendering = false }
        try? await Task.sleep(nanoseconds: 90_000_000)
        if Task.isCancelled { return }
        do {
            let img = try await model.thumbnailImage(c)
            if Task.isCancelled { return }
            preview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            shownFor = c.id
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - The thumbnail settings (in place of the captions panel)

struct ThumbnailSheet: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @State private var presets = Store.loadThumbPresets()
    @State private var showSave = false
    @State private var presetName = ""
    @State private var titleText = ""
    @State private var titleClip: UUID? = nil

    var s: ThumbnailStyle { model.thumbnailStyle }
    func set(_ change: (inout ThumbnailStyle) -> Void) { var st = s; change(&st); model.setThumbnailStyle(st) }

    var body: some View {
        if let clip = model.selectedClip {
            VStack(spacing: 0) {
                header
                Divider()
                Form {
                    Section("Picture to use") { frameControls(clip) }
                    Section("This clip's title") { titleField(clip) }
                    Section {
                        titleControls
                    } header: {
                        HStack {
                            Text("Title look")
                            Spacer()
                            if model.thumbnailStyleIsCaptions {
                                Text("following the caption style").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Shade behind the title") {
                        slider("Strength", s.shade, 0...0.95) { v in set { $0.shade = v } }
                        ColorPicker("Colour", selection: Binding(get: { s.shadeColor.color }, set: { v in set { $0.shadeColor = RGBA(v) } }))
                            .disabled(s.shade < 0.01)
                    }
                    Section("Logo") { logoControls }
                    Section("Adjust the picture") {
                        slider("Brightness", s.brightness, -0.3...0.3) { v in set { $0.brightness = v } }
                        slider("Contrast", s.contrast, 0.6...1.6) { v in set { $0.contrast = v } }
                        slider("Saturation", s.saturation, 0...2) { v in set { $0.saturation = v } }
                        Button("Reset the picture") { set { $0.brightness = 0; $0.contrast = 1; $0.saturation = 1 } }
                            .disabled(s.pictureIsDefault)
                    }
                    Section("Saving") {
                        HStack {
                            Button("Save Thumbnail…") { Task { await model.saveThumbnailAsking(clip.id) } }
                            Spacer()
                        }
                        Toggle("Save a thumbnail next to every exported video", isOn: Binding(get: { s.withExport }, set: { v in set { $0.withExport = v } }))
                        Picker("File type", selection: Binding(get: { s.png }, set: { v in set { $0.png = v } })) {
                            Text("JPEG").tag(false); Text("PNG").tag(true)
                        }
                        Text("The look starts from the caption style and is shared by every clip in this project; each clip keeps its own picture and title. Presets carry a look to other projects.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            .onAppear { engine.pause(); syncTitle(clip) }
            .onChange(of: clip.id) { _, _ in syncTitle(clip) }
            .alert("Save thumbnail preset", isPresented: $showSave) {
                TextField("Preset name", text: $presetName)
                Button("Save") { savePreset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saves this thumbnail look (title, shade, logo, picture) so you can use it in any project. A name that already exists is replaced.")
            }
        }
    }

    var header: some View {
        HStack {
            Text("Thumbnail").font(.title3.weight(.semibold))
            Spacer()
            Menu("Presets") {
                Button("Match the Caption Style") {
                    model.setThumbnailStyle(ThumbnailStyle.matching(model.project.captionStyle, keeping: s))
                }
                Section("Built in") {
                    ForEach(ThumbnailStyle.builtIns) { p in Button(p.name) { applyPreset(p.style) } }
                }
                if !presets.presets.isEmpty {
                    Section("My presets") {
                        ForEach(presets.presets) { p in
                            Button(p.name + (presets.defaultName == p.name ? "  (new projects)" : "")) { applyPreset(p.style) }
                        }
                    }
                }
                Divider()
                Button("Save current look as a preset…") { presetName = ""; showSave = true }
                if !presets.presets.isEmpty {
                    Menu("Start new projects with") {
                        Button("The caption style" + (presets.defaultName == nil ? "  ✓" : "")) { presets.defaultName = nil; Store.saveThumbPresets(presets) }
                        ForEach(presets.presets) { p in
                            Button(p.name + (presets.defaultName == p.name ? "  ✓" : "")) { presets.defaultName = p.name; Store.saveThumbPresets(presets) }
                        }
                    }
                    Menu("Delete a preset") {
                        ForEach(presets.presets) { p in
                            Button(p.name, role: .destructive) {
                                presets.presets.removeAll { $0.name == p.name }
                                if presets.defaultName == p.name { presets.defaultName = nil }
                                Store.saveThumbPresets(presets)
                            }
                        }
                    }
                }
            }
            .fixedSize()
            Button("Done") { model.showThumbnail = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    /// A preset keeps this project's logo when it has none of its own.
    func applyPreset(_ st: ThumbnailStyle) {
        var n = st
        if n.logoPath == nil { n.logoPath = s.logoPath; n.logoSize = s.logoSize; n.logoCorner = s.logoCorner }
        n.withExport = s.withExport
        model.setThumbnailStyle(n)
    }

    func savePreset() {
        let n = presetName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        presets.presets.removeAll { $0.name == n }
        presets.presets.append(ThumbnailPreset(name: n, style: s))
        presets.presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Store.saveThumbPresets(presets)
        model.notice = "Saved thumbnail preset “\(n)”. It's in Presets in every project."
    }

    // MARK: where the picture comes from

    var frameStep: Double { 1 / max(1, model.project.angles.first { $0.isVideo }?.fps ?? 30) }

    @ViewBuilder func frameControls(_ clip: Clip) -> some View {
        let src = clip.thumbnail?.source ?? .clip
        Picker("From", selection: Binding(get: { src }, set: { v in
            if v == .file { DispatchQueue.main.async { chooseImage(clip) } } else { model.setThumbnailSource(clip.id, v) }
        })) {
            ForEach(ThumbSource.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        switch src {
        case .clip:
            let t = model.thumbnailOutTime(clip)
            scrubber(value: t, range: 0...max(0.05, clip.outputDuration - 0.02),
                     set: { v, live in model.setThumbnailClipTime(clip.id, out: v, live: live) })
            HStack {
                Text(clip.thumbnail?.time == nil ? "None picked yet: one second in." : "Or move the playhead and press T.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Use Playhead") { model.useFrameAsThumbnail() }.controlSize(.small)
                    .help("Use the frame under the playhead (T)")
            }
        case .recording:
            let m = clip.thumbnail?.time ?? model.thumbnailMasterTime(clip)
            scrubber(value: m, range: 0...max(0.05, model.project.masterDuration - 0.02),
                     set: { v, live in model.setThumbnailRecordingTime(clip.id, master: v, live: live) })
            HStack {
                Text(m >= clip.start && m <= clip.end ? "Inside the clip" : (m < clip.start ? "\(fmtSpan(clip.start - m)) before the clip" : "\(fmtSpan(m - clip.end)) after the clip"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clip Start") { model.setThumbnailRecordingTime(clip.id, master: clip.start + 0.5) }.controlSize(.small)
            }
            Picker("Camera", selection: Binding(get: { clip.thumbnail?.angle ?? -1 }, set: { v in model.setThumbnailAngle(clip.id, v < 0 ? nil : v) })) {
                Text("Auto").tag(-1)
                ForEach(model.project.videoIndices, id: \.self) { i in Text(model.project.angles[i].shortName).tag(i) }
            }
            .pickerStyle(.segmented)
            .help("Auto shows whoever is talking at that moment; the picture uses this clip's framing for that camera")
        case .file:
            HStack {
                Image(systemName: "photo.on.rectangle")
                Text(URL(fileURLWithPath: clip.thumbnail?.imagePath ?? "").lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseImage(clip) }.controlSize(.small)
            }
            Text("The picture fills the clip's shape (centred). Title, shade, logo and picture adjustments go on top.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A slider over the frames, with frame-step buttons and the time (click to type one).
    @ViewBuilder func scrubber(value: Double, range: ClosedRange<Double>, set: @escaping (Double, Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Button { set(max(range.lowerBound, value - frameStep), false) } label: { Image(systemName: "backward.frame.fill") }
                .buttonStyle(.borderless).help("Back one frame")
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { set($0, true) }), in: range)
                .controlSize(.small)
            Button { set(min(range.upperBound, value + frameStep), false) } label: { Image(systemName: "forward.frame.fill") }
                .buttonStyle(.borderless).help("Forward one frame")
            ReadoutField(text: fmtTime(value, frac: true), enabled: true, help: "Click to type a time (like 12:34.5)") { typed in
                guard let t = parseTime(typed) else { return false }
                set(min(range.upperBound, max(range.lowerBound, t)), false)
                return true
            }
            .frame(minWidth: 56)
        }
    }

    func chooseImage(_ clip: Clip) {
        let p = NSOpenPanel()
        p.title = "Choose a Picture for the Thumbnail"
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.message = "It fills the clip's shape; the title, shade and logo go on top."
        if let cur = clip.thumbnail?.imagePath { p.directoryURL = URL(fileURLWithPath: cur).deletingLastPathComponent() }
        guard p.runModal() == .OK, let u = p.url else { return }
        guard NSImage(contentsOf: u) != nil else { model.errorText = "That file isn't a picture Winnow can read."; return }
        model.setThumbnailImage(clip.id, u.path)
    }

    // MARK: title

    @ViewBuilder func titleField(_ clip: Clip) -> some View {
        TextField(clip.title, text: $titleText, axis: .vertical)
            .lineLimit(1...3)
            .onChange(of: titleText) { _, v in
                if titleClip == clip.id, v != (clip.thumbnail?.title ?? "") { model.setThumbnailTitle(clip.id, v) }
            }
            .help("Leave it empty to use the clip's name. Press ⌥Return for a new line.")
        if clip.thumbnail != nil {
            HStack {
                Spacer()
                Button("Reset This Clip's Thumbnail") { model.updateClip(rebuild: false) { $0.thumbnail = nil }; titleText = "" }
                    .controlSize(.small).help("Back to the frame one second in and the clip's name")
            }
        }
    }

    @ViewBuilder var titleControls: some View {
        Toggle("Show the title", isOn: Binding(get: { s.showTitle }, set: { v in set { $0.showTitle = v } }))
        Group {
            let cs: CaptionStyle = { var c = CaptionStyle(); c.fontName = s.fontName; c.fontWeight = s.fontWeight; return c }()
            CaptionFontControls(style: cs) { change in
                var c = cs; change(&c)
                set { $0.fontName = c.fontName; $0.fontWeight = c.fontWeight }
            }
            slider("Size", s.textSize, 0.03...0.2) { v in set { $0.textSize = v } }
            ColorPicker("Text colour", selection: Binding(get: { s.textColor.color }, set: { v in set { $0.textColor = RGBA(v) } }))
            Toggle("ALL CAPS", isOn: Binding(get: { s.uppercase }, set: { v in set { $0.uppercase = v } }))
            Picker("Line up", selection: Binding(get: { s.alignLeft }, set: { v in set { $0.alignLeft = v } })) {
                Text("Centre").tag(false); Text("Left").tag(true)
            }
            .pickerStyle(.segmented)
            slider("Height on picture", 1 - s.titleY, 0.05...0.95) { v in set { $0.titleY = 1 - v } }
                .help("Drag right to move the title up")
            slider("Width", s.textWidth, 0.4...0.96) { v in set { $0.textWidth = v } }
            slider("Outline", s.outline, 0...0.2) { v in set { $0.outline = v } }
            ColorPicker("Outline colour", selection: Binding(get: { s.outlineColor.color }, set: { v in set { $0.outlineColor = RGBA(v) } }))
                .disabled(s.outline < 0.001)
            Toggle("Drop shadow", isOn: Binding(get: { s.shadow }, set: { v in set { $0.shadow = v } }))
        }
        .disabled(!s.showTitle)
    }

    @ViewBuilder var logoControls: some View {
        HStack {
            if let p = s.logoPath {
                if let img = NSImage(contentsOfFile: p) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 24)
                }
                Text(URL(fileURLWithPath: p).lastPathComponent).lineLimit(1).truncationMode(.middle)
            } else {
                Text("No logo").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { chooseLogo() }.controlSize(.small)
            if s.logoPath != nil { Button("Remove") { set { $0.logoPath = nil } }.controlSize(.small) }
        }
        .help("A PNG with a see-through background works best")
        if s.logoPath != nil {
            slider("Size", s.logoSize, 0.06...0.5) { v in set { $0.logoSize = v } }
            Picker("Corner", selection: Binding(get: { s.logoCorner }, set: { v in set { $0.logoCorner = v } })) {
                ForEach(0..<4, id: \.self) { Text(ThumbnailStyle.cornerNames[$0]).tag($0) }
            }
        }
    }

    func chooseLogo() {
        let p = NSOpenPanel()
        p.title = "Choose a Logo"
        p.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .svg, .pdf]
        p.allowsMultipleSelection = false
        p.message = "A PNG with a see-through background works best."
        if let cur = s.logoPath { p.directoryURL = URL(fileURLWithPath: cur).deletingLastPathComponent() }
        guard p.runModal() == .OK, let u = p.url else { return }
        guard NSImage(contentsOf: u) != nil else { model.errorText = "That file isn't a picture Winnow can read."; return }
        set { $0.logoPath = u.path }
    }

    func syncTitle(_ clip: Clip?) {
        titleClip = clip?.id ?? model.selectedClipID
        titleText = clip?.thumbnail?.title ?? ""
    }

    func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}
