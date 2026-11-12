import SwiftUI
import AppKit

/// Teal, so a followed shot doesn't get mixed up with shot framing (gold) or the cameras' colours.
let followColor = Color(red: 0.16, green: 0.70, blue: 0.68)

// MARK: - In the framing pop-over

/// "Follow a point": pick something in the picture and the framing moves with it.
struct FollowBox: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @AppStorage("followMarker") var showMarker = true

    var body: some View {
        if let clip = model.selectedClip, let pc = model.shotAtPlayhead {
            let cam = model.project.angles[pc.angle].shortName
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(followColor)
                    Text("Follow a point").font(.callout.weight(.medium))
                    Spacer()
                    if let tr = model.follow(for: pc), model.followJob == nil {
                        Button("Stop following") { model.removeFollow(tr.id) }
                            .controlSize(.small)
                            .help("This shot goes back to its normal framing")
                    }
                }
                if let job = model.followJob {
                    running(job, clip)
                } else if let tr = model.follow(for: pc) {
                    following(clip, pc, tr)
                } else {
                    Text("Pick something that should stay put on screen (a face, a logo, the corner of a window) and the framing moves with it as the camera drifts, pans or zooms.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("", selection: $model.followWholeClip) {
                        Text("This shot").tag(false)
                        Text("Every \(cam) shot").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .help("This shot: only the shot under the playhead. Every \(cam) shot: camera \(cam) follows it wherever it's on screen in this clip.")
                    Button { model.startFollowPick() } label: {
                        Label("Pick It in the Viewer…", systemImage: "viewfinder").frame(maxWidth: .infinity)
                    }
                    .help("Drag a box around it in the viewer, or just click it")
                }
            }
            .padding(10)
            .background(followColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(followColor.opacity(0.45), lineWidth: 1))
        }
    }

    @ViewBuilder func running(_ job: FollowJob, _ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.clipID == clip.id ? "Tracking it through the shot…" : "Tracking in another clip…").font(.caption)
                Spacer()
                Button("Stop") { model.stopFollowJob() }.controlSize(.mini)
            }
            ProgressView(value: model.followProgress).progressViewStyle(.linear).tint(followColor)
        }
    }

    @ViewBuilder func following(_ clip: Clip, _ pc: EditPiece, _ tr: FollowTrack) -> some View {
        let path = model.followPath(for: pc)
        let cam = model.project.angles[tr.angle].shortName
        let whole = tr.end - tr.start >= clip.end - clip.start - 0.05
        VStack(alignment: .leading, spacing: 6) {
            let face = tr.runs.contains { $0.kind == "face" }
            Text((whole ? "Camera \(cam) follows it all through this clip" : "This \(cam) shot follows it")
                 + (face ? ", by the face's features." : ", by the picture around it."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let p = path {
                ForEach(Array(p.held.prefix(3).enumerated()), id: \.offset) { _, h in
                    problemRow("eye.slash", .orange,
                               "Not seen \(span(h, clip)) — holds still", go: h.lowerBound)
                }
                ForEach(Array(p.edges.prefix(3).enumerated()), id: \.offset) { _, e in
                    problemRow("rectangle.dashed", .red,
                               "Runs off the picture \(span(e, clip))", go: e.lowerBound)
                }
                if p.boost > 1.005 {
                    Label(String(format: "Zoomed in %.2f× so it never runs off the picture", p.boost), systemImage: "plus.magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Zoom in so the frame never runs off the picture", isOn: Binding(
                get: { tr.zoomsToFit }, set: { v in model.setFollow(tr.id, live: false) { $0.autoZoom = v } }))
                .controlSize(.small)
                .help("Following can push the frame past the edge of the camera picture (a vertical clip from a wide camera has no room up or down at 1×). This zooms in just enough, for this shot, that it never does.")
            Toggle("Keep it the same size (the camera zooms)", isOn: Binding(
                get: { tr.locksSize }, set: { v in model.setFollow(tr.id, live: false) { $0.lockSize = v } }))
                .controlSize(.small)
                .help("When the camera zooms in or out, the framing zooms the other way so the thing you picked stays the same size. Zooming out past the picture fills the rest with a blurred copy.")
            ScaledSlider(title: "Hold", value: tr.smooth, range: 0...1, enabled: true,
                         ends: ("Locked", "Smooth"), ticks: [0, 0.25, 0.5, 0.75, 1],
                         readout: tr.smooth < 0.05 ? "locked" : tr.smooth > 0.8 ? "loose" : "\(Int((tr.smooth * 100).rounded()))%",
                         help: "Locked: it stays exactly in place (for a camera that drifts). Smooth: the framing glides after it like a camera operator, ignoring small wobbles.",
                         set: { v in model.setFollow(tr.id) { $0.smoothing = v } },
                         reset: { model.setFollow(tr.id) { $0.smoothing = nil } }, isDefault: tr.smoothing == nil)
            HStack(spacing: 6) {
                Button("Pick Again Here") { model.startFollowPick() }
                    .controlSize(.small)
                    .help("Point at it again from the playhead on (when it got lost, or to follow something else from here). What came before stays.")
                Spacer()
                Toggle("Show it", isOn: $showMarker).controlSize(.small).toggleStyle(.checkbox)
                    .help("Draw a box around the followed point in the viewer while paused")
            }
        }
    }

    func span(_ r: ClosedRange<Double>, _ c: Clip) -> String {
        let a = c.outputTimeClamped(forMaster: r.lowerBound), b = c.outputTimeClamped(forMaster: r.upperBound)
        return "\(fmtTime(a, frac: true))–\(fmtTime(b, frac: true))"
    }

    @ViewBuilder func problemRow(_ icon: String, _ color: Color, _ text: String, go m: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(text).font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Button("Go") { model.seekMaster(m + 0.02) }.controlSize(.mini)
                .help("Move the playhead there (then Pick Again Here if it's visible)")
        }
    }
}

// MARK: - In the viewer

/// The video's place inside a view (the frame shape fitted, like the player does).
func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let k = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * k, h = size.height * k
    return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
}

/// Drawing the box (or clicking) around the thing to follow.
struct FollowPickOverlay: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @State private var from: CGPoint? = nil
    @State private var to: CGPoint? = nil

    var body: some View {
        GeometryReader { g in
            let r = fittedRect(engine.renderSize, in: g.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                Path { p in p.addRect(CGRect(origin: .zero, size: g.size)); p.addRect(r) }
                    .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))
                if let a = from, let b = to {
                    let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    Rectangle().stroke(followColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: max(2, box.width), height: max(2, box.height))
                        .offset(x: box.minX, y: box.minY)
                }
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder").foregroundStyle(followColor)
                        Text("Drag a box around something that should stay put, or click it. On a face, it follows the face.")
                            .font(.callout)
                        Button("Cancel") { model.followPicking = false }.controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if from == nil { from = v.startLocation }
                    to = v.location
                }
                .onEnded { v in
                    let a = from ?? v.startLocation, b = v.location
                    from = nil; to = nil
                    guard r.width > 0 else { return }
                    let k = engine.renderSize.width / r.width
                    let box = CGRect(x: (min(a.x, b.x) - r.minX) * k, y: (min(a.y, b.y) - r.minY) * k,
                                     width: abs(a.x - b.x) * k, height: abs(a.y - b.y) * k)
                    model.pickFollow(renderRect: box)
                })
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        }
    }
}

