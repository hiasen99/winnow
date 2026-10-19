import Foundation
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Style

/// How clip thumbnails look in a project: the clip's frame with picture adjustments, a dark fade, the title and a logo.
/// Sizes are fractions of the picture, so one style works for 9:16, 1:1 and 16:9 clips.
struct ThumbnailStyle: Codable, Hashable {
    var showTitle = true
    var fontName = "AvenirNext-Heavy"
    var fontWeight: Double? = nil
    var textSize = 0.1              // fraction of the picture's shorter side
    var textColor: RGBA = .white
    var uppercase = true
    var alignLeft = false
    var titleY = 0.8                // centre of the title, fraction of the height (0 = top)
    var textWidth = 0.84            // how wide the title may get, fraction of the width
    var outline = 0.0               // fraction of the font size
    var outlineColor: RGBA = .black
    var shadow = true
    var shade = 0.6                 // dark fade behind the title (0 = none)
    var shadeColor: RGBA = .black
    var logoPath: String? = nil
    var logoSize = 0.22             // fraction of the width
    var logoCorner = 1              // 0 top left, 1 top right, 2 bottom left, 3 bottom right
    var brightness = 0.0            // -0.3 … 0.3
    var contrast = 1.0              // 0.6 … 1.6
    var saturation = 1.0            // 0 … 2
    var withExport = true           // save one next to every exported video
    var png = false                 // file type (false = JPEG)

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = ThumbnailStyle()
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        showTitle = g(.showTitle, z.showTitle); fontName = g(.fontName, z.fontName)
        fontWeight = (try? c.decodeIfPresent(Double.self, forKey: .fontWeight)) ?? nil
        textSize = g(.textSize, z.textSize); textColor = g(.textColor, z.textColor); uppercase = g(.uppercase, z.uppercase)
        alignLeft = g(.alignLeft, z.alignLeft); titleY = g(.titleY, z.titleY); textWidth = g(.textWidth, z.textWidth)
        outline = g(.outline, z.outline); outlineColor = g(.outlineColor, z.outlineColor); shadow = g(.shadow, z.shadow)
        shade = g(.shade, z.shade); shadeColor = g(.shadeColor, z.shadeColor)
        logoPath = (try? c.decodeIfPresent(String.self, forKey: .logoPath)) ?? nil
        logoSize = g(.logoSize, z.logoSize); logoCorner = g(.logoCorner, z.logoCorner)
        brightness = g(.brightness, z.brightness); contrast = g(.contrast, z.contrast); saturation = g(.saturation, z.saturation)
        withExport = g(.withExport, z.withExport); png = g(.png, z.png)
    }

    /// Where thumbnails start: the project's caption look (font, weight, colour, caps, outline, shadow, height, margins).
    static func matching(_ c: CaptionStyle, keeping k: ThumbnailStyle? = nil) -> ThumbnailStyle {
        var s = k ?? ThumbnailStyle()
        s.showTitle = true
        s.fontName = c.fontName; s.fontWeight = c.fontWeight
        s.textSize = c.fontSize
        s.textColor = c.textColor; s.uppercase = c.uppercase
        s.outline = c.strokeWidth / 2              // captions stroke both sides of the edge; thumbnails measure the outside part
        s.outlineColor = c.strokeColor; s.shadow = c.shadow
        s.titleY = c.positionY
        s.textWidth = min(0.96, max(0.4, 1 - 2 * c.sideMargin))
        s.alignLeft = false
        return s
    }

    var pictureIsDefault: Bool { abs(brightness) < 0.001 && abs(contrast - 1) < 0.001 && abs(saturation - 1) < 0.001 }
    var ext: String { png ? "png" : "jpg" }
    var format: StillFormat { png ? .png : .jpeg }
    static let cornerNames = ["Top left", "Top right", "Bottom left", "Bottom right"]

    static var builtIns: [ThumbnailPreset] {
        let bottom = ThumbnailStyle()
        var top = ThumbnailStyle(); top.titleY = 0.18; top.logoCorner = 3
        var big = ThumbnailStyle(); big.titleY = 0.5; big.textSize = 0.14; big.shade = 0; big.outline = 0.1; big.textWidth = 0.9
        big.fontName = "Impact"; big.contrast = 1.1; big.saturation = 1.15
        var clean = ThumbnailStyle(); clean.showTitle = false; clean.shade = 0
        return [ThumbnailPreset(name: "Title at the bottom, dark fade", style: bottom),
                ThumbnailPreset(name: "Title at the top", style: top),
                ThumbnailPreset(name: "Big outlined title in the middle", style: big),
                ThumbnailPreset(name: "Just the picture (and logo)", style: clean)]
    }
}

