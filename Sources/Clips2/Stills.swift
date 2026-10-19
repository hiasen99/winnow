import Foundation
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Picture files

/// The kinds of picture a frame can be saved as.
enum StillFormat: Int, CaseIterable {
    case png, jpeg, small
    var label: String {
        switch self {
        case .png: return "PNG (best quality)"
        case .jpeg: return "JPEG (photo)"
        case .small: return "JPEG, 1280 wide (YouTube thumbnail size)"
        }
    }
    var ext: String { self == .png ? "png" : "jpg" }
    var type: UTType { self == .png ? .png : .jpeg }
    static var saved: StillFormat { StillFormat(rawValue: UserDefaults.standard.integer(forKey: "stillFormat")) ?? .png }
    static func parse(_ s: String?) -> StillFormat? {
        switch (s ?? "").lowercased().trimmingCharacters(in: .whitespaces) {
        case "png": return .png
        case "jpg", "jpeg", "photo": return .jpeg
        case "small", "youtube", "thumb", "thumbnail", "1280": return .small
        default: return nil
        }
    }
}

enum Stills {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The picture as file bytes; `.small` scales it down to 1280 wide (never up).
    static func encode(_ img: CGImage, _ f: StillFormat) throws -> Data {
        var image = img
        if f == .small, img.width > 1280, let s = scaled(img, width: 1280) { image = s }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, f.type.identifier as CFString, 1, nil) else {
            throw ClipsError("Couldn't make the picture file.")
        }
        let props: [CFString: Any] = f == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: f == .small ? 0.88 : 0.93]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ClipsError("Couldn't write the picture.") }
        return data as Data
    }

    static func write(_ img: CGImage, to url: URL, format: StillFormat) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(img, format).write(to: url, options: .atomic)
    }

    static func scaled(_ img: CGImage, width: Int) -> CGImage? {
        let h = max(1, Int((Double(img.height) * Double(width) / Double(img.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()
    }

    /// "1m02.5s" (for file names: no colons).
    static func stamp(_ t: Double) -> String {
        let tt = (max(0, t) * 10).rounded() / 10
        let h = Int(tt) / 3600, m = (Int(tt) % 3600) / 60
        let s = String(format: "%04.1f", tt - Double(h * 3600 + m * 60))
        return h > 0 ? "\(h)h\(String(format: "%02d", m))m\(s)s" : "\(m)m\(s)s"
    }

    /// A file in `folder` that doesn't exist yet: "name.ext", then "name 2.ext"…
    static func freeURL(_ folder: URL, _ base: String, _ ext: String) -> URL {
        var url = folder.appendingPathComponent(base + "." + ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return url
    }

    static func tilde(_ u: URL) -> String { u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

// MARK: - Frames and grabs

@MainActor
extension ProjectModel {

    /// A frame as a picture. In a clip: exactly as the clip exports (shape, framing, camera; captions if asked), full export size.
    /// On the full recording: the untouched frame of the camera showing at that moment, at the camera's own size.
    func stillImage(clip: Clip?, at out: Double, captions: Bool) async throws -> CGImage {
        if let c = clip {
            let r = c.format.renderSize
            return try await Exporter.frame(project: project, clip: c, auto: auto, loaded: sources, at: out,
                                            captions: captions, maxSide: max(r.width, r.height))
        }
        let t = max(0, min(out, project.masterDuration - 0.001))
        var order: [Int] = []
        if let a = fullViewAngle { order.append(a) }
        if let pc = Schedule.pieces(project: project, clip: nil, auto: auto).last(where: { $0.outStart <= t + 1e-4 }) { order.append(pc.angle) }
        order += project.videoIndices
        for a in order where a < sources.count {
            guard let l = sources[a], l.video != nil else { continue }
            let st = t + project.angles[a].offset
            guard st >= 0, st <= l.duration - 0.001 else { continue }
            let gen = AVAssetImageGenerator(asset: l.asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return try await gen.image(at: CompositionBuilder.t(st)).image
        }
        throw ClipsError("No camera has picture at \(fmtTime(t, frac: true)).")
    }

    /// Grabbed frames in what's showing (a clip's own, or the full recording's): master time and time in the view.
    var grabsInView: [(master: Double, out: Double)] { grabs(in: selectedClip) }

    func grabs(in clip: Clip?) -> [(master: Double, out: Double)] {
        if let c = clip { return (c.grabs ?? []).compactMap { m in c.outputTime(forMaster: m).map { (m, $0) } } }
        return (project.grabs ?? []).map { ($0, $0) }
    }

    /// Two grabs closer than this are the same frame.
    static let grabTolerance = 0.02

    var playheadIsGrabbed: Bool {
        let m = masterTime(engine.time)
        return grabsInView.contains { abs($0.master - m) < Self.grabTolerance }
    }

    /// G: mark the frame under the playhead to be saved as a picture (or un-mark it).
    func toggleGrab() {
        let m = masterTime(engine.time)
        var removed = false
        func flip(_ list: [Double]?) -> [Double]? {
            var g = list ?? []
            if let k = g.firstIndex(where: { abs($0 - m) < Self.grabTolerance }) { g.remove(at: k); removed = true }
            else { g.append(m); g.sort() }
            return g.isEmpty ? nil : g
        }
        if let i = clipIndex { edit(rebuild: false) { p in p.clips[i].grabs = flip(p.clips[i].grabs) } }
        else { edit(rebuild: false) { p in p.grabs = flip(p.grabs) } }
        let n = grabsInView.count
        notice = removed ? "Frame un-grabbed (\(n) left)."
            : "Frame grabbed (\(n) so far). Save them all with “Save \(n) Grabbed Frame\(n == 1 ? "" : "s")…” under the clip settings."
    }

    func removeGrab(master m: Double) {
        if let i = clipIndex {
            edit(rebuild: false) { p in
                p.clips[i].grabs?.removeAll { abs($0 - m) < Self.grabTolerance }
                if p.clips[i].grabs?.isEmpty == true { p.clips[i].grabs = nil }
            }
        } else {
            edit(rebuild: false) { p in p.grabs?.removeAll { abs($0 - m) < Self.grabTolerance }; if p.grabs?.isEmpty == true { p.grabs = nil } }
        }
    }

    func clearGrabs() {
        if let i = clipIndex { edit(rebuild: false) { $0.clips[i].grabs = nil } }
        else { edit(rebuild: false) { $0.grabs = nil } }
    }

    // MARK: Saving frames

    /// ⇧⌘S: save the frame under the playhead (asks where).
    func saveFrameAsking() async {
        engine.pause()
        let t = engine.time
        let clip = selectedClip
        let base = Exporter.safeName(clip?.title ?? project.name) + " " + Stills.stamp(t)
        let panel = SaveFramePanel(baseName: base, folder: exportFolder, inClip: clip != nil)
        guard let url = panel.run() else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "exportDir.\(project.id.uuidString)")
        await saveFrame(clip: clip, at: t, to: url, format: panel.format, captions: panel.captions)
    }

    @discardableResult
    func saveFrame(clip: Clip?, at out: Double, to url: URL, format: StillFormat, captions: Bool) async -> Bool {
        do {
            let img = try await stillImage(clip: clip, at: out, captions: captions && clip != nil)
            try Stills.write(img, to: url, format: format)
            lastExportBatch = []
            lastExport = url
            notice = "Saved “\(url.lastPathComponent)” in \(Stills.tilde(url.deletingLastPathComponent()))"
            return true
        } catch {
            errorText = "Couldn't save the frame: \(error.localizedDescription)"
            Log.write("save frame failed: \(error)")
            return false
        }
    }

    /// Save every grabbed frame of what's showing into a "Frame Grabs" folder (asks where).
    func saveGrabsAsking() async {
        let list = grabsInView
        guard !list.isEmpty else { notice = "No grabbed frames here yet. Press G on a frame to grab it."; return }
        engine.pause()
        let clip = selectedClip
        let panel = FramesFolderPanel(count: list.count, folder: exportFolder, inClip: clip != nil)
        guard let folder = panel.run() else { return }
        UserDefaults.standard.set(folder.path, forKey: "exportDir.\(project.id.uuidString)")
        let dir = folder.lastPathComponent == "Frame Grabs" ? folder : folder.appendingPathComponent("Frame Grabs", isDirectory: true)
        await saveGrabs(clip: clip, outs: list.map { $0.out }, to: dir, format: panel.format, captions: panel.captions)
    }

    @discardableResult
    func saveGrabs(clip: Clip?, outs: [Double], to dir: URL, format: StillFormat, captions: Bool) async -> [URL] {
        let base = Exporter.safeName(clip?.title ?? project.name)
        var saved: [URL] = []
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, o) in outs.enumerated() {
                if outs.count > 2 { notice = "Saving frames… \(i + 1) of \(outs.count)" }
                let img = try await stillImage(clip: clip, at: o, captions: captions && clip != nil)
                let url = Stills.freeURL(dir, base + " " + Stills.stamp(o), format.ext)
                try Stills.write(img, to: url, format: format)
                saved.append(url)
            }
        } catch {
            errorText = "Saved \(saved.count) of \(outs.count) frames, then: \(error.localizedDescription)"
            Log.write("save grabs failed: \(error)")
        }
        lastExportBatch = saved
        lastExport = saved.last
        if !saved.isEmpty { notice = "Saved \(saved.count) frame\(saved.count == 1 ? "" : "s") in \(Stills.tilde(dir))" }
        return saved
    }
}

// MARK: - Save windows

/// The save window for one frame: format, and (in a clip) whether the captions are drawn on it.
@MainActor
final class SaveFramePanel: NSObject {
    let panel = NSSavePanel()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let capBox = NSButton(checkboxWithTitle: "Include the captions", target: nil, action: nil)
    private(set) var format = StillFormat.saved
    private let inClip: Bool
    var captions: Bool { inClip && capBox.state == .on }

    init(baseName: String, folder: URL, inClip: Bool) {
        self.inClip = inClip
        super.init()
        panel.title = "Save Frame"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = folder
        panel.nameFieldStringValue = baseName + "." + format.ext
        panel.accessoryView = StillsAccessory.make(popup: popup, capBox: inClip ? capBox : nil, target: self, action: #selector(changed))
        capBox.state = UserDefaults.standard.bool(forKey: "stillCaptions") ? .on : .off
        apply()
    }
    @objc private func changed() { format = StillFormat(rawValue: popup.indexOfSelectedItem) ?? .png; apply() }
    private func apply() {
        popup.selectItem(at: format.rawValue)
        panel.allowedContentTypes = [format.type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.ext
        panel.message = inClip ? "This frame as the clip shows it: its shape, framing and camera, at full export size."
                               : "This frame straight from the camera, at the camera's full size."
    }
    func run() -> URL? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(format.rawValue, forKey: "stillFormat")
        if inClip { UserDefaults.standard.set(capBox.state == .on, forKey: "stillCaptions") }
        return url
    }
}

/// The folder window for "Save Grabbed Frames".
@MainActor
final class FramesFolderPanel: NSObject {
    let panel = NSOpenPanel()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let capBox = NSButton(checkboxWithTitle: "Include the captions", target: nil, action: nil)
    private(set) var format = StillFormat.saved
    private let inClip: Bool
    var captions: Bool { inClip && capBox.state == .on }

    init(count: Int, folder: URL, inClip: Bool) {
        self.inClip = inClip
        super.init()
        panel.title = "Save \(count) Grabbed Frame\(count == 1 ? "" : "s")"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Save \(count) Here"
        panel.message = "Choose a folder. The pictures go in a “Frame Grabs” folder inside it, named after the "
            + (inClip ? "clip" : "project") + " and the time of each frame."
        panel.accessoryView = StillsAccessory.make(popup: popup, capBox: inClip ? capBox : nil, target: self, action: #selector(changed))
        panel.isAccessoryViewDisclosed = true
        capBox.state = UserDefaults.standard.bool(forKey: "stillCaptions") ? .on : .off
        popup.selectItem(at: format.rawValue)
    }
    @objc private func changed() { format = StillFormat(rawValue: popup.indexOfSelectedItem) ?? .png }
    func run() -> URL? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(format.rawValue, forKey: "stillFormat")
        if inClip { UserDefaults.standard.set(capBox.state == .on, forKey: "stillCaptions") }
        return url
    }
}

@MainActor
enum StillsAccessory {
    static func make(popup: NSPopUpButton, capBox: NSButton?, target: AnyObject, action: Selector) -> NSView {
        popup.removeAllItems()
        for f in StillFormat.allCases { popup.addItem(withTitle: f.label) }
        popup.target = target
        popup.action = action
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.orientation = .horizontal
        row.spacing = 8
        var views: [NSView] = [row]
        if let capBox { views.append(capBox) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: capBox == nil ? 46 : 72))
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            stack.topAnchor.constraint(equalTo: holder.topAnchor),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }
}
