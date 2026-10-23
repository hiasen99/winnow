import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - In the clip settings

/// The clip's follow popups (click one to edit it) and a menu to add one at the playhead.
struct PopupsRow: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    var body: some View {
        let pops = clip.popups ?? []
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(pops.isEmpty ? Color.secondary : Brand.green)
                Text(pops.isEmpty ? "Follow popups" : "\(pops.count) follow popup\(pops.count == 1 ? "" : "s")").font(.caption)
                    .help(pops.isEmpty ? "None yet" : "Click one on the timeline's popup lane (above the picture) or in the viewer to edit it")
                Spacer(minLength: 4)
                Menu {
                    Button { model.addPopup(.circle) } label: { Label("Circle with Follow button", systemImage: PopupKind.circle.icon) }
                    Button { model.addPopup(.bar) } label: { Label("YouTube bar with Subscribe and bell", systemImage: PopupKind.bar.icon) }
                    Divider()
                    Button("Brands…") { model.showBrands = true }
                } label: { Text("Add at Playhead") }
                .controlSize(.mini).fixedSize()
                .help("Add a popup at the playhead asking people to follow or subscribe. It uses the project's brand (picture, name, colours); set those up in Brands…")
            }
        }
    }
}

// MARK: - The popup's settings (right column)

struct PopupPanel: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var lib = BrandLibrary.shared
    @State private var buttonText = ""
    @State private var textFor: UUID? = nil

    var body: some View {
        if let c = model.selectedClip, let p = model.popup(model.selectedPopup) {
            let b = Popups.brand(for: p, project: model.project)
            let sp = model.popupSpan(p)
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: p.kind.icon).foregroundStyle(b.color.color)
                    Text(p.kind == .circle ? "Follow Popup" : "Subscribe Bar").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { model.selectPopup(nil) }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                Form {
                    Section {
                        Picker("Kind", selection: Binding(get: { p.kind }, set: { k in model.updatePopup(p.id) { $0.kind = k } })) {
                            Text("Circle + Follow").tag(PopupKind.circle)
                            Text("YouTube bar").tag(PopupKind.bar)
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Picker("Brand", selection: Binding(get: { p.brandID }, set: { v in model.updatePopup(p.id) { $0.brandID = v } })) {
                                Text("Project's brand (\(model.projectBrand?.name ?? "none"))").tag(UUID?.none)
                                ForEach(lib.brands) { br in Text(br.name).tag(Optional(br.id)) }
                            }
                            Button("Brands…") { model.showBrands = true }.controlSize(.small)
                        }
                        if lib.brands.isEmpty {
                            Text("No brands yet, so it shows “Your Channel”. Click Brands… to add your picture, name and colours.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Button") {
                        TextField("Button word", text: $buttonText, prompt: Text(p.kind == .circle ? b.follow : b.subscribe))
                            .onChange(of: buttonText) { _, v in
                                guard textFor == p.id else { return }
                                let t = v.trimmingCharacters(in: .whitespaces)
                                if (p.button ?? "") != t { model.updatePopup(p.id, live: true) { $0.button = t.isEmpty ? nil : t } }
                            }
                        let w = Popups.words(p, b)
                        Toggle("Tap the button (\(w.before) → \(w.after)\(p.kind == .bar ? ", then ring the bell" : ""))",
                               isOn: Binding(get: { p.taps }, set: { v in model.updatePopup(p.id) { $0.tap = v ? nil : false } }))
                        Toggle("Show a hand doing the tapping", isOn: Binding(get: { p.showsHand }, set: { v in model.updatePopup(p.id) { $0.hand = v ? nil : false } }))
                            .disabled(!p.taps)
                        if p.taps && Popups.tapTime(p, start: sp.start, end: sp.end) == nil {
                            Text("Too short to fit the tap: make it at least \(p.kind == .circle ? "2.2" : "3") seconds long.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("Timing") {
                        HStack {
                            Text("Shows \(fmtTime(sp.start, frac: true))–\(fmtTime(sp.end, frac: true))").monospacedDigit()
                            Spacer()
                            Button { model.setPopupStart(p.id, out: sp.start - 0.5) } label: { Image(systemName: "chevron.left") }
                                .help("Half a second earlier")
                            Button { model.setPopupStart(p.id, out: sp.start + 0.5) } label: { Image(systemName: "chevron.right") }
                                .help("Half a second later")
                            Button("Start at Playhead") { model.movePopupToPlayhead(p.id) }
                        }
                        .controlSize(.small)
                        let maxLen = max(FollowPopup.minLength + 0.1, min(FollowPopup.maxLength, c.outputDuration - sp.start))
                        HStack {
                            Text("Length")
                            Slider(value: Binding(get: { min(p.length, maxLen) }, set: { v in model.updatePopup(p.id, live: true) { $0.length = (v * 10).rounded() / 10 } }),
                                   in: FollowPopup.minLength...maxLen)
                            Text(String(format: "%.1f s", min(p.length, maxLen))).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        Text("Drag it on the timeline's popup lane to move it, or its ends to change how long it shows.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Place") {
                        spots(p)
                        HStack {
                            Text("Size")
                            Slider(value: Binding(get: { p.size }, set: { v in model.updatePopup(p.id, live: true) { $0.scale = abs(v - 1) < 0.03 ? nil : v } }),
                                   in: FollowPopup.minSize...FollowPopup.maxSize)
                            Text(String(format: "%.0f%%", p.size * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        Text("Or drag the popup in the viewer.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        HStack {
                            Button("Duplicate") { model.duplicatePopup(p.id) }
                            Spacer()
                            Button("Delete Popup", role: .destructive) { model.removePopup(p.id) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .onAppear { syncText(p) }
            .onChange(of: p.id) { _, _ in syncText(p) }
        }
    }

    func syncText(_ p: FollowPopup) {
        textFor = nil
        buttonText = p.button ?? ""
        DispatchQueue.main.async { textFor = p.id }
    }

    /// A 3 × 3 grid of quick spots.
    func spots(_ p: FollowPopup) -> some View {
        let cur = PopupSpot.allCases.min { a, b in
            hypot(a.xy.0 - p.x, a.xy.1 - p.y) < hypot(b.xy.0 - p.x, b.xy.1 - p.y)
        }
        let near = cur.map { hypot($0.xy.0 - p.x, $0.xy.1 - p.y) < 0.03 } ?? false
        return HStack(alignment: .top) {
            Text("Spot")
            Spacer()
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(0..<3, id: \.self) { k in
                            let s = PopupSpot.allCases[r * 3 + k]
                            let on = near && s == cur
                            Button { model.placePopup(p.id, at: s) } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(on ? Brand.green : Color.secondary.opacity(0.25))
                                    .frame(width: 26, height: 16)
                            }
                            .buttonStyle(.plain)
                            .help(s.label)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Brand menu (captions panel header)

struct BrandMenu: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var lib = BrandLibrary.shared

    var body: some View {
        Menu {
            Button("No brand" + (model.project.brandID == nil ? "  ✓" : "")) { model.applyBrand(nil) }
            ForEach(lib.brands) { b in
                Button(b.name + (model.project.brandID == b.id ? "  ✓" : "")) { model.applyBrand(b.id) }
            }
            Divider()
            Button("Brands…") { model.showBrands = true }
        } label: {
            Label(model.projectBrand?.name ?? "Brand", systemImage: "person.crop.square")
        }
        .frame(maxWidth: 130)
        .fixedSize(horizontal: false, vertical: true)
        .help("The project's brand: picking one uses its caption look (and thumbnail look) and makes it who the follow popups are for.")
    }
}

// MARK: - The brand library

struct BrandsSheet: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var lib = BrandLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sel: UUID? = nil
    @State private var confirmDelete = false
    @State private var presets = Store.loadPresets()

    var current: ChannelBrand? { lib.brand(sel) }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $sel) {
                        ForEach(lib.brands) { b in
                            HStack(spacing: 8) {
                                avatar(b, size: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(b.name).lineLimit(1)
                                    if !b.displayHandle.isEmpty { Text(b.displayHandle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                                if model.project.brandID == b.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green).help("This project's brand")
                                }
                            }
                            .tag(b.id)
                        }
                    }
                    Divider()
                    HStack(spacing: 4) {
                        Button { sel = lib.add(named: "New Brand").id } label: { Image(systemName: "plus") }
                            .help("Add a brand")
                        Button { confirmDelete = true } label: { Image(systemName: "minus") }
                            .disabled(current == nil)
                            .help("Delete the selected brand")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
                Group {
                    if let b = current { editor(b) } else {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.square").font(.system(size: 40)).foregroundStyle(.tertiary)
                            Text(lib.brands.isEmpty ? "Make a brand for each channel or account you post for." : "Pick a brand to edit it.")
                                .foregroundStyle(.secondary)
                            if lib.brands.isEmpty { Button("Add a Brand") { sel = lib.add(named: model.project.name.isEmpty ? "My Channel" : "My Channel").id } }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let b = current {
                    Button(model.project.brandID == b.id ? "This Project Uses \(b.name)" : "Use \(b.name) for This Project") {
                        model.applyBrand(b.id)
                    }
                    .disabled(model.project.brandID == b.id)
                    .help("Sets this project's brand: popups use it, and its caption / thumbnail looks are applied")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 620)
        .onAppear {
            lib.reload()
            sel = model.project.brandID.flatMap { id in lib.brands.first { $0.id == id }?.id } ?? lib.brands.first?.id
        }
        .alert("Delete \(current?.name ?? "this brand")?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = sel { lib.remove(id); sel = lib.brands.first?.id; model.refreshPopups() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Projects and popups that use it will show “Your Channel” until you pick another brand.")
        }
    }

    func avatar(_ b: ChannelBrand, size: CGFloat) -> some View {
        Group {
            if let im = BrandStore.picture(b) {
                Image(decorative: im, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    b.color.color
                    Text(String(b.name.first ?? "?").uppercased()).font(.system(size: size * 0.45, weight: .heavy)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(b.color.color, lineWidth: max(1.5, size * 0.06)))
    }

    // edits save straight into the library (and the viewer redraws its popups)
    func save(_ b: ChannelBrand) { lib.save(b); model.refreshPopups() }
    func bind<T>(_ b: ChannelBrand, _ kp: WritableKeyPath<ChannelBrand, T>) -> Binding<T> {
        Binding(get: { lib.brand(b.id)?[keyPath: kp] ?? b[keyPath: kp] },
                set: { v in guard var x = lib.brand(b.id) else { return }; x[keyPath: kp] = v; save(x) })
    }
    func bindText(_ b: ChannelBrand, _ kp: WritableKeyPath<ChannelBrand, String?>) -> Binding<String> {
        Binding(get: { lib.brand(b.id)?[keyPath: kp] ?? "" },
                set: { v in guard var x = lib.brand(b.id) else { return }; x[keyPath: kp] = v.isEmpty ? nil : v; save(x) })
    }
    func bindColor(_ b: ChannelBrand, _ kp: WritableKeyPath<ChannelBrand, RGBA>) -> Binding<Color> {
        Binding(get: { (lib.brand(b.id) ?? b)[keyPath: kp].color },
                set: { v in guard var x = lib.brand(b.id) else { return }; x[keyPath: kp] = RGBA(v); save(x) })
    }

    @ViewBuilder func editor(_ b: ChannelBrand) -> some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    preview(b, .circle)
                    preview(b, .bar)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Section("Who") {
                TextField("Name", text: bind(b, \.name))
                TextField("Handle", text: bind(b, \.handle), prompt: Text("@yourname"))
                TextField("Second line on the YouTube bar", text: bindText(b, \.subtitle), prompt: Text(b.displayHandle.isEmpty ? "e.g. 12K subscribers" : b.displayHandle))
                HStack {
                    Text("Profile picture")
                    Spacer()
                    avatar(b, size: 40)
                        .dropDestination(for: URL.self) { urls, _ in if let u = urls.first { setPicture(b, u) }; return true }
                    Button("Choose…") { choosePicture(b) }
                    if b.picture != nil {
                        Button("Remove") {
                            guard var x = lib.brand(b.id) else { return }
                            if let old = x.pictureURL { try? FileManager.default.removeItem(at: old) }
                            x.picture = nil; save(x)
                        }
                    }
                }
            }
            Section("Colours") {
                ColorPicker("Ring and button", selection: bindColor(b, \.color), supportsOpacity: false)
                HStack {
                    Toggle("Fade the ring into a second colour", isOn: Binding(get: { (lib.brand(b.id) ?? b).color2 != nil }, set: { on in
                        guard var x = lib.brand(b.id) else { return }
                        x.color2 = on ? RGBA(r: 0.79, g: 0.6, b: 0.18) : nil; save(x)
                    }))
                    if let c2 = (lib.brand(b.id) ?? b).color2 {
                        ColorPicker("", selection: Binding(get: { c2.color }, set: { v in
                            guard var x = lib.brand(b.id) else { return }; x.color2 = RGBA(v); save(x)
                        }), supportsOpacity: false).labelsHidden()
                    }
                }
                ColorPicker("Button text", selection: Binding(get: { (lib.brand(b.id) ?? b).buttonText.color }, set: { v in
                    guard var x = lib.brand(b.id) else { return }; x.buttonTextColor = RGBA(v); save(x)
                }), supportsOpacity: false)
                Picker("YouTube bar", selection: Binding(get: { (lib.brand(b.id) ?? b).dark }, set: { v in
                    guard var x = lib.brand(b.id) else { return }; x.darkCard = v ? true : nil; save(x)
                })) {
                    Text("White card").tag(false)
                    Text("Dark card").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section("Button words") {
                HStack {
                    TextField("Circle", text: bindText(b, \.followWord), prompt: Text("Follow"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("after the tap", text: bindText(b, \.followingWord), prompt: Text("Following")).labelsHidden()
                }
                HStack {
                    TextField("YouTube bar", text: bindText(b, \.subscribeWord), prompt: Text("Subscribe"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("after the tap", text: bindText(b, \.subscribedWord), prompt: Text("Subscribed")).labelsHidden()
                }
            }
            Section {
                HStack {
                    Text("Captions")
                    Spacer()
                    Text(b.captionStyle == nil ? "leaves captions alone" : (b.captionLookName ?? "saved look")).foregroundStyle(.secondary).lineLimit(1)
                    Menu("Set") {
                        Button("This project's caption look") {
                            guard var x = lib.brand(b.id) else { return }
                            x.captionStyle = model.project.captionStyle; x.captionLookName = "From “\(model.project.name)”"; save(x)
                        }
                        Section("Built in") {
                            ForEach(CaptionStyleSheet.builtIns, id: \.name) { p in
                                Button(p.name) { guard var x = lib.brand(b.id) else { return }; x.captionStyle = p.style; x.captionLookName = p.name; save(x) }
                            }
                        }
                        if !presets.presets.isEmpty {
                            Section("My presets") {
                                ForEach(presets.presets) { p in
                                    Button(p.name) { guard var x = lib.brand(b.id) else { return }; x.captionStyle = p.style; x.captionLookName = p.name; save(x) }
                                }
                            }
                        }
                        Divider()
                        Button("None (leave captions alone)") { guard var x = lib.brand(b.id) else { return }; x.captionStyle = nil; x.captionLookName = nil; save(x) }
                    }
                    .fixedSize()
                }
                HStack {
                    Text("Thumbnails")
                    Spacer()
                    Text(b.thumbnailStyle == nil ? "leaves thumbnails alone" : "saved look").foregroundStyle(.secondary)
                    Menu("Set") {
                        Button("This project's thumbnail look") { guard var x = lib.brand(b.id) else { return }; x.thumbnailStyle = model.thumbnailStyle; save(x) }
                        Button("None (leave thumbnails alone)") { guard var x = lib.brand(b.id) else { return }; x.thumbnailStyle = nil; save(x) }
                    }
                    .fixedSize()
                }
                Toggle("Start new projects with this brand", isOn: Binding(get: { lib.defaultID == b.id }, set: { v in lib.setDefault(v ? b.id : nil) }))
            } header: {
                Text("Looks that go with it")
            } footer: {
                Text("Picking this brand for a project applies these looks and makes it who the follow popups are for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { presets = Store.loadPresets() }
    }

    func preview(_ b: ChannelBrand, _ kind: PopupKind) -> some View {
        let fresh = lib.brand(b.id) ?? b
        _ = lib.version
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.35))
            if let im = Popups.still(kind: kind, brand: fresh, unit: 420) {
                Image(decorative: im, scale: 2).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: kind == .circle ? 90 : 280, maxHeight: kind == .circle ? 88 : 70)
            }
        }
        .frame(width: kind == .circle ? 110 : 300, height: 100)
    }

    func choosePicture(_ b: ChannelBrand) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose the profile picture for \(b.name) (it's cropped to a square)"
        p.prompt = "Use Picture"
        if p.runModal() == .OK, let u = p.url { setPicture(b, u) }
    }
    func setPicture(_ b: ChannelBrand, _ u: URL) {
        guard var x = lib.brand(b.id) else { return }
        do {
            let name = try BrandStore.importPicture(u, for: x.id)
            if let old = x.pictureURL { try? FileManager.default.removeItem(at: old) }
            x.picture = name
            save(x)
        } catch { NSSound.beep() }
    }
}

// MARK: - Clip settings tiles (side by side under the clip list)

/// One small box: a title, a one-line summary and its button.
struct InspectorTile<Control: View>: View {
    var title: String
    var icon: String
    var tint: Color = .secondary
    var detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint).font(.caption)
                Text(title).font(.caption.weight(.semibold))
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            control()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Shape, safe zones, every shot / this shot and the framing itself, all behind one button.
struct PositionTile: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    let clip: Clip

    var body: some View {
        let pc = model.shotAtPlayhead
        let own = pc.map { model.shotHasOwnFraming($0) } ?? false
        InspectorTile(title: "Position", icon: "crop", tint: own ? Brand.gold : .secondary,
                      detail: clip.format.label + (model.frameScope == .shot ? " · this shot" : "") + (own ? " · own framing" : "")) {
            Button { model.showFraming.toggle() } label: { Text("Framing…").frame(maxWidth: .infinity) }
                .help("Shape of the clip, safe zones, and moving / zooming each camera's picture (or just one shot). You can also drag the picture in the viewer, or pinch to zoom.")
                .popover(isPresented: $model.showFraming, arrowEdge: .trailing) {
                    FramingPopover(model: model, engine: model.engine).frame(width: 330)
                }
        }
    }
}

/// The clip's follow popups: add one, or pick one to edit.
struct PopupsTile: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    var body: some View {
        let pops = clip.popups ?? []
        InspectorTile(title: "Popups", icon: "person.crop.circle.badge.plus", tint: pops.isEmpty ? .secondary : Brand.green,
                      detail: pops.isEmpty ? "none yet" : "\(pops.count) on this clip") {
            Menu {
                Section("Add at the playhead") {
                    Button { model.addPopup(.circle) } label: { Label("Circle with Follow button", systemImage: PopupKind.circle.icon) }
                    Button { model.addPopup(.bar) } label: { Label("YouTube bar with Subscribe", systemImage: PopupKind.bar.icon) }
                }
                if !pops.isEmpty {
                    Section("Edit") {
                        ForEach(pops) { p in
                            let sp = model.popupSpan(p)
                            Button("\(Popups.words(p, Popups.brand(for: p, project: model.project)).before)  \(fmtTime(sp.start, frac: true))–\(fmtTime(sp.end, frac: true))") {
                                model.selectPopup(p.id, show: true)
                            }
                        }
                    }
                }
                Divider()
                Button("Brands…") { model.showBrands = true }
            } label: { Text(pops.isEmpty ? "Add" : "Popups") }
            .help("Add a popup at the playhead asking people to follow or subscribe, or pick one to edit. Popups use the project's brand (set up in Brands…).")
        }
    }
}

/// The clip's thumbnail: click to edit it; the arrow has Use This Frame and Save.
struct ThumbnailTile: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    let clip: Clip

    var body: some View {
        let th = clip.thumbnail
        let src = th?.source ?? .clip
        let picked = th?.time != nil || src == .file
        let t = model.thumbnailOutTime(clip)
        InspectorTile(title: "Thumbnail", icon: "photo", tint: picked ? Brand.green : .secondary, detail: detail(src, t)) {
            Menu {
                Button("Use This Frame  (T)") { model.useFrameAsThumbnail() }
                if src == .clip && th?.time != nil {
                    Button("Go to the Thumbnail's Frame") { engine.pause(); engine.seek(t) }
                }
                Button("Save Thumbnail…") { Task { await model.saveThumbnailAsking(clip.id) } }
            } label: { Text("Edit…") } primaryAction: {
                model.showThumbnail = true
            }
            .help("Click to edit the thumbnail (frame, title, look). The arrow: use the frame under the playhead (T), or save it.")
        }
    }

    func detail(_ s: ThumbSource, _ t: Double) -> String {
        switch s {
        case .file: return "picture file"
        case .recording: return "from the recording"
        case .clip: return clip.thumbnail?.time != nil ? "at \(fmtTime(t, frac: true))" : "1 s in"
        }
    }
}