struct ThumbnailPreset: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var style: ThumbnailStyle
}

extension Store {
    struct ThumbPresetFile: Codable {
        var presets: [ThumbnailPreset] = []
        var defaultName: String? = nil
    }
    static var thumbPresetsURL: URL { supportDir.appendingPathComponent("thumbnail-presets.json") }
    static func loadThumbPresets() -> ThumbPresetFile {
        guard let d = try? Data(contentsOf: thumbPresetsURL), let f = try? decoder.decode(ThumbPresetFile.self, from: d) else { return ThumbPresetFile() }
        return f
    }
    static func saveThumbPresets(_ f: ThumbPresetFile) {
        try? encoder.encode(f).write(to: thumbPresetsURL, options: .atomic)
        cachedDefaultThumb = nil
    }
    nonisolated(unsafe) static var cachedDefaultThumb: ThumbnailStyle?? = nil
    /// The style new projects start with ("Use for new projects" in the thumbnail presets).
    static var defaultThumbnailStyle: ThumbnailStyle? {
        if let c = cachedDefaultThumb { return c }
        let f = loadThumbPresets()
        let s = f.defaultName.flatMap { n in f.presets.first { $0.name == n }?.style }
        cachedDefaultThumb = .some(s)
        return s
    }
}

// MARK: - Drawing

