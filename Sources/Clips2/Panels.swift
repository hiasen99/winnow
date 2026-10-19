import SwiftUI
import AppKit

// MARK: - Clip inspector

/// Under the clip list: the clip's shape, safe zones, and an "Adjust framing" pop-over with each camera's sliders.
struct ClipInspector: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        if let clip = model.selectedClip {
            VStack(alignment: .leading, spacing: 10) {
                Text("Position").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { clip.format }, set: { f in model.updateClip { $0.format = f } })) {
                    ForEach(ClipFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("The shape of the finished video")
                HStack(spacing: 8) {
                    Button { model.showFraming.toggle() } label: { Label("Adjust framing…", systemImage: "crop") }
                        .controlSize(.small)
                        .help("Move and zoom each camera's picture inside the frame, or just one shot. You can also drag the picture in the viewer, or pinch to zoom.")
                        .popover(isPresented: $model.showFraming, arrowEdge: .trailing) {
                            FramingPopover(model: model, engine: model.engine).frame(width: 330)
                        }
                    Spacer()
                    if clip.format == .vertical {
                        Toggle("Safe zones", isOn: $model.showGuides).controlSize(.small)
                            .help("Show the area social apps leave clear of their buttons and captions")
                    }
                }
                ShotScopeRow(model: model, engine: model.engine)
                Divider()
                ThumbnailRow(model: model, engine: model.engine, clip: clip)
                GrabsRow(model: model)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Full recording").font(.headline)
                if model.isReady {
                    Text("\(fmtTime(model.project.masterDuration)) · \(model.project.videoIndices.count) angle\(model.project.videoIndices.count == 1 ? "" : "s")\(model.project.micIndices.isEmpty ? "" : " + \(model.project.micIndices.count) mic\(model.project.micIndices.count == 1 ? "" : "s")") · \(model.project.words.count) words · \(model.project.speakers.count) speaker\(model.project.speakers.count == 1 ? "" : "s")")
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.busy == nil {
                    Button("Analyse again") { Task { await model.analyze() } }
                }
                GrabsRow(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Under "Adjust framing…": whether dragging the picture changes every shot from that camera or just this shot.
struct ShotScopeRow: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        let pc = model.shotAtPlayhead
        let cam = pc.map { model.project.angles[$0.angle].shortName } ?? ""
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Frame").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.frameScope) {
                    Text("Every shot").tag(ProjectModel.FrameScope.camera)
                    Text("This shot").tag(ProjectModel.FrameScope.shot)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            .help("Every shot: dragging the picture moves that camera in every shot. This shot: only the shot under the playhead, for when someone moves. ↑ / ↓ jump from shot to shot.")
            if let pc, model.shotHasOwnFraming(pc) {
                HStack(spacing: 5) {
                    Image(systemName: "crop").foregroundStyle(Brand.gold)
                    Text("This \(cam) shot has its own framing").font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Use camera's") { model.removeShotFraming(pc) }.controlSize(.mini)
                        .help("Back to the framing every other \(cam) shot uses")
                }
            } else if model.frameScope == .shot, pc != nil {
                Text("Drag the picture to reframe just this \(cam) shot.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Each camera's framing: a little map of the whole camera picture with the part that's used,
/// and sliders with a scale so you can see how far it can still move.
struct FramingPopover: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        if let clip = model.selectedClip {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Framing · \(clip.format.label)").font(.headline)
                        Spacer()
                        Menu("More") {
                            Button("Reset every camera to centre") {
                                model.updateClip { c in c.framing = model.project.angles.indices.map { c.framing(for: $0).pictureReset } }
                            }
                            if let n = clip.shotFraming?.count, n > 0 {
                                Button("Shots framed on their own (\(n)) back to their camera") { model.removeAllShotFraming() }
                            }
                            Button("Use this framing for all \(clip.format.label) clips") { model.copyFramingToAllClips() }
                        }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                        .help("Reset, or copy this framing to your other clips of the same shape")
                    }
                    Picker("", selection: $model.frameScope) {
                        Text("Every shot").tag(ProjectModel.FrameScope.camera)
                        Text("This shot only").tag(ProjectModel.FrameScope.shot)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .help("Every shot: a camera's framing is used every time that camera is on screen. This shot only: frame the shot under the playhead by itself (when someone moves).")
                    if let pc = model.shotAtPlayhead, model.framesShot(pc) {
                        shotBox(clip, pc)
                        Text("Cameras (every other shot)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    ForEach(model.project.videoIndices, id: \.self) { i in
                        cameraBox(clip, i)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 620)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Pick a clip first.").padding(20)
        }
    }

    /// The shot under the playhead, framed on its own.
    @ViewBuilder func shotBox(_ clip: Clip, _ pc: EditPiece) -> some View {
        let i = pc.angle
        let f = model.framing(of: pc)
        let own = model.shotHasOwnFraming(pc)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "crop").foregroundStyle(Brand.gold)
                Text("This shot · \(model.project.angles[i].name)").font(.callout.weight(.medium))
                Text("\(fmtTime(pc.outStart, frac: true))–\(fmtTime(pc.outStart + pc.duration, frac: true))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                fitButton(clip, i, f) { g in model.setShotFraming(pc, g) }
                Button("Use camera's") { model.removeShotFraming(pc) }
                    .controlSize(.small).disabled(!own)
                    .help("This shot goes back to the framing every other \(model.project.angles[i].shortName) shot uses")
            }
            framingControls(clip, i, f, color: Brand.gold) { g in model.setShotFraming(pc, g) }
            Text(own ? "Only this shot. Move the playhead to another shot to frame that one." : "Change anything here and this shot gets its own framing; the other \(model.project.angles[i].shortName) shots stay as they are.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Brand.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.gold.opacity(0.5), lineWidth: 1))
    }

    /// Map + left/right, down/up and zoom sliders for one framing.
    @ViewBuilder func framingControls(_ clip: Clip, _ i: Int, _ f: Framing, color: Color, set: @escaping (Framing) -> Void) -> some View {
        let lim = model.framingLimits(angle: i, format: clip.format, zoom: f.zoom)
        let canX = lim.x.upperBound - lim.x.lowerBound > 0.001
        let canY = lim.y.upperBound - lim.y.lowerBound > 0.001
        let ux = canX ? (lim.x.upperBound - min(lim.x.upperBound, max(lim.x.lowerBound, f.x))) / (lim.x.upperBound - lim.x.lowerBound) : 0.5
        let uy = canY ? (min(lim.y.upperBound, max(lim.y.lowerBound, f.y)) - lim.y.lowerBound) / (lim.y.upperBound - lim.y.lowerBound) : 0.5
        HStack(alignment: .top, spacing: 12) {
            FramingMap(source: sourceSize(i), half: model.framingHalf(angle: i, format: clip.format, zoom: f.zoom), f: f, color: color)
                .frame(width: 96, height: 72)
                .help("The whole camera picture. The coloured box is the part your clip shows.")
            VStack(alignment: .leading, spacing: 10) {
                ScaledSlider(title: "Left / right", value: ux, range: 0...1, enabled: canX,
                             ends: ("Left", "Right"), ticks: [0, 0.25, 0.5, 0.75, 1],
                             readout: canX ? sideText(ux, "left", "right") : "no room",
                             help: canX ? "Slide right and the picture moves right" : "The whole width is already in the frame. Zoom in or out to move it.",
                             set: { u in var g = f; g.x = lim.x.upperBound - u * (lim.x.upperBound - lim.x.lowerBound); set(g) },
                             reset: { var g = f; g.x = 0.5; set(g) }, isDefault: abs(f.x - 0.5) < 0.002, parse: SliderParse.side("left", "right"))
                ScaledSlider(title: "Down / up", value: uy, range: 0...1, enabled: canY,
                             ends: ("Down", "Up"), ticks: [0, 0.25, 0.5, 0.75, 1],
                             readout: canY ? sideText(uy, "down", "up") : "no room",
                             help: canY ? "Slide right and the picture moves up" : "The whole height is already in the frame. Zoom in or out to move it.",
                             set: { u in var g = f; g.y = lim.y.lowerBound + u * (lim.y.upperBound - lim.y.lowerBound); set(g) },
                             reset: { var g = f; g.y = 0.5; set(g) }, isDefault: abs(f.y - 0.5) < 0.002, parse: SliderParse.side("down", "up"))
                zoomSlider(clip, i, f) { v in var g = f; g.zoom = v; set(g) }
            }
        }
    }

    @ViewBuilder func cameraBox(_ clip: Clip, _ i: Int) -> some View {
        let f = clip.framing(for: i)
        let lim = model.framingLimits(angle: i, format: clip.format, zoom: f.zoom)
        let canX = lim.x.upperBound - lim.x.lowerBound > 0.001
        let canY = lim.y.upperBound - lim.y.lowerBound > 0.001
        let color = angleColors[i % angleColors.count]
        // slider positions, 0…1, 0.5 = centred
        let ux = canX ? (lim.x.upperBound - min(lim.x.upperBound, max(lim.x.lowerBound, f.x))) / (lim.x.upperBound - lim.x.lowerBound) : 0.5
        let uy = canY ? (min(lim.y.upperBound, max(lim.y.lowerBound, f.y)) - lim.y.lowerBound) / (lim.y.upperBound - lim.y.lowerBound) : 0.5
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(model.project.angles[i].name).font(.callout.weight(.medium))
                Spacer()
                fitButton(clip, i, f) { g in model.setFraming(i, g) }
                Button("Reset") { model.setFraming(i, f.pictureReset) }
                    .controlSize(.small)
                    .disabled(f.pictureIsDefault)
                    .help("Back to the default: centred, not zoomed")
            }
            HStack(alignment: .top, spacing: 12) {
                FramingMap(source: sourceSize(i), half: model.framingHalf(angle: i, format: clip.format, zoom: f.zoom), f: f, color: color)
                    .frame(width: 96, height: 72)
                    .help("The whole camera picture. The coloured box is the part your clip shows.")
                VStack(alignment: .leading, spacing: 10) {
                    ScaledSlider(title: "Left / right", value: ux, range: 0...1, enabled: canX,
                                 ends: ("Left", "Right"), ticks: [0, 0.25, 0.5, 0.75, 1],
                                 readout: canX ? sideText(ux, "left", "right") : "no room",
                                 help: canX ? "Slide right and the picture moves right" : "The whole width is already in the frame. Zoom in or out to move it.",
                                 set: { u in var g = clip.framing(for: i); g.x = lim.x.upperBound - u * (lim.x.upperBound - lim.x.lowerBound); model.setFraming(i, g) },
                                 reset: { var g = clip.framing(for: i); g.x = 0.5; model.setFraming(i, g) }, isDefault: abs(f.x - 0.5) < 0.002, parse: SliderParse.side("left", "right"))
                    ScaledSlider(title: "Down / up", value: uy, range: 0...1, enabled: canY,
                                 ends: ("Down", "Up"), ticks: [0, 0.25, 0.5, 0.75, 1],
                                 readout: canY ? sideText(uy, "down", "up") : "no room",
                                 help: canY ? "Slide right and the picture moves up" : "The whole height is already in the frame. Zoom in or out to move it.",
                                 set: { u in var g = clip.framing(for: i); g.y = lim.y.lowerBound + u * (lim.y.upperBound - lim.y.lowerBound); model.setFraming(i, g) },
                                 reset: { var g = clip.framing(for: i); g.y = 0.5; model.setFraming(i, g) }, isDefault: abs(f.y - 0.5) < 0.002, parse: SliderParse.side("down", "up"))
                    zoomSlider(clip, i, f) { v in var g = clip.framing(for: i); g.zoom = v; model.setFraming(i, g) }
                }
            }
            // where the captions sit while this camera is showing
            let styleY = model.project.captionStyle.positionY
            ScaledSlider(title: "Captions while \(model.project.angles[i].name) is showing", value: f.captionY ?? styleY, range: 0.15...0.85, enabled: true,
                         ends: ("Higher", "Lower"), ticks: [0.15, 0.325, 0.5, 0.675, 0.85],
                         readout: f.captionY == nil ? "caption style" : "\(Int(((f.captionY ?? styleY) * 100).rounded()))% down",
                         help: "Move the captions up or down only while this camera is on screen. Reset to use the height from the caption style.",
                         set: { v in var g = clip.framing(for: i); g.captionY = v; model.setFraming(i, g) },
                         reset: { var g = clip.framing(for: i); g.captionY = nil; model.setFraming(i, g) }, isDefault: f.captionY == nil, parse: SliderParse.percentDown)
                .padding(.top, 2)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Zoom: 1× fills the frame; below 1× the picture gets smaller with a blurred copy of it behind.
    @ViewBuilder func zoomSlider(_ clip: Clip, _ i: Int, _ f: Framing, set: @escaping (Double) -> Void) -> some View {
        let zr = model.zoomRange(angle: i, format: clip.format)
        let fit = model.fitZoom(angle: i, format: clip.format)
        let ticks = [zr.lowerBound, 1, 1.5, 2, 2.5] + (fit < 0.98 && fit > zr.lowerBound + 0.02 ? [fit] : [])
        VStack(alignment: .leading, spacing: 3) {
            ScaledSlider(title: "Zoom", value: min(zr.upperBound, max(zr.lowerBound, f.zoom)), range: zr, enabled: true,
                         ends: (String(format: "%.2g×", zr.lowerBound), "2.5×"), ticks: ticks, major: 1,
                         readout: fit < 0.98 && abs(f.zoom - fit) < 0.005 ? "whole picture" : String(format: f.zoom < 0.999 ? "%.2f×" : "%.1f×", f.zoom),
                         help: "Zoom in, or slide below 1× to zoom out: the picture gets smaller and a blurred copy of it fills the frame behind. You can pinch in the viewer too.",
                         set: { v in
                             // stick at 1× (just fills the frame) and at the whole picture
                             if abs(v - 1) < 0.03 { set(1) } else if fit < 0.98 && abs(v - fit) < 0.02 { set(fit) } else { set(v) }
                         },
                         reset: { set(1) }, isDefault: abs(f.zoom - 1) < 0.002,
                         parse: SliderParse.zoom(fit: fit), setExact: set)
            if f.zoom < 0.999 {
                Label("Blurred copy behind", systemImage: "drop.halffull")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    /// "Fit": zoom out until the whole camera picture shows (only when it doesn't already, e.g. a wide camera in a tall clip).
    @ViewBuilder func fitButton(_ clip: Clip, _ i: Int, _ f: Framing, set: @escaping (Framing) -> Void) -> some View {
        let fit = model.fitZoom(angle: i, format: clip.format)
        if fit < 0.98 {
            Button("Fit") { var g = f; g.zoom = fit; g.x = 0.5; g.y = 0.5; set(g) }
                .controlSize(.small)
                .disabled(abs(f.zoom - fit) < 0.005 && abs(f.x - 0.5) < 0.002 && abs(f.y - 0.5) < 0.002)
                .help("Zoom out until the whole camera picture fits in the frame, with a blurred copy of it filling the space behind")
        }
    }

    func sourceSize(_ i: Int) -> CGSize {
        guard i < model.sources.count, let l = model.sources[i] else { return CGSize(width: 16, height: 9) }
        return l.naturalSize
    }

    /// 0.5 → "centred", 0.8 → "60% right" (how far towards the end of the room it has)
    func sideText(_ u: Double, _ low: String, _ high: String) -> String {
        let d = (u - 0.5) * 2
        if abs(d) < 0.01 { return "centred" }
        return "\(Int((abs(d) * 100).rounded()))% \(d < 0 ? low : high)"
    }
}

/// The whole camera frame (grey) with the part the clip uses (coloured box).
struct FramingMap: View {
    var source: CGSize
    /// half the frame in camera pictures (≥ 0.5 = the whole width/height of the picture shows)
    var half: (x: Double, y: Double)
    var f: Framing
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let aspect = source.width / max(1, source.height)
            var w = size.width, h = w / aspect
            if h > size.height { h = size.height; w = h * aspect }
            let outer = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            ctx.fill(Path(roundedRect: outer, cornerRadius: 2), with: .color(.primary.opacity(0.12)))
            ctx.stroke(Path(roundedRect: outer, cornerRadius: 2), with: .color(.primary.opacity(0.35)), lineWidth: 1)
            // centre lines
            var c = Path()
            c.move(to: CGPoint(x: outer.midX, y: outer.minY)); c.addLine(to: CGPoint(x: outer.midX, y: outer.maxY))
            c.move(to: CGPoint(x: outer.minX, y: outer.midY)); c.addLine(to: CGPoint(x: outer.maxX, y: outer.midY))
            ctx.stroke(c, with: .color(.primary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            let cw = min(1, 2 * half.x), ch = min(1, 2 * half.y)
            let cx = half.x >= 0.5 ? 0.5 : min(1 - half.x, max(half.x, f.x))
            let cy = half.y >= 0.5 ? 0.5 : min(1 - half.y, max(half.y, f.y))
            let crop = CGRect(x: outer.minX + (cx - cw / 2) * w, y: outer.minY + (cy - ch / 2) * h, width: cw * w, height: ch * h)
            ctx.fill(Path(crop), with: .color(color.opacity(0.3)))
            ctx.stroke(Path(crop), with: .color(color), lineWidth: 1.5)
        }
    }
}

/// A slider with tick marks under it, end labels and the current value, so it's clear how far it goes.
struct ScaledSlider: View {
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var enabled: Bool
    var ends: (String, String)
    var ticks: [Double]
    /// an extra tick drawn long (besides the ends and the middle)
    var major: Double? = nil
    var readout: String
    var help: String
    var set: (Double) -> Void
    var reset: () -> Void
    var isDefault: Bool
    /// Typed values: text → a slider value (nil = not understood). Without it the readout can't be typed in.
    var parse: ((String) -> Double?)? = nil
    /// Used for typed values instead of `set` (e.g. to skip the slider's snapping).
    var setExact: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title).font(.caption)
                Spacer()
                if let parse {
                    ReadoutField(text: readout, enabled: enabled, help: "Click to type a value") { typed in
                        let t = typed.trimmingCharacters(in: .whitespaces).lowercased()
                        if SliderParse.resetWords.contains(t) { reset(); return true }
                        guard let v = parse(t) else { return false }
                        (setExact ?? set)(min(range.upperBound, max(range.lowerBound, v)))
                        return true
                    }
                } else {
                    Text(readout).font(.caption.monospacedDigit()).foregroundStyle(enabled ? .primary : .tertiary)
                }
                Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(isDefault || !enabled)
                    .help("Back to the default")
            }
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
                .disabled(!enabled)
                .help(help)
            // the scale: ticks line up with the slider's travel (the knob's centre stops ~7 pt from each end)
            Canvas { ctx, size in
                let inset: CGFloat = 7
                let span = max(1, size.width - inset * 2)
                for t in ticks {
                    let x = inset + CGFloat((t - range.lowerBound) / (range.upperBound - range.lowerBound)) * span
                    let major = t == ticks.min() || t == ticks.max() || (self.major.map { abs(t - $0) < 1e-6 } ?? (abs(t - (range.lowerBound + range.upperBound) / 2) < 1e-6))
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: major ? 5 : 3))
                    ctx.stroke(p, with: .color(.secondary.opacity(enabled ? 0.8 : 0.3)), lineWidth: 1)
                }
            }
            .frame(height: 5)
            HStack {
                Text(ends.0); Spacer(); Text(ends.1)
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

// MARK: - Caption style

struct CaptionStyleSheet: View {
    @ObservedObject var model: ProjectModel
    var onDone: () -> Void
    static let fonts = ["AvenirNext-Heavy", "AvenirNext-Bold", "Futura-Bold", "HelveticaNeue-Bold", "Arial-BoldMT",
                        "Impact", "GillSans-UltraBold", "Poppins-Bold", "Montserrat-Black", "Menlo-Bold", "Georgia-Bold"]

    @State private var presets = Store.loadPresets()
    @State private var showSave = false
    @State private var presetName = ""

    static var builtIns: [CaptionPreset] {
        var pop = CaptionStyle()
        pop.mode = .revealHighlight
        var clean = CaptionStyle(); clean.mode = .reveal; clean.box = true; clean.shadow = false; clean.fontName = "HelveticaNeue-Bold"; clean.fontSize = 0.06
        var big = CaptionStyle(); big.uppercase = true; big.strokeWidth = 0.12; big.fontName = "Impact"; big.fontSize = 0.085
        big.mode = .highlight; big.activeColor = RGBA(r: 0.2, g: 0.9, b: 0.4); big.maxCharsPerLine = 14
        var line = CaptionStyle(); line.maxLines = 1; line.maxCharsPerLine = 22; line.mode = .highlight; line.positionY = 0.72
        var boxed = CaptionStyle(); boxed.mode = .highlight; boxed.uppercase = true; boxed.wordBox = true
        boxed.wordBoxColor = RGBA(r: 1, g: 0.83, b: 0); boxed.activeColor = .black; boxed.shadow = true
        return [CaptionPreset(name: "Yellow pop (word by word)", style: pop),
                CaptionPreset(name: "Clean white, black box", style: clean),
                CaptionPreset(name: "Big uppercase, outlined", style: big),
                CaptionPreset(name: "One line, karaoke", style: line),
                CaptionPreset(name: "Box on the spoken word", style: boxed)]
    }

    func savePreset() {
        let n = presetName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        presets.presets.removeAll { $0.name == n }
        presets.presets.append(CaptionPreset(name: n, style: model.project.captionStyle))
        presets.presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Store.savePresets(presets)
        model.notice = "Saved caption preset “\(n)”. It's in Presets in every project."
    }

    var s: CaptionStyle { model.project.captionStyle }
    func set(_ change: (inout CaptionStyle) -> Void) {
        var st = model.project.captionStyle; change(&st); model.setCaptionStyle(st)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Caption style").font(.title3.weight(.semibold))
                Spacer()
                Menu("Presets") {
                    Section("Built in") {
                        ForEach(Self.builtIns, id: \.name) { p in Button(p.name) { model.setCaptionStyle(p.style) } }
                    }
                    if !presets.presets.isEmpty {
                        Section("My presets") {
                            ForEach(presets.presets) { p in
                                Button(p.name + (presets.defaultName == p.name ? "  (default)" : "")) { model.setCaptionStyle(p.style) }
                            }
                        }
                    }
                    Divider()
                    Button("Save current style as a preset…") { presetName = ""; showSave = true }
                    if !presets.presets.isEmpty {
                        Menu("Use for new projects") {
                            Button("Built-in default") { presets.defaultName = nil; Store.savePresets(presets) }
                            ForEach(presets.presets) { p in
                                Button(p.name) { presets.defaultName = p.name; Store.savePresets(presets) }
                            }
                        }
                        Menu("Delete a preset") {
                            ForEach(presets.presets) { p in
                                Button(p.name, role: .destructive) {
                                    presets.presets.removeAll { $0.name == p.name }
                                    if presets.defaultName == p.name { presets.defaultName = nil }
                                    Store.savePresets(presets)
                                }
                            }
                        }
                    }
                }
                .fixedSize()
                Button("Done") { onDone() }
            }
            .padding(16)
            Divider()
            Form {
                Section("Text") {
                    CaptionFontControls(style: s) { change in set(change) }
                    slider("Size", s.fontSize, 0.035...0.13) { v in set { $0.fontSize = v } }
                    Toggle("ALL CAPS", isOn: Binding(get: { s.uppercase }, set: { v in set { $0.uppercase = v } }))
                    ColorPicker("Text colour", selection: Binding(get: { s.textColor.color }, set: { v in set { $0.textColor = RGBA(v) } }))
                }
                Section("Word animation") {
                    Picker("Style", selection: Binding(get: { s.mode }, set: { v in set { $0.mode = v } })) {
                        ForEach(CaptionMode.allCases) { Text($0.label).tag($0) }
                    }
                    ColorPicker("Spoken-word colour", selection: Binding(get: { s.activeColor.color }, set: { v in set { $0.activeColor = RGBA(v) } }))
                        .disabled(s.mode == .reveal || s.mode == .line)
                }
                Section("Box behind the spoken word") {
                    Toggle("Show a box behind the word being said", isOn: Binding(get: { s.wordBoxOn }, set: { v in set {
                        $0.wordBox = v
                        // keep the word readable on its box
                        if v, $0.mode == .highlight || $0.mode == .revealHighlight,
                           abs($0.activeColor.r - $0.wordBoxRGBA.r) + abs($0.activeColor.g - $0.wordBoxRGBA.g) + abs($0.activeColor.b - $0.wordBoxRGBA.b) < 0.4 {
                            $0.activeColor = .black
                        }
                    } }))
                    ColorPicker("Box colour", selection: Binding(get: { s.wordBoxRGBA.color }, set: { v in set { $0.wordBoxColor = RGBA(v) } }), supportsOpacity: true)
                        .disabled(!s.wordBoxOn)
                    slider("Roundness", s.wordBoxRoundness, 0...1) { v in set { $0.wordBoxRound = v } }
                        .disabled(!s.wordBoxOn)
                    Text("Tip: with “Highlight spoken word”, the spoken-word colour is the text colour on the box.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Outline, shadow & box") {
                    slider("Outline", s.strokeWidth, 0...0.25) { v in set { $0.strokeWidth = v } }
                    ColorPicker("Outline colour", selection: Binding(get: { s.strokeColor.color }, set: { v in set { $0.strokeColor = RGBA(v) } }))
                    Toggle("Drop shadow", isOn: Binding(get: { s.shadow }, set: { v in set { $0.shadow = v } }))
                    Toggle("Box behind each whole line", isOn: Binding(get: { s.box }, set: { v in set { $0.box = v } }))
                    ColorPicker("Box colour", selection: Binding(get: { s.boxColor.color }, set: { v in set { $0.boxColor = RGBA(v) } }), supportsOpacity: true)
                        .disabled(!s.box)
                }
                Section("Layout") {
                    Stepper("Lines on screen: \(s.maxLines)", value: Binding(get: { s.maxLines }, set: { v in set { $0.maxLines = v } }), in: 1...3)
                    Stepper("Letters per line: \(s.maxCharsPerLine)", value: Binding(get: { s.maxCharsPerLine }, set: { v in set { $0.maxCharsPerLine = v } }), in: 8...36)
                    slider("Height on screen", s.positionY, 0.15...0.85) { v in set { $0.positionY = v } }
                        .help("Where captions sit. A camera can have its own height in a clip: Adjust framing… ▸ Captions while … is showing.")
                    slider("Side margins", s.sideMargin, 0.03...0.2) { v in set { $0.sideMargin = v } }
                    Text("With the 9:16 safe-zone guides on, keep captions inside the dashed box so app buttons don't cover them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .alert("Save caption preset", isPresented: $showSave) {
            TextField("Preset name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current caption look so you can use it in any project. Using a name that already exists replaces that preset.")
        }
    }

    func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }
}

// MARK: - Find clips

struct FindClipsSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("finderCount") var count = 8
    @AppStorage("finderMin") var minLen = 20
    @AppStorage("finderMax") var maxLen = 75
    @AppStorage("finderGuidance") var guidance = ""
    @AppStorage("claudeModel") var claudeModel = ClipFinder.models[0].id
    @State private var pasted = ""
    @State private var copied = false
    @State private var showChat = false
    @State private var key = ""
    @State private var hasKey = !ClipFinder.loadKey().isEmpty

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label { Text("Find clips with Claude") } icon: { Image(systemName: "sparkles").foregroundStyle(Brand.gold) }.font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should Claude look for? (optional)").font(.callout.weight(.medium))
                TextField("e.g. “strong answers to objections”, “stories”, “quotable lines about missions”", text: $guidance, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 18) {
                Stepper("\(count) clips", value: $count, in: 1...30).fixedSize()
                HStack(spacing: 6) {
                    Text("each").fixedSize()
                    Stepper("\(minLen)s", value: $minLen, in: 5...180, step: 5).fixedSize()
                    Text("to")
                    Stepper("\(maxLen)s", value: $maxLen, in: 10...300, step: 5).fixedSize()
                }
                Spacer()
                Picker("", selection: $claudeModel) {
                    ForEach(ClipFinder.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                .help("Which Claude model picks the clips")
            }
            .controlSize(.small)

            if hasKey {
                HStack(spacing: 12) {
                    Button { find() } label: {
                        Label("Find clips", systemImage: "sparkles").frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.green).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    Text("Sends only the transcript text. The clips land in your list, ready to review (U = use, X = rejected).")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste your Claude API key once and Winnow can ask Claude directly. It's stored only on this Mac.")
                        .font(.callout)
                    HStack {
                        SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
                        Button("Save key") {
                            ClipFinder.saveKey(key)
                            hasKey = !ClipFinder.loadKey().isEmpty
                            key = ""
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }
                .padding(12)
                .background(Brand.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            DisclosureGroup(isExpanded: $showChat) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { model.copyPrompt(count: count, minLen: minLen, maxLen: maxLen, guidance: guidance); copied = true } label: {
                            Label("Copy prompt + transcript", systemImage: "doc.on.doc")
                        }
                        if copied { Text("Copied ✓ — paste it into a Claude chat").foregroundStyle(.secondary).font(.caption) }
                    }
                    Text("Then paste Claude's answer here (timestamps work too, e.g. “12:03 – 12:58 Why the argument fails”).").font(.caption)
                    TextEditor(text: $pasted)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Button("Paste from clipboard") { pasted = NSPasteboard.general.string(forType: .string) ?? "" }
                        Spacer()
                        let n = ClipFinder.parse(pasted).count
                        Text(pasted.isEmpty ? "" : "\(n) clip\(n == 1 ? "" : "s") found").foregroundStyle(.secondary)
                        Button("Add clips") {
                            let added = model.addIdeas(ClipFinder.parse(pasted))
                            model.notice = "Added \(added) clips."
                            dismiss()
                        }
                        .disabled(ClipFinder.parse(pasted).isEmpty)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("No API key? Use a Claude chat instead (copy / paste)").font(.callout)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    func find() {
        dismiss()
        Task { await model.askClaude(count: count, minLen: minLen, maxLen: maxLen, guidance: guidance, model: claudeModel) }
    }
}

// MARK: - Speakers & sync

struct SpeakersSheet: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Speakers & sync").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            GroupBox("Who's talking → which camera") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.project.speakers.isEmpty {
                        Text("Speakers appear after the transcript is made.").foregroundStyle(.secondary)
                    }
                    ForEach(model.project.speakers.indices, id: \.self) { i in
                        HStack {
                            Circle().fill(Color(nsColor: speakerColors[i % speakerColors.count])).frame(width: 10, height: 10)
                            TextField("Name", text: Binding(get: { model.project.speakers[i].name }, set: { v in
                                model.renameSpeaker(i, v)
                            }))
                            .frame(width: 180)
                            Text("show")
                            Picker("", selection: Binding(get: { model.project.speakers[i].angle }, set: { v in
                                model.edit { $0.speakers[i].angle = v; $0.speakerCamerasByHand = true }
                            })) {
                                ForEach(model.project.videoIndices, id: \.self) { a in Text(model.project.angles[a].name).tag(a) }
                            }
                            .labelsHidden().frame(width: 120)
                        }
                    }
                    HStack {
                        if model.project.speakers.count == 2 {
                            Button("Swap cameras") {
                                model.edit { p in let a = p.speakers[0].angle; p.speakers[0].angle = p.speakers[1].angle; p.speakers[1].angle = a; p.speakerCamerasByHand = true }
                            }
                        }
                        Button("Detect speakers again") { model.redetectSpeakers() }
                    }
                    Text(model.project.micIndices.isEmpty
     ? "Speakers are told apart by which camera's mic hears them loudest. If both cameras recorded the same sound, everyone shows as one speaker; cut cameras by hand with 1 / 2 instead."
     : "Speakers are told apart by which mic recording hears them loudest (Speaker 1 = loudest on Mic 1).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            GroupBox("Automatic camera switching") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Shortest shot")
                        Slider(value: Binding(get: { model.project.minShot }, set: { v in model.setAutoParams(minShot: v) }), in: 0.5...8)
                        Text(String(format: "%.1fs", model.project.minShot)).monospacedDigit().frame(width: 40)
                    }
                    HStack {
                        Text("Cut before they speak")
                        Slider(value: Binding(get: { model.project.switchLead }, set: { v in model.setAutoParams(lead: v) }), in: 0...1)
                        Text(String(format: "%.2fs", model.project.switchLead)).monospacedDigit().frame(width: 40)
                    }
                    Text("Short replies like “yeah” shorter than the shortest shot don't trigger a cut.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            if model.project.angles.count > 1 {
                GroupBox("Sync") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                dismiss()
                                Task { await model.resync() }
                            } label: { Label("Re-sync everything from the sound", systemImage: "waveform.badge.magnifyingglass") }
                            .buttonStyle(.borderedProminent).tint(Brand.green)
                            .disabled(model.busy != nil)
                            Spacer()
                            Button { model.chooseFilesToAdd() } label: { Label("Add file…", systemImage: "plus") }
                                .disabled(model.busy != nil)
                        }
                        Text("Lines every file up again (using whichever files share sound, e.g. a combined recording) and re-makes the transcript. Clips keep their times.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        ForEach(model.project.angles.indices, id: \.self) { i in
                            SyncRow(model: model, index: i)
                        }
                        Text("Offset = how many seconds into that file the timeline starts (bigger = that file started recording earlier). Type a number and press Return to set it by hand.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
            }
        }
        .padding(20)
        }
        .frame(width: 740)
        .frame(minHeight: 420, idealHeight: 680, maxHeight: 820)
    }
}

struct SyncRow: View {
    @ObservedObject var model: ProjectModel
    var index: Int
    var body: some View {
        let a = model.project.angles[index]
        HStack(spacing: 8) {
            Image(systemName: a.isVideo ? "video" : "mic").frame(width: 16).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(.callout.weight(.medium))
                Text(URL(fileURLWithPath: a.path).lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 170, alignment: .leading)
            status(a).frame(maxWidth: .infinity, alignment: .leading)
            TextField("", value: Binding(get: { a.offset }, set: { model.setOffset(index, $0) }),
                      format: .number.precision(.fractionLength(3)))
                .multilineTextAlignment(.trailing).frame(width: 82).monospacedDigit()
            Text("s").foregroundStyle(.secondary)
            Button("−1f") { model.nudgeSync(index, -1 / max(24, a.fps)) }.controlSize(.small).help("One frame earlier")
            Button("+1f") { model.nudgeSync(index, 1 / max(24, a.fps)) }.controlSize(.small).help("One frame later")
        }
    }

    @ViewBuilder func status(_ a: AngleSource) -> some View {
        if a.syncFailed {
            Label("not lined up", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        } else if let w = a.syncedWith {
            let score = a.syncScore ?? 0
            let word = score >= 3 ? "solid" : score >= 1.5 ? "ok" : "weak"
            VStack(alignment: .leading, spacing: 1) {
                Label(w == "set by hand" ? "set by hand" : "matched to \(w) (\(word))",
                      systemImage: score >= 1.5 || w == "set by hand" ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(score >= 1.5 || w == "set by hand" ? Color.secondary : Color.orange)
                if let d = a.syncDrift, d > 0.1 {
                    Text(String(format: "drifts up to %.2fs", d)).foregroundStyle(.orange)
                }
            }
            .font(.caption)
        } else {
            Label("reference", systemImage: "scope").foregroundStyle(.secondary).font(.caption)
        }
    }
}


/// A slider's value readout you can click and type into. Return or clicking away applies it, Esc cancels;
/// text it can't read beeps and keeps the old value.
struct ReadoutField: View {
    var text: String
    var enabled: Bool
    var help: String
    var commit: (String) -> Bool
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 96)
                .focused($focused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .onChange(of: focused) { _, f in if !f && editing { finish(apply: true) } }
                .onAppear { DispatchQueue.main.async { focused = true } }
        } else {
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(enabled ? .primary : .tertiary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(enabled ? (hover ? 0.12 : 0.05) : 0), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture {
                    guard enabled else { return }
                    draft = text
                    editing = true
                }
                .help(enabled ? help : "")
        }
    }

    private func finish(apply: Bool) {
        guard editing else { return }
        if apply, draft != text, !commit(draft) { NSSound.beep(); return }
        editing = false
    }
}

/// Reading typed slider values: "35 left", "-35", "40% up", "0.6", "1.4x", "fit", "30% down", "reset".
enum SliderParse {
    static let resetWords: Set<String> = ["reset", "default", "style", "caption style", "centre", "center", "centred", "centered"]

    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: ",", with: ".")
        guard let r = t.range(of: #"[-+]?\d*\.?\d+"#, options: .regularExpression) else { return nil }
        return Double(t[r])
    }

    /// Left/right or down/up: a percentage of the room it has, towards `low` or `high`.
    /// Plain numbers: negative = `low`, positive = `high`. Returns the slider position 0…1 (0.5 = centred).
    static func side(_ low: String, _ high: String) -> (String) -> Double? {
        { s in
            guard var n = number(s) else { return nil }
            if s.contains(low) { n = -abs(n) } else if s.contains(high) { n = abs(n) }
            return 0.5 + n / 200
        }
    }

    /// Zoom: "0.6", "1.4x", "60%", or "fit" / "whole" for the whole picture.
    static func zoom(fit: Double) -> (String) -> Double? {
        { s in
            if s.contains("fit") || s.contains("whole") { return fit }
            guard let n = number(s), n > 0 else { return nil }
            return s.contains("%") ? n / 100 : n
        }
    }

    /// Caption height: "30" or "30% down" (percent of the frame from the top), or a fraction like 0.3.
    static func percentDown(_ s: String) -> Double? {
        guard let n = number(s) else { return nil }
        return n > 1 ? n / 100 : n
    }
}

// MARK: - Caption font: family, weight, and the weight axis of variable fonts

struct CaptionFontControls: View {
    let style: CaptionStyle
    let set: ((inout CaptionStyle) -> Void) -> Void

    var body: some View {
        let fam = FontCatalog.family(of: style.fontName)
        let members = fam.map { FontCatalog.members($0) } ?? []
        let ps = FontCatalog.postScript(of: style.fontName)
        let axis = FontCatalog.weightAxis(style.fontName)

        LabeledContent("Font") {
            Menu {
                let installed = Set(FontCatalog.families)
                let sug = FontCatalog.suggested.filter { installed.contains($0) }
                Section("Suggested") {
                    ForEach(sug, id: \.self) { f in familyButton(f, current: fam) }
                }
                Section("All fonts") {
                    ForEach(FontCatalog.families, id: \.self) { f in familyButton(f, current: fam) }
                }
            } label: {
                Text(fam ?? style.fontName)
            }
            .fixedSize()
            .help("Every font installed on this Mac. Fonts you add with Font Book show up here after reopening the caption style.")
        }

        if members.count > 1 {
            Picker("Weight", selection: Binding(get: { ps }, set: { v in set { $0.fontName = v; $0.fontWeight = nil } })) {
                ForEach(members, id: \.postScript) { m in
                    Text(m.style).font(.custom(m.postScript, size: 13)).tag(m.postScript)
                }
                if !members.contains(where: { $0.postScript == ps }) { Text(ps).tag(ps) }
            }
        }

        if let ax = axis {
            let base = FontCatalog.baseWeight(style.fontName) ?? ax.def
            let v = style.fontWeight ?? base
            HStack {
                Text("Thickness")
                Slider(value: Binding(get: { v }, set: { nv in set { $0.fontWeight = nv } }), in: ax.min...ax.max)
                Text(FontCatalog.weightText(v, axisMax: ax.max))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 32, alignment: .trailing)
                Button { set { $0.fontWeight = nil } } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).disabled(style.fontWeight == nil)
                    .help("Back to the weight chosen above")
            }
            .help("This is a variable font: drag for any thickness between its lightest and heaviest.")
        } else if members.count <= 1, let f = fam {
            Text("Only one weight of \(f) is installed. For heavier text, install its Bold or Black font files (Font Book), or use a thin Outline in the text colour.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder func familyButton(_ f: String, current: String?) -> some View {
        Button {
            guard let m = FontCatalog.closestMember(in: f, to: style.fontName) else { return }
            set { $0.fontName = m.postScript; $0.fontWeight = nil }
        } label: {
            if f == current { Label(f, systemImage: "checkmark") } else { Text(f) }
        }
    }
}
