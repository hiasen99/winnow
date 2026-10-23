import Foundation
import AppKit
import QuartzCore
import CoreText
import AVFoundation

/// A follow / subscribe popup on a clip: it springs in, its button gets "tapped" (Follow → Following,
/// Subscribe → Subscribed and the bell rings), and it springs out.
struct FollowPopup: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: PopupKind = .circle
    /// When it appears (master time, so it stays with the moment when the clip is trimmed).
    var time: Double
    /// How long it's on screen, seconds of the finished clip.
    var length: Double = 4
    /// Centre of the popup, fraction of the frame (0, 0 = top left).
    var x: Double = 0.5
    var y: Double = 0.3
    /// Size (1 = normal).
    var scale: Double? = nil
    /// Whose popup it is (nil = the project's brand).
    var brandID: UUID? = nil
    /// Its own button word (nil = the brand's Follow / Subscribe word).
    var button: String? = nil
    /// The button gets tapped part way through (nil = yes).
    var tap: Bool? = nil
    /// A hand comes in and does the tapping (nil = yes).
    var hand: Bool? = nil

    var size: Double { scale ?? 1 }
    var taps: Bool { tap ?? true }
    var showsHand: Bool { hand ?? true }

    static let minLength = 1.0, maxLength = 20.0
    static let minSize = 0.5, maxSize = 2.0

    /// Where a new popup goes: above the captions on tall clips, the lower right / lower third on wide ones.
    static func defaultSpot(_ kind: PopupKind, _ f: ClipFormat) -> (x: Double, y: Double) {
        switch (f, kind) {
        case (.vertical, .circle): return (0.5, 0.2)
        case (.vertical, .bar): return (0.5, 0.2)
        case (.square, .circle): return (0.5, 0.22)
        case (.square, .bar): return (0.5, 0.17)
        case (.horizontal, .circle): return (0.86, 0.72)
        case (.horizontal, .bar): return (0.5, 0.84)
        }
    }
}

/// Named spots for placing a popup quickly (also used by Claude: "top", "bottom right", …).
enum PopupSpot: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, middle, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }
    var xy: (Double, Double) {
        let xs: [Double] = [0.24, 0.5, 0.76], ys: [Double] = [0.2, 0.5, 0.8]
        let i = PopupSpot.allCases.firstIndex(of: self)!
        return (xs[i % 3], ys[i / 3])
    }
    var label: String {
        ["Top left", "Top", "Top right", "Left", "Middle", "Right", "Bottom left", "Bottom", "Bottom right"][PopupSpot.allCases.firstIndex(of: self)!]
    }
    static func parse(_ s: String) -> PopupSpot? {
        let k = s.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "centre", with: "middle").replacingOccurrences(of: "center", with: "middle")
            .split(separator: " ").joined(separator: " ")
        let map: [String: PopupSpot] = ["top left": .topLeft, "top": .top, "top middle": .top, "top right": .topRight,
                                        "left": .left, "middle left": .left, "middle": .middle, "right": .right, "middle right": .right,
                                        "bottom left": .bottomLeft, "bottom": .bottom, "bottom middle": .bottom, "bottom right": .bottomRight]
        return map[k]
    }
}

/// Where everything in a popup goes (render pixels, top-left origin, inside the popup's box).
struct PopupLayout {
    var box: CGSize
    var unit: CGFloat
    var avatar: CGRect
    var button: CGRect
    var bell: CGRect = .zero
    var card: CGRect = .zero
    var before: String
    var after: String
    var buttonFont: NSFont
    var name: String = ""
    var sub: String = ""
    var nameFont: NSFont? = nil
    var subFont: NSFont? = nil
    var textX: CGFloat = 0
}

enum Popups {

    // MARK: words & brand

    static func brand(for p: FollowPopup, project: Project) -> ChannelBrand {
        BrandStore.brand(p.brandID ?? project.brandID) ?? BrandStore.brand(project.brandID) ?? .placeholder
    }