enum Thumbnailer {
    static let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// The title as it's drawn (ALL CAPS applied).
    static func text(_ title: String, _ s: ThumbnailStyle) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.uppercase ? t.uppercased() : t
    }

    /// Draws the thumbnail on top of `frame` (same size as the frame).
    @MainActor
    static func compose(frame: CGImage, title: String, style s: ThumbnailStyle) -> CGImage? {
        let W = frame.width, H = frame.height
        let size = CGSize(width: W, height: H)
        var base = frame
        if !s.pictureIsDefault, let f = CIFilter(name: "CIColorControls") {
            let input = CIImage(cgImage: frame)
            f.setValue(input, forKey: kCIInputImageKey)
            f.setValue(s.brightness, forKey: kCIInputBrightnessKey)
            f.setValue(s.contrast, forKey: kCIInputContrastKey)
            f.setValue(s.saturation, forKey: kCIInputSaturationKey)
            if let out = f.outputImage, let cg = ci.createCGImage(out, from: input.extent) { base = cg }
        }
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: Stills.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(origin: .zero, size: size))
        // from here on: y down, like the screen
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }

        let words = text(title, s)
        if s.showTitle && !words.isEmpty {
            let (attr, outlineAttr, rect) = layoutTitle(words, s, size)
            if s.shade > 0.001 {
                let below = s.titleY >= 0.5
                let pad = size.height * 0.14
                let a = below ? max(0, rect.minY - pad) : 0
                let b = below ? size.height : min(size.height, rect.maxY + pad)
                let c0 = s.shadeColor
                let colors = [CGColor(srgbRed: c0.r, green: c0.g, blue: c0.b, alpha: 0),
                              CGColor(srgbRed: c0.r, green: c0.g, blue: c0.b, alpha: min(1, s.shade))] as CFArray
                if let gr = CGGradient(colorsSpace: Stills.sRGB, colors: colors, locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: 0, y: a, width: size.width, height: b - a))
                    ctx.drawLinearGradient(gr, start: CGPoint(x: 0, y: below ? a : b), end: CGPoint(x: 0, y: below ? b : a), options: [])
                    ctx.restoreGState()
                }
            }
            if let o = outlineAttr {
                // round corners on the outline (the default mitre join leaves spikes on letters like V, W, Y)
                ctx.saveGState()
                ctx.setLineJoin(.round); ctx.setLineCap(.round)
                o.draw(with: rect, options: [.usesLineFragmentOrigin])
                ctx.restoreGState()
            }
            attr.draw(with: rect, options: [.usesLineFragmentOrigin])
        }
        if let path = s.logoPath, let logo = NSImage(contentsOfFile: path), logo.size.width > 0 {
            let margin = min(size.width, size.height) * 0.045
            var w = size.width * s.logoSize
            var h = w * logo.size.height / logo.size.width
            if h > size.height * 0.3 { h = size.height * 0.3; w = h * logo.size.width / logo.size.height }
            let left = s.logoCorner % 2 == 0, top = s.logoCorner < 2
            let r = CGRect(x: left ? margin : size.width - margin - w, y: top ? margin : size.height - margin - h, width: w, height: h)
            logo.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        return ctx.makeImage()
    }

    /// The title's text (and its outline pass) and where it goes; shrinks a long title until it fits.
    static func layoutTitle(_ words: String, _ s: ThumbnailStyle, _ size: CGSize) -> (NSAttributedString, NSAttributedString?, CGRect) {
        let short = min(size.width, size.height)
        let maxW = size.width * min(0.98, max(0.3, s.textWidth))
        var pt = CGFloat(s.textSize) * short
        var attr = NSAttributedString(), outline: NSAttributedString? = nil
        var box = CGSize.zero
        for _ in 0..<14 {
            let font = FontCatalog.font(s.fontName, size: pt, weight: s.fontWeight) ?? NSFont.systemFont(ofSize: pt, weight: .heavy)
            let para = NSMutableParagraphStyle()
            para.alignment = s.alignLeft ? .left : .center
            para.lineHeightMultiple = 0.92
            para.lineBreakMode = .byWordWrapping
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: s.textColor.cgColor) ?? .white, .paragraphStyle: para]
            if s.shadow && s.outline < 0.001 {
                let sh = NSShadow()
                sh.shadowBlurRadius = pt * 0.18
                sh.shadowOffset = NSSize(width: 0, height: -pt * 0.05)
                sh.shadowColor = NSColor.black.withAlphaComponent(0.65)
                a[.shadow] = sh
            }
            attr = NSAttributedString(string: words, attributes: a)
            box = attr.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
            if s.outline > 0.001 {
                var o = a
                o[.strokeWidth] = s.outline * 200          // percent of the font size, drawn on both sides of the edge
                o[.strokeColor] = NSColor(cgColor: s.outlineColor.cgColor) ?? .black
                if s.shadow {
                    let sh = NSShadow()
                    sh.shadowBlurRadius = pt * 0.18
                    sh.shadowOffset = NSSize(width: 0, height: -pt * 0.05)
                    sh.shadowColor = NSColor.black.withAlphaComponent(0.65)
                    o[.shadow] = sh
                }
                outline = NSAttributedString(string: words, attributes: o)
            } else { outline = nil }
            if box.height <= size.height * 0.5 && box.width <= maxW + 1 { break }
            pt *= 0.9
        }
        let x = (size.width - maxW) / 2
        var y = size.height * CGFloat(s.titleY) - box.height / 2
        y = max(short * 0.03, min(size.height - box.height - short * 0.03, y))
        return (attr, outline, CGRect(x: x, y: y, width: maxW, height: ceil(box.height) + 2))
    }
}

// MARK: - Clip thumbnails

@MainActor
private enum ThumbFrameCache {
    static var frames: [String: CGImage] = [:]
    static var order: [String] = []
    static func get(_ k: String) -> CGImage? { frames[k] }
    static func put(_ k: String, _ img: CGImage) {
        frames[k] = img; order.removeAll { $0 == k }; order.append(k)
        while order.count > 6 { frames[order.removeFirst()] = nil }
    }
}

@MainActor
extension ProjectModel {
    /// This project's thumbnail look (or the one set for new projects, or the built-in one).
    /// Until it's changed, it follows the caption style (or the preset chosen for new projects).
    var thumbnailStyle: ThumbnailStyle { project.thumbnailStyle ?? Store.defaultThumbnailStyle ?? ThumbnailStyle.matching(project.captionStyle) }
    var thumbnailStyleIsCaptions: Bool { project.thumbnailStyle == nil && Store.defaultThumbnailStyle == nil }