/// While paused: a box around the followed point (red-dashed where the tracker couldn't see it).
struct FollowMarkerOverlay: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var engine: PlayerEngine
    @AppStorage("followMarker") var showMarker = true

    var body: some View {
        GeometryReader { g in
            if showMarker, !engine.isPlaying, !model.followPicking, model.selectedClip != nil, !model.showThumbnail,
               let m = model.followMarker() {
                let r = fittedRect(engine.renderSize, in: g.size)
                let k = r.width / max(1, engine.renderSize.width)
                let box = CGRect(x: r.minX + m.rect.minX * k, y: r.minY + m.rect.minY * k, width: m.rect.width * k, height: m.rect.height * k)
                let col = m.held ? Color.orange : m.edge ? Color.red : followColor
                ZStack(alignment: .topLeading) {
                    Rectangle().stroke(col, style: StrokeStyle(lineWidth: 1.5, dash: m.held ? [4, 3] : []))
                        .frame(width: max(6, box.width), height: max(6, box.height))
                        .offset(x: box.minX, y: box.minY)
                    Path { p in
                        p.move(to: CGPoint(x: box.midX - 5, y: box.midY)); p.addLine(to: CGPoint(x: box.midX + 5, y: box.midY))
                        p.move(to: CGPoint(x: box.midX, y: box.midY - 5)); p.addLine(to: CGPoint(x: box.midX, y: box.midY + 5))
                    }.stroke(col, lineWidth: 1)
                }
                .clipShape(Rectangle().path(in: r))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Progress over the viewer

struct FollowProgressBadge: View {
    @ObservedObject var model: ProjectModel
    var body: some View {
        if model.followJob != nil {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "scope").foregroundStyle(followColor)
                    Text("Following the point… \(Int((model.followProgress * 100).rounded()))%").font(.caption.monospacedDigit())
                    ProgressView(value: model.followProgress).progressViewStyle(.linear).frame(width: 90).tint(followColor)
                    Button("Stop") { model.stopFollowJob() }.controlSize(.mini)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }
}