    /// The button's word before and after the tap.
    static func words(_ p: FollowPopup, _ b: ChannelBrand) -> (before: String, after: String) {
        let def = p.kind == .circle ? (b.follow, b.following) : (b.subscribe, b.subscribed)
        let own = (p.button ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty, own.lowercased() != def.0.lowercased() else { return def }
        let low = own.lowercased()
        if low == b.subscribe.lowercased() { return (own, b.subscribed) }
        if low == b.follow.lowercased() { return (own, b.following) }
        if low.hasPrefix("subscribe") { return (own, "Subscribed") }
        if low.hasPrefix("follow") { return (own, "Following") }
        if low.hasPrefix("join") { return (own, "Joined") }
        return (own, own)
    }

    // MARK: layout

    static func unit(_ r: CGSize) -> CGFloat { min(r.width, r.height) }

    static func measure(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }

    static func truncate(_ s: String, _ f: NSFont, _ maxW: CGFloat) -> String {
        if measure(s, f) <= maxW { return s }
        var t = s
        while !t.isEmpty && measure(t + "…", f) > maxW { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func layout(_ p: FollowPopup, brand b: ChannelBrand, renderSize R: CGSize) -> PopupLayout {
        let U = unit(R) * CGFloat(max(FollowPopup.minSize, min(FollowPopup.maxSize, p.size)))
        let w = words(p, b)
        switch p.kind {
        case .circle:
            let D = U * 0.19
            let fs = U * 0.034
            let font = NSFont.systemFont(ofSize: fs, weight: .bold)
            let tw = max(measure(w.before, font), measure(w.after, font) + fs * 1.15)   // room for the check
            let ph = U * 0.074
            let pw = min(R.width * 0.9, max(D * 0.9, tw + 2 * U * 0.042))
            let bw = max(D, pw), bh = D + ph * 0.4
            return PopupLayout(box: CGSize(width: bw, height: bh), unit: U,
                               avatar: CGRect(x: (bw - D) / 2, y: 0, width: D, height: D),
                               button: CGRect(x: (bw - pw) / 2, y: D - ph * 0.6, width: pw, height: ph),
                               before: w.before, after: w.after, buttonFont: font)
        case .bar:
            let H = U * 0.13
            let pad = H * 0.15, a = H - 2 * pad, gap = H * 0.17
            let nameFont = NSFont.systemFont(ofSize: H * 0.215, weight: .bold)
            let subFont = NSFont.systemFont(ofSize: H * 0.155, weight: .regular)
            let btnFont = NSFont.systemFont(ofSize: H * 0.175, weight: .semibold)
            let bh = H * 0.5
            let bw = max(measure(w.before, btnFont), measure(w.after, btnFont)) + 2 * H * 0.3
            let bellW = H * 0.42
            let fixed = pad + a + gap + gap * 1.3 + bw + gap * 0.6 + bellW + pad * 1.1
            let maxText = max(H, R.width * 0.94 - fixed)
            let name = b.name, sub = b.secondLine
            let textW = min(maxText, max(H * 1.1, measure(name, nameFont), measure(sub, subFont)))
            let W = fixed + textW
            let textX = pad + a + gap
            let bx = textX + textW + gap * 1.3
            var L = PopupLayout(box: CGSize(width: W, height: H), unit: U,
                                avatar: CGRect(x: pad, y: pad, width: a, height: a),
                                button: CGRect(x: bx, y: (H - bh) / 2, width: bw, height: bh),
                                bell: CGRect(x: bx + bw + gap * 0.6, y: (H - bellW) / 2, width: bellW, height: bellW),
                                card: CGRect(x: 0, y: 0, width: W, height: H),
                                before: w.before, after: w.after, buttonFont: btnFont)
            L.name = truncate(name, nameFont, textW)
            L.sub = truncate(sub, subFont, textW)
            L.nameFont = nameFont; L.subFont = subFont; L.textX = textX
            return L
        }
    }

    /// The popup's box in the frame (render pixels, top-left origin), kept inside the frame.
    static func frame(_ p: FollowPopup, layout L: PopupLayout, renderSize R: CGSize) -> CGRect {
        var cx = CGFloat(p.x) * R.width, cy = CGFloat(p.y) * R.height
        cx = min(max(cx, L.box.width / 2), max(L.box.width / 2, R.width - L.box.width / 2))
        cy = min(max(cy, L.box.height / 2), max(L.box.height / 2, R.height - L.box.height / 2))
        return CGRect(x: cx - L.box.width / 2, y: cy - L.box.height / 2, width: L.box.width, height: L.box.height)
    }

    /// Popup start / end in the finished clip.
    static func span(_ p: FollowPopup, clip: Clip) -> (start: Double, end: Double) {
        let total = clip.outputDuration
        let s = min(max(0, clip.outputTimeClamped(forMaster: p.time)), max(0, total - 0.05))
        return (s, min(total, s + max(FollowPopup.minLength, p.length)))
    }

    /// When the button is tapped (nil = no tap: switched off, or too short to fit one).
    static func tapTime(_ p: FollowPopup, start T0: Double, end T1: Double) -> Double? {
        guard p.taps else { return nil }
        let L = T1 - T0
        guard L >= (p.kind == .circle ? 2.2 : 3.0) else { return nil }
        return T0 + min(1.5, max(0.95, L * 0.3))
    }
    static let bellDelay = 0.8

    /// Popups on screen at clip time t, topmost last, with their boxes (render pixels).
    static func visible(clip: Clip, project: Project, renderSize R: CGSize, at t: Double) -> [(id: UUID, rect: CGRect)] {
        (clip.popups ?? []).compactMap { p in
            let sp = span(p, clip: clip)
            guard t >= sp.start - 0.001 && t <= sp.end + 0.001 else { return nil }
            let L = layout(p, brand: brand(for: p, project: project), renderSize: R)
            return (p.id, frame(p, layout: L, renderSize: R))
        }
    }

    // MARK: drawing

    static func bitmap(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = max(1, Int(ceil(size.width))), h = max(1, Int(ceil(size.height)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Stills.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)    // draw with y going down
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    /// Draws an (upright) image into a y-down context.
    static func drawImage(_ ctx: CGContext, _ img: CGImage, _ r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// One line of text, its capitals centred on `centerY` (y-down context).
    static func drawText(_ ctx: CGContext, _ s: String, font: NSFont, color: CGColor, x: CGFloat, centerY: CGFloat) {
        let ctKey = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, ctKey: true]))
        ctx.saveGState()
        ctx.translateBy(x: x, y: centerY + font.capHeight / 2); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(color)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// An SF Symbol as an image in one colour.
    static func symbol(_ name: String, pointSize: CGFloat, color: CGColor, weight: NSFont.Weight = .semibold) -> CGImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)) else { return nil }
        let w = Int(ceil(img.size.width)), h = Int(ceil(img.size.height))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Stills.sRGB,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func setShadow(_ ctx: CGContext, _ U: CGFloat, strength: CGFloat = 1) {
        ctx.setShadow(offset: CGSize(width: 0, height: -U * 0.006), blur: U * 0.022,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.38 * strength))
    }

    /// The profile picture in its ring.
    static func drawAvatar(_ ctx: CGContext, _ r: CGRect, brand b: ChannelBrand, ring: CGFloat, gapColor: CGColor) {
        let D = r.width
        let rw = D * ring, gap = D * 0.035
        ctx.saveGState()
        ctx.addEllipse(in: r); ctx.clip()
        if let c2 = b.color2, let g = CGGradient(colorsSpace: Stills.sRGB, colors: [b.color.cgColor, c2.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        } else {
            ctx.setFillColor(b.color.cgColor); ctx.fill(r)
        }
        ctx.restoreGState()
        ctx.setFillColor(gapColor)
        ctx.fillEllipse(in: r.insetBy(dx: rw, dy: rw))
        let pr = r.insetBy(dx: rw + gap, dy: rw + gap)
        ctx.saveGState()
        ctx.addEllipse(in: pr); ctx.clip()
        if let img = BrandStore.picture(b) {
            drawImage(ctx, img, pr)
        } else {
            // no picture yet: the first letter on the brand colour
            ctx.setFillColor(b.color.cgColor); ctx.fill(pr)
            let letter = String(b.name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased()
            let f = NSFont.systemFont(ofSize: pr.height * 0.46, weight: .heavy)
            drawText(ctx, letter, font: f, color: b.buttonText.cgColor, x: pr.midX - measure(letter, f) / 2, centerY: pr.midY)
        }
        ctx.restoreGState()
    }

    /// A pill button with its word (and a check after the tap on the circle popup).
    static func drawButton(_ ctx: CGContext, _ r: CGRect, text: String, font: NSFont, fill: CGColor, textColor: CGColor, check: Bool) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(fill); ctx.fillPath()
        let tw = measure(text, font)
        var x = r.midX - tw / 2
        if check, let ck = symbol("checkmark", pointSize: font.pointSize * 0.85, color: textColor, weight: .heavy) {
            let ch = font.capHeight * 1.05, cw = ch * CGFloat(ck.width) / CGFloat(max(1, ck.height))
            let total = cw + font.pointSize * 0.3 + tw
            x = r.midX - total / 2
            drawImage(ctx, ck, CGRect(x: x, y: r.midY - ch / 2, width: cw, height: ch))
            x += cw + font.pointSize * 0.3
        }
        drawText(ctx, text, font: font, color: textColor, x: x, centerY: r.midY)
    }

    struct Piece { var image: CGImage; var frame: CGRect }

    /// The popup's parts as pictures, each with its place in the popup's box (shadows make some bigger than the part).
    static func pieces(_ L: PopupLayout, brand b: ChannelBrand, kind: PopupKind) -> [String: Piece] {
        let U = L.unit
        let sp = (U * 0.05).rounded()        // room for the shadow
        var out: [String: Piece] = [:]
        func piece(_ key: String, _ r: CGRect, pad: CGFloat, _ draw: (CGContext, CGRect) -> Void) {
            let fr = r.insetBy(dx: -pad, dy: -pad)
            if let im = bitmap(fr.size, { ctx in draw(ctx, CGRect(x: pad, y: pad, width: r.width, height: r.height)) }) {
                out[key] = Piece(image: im, frame: fr)
            }
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        switch kind {
        case .circle:
            piece("avatar", L.avatar, pad: sp) { ctx, r in
                ctx.saveGState(); setShadow(ctx, U); ctx.setFillColor(white); ctx.fillEllipse(in: r); ctx.restoreGState()
                drawAvatar(ctx, r, brand: b, ring: 0.055, gapColor: white)
            }
            for (key, after) in [("before", false), ("after", true)] {
                piece(key, L.button, pad: sp) { ctx, r in
                    ctx.saveGState(); setShadow(ctx, U, strength: 0.8)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
                    ctx.setFillColor(white); ctx.fillPath(); ctx.restoreGState()
                    drawButton(ctx, r, text: after ? L.after : L.before, font: L.buttonFont,
                               fill: after ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : b.color.cgColor,
                               textColor: after ? white : b.buttonText.cgColor, check: after)
                }
            }
        case .bar:
            let dark = b.dark
            let cardCol = dark ? CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 0.96) : white
            let ink = dark ? white : CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
            let soft = dark ? CGColor(srgbRed: 0.72, green: 0.72, blue: 0.75, alpha: 1) : CGColor(srgbRed: 0.38, green: 0.38, blue: 0.41, alpha: 1)
            piece("card", L.card, pad: sp) { ctx, r in
                let rad = r.height * 0.3
                ctx.saveGState(); setShadow(ctx, U)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
                ctx.setFillColor(cardCol); ctx.fillPath(); ctx.restoreGState()
                let ar = L.avatar.offsetBy(dx: r.minX, dy: r.minY)
                drawAvatar(ctx, ar, brand: b, ring: 0.06, gapColor: cardCol)
                let tx = r.minX + L.textX
                if let nf = L.nameFont, let sf = L.subFont {
                    if L.sub.isEmpty {
                        drawText(ctx, L.name, font: nf, color: ink, x: tx, centerY: r.midY)
                    } else {
                        drawText(ctx, L.name, font: nf, color: ink, x: tx, centerY: r.minY + r.height * 0.38)
                        drawText(ctx, L.sub, font: sf, color: soft, x: tx, centerY: r.minY + r.height * 0.66)
                    }
                }
            }
            let doneFill = dark ? CGColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1) : CGColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1)
            for (key, after) in [("before", false), ("after", true)] {
                piece(key, L.button, pad: 2) { ctx, r in
                    drawButton(ctx, r, text: after ? L.after : L.before, font: L.buttonFont,
                               fill: after ? doneFill : b.color.cgColor, textColor: after ? ink : b.buttonText.cgColor, check: false)
                }
            }
            for (key, name) in [("bellBefore", "bell"), ("bellAfter", "bell.fill")] {
                piece(key, L.bell, pad: 2) { ctx, r in
                    guard let im = symbol(name, pointSize: r.height * 0.62, color: ink, weight: .medium) else { return }
                    let h = r.height * 0.7, w = h * CGFloat(im.width) / CGFloat(max(1, im.height))
                    drawImage(ctx, im, CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
                }
            }
        }
        return out
    }

    /// The tapping hand (white, outlined), and where its fingertip is (fraction of the image).
    static func handImage(height: CGFloat) -> (image: CGImage, tip: CGPoint)? {
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        guard let fill = symbol("hand.point.up.left.fill", pointSize: height * 0.8, color: white, weight: .regular),
              let line = symbol("hand.point.up.left", pointSize: height * 0.8, color: black, weight: .regular) else { return nil }
        let pad = (height * 0.12).rounded()
        let sz = CGSize(width: CGFloat(fill.width) + 2 * pad, height: CGFloat(fill.height) + 2 * pad)
        guard let im = bitmap(sz, { ctx in
            let r = CGRect(x: pad, y: pad, width: CGFloat(fill.width), height: CGFloat(fill.height))
            ctx.saveGState(); setShadow(ctx, height * 2.5); drawImage(ctx, fill, r); ctx.restoreGState()
            drawImage(ctx, line, r)
        }) else { return nil }
        // the index fingertip sits near the top left of the symbol
        let tip = CGPoint(x: (pad + CGFloat(fill.width) * 0.17) / sz.width, y: (pad + CGFloat(fill.height) * 0.04) / sz.height)
        return (im, tip)
    }

    // MARK: motion

    static func spring(_ u: Double, from: Double, zeta: Double = 0.55, omega: Double = 16) -> Double {
        if u <= 0 { return from }
        let wd = omega * sqrt(max(1e-6, 1 - zeta * zeta))
        return 1 - (1 - from) * exp(-zeta * omega * u) * (cos(wd * u) + zeta * omega / wd * sin(wd * u))
    }
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    static func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
    static func easeIn(_ x: Double) -> Double { let t = clamp01(x); return t * t * t }
    static func easeOut(_ x: Double) -> Double { let t = 1 - clamp01(x); return 1 - t * t * t }

    /// A press: dips to 86 % and springs back.
    static func press(_ t: Double, at tp: Double?) -> Double {
        guard let tp else { return 1 }
        let u = t - tp
        if u < 0 { return 1 }
        if u < 0.08 { return 1 - 0.14 * easeInOut(u / 0.08) }
        return spring(u - 0.08, from: 0.86, zeta: 0.42, omega: 26)
    }

    private static func keyframes(_ keyPath: String, _ values: [Any], _ times: [Double], total: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        let T = max(total, 0.001)
        var vals = values
        var kt = times.map { NSNumber(value: min(1, max(0, $0 / T))) }
        if let f = kt.first, f.doubleValue > 0, let v = values.first { kt.insert(0, at: 0); vals.insert(v, at: 0) }
        if let l = kt.last, l.doubleValue < 1, let v = values.last { kt.append(1); vals.append(v) }
        a.values = vals
        a.keyTimes = kt
        a.calculationMode = .linear
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.duration = T
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        return a
    }

    /// `f` sampled 60 times a second from a to b; held before and after.
    static func track(_ keyPath: String, _ a: Double, _ b: Double, total: Double, _ f: (Double) -> Any) -> CAKeyframeAnimation {
        let n = max(2, Int(ceil((b - a) * 60)) + 1)
        var ts: [Double] = [], vs: [Any] = []
        for k in 0..<n { let t = a + (b - a) * Double(k) / Double(n - 1); ts.append(t); vs.append(f(t)) }
        return keyframes(keyPath, vs, ts, total: total)
    }
    static func num(_ x: Double) -> NSNumber { NSNumber(value: x) }

    // MARK: layers

    /// Every popup of the clip, animated along the clip's timeline. Top-left coordinates (inside a flipped container).
    static func layer(clip: Clip, project: Project, renderSize R: CGSize, total: Double) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: R)
        root.name = "popups"
        for p in clip.popups ?? [] {
            if let l = popupLayer(p, clip: clip, project: project, renderSize: R, total: total) { root.addSublayer(l) }
        }
        return root
    }

    static func popupLayer(_ p: FollowPopup, clip: Clip, project: Project, renderSize R: CGSize, total: Double) -> CALayer? {
        let b = brand(for: p, project: project)
        let L = layout(p, brand: b, renderSize: R)
        let sp = span(p, clip: clip)
        let T0 = sp.start, T1 = min(sp.end, total)
        guard T1 > T0 + 0.2 else { return nil }
        let box = frame(p, layout: L, renderSize: R)
        let parts = pieces(L, brand: b, kind: p.kind)
        let tapT = tapTime(p, start: T0, end: T1)
        let bellT = p.kind == .bar ? tapT.map { $0 + bellDelay } : nil
        let outDur = 0.32
        let a = T0 - 1.0 / 60, z = T1 + 1.0 / 60

        let wrapper = CALayer()
        wrapper.name = "popup:" + p.id.uuidString
        wrapper.frame = box

        let mover = CALayer()
        mover.frame = CGRect(origin: .zero, size: box.size)
        mover.opacity = 0
        mover.add(track("opacity", a, z, total: total) { t in
            if t < T0 || t > T1 { return num(0) }
            return num(min(clamp01((t - T0) / 0.1), 1 - clamp01((t - (T1 - outDur * 0.8)) / (outDur * 0.8))))
        }, forKey: "popup.opacity")
        let scaler = CALayer()
        scaler.frame = mover.bounds
        if p.kind == .circle {
            // scale from the middle of the picture
            scaler.anchorPoint = CGPoint(x: 0.5, y: L.avatar.midY / max(1, box.height))
            scaler.frame = mover.bounds
            scaler.add(track("transform.scale", a, z, total: total) { t in
                let u2 = t - (T1 - outDur)
                if u2 > 0 {
                    return num(u2 < 0.08 ? 1 + 0.05 * easeOut(u2 / 0.08) : 1.05 - 0.75 * easeIn((u2 - 0.08) / (outDur - 0.08)))
                }
                return num(spring(t - T0, from: 0.25, zeta: 0.5, omega: 17))
            }, forKey: "popup.scale")
        } else {
            let H = Double(box.height)
            mover.add(track("transform.translation.y", a, z, total: total) { t in
                let u2 = t - (T1 - outDur)
                if u2 > 0 { return num(H * 0.7 * easeIn(u2 / outDur)) }
                return num((1 - spring(t - T0, from: 0, zeta: 0.72, omega: 15)) * H * 0.9)
            }, forKey: "popup.slide")
            scaler.add(track("transform.scale", a, z, total: total) { t in
                let u2 = t - (T1 - outDur)
                if u2 > 0 { return num(1 - 0.05 * easeIn(u2 / outDur)) }
                return num(spring(t - T0, from: 0.88, zeta: 0.6, omega: 16))
            }, forKey: "popup.scale")
        }
        wrapper.addSublayer(mover)
        mover.addSublayer(scaler)

        func image(_ key: String) -> CALayer? {
            guard let pc = parts[key] else { return nil }
            let l = CALayer()
            l.frame = pc.frame
            l.contents = pc.image
            l.contentsGravity = .resize
            return l
        }
        func swap(_ l: CALayer, at ts: Double?, showAfter: Bool) {
            guard let ts else { l.opacity = showAfter ? 0 : 1; return }
            l.opacity = showAfter ? 0 : 1
            l.add(track("opacity", ts + 0.04, ts + 0.09, total: total) { t in
                let k = clamp01((t - ts - 0.04) / 0.05)
                return num(showAfter ? k : 1 - k)
            }, forKey: "popup.swap")
        }
        if let c = image("card") { scaler.addSublayer(c) }
        if let av = image("avatar") { scaler.addSublayer(av) }

        // the button: its own pop-in (circle) and the press
        let btn = CALayer()
        btn.frame = parts["before"]?.frame ?? L.button
        let isCircle = p.kind == .circle
        btn.add(track("transform.scale", a, z, total: total) { t in
            let appear = isCircle ? spring(t - (T0 + 0.16), from: 0.001, zeta: 0.5, omega: 20) : 1
            return num(max(0.001, appear) * press(t, at: tapT))
        }, forKey: "popup.button")
        for (key, after) in [("before", false), ("after", true)] {
            if let l = image(key) {
                l.frame = CGRect(origin: .zero, size: btn.bounds.size)
                swap(l, at: tapT, showAfter: after)
                btn.addSublayer(l)
            }
        }
        scaler.addSublayer(btn)

        // the bell rings and fills in
        if p.kind == .bar {
            let bell = CALayer()
            let br = parts["bellBefore"]?.frame ?? L.bell
            bell.anchorPoint = CGPoint(x: 0.5, y: 0.18)
            bell.frame = br
            if let bt = bellT {
                bell.add(track("transform.rotation.z", bt - 0.02, bt + 0.95, total: total) { t in
                    let u = t - bt
                    if u <= 0 { return num(0) }
                    return num(0.5 * exp(-4.2 * u) * sin(2 * .pi * 5 * u))
                }, forKey: "popup.ring")
            }
            for (key, after) in [("bellBefore", false), ("bellAfter", true)] {
                if let l = image(key) {
                    l.frame = CGRect(origin: .zero, size: br.size)
                    swap(l, at: bellT, showAfter: after)
                    bell.addSublayer(l)
                }
            }
            scaler.addSublayer(bell)
        }

        // a hand comes in and taps (the button, then the bell)
        if p.showsHand, let tp = tapT, let hand = handImage(height: L.unit * 0.09) {
            let h = CALayer()
            h.contents = hand.image
            h.contentsGravity = .resize
            h.bounds = CGRect(x: 0, y: 0, width: hand.image.width, height: hand.image.height)
            h.anchorPoint = hand.tip
            let U = Double(L.unit)
            let t1 = CGPoint(x: L.button.midX, y: L.button.midY + L.button.height * 0.1)
            let t2 = bellT != nil ? CGPoint(x: L.bell.midX, y: L.bell.midY + L.bell.height * 0.2) : t1
            let lastPress = bellT ?? tp
            let off = CGPoint(x: U * 0.17, y: U * 0.24)
            let start = CGPoint(x: t1.x + off.x, y: t1.y + off.y)
            let end = CGPoint(x: t2.x + off.x * 1.1, y: t2.y + off.y)
            let a0 = tp - 0.62, a1 = tp - 0.03, l0 = lastPress + 0.3, l1 = lastPress + 0.75
            func lerp(_ p: CGPoint, _ q: CGPoint, _ k: Double) -> CGPoint {
                CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k)
            }
            func pos(_ t: Double) -> CGPoint {
                if t < a1 { return lerp(start, t1, easeOut((t - a0) / (a1 - a0))) }
                if let bt = bellT, t < bt - 0.03 {
                    let m0 = tp + 0.28
                    return t < m0 ? t1 : lerp(t1, t2, easeInOut((t - m0) / (bt - 0.03 - m0)))
                }
                if t < l0 { return t2 }
                return lerp(t2, end, easeIn((t - l0) / (l1 - l0)))
            }
            h.position = pos(a0)
            h.opacity = 0
            h.add(track("position", a0 - 0.02, l1 + 0.02, total: total) { t in NSValue(point: pos(t)) }, forKey: "hand.move")
            h.add(track("opacity", a0 - 0.02, l1 + 0.02, total: total) { t in
                if t < a0 || t > l1 { return num(0) }
                return num(min(clamp01((t - a0) / 0.15), 1 - clamp01((t - (l1 - 0.25)) / 0.25)))
            }, forKey: "hand.opacity")
            h.add(track("transform.scale", tp - 0.05, lastPress + 0.3, total: total) { t in
                func dip(_ at: Double) -> Double {
                    let u = t - at
                    if u < 0 || u > 0.22 { return 0 }
                    return 0.14 * sin(.pi * u / 0.22)
                }
                return num(1 - dip(tp) - (bellT.map { dip($0) } ?? 0))
            }, forKey: "hand.press")
            wrapper.addSublayer(h)
        }
        return wrapper
    }

    // MARK: stills (brand previews)

    /// The popup drawn still (after it has popped in), on a transparent background.
    static func still(kind: PopupKind, brand b: ChannelBrand, tapped: Bool = false, unit: CGFloat = 540) -> CGImage? {
        var p = FollowPopup(kind: kind, time: 0)
        p.tap = false
        let R = CGSize(width: unit * 2, height: unit)
        let L = layout(p, brand: b, renderSize: R)
        let parts = pieces(L, brand: b, kind: kind)
        let all = parts.values.map { $0.frame }.reduce(CGRect(origin: .zero, size: L.box)) { $0.union($1) }
        return bitmap(all.size) { ctx in
            ctx.translateBy(x: -all.minX, y: -all.minY)
            let order = kind == .circle ? ["avatar", tapped ? "after" : "before"]
                                        : ["card", tapped ? "after" : "before", tapped ? "bellAfter" : "bellBefore"]
            for k in order { if let pc = parts[k] { drawImage(ctx, pc.image, pc.frame) } }
        }
    }
}

/// Everything drawn over the picture: the captions (when wanted) and the follow popups.
/// Top-left coordinates: wrap it with `Captions.container`.
enum Overlay {
    static func layer(clip: Clip, project: Project, renderSize: CGSize, total: Double, captions: Bool, track: CaptionTrack? = nil) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        if captions {
            let tr = track ?? Captions.track(for: clip, project: project, renderSize: renderSize)
            let c = Captions.makeLayer(tr, style: project.captionStyle, renderSize: renderSize, total: total)
            c.name = "captions"
            root.addSublayer(c)
        }
        root.addSublayer(Popups.layer(clip: clip, project: project, renderSize: renderSize, total: total))
        return root
    }
    /// Anything to draw at all?
    static func needed(clip: Clip, captions: Bool) -> Bool { captions || !(clip.popups ?? []).isEmpty }
}