    func setThumbnailStyle(_ s: ThumbnailStyle) { liveEdit { $0.thumbnailStyle = s } }

    /// The moment a clip's thumbnail shows, in clip time: the frame you picked, or one second in.
    /// (For a frame from the recording or a picture file, the nearest moment in the clip.)
    func thumbnailOutTime(_ c: Clip) -> Double {
        if let m = c.thumbnail?.time { return min(c.outputTimeClamped(forMaster: m), max(0, c.outputDuration - 0.05)) }
        return min(1.0, c.outputDuration / 2)
    }
    /// The thumbnail's moment in the full recording (seconds).
    func thumbnailMasterTime(_ c: Clip) -> Double { c.thumbnail?.time ?? c.masterTime(forOutput: thumbnailOutTime(c)) }

    /// One change to a clip's thumbnail; `live` = slider / typing (one undo step per gesture).
    func changeThumbnail(_ id: UUID, live: Bool = false, _ f: (inout ClipThumbnail) -> Void) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var t = project.clips[i].thumbnail ?? ClipThumbnail(); f(&t)
        let new: ClipThumbnail? = t.isEmpty ? nil : t
        guard new != project.clips[i].thumbnail else { return }
        if live { liveEdit { $0.clips[i].thumbnail = new } } else { edit(rebuild: false) { $0.clips[i].thumbnail = new } }
    }
    /// A frame inside the clip (clip time).
    func setThumbnailClipTime(_ id: UUID, out: Double, live: Bool = false) {
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        let m = c.masterTime(forOutput: max(0, min(out, c.outputDuration)))
        changeThumbnail(id, live: live) { $0.time = m; $0.fromRecording = nil; $0.angle = nil; $0.imagePath = nil }
    }
    /// A frame from anywhere in the recording (it can be outside the clip).
    func setThumbnailRecordingTime(_ id: UUID, master: Double, live: Bool = false) {
        let m = max(0, min(master, project.masterDuration - 0.02))
        changeThumbnail(id, live: live) { $0.time = m; $0.fromRecording = true; $0.imagePath = nil }
    }
    func setThumbnailAngle(_ id: UUID, _ a: Int?) { changeThumbnail(id) { $0.angle = a } }
    func setThumbnailImage(_ id: UUID, _ path: String?) { changeThumbnail(id) { $0.imagePath = path } }
    func setThumbnailSource(_ id: UUID, _ s: ThumbSource) {
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        switch s {
        case .clip: setThumbnailClipTime(id, out: thumbnailOutTime(c))
        case .recording: setThumbnailRecordingTime(id, master: thumbnailMasterTime(c))
        case .file: break    // set when a picture is chosen
        }
    }
    func thumbnailTitle(_ c: Clip) -> String {
        if let t = c.thumbnail?.title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return c.title
    }

    /// T: the frame under the playhead becomes this clip's thumbnail.
    func useFrameAsThumbnail() {
        guard selectedClip != nil else { notice = "Open a clip first: thumbnails belong to clips."; return }
        let m = masterTime(engine.time)
        updateClip(rebuild: false) { c in
            var t = c.thumbnail ?? ClipThumbnail(); t.time = m; t.fromRecording = nil; t.angle = nil; t.imagePath = nil; c.thumbnail = t
        }
        notice = "This frame is the clip's thumbnail. Adjust its title and look with Thumbnail ▸ Edit…"
    }
    func setThumbnailFrame(_ id: UUID, master: Double?) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        edit(rebuild: false) { p in
            var t = p.clips[i].thumbnail ?? ClipThumbnail(); t.time = master
            if master == nil { t.fromRecording = nil; t.angle = nil }
            p.clips[i].thumbnail = t.isEmpty ? nil : t
        }
    }
    /// Its own title for the thumbnail (nil or empty = the clip's title).
    func setThumbnailTitle(_ id: UUID, _ s: String?) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let v = (s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? nil : s
        liveEdit { p in
            var t = p.clips[i].thumbnail ?? ClipThumbnail(); t.title = v
            p.clips[i].thumbnail = t.isEmpty ? nil : t
        }
    }

    /// The clip's frame for its thumbnail (no captions), cached while the style is being changed.
    func thumbnailFrame(_ c: Clip) async throws -> CGImage {
        var k = c; k.thumbnail?.title = nil; k.title = ""; k.status = nil; k.note = ""; k.grabs = nil
        let key = "\(folder.path)|\(k.hashValue)|\(project.angles.hashValue)"
        if let img = ThumbFrameCache.get(key) { return img }
        let size = c.format.renderSize
        let img: CGImage
        if let path = c.thumbnail?.imagePath {
            // a picture file, filling the clip's shape
            guard let ns = NSImage(contentsOfFile: path), let src = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ClipsError("Couldn't read the picture \(URL(fileURLWithPath: path).lastPathComponent).")
            }
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: Stills.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClipsError("Couldn't draw the picture.") }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.interpolationQuality = .high
            let k = max(size.width / CGFloat(src.width), size.height / CGFloat(src.height))
            let w = CGFloat(src.width) * k, h = CGFloat(src.height) * k
            ctx.draw(src, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            guard let out = ctx.makeImage() else { throw ClipsError("Couldn't draw the picture.") }
            img = out
        } else if c.thumbnail?.fromRecording == true, let m = c.thumbnail?.time {
            // anywhere in the recording: a one-second stand-in clip around it, with this clip's shape and camera framing
            var t = c
            let a = max(0, m - 0.5), b = min(project.masterDuration, max(m + 0.5, a + 0.1))
            t.ranges = [TimeRange(start: a, end: b)]
            t.splits = nil; t.shotFraming = nil; t.captionBlocks = nil
            t.switches = c.thumbnail?.angle.map { [AngleSwitch(time: a, angle: $0)] } ?? []
            img = try await stillImage(clip: t, at: m - a, captions: false)
        } else {
            img = try await stillImage(clip: c, at: thumbnailOutTime(c), captions: false)
        }
        ThumbFrameCache.put(key, img)
        return img
    }

    func thumbnailImage(_ c: Clip, style: ThumbnailStyle? = nil) async throws -> CGImage {
        let frame = try await thumbnailFrame(c)
        guard let img = Thumbnailer.compose(frame: frame, title: thumbnailTitle(c), style: style ?? thumbnailStyle) else {
            throw ClipsError("Couldn't draw the thumbnail.")
        }
        return img
    }

    @discardableResult
    func saveThumbnail(_ c: Clip, to url: URL, quiet: Bool = false) async -> Bool {
        do {
            let img = try await thumbnailImage(c)
            try Stills.write(img, to: url, format: url.pathExtension.lowercased() == "png" ? .png : .jpeg)
            if !quiet {
                lastExportBatch = []; lastExport = url
                notice = "Saved “\(url.lastPathComponent)” in \(Stills.tilde(url.deletingLastPathComponent()))"
            }
            return true
        } catch {
            if !quiet { errorText = "Couldn't save the thumbnail: \(error.localizedDescription)" }
            Log.write("thumbnail failed: \(error)")
            return false
        }
    }

    func saveThumbnailAsking(_ id: UUID) async {
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        engine.pause()
        let s = thumbnailStyle
        let panel = NSSavePanel()
        panel.title = "Save Thumbnail"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = exportFolder
        panel.allowedContentTypes = [s.png ? .png : .jpeg]
        panel.nameFieldStringValue = Exporter.safeName(c.title) + " thumbnail." + s.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "exportDir.\(project.id.uuidString)")
        await saveThumbnail(c, to: url)
    }

    /// After a clip's video is exported: "<video name> thumbnail.jpg" beside it (when the style says so).
    func writeThumbnail(_ c: Clip, beside video: URL) async {
        let s = thumbnailStyle
        guard s.withExport else { return }
        let url = video.deletingLastPathComponent()
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent + " thumbnail." + s.ext)
        await saveThumbnail(c, to: url, quiet: true)
    }
}
