import Foundation
import AppKit
import QuartzCore
import CoreText

/// Captions that copy Descript's animated captions, measured frame by frame from a Descript export
/// (reference sample, Nov 2026: Roboto Condensed Bold, ALL CAPS, white, tan box on the spoken word).
/// Turned on with `CaptionStyle.descript`.
///
/// - Grouping: each sentence is split into the fewest lines that fit the width, then the lines are evened out
///   (least total squared space left over). A sentence ends at . ? ! (also ?" and !", but not .").
///   `maxLines` lines show at a time (Descript: 1).
/// - Timing: a caption appears one frame (1/30 s) before its first word and stays until the next caption,
///   through pauses shorter than `holdGap`. The box sits on a word from its start to the next word's start.
/// - The box pops: 0.95× at the word's start, eases to 1.05× in 80 ms, holds 20 ms, eases back to 1× in 120 ms.
/// - One soft black shadow (Gaussian, σ ≈ 0.113 em, no offset) under the text and the box; text is drawn on top.
/// All sizes are fractions of the font size (em), measured at 84.3 px on a 1080 × 1920 frame.
enum DescriptCaptions {
    static let lead = 1.0 / 30               // a caption shows this long before its first word
    static let holdGap = 2.0                 // stays up through a pause shorter than this (seconds)
    static let wordGapExtra = 0.0013         // added to the font's space between words (CoreText's space)
    static let boxPadX = 0.1209              // box past each side of the word
    static let boxTop = 0.8556               // box top, above the baseline
    static let boxBottom = 0.2906            // box bottom, below the baseline
    static let baselineBelowCentre = 0.249   // a one-line caption's baseline sits this far below `positionY`
    static let centreNudge = 0.0036          // where Descript centres the line, relative to the middle
    static let shadowSigma = 0.1127          // shadow blur (standard deviation)
    static let embolden = 0.0164             // stroke on the letter outlines: Descript's stems are this much heavier (measured)
    static let textShadowAlpha: CGFloat = 0.94   // the text's shadow is a little lighter than the box's
    // CoreGraphics / CoreAnimation blur amounts per unit of standard deviation (matched against exports)
    static var cgBlurPerSigma: CGFloat = 1.71
    static var caRadiusPerSigma: CGFloat = 0.85
    static let popFrom = 0.95, popPeak = 1.05, popRise = 0.080, popHold = 0.020, popFall = 0.120

    /// How a word is drawn: Descript writes an ellipsis as three full stops.
    static func shown(_ s: String) -> String { s.replacingOccurrences(of: "…", with: "...") }

    /// Does this word end a sentence (for grouping)?
    static func endsSentence(_ w: String) -> Bool {
        var t = w
        if t.hasSuffix("\"") || t.hasSuffix("”") {
            t.removeLast()
            return t.hasSuffix("?") || t.hasSuffix("!")
        }
        return t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") || t.hasSuffix("…")
    }

    struct Metrics {
        let font: NSFont
        let px: CGFloat
        let gap: CGFloat      // from the end of one word to the start of the next
        let maxW: CGFloat
    }

    static func metrics(_ style: CaptionStyle, _ size: CGSize) -> Metrics {
        let f = Captions.font(style, width: size.width)
        let px = f.pointSize
        let space = Captions.measure(" ", font: f)
        return Metrics(font: f, px: px, gap: space + CGFloat(wordGapExtra) * px, maxW: size.width * (1 - 2 * style.sideMargin))
    }

    /// Word widths → lines: the fewest lines no wider than `maxW`, evened out (least total squared slack).
    /// A word wider than a line gets a line to itself.
    static func balance(_ w: [CGFloat], gap: CGFloat, maxW: CGFloat) -> [Range<Int>] {
        let n = w.count
        guard n > 0 else { return [] }
        var pre = [CGFloat](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + w[i] }
        func width(_ i: Int, _ j: Int) -> CGFloat { pre[j] - pre[i] + gap * CGFloat(j - i - 1) }
        var k = 0
        var lineW: CGFloat = -1
        for x in w {
            if lineW < 0 || lineW + gap + x > maxW { k += 1; lineW = x } else { lineW += gap + x }
        }
        let inf = Double.infinity
        var best = [[Double]](repeating: [Double](repeating: inf, count: k + 1), count: n + 1)
        var next = [[Int]](repeating: [Int](repeating: -1, count: k + 1), count: n + 1)
        best[n][0] = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            for l in 1...k {
                var j = i + 1
                while j <= n {
                    let lw = width(i, j)
                    if lw > maxW && j > i + 1 { break }
                    let rest = best[j][l - 1]
                    if rest < inf {
                        let slack = Double(maxW - lw)
                        let c = rest + slack * slack
                        if c < best[i][l] { best[i][l] = c; next[i][l] = j }
                    }
                    j += 1
                }
            }
        }
        var out: [Range<Int>] = []
        var i = 0, l = k
        while i < n, l > 0, next[i][l] > i { out.append(i..<next[i][l]); i = next[i][l]; l -= 1 }
        if i < n { out.append(i..<n) }
        return out
    }

    /// One hand-made caption's words as lines (all shown together).
    static func wrap(_ ws: [CaptionWord], style: CaptionStyle, renderSize: CGSize) -> [[Int]] {
        guard !ws.isEmpty else { return [] }
        let m = metrics(style, renderSize)
        return balance(ws.map { Captions.measure(shown($0.text), font: m.font) }, gap: m.gap, maxW: m.maxW).map { Array($0) }
    }

    /// Groups words into on-screen captions the way Descript does.
    static func pages(_ words: [CaptionWord], style: CaptionStyle, renderSize: CGSize, total: Double) -> [CaptionPage] {
        guard !words.isEmpty else { return [] }
        let m = metrics(style, renderSize)
        let widths = words.map { Captions.measure(shown($0.text), font: m.font) }
        // sentences (also broken at long pauses, where the clip jumps to a moved part, and every 80 words)
        var units: [[Int]] = []
        var cur: [Int] = []
        for i in words.indices {
            if let p = cur.last, words[i].start - words[p].end > style.pauseBreak || words[i].part != words[p].part {
                units.append(cur); cur = []
            }
            cur.append(i)
            if endsSentence(words[i].text) || cur.count >= 80 { units.append(cur); cur = [] }
        }
        if !cur.isEmpty { units.append(cur) }
        var pages: [CaptionPage] = []
        let per = max(1, style.maxLines)
        for u in units {
            let lines = balance(u.map { widths[$0] }, gap: m.gap, maxW: m.maxW).map { r in r.map { u[$0] } }
            var k = 0
            while k < lines.count {
                let ls = Array(lines[k..<min(lines.count, k + per)])
                pages.append(CaptionPage(start: words[ls[0][0]].start, end: words[ls[ls.count - 1].last!].end, lines: ls))
                k += per
            }
        }
        for i in pages.indices {
            var s = words[pages[i].lines[0][0]].start - lead
            if i > 0 { s = max(s, pages[i - 1].start + 0.01) }
            pages[i].start = max(0, s)
        }
        for i in pages.indices {
            let lastEnd = words[pages[i].lines[pages[i].lines.count - 1].last!].end
            if i + 1 < pages.count {
                let nextFirst = words[pages[i + 1].lines[0][0]].start
                pages[i].end = nextFirst - lastEnd < holdGap ? pages[i + 1].start : min(lastEnd + 0.35, pages[i + 1].start)
            } else {
                pages[i].end = lastEnd + 0.35
            }
            pages[i].end = max(pages[i].end, pages[i].start + 0.05)
        }
        return pages
    }

    /// The box's size while it pops, `t` seconds after its word starts.
    static func popScale(_ t: Double) -> Double {
        func ss(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        if t < popRise { return popFrom + (popPeak - popFrom) * ss(t / popRise) }
        if t < popRise + popHold { return popPeak }
        return popPeak + (1 - popPeak) * ss((t - popRise - popHold) / popFall)
    }

    static func pop(start: Double, total: Double) -> CAKeyframeAnimation {
        let dur = popRise + popHold + popFall
        let n = 44
        var vals: [Any] = [], times: [Double] = []
        for i in 0...n {
            let t = dur * Double(i) / Double(n)
            vals.append(NSNumber(value: popScale(t)))
            times.append(start + t)
        }
        return Captions.moving("transform.scale", vals, times, total: total)
    }

    /// The outline of a word's letters (origin on the baseline at its left end), so it can be filled and stroked exactly.
    static func glyphPath(_ s: String, font: NSFont) -> CGPath {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? (font as CTFont)
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    path.addPath(g, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        return path
    }

    private struct Placed { let index: Int; let x: CGFloat; let width: CGFloat; let baseline: CGFloat }

    /// The caption overlay (top-left coordinates, like `Captions.makeLayer`).
    static func makeLayer(_ track: CaptionTrack, style: CaptionStyle, renderSize: CGSize, total: Double) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        let m = metrics(style, renderSize)
        let px = m.px
        let words = track.words
        let step = px * CGFloat(style.lineSpacing)
        let sigma = CGFloat(shadowSigma) * px
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let highlightText = (style.mode == .highlight || style.mode == .revealHighlight) && style.activeColor != style.textColor

        for page in track.pages where !page.lines.isEmpty {
            let pageLayer = CALayer()
            pageLayer.frame = root.bounds
            pageLayer.opacity = 0
            pageLayer.add(Captions.discrete([0, 1, 0], [page.start, page.end], total: total), forKey: "show")

            // where every word goes
            let centreY = CGFloat(page.positionY ?? style.positionY) * renderSize.height
            let n = page.lines.count
            var placed: [Placed] = []
            for (li, line) in page.lines.enumerated() {
                let ws = line.map { Captions.measure(shown(words[$0].text), font: m.font) }
                let lineW = ws.reduce(0, +) + m.gap * CGFloat(max(0, line.count - 1))
                var x = (renderSize.width - lineW) / 2 + CGFloat(centreNudge) * px
                let baseline = centreY + CGFloat(baselineBelowCentre) * px + (CGFloat(li) - CGFloat(n - 1) / 2) * step
                for (k, wi) in line.enumerated() {
                    placed.append(Placed(index: wi, x: x, width: ws[k], baseline: baseline))
                    x += ws[k] + m.gap
                }
            }
            guard !placed.isEmpty else { continue }

            // one picture area around the text (room for the shadow and the box)
            let margin = ceil(3.5 * sigma + CGFloat(boxPadX) * px * 1.1)
            let minX = placed.map { $0.x }.min()!, maxX = placed.map { $0.x + $0.width }.max()!
            let minB = placed.map { $0.baseline }.min()!, maxB = placed.map { $0.baseline }.max()!
            let band = CGRect(x: floor(minX - margin), y: floor(minB - CGFloat(boxTop) * px * 1.06 - margin),
                              width: 0, height: 0)
            let bandW = ceil(maxX + margin) - band.minX
            let bandH = ceil(maxB + CGFloat(boxBottom) * px * 1.06 + margin) - band.minY
            let area = CGRect(x: band.minX, y: band.minY, width: bandW, height: bandH)

            /// A picture of `area`. `spare`: the canvas is twice as wide, the words are drawn in the right half,
            /// and only the left half is kept (for a shadow on its own, cast across by an offset).
            func picture(spare: Bool = false, _ draw: (CGContext) -> Void) -> CALayer? {
                let w = Int(area.width), h = Int(area.height)
                guard w > 0, h > 0,
                      let ctx = CGContext(data: nil, width: spare ? 2 * w : w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                draw(ctx)
                guard var img = ctx.makeImage() else { return nil }
                if spare, let c = img.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) { img = c }
                let l = CALayer()
                l.frame = area
                l.contents = img
                l.contentsGravity = .resize
                return l
            }
            func drawWords(_ ctx: CGContext, _ color: CGColor, only: Int? = nil, dx: CGFloat = 0) {
                ctx.setFillColor(color)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(CGFloat(embolden) * px)
                ctx.setLineJoin(.round)
                for p in placed where only == nil || p.index == only! {
                    ctx.saveGState()
                    ctx.translateBy(x: p.x - area.minX + dx, y: area.maxY - p.baseline)
                    ctx.addPath(glyphPath(shown(words[p.index].text), font: m.font))
                    ctx.drawPath(using: embolden > 0 ? .fillStroke : .fill)
                    ctx.restoreGState()
                }
            }

            // 1. the text's shadow on its own (also under the letters, so their soft edges sit on it), under the boxes
            if style.shadow, let sh = picture(spare: true, { ctx in
                let w = area.width
                ctx.setShadow(offset: CGSize(width: -w, height: 0), blur: sigma * cgBlurPerSigma,
                              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: textShadowAlpha))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                drawWords(ctx, black, dx: w)
                ctx.endTransparencyLayer()
            }) { pageLayer.addSublayer(sh) }

            // 2. the box on the spoken word, popping as each word starts
            if style.wordBoxOn {
                for (k, p) in placed.enumerated() {
                    let w = words[p.index]
                    let nextStart = k + 1 < placed.count ? min(words[placed[k + 1].index].start, page.end) : page.end
                    guard nextStart > w.start else { continue }
                    let r = CGRect(x: p.x - CGFloat(boxPadX) * px, y: p.baseline - CGFloat(boxTop) * px,
                                   width: p.width + 2 * CGFloat(boxPadX) * px, height: CGFloat(boxTop + boxBottom) * px)
                    let b = CALayer()
                    b.frame = r
                    b.backgroundColor = style.wordBoxRGBA.cgColor
                    b.cornerRadius = r.height / 2 * CGFloat(style.wordBoxRoundness)
                    if style.shadow {
                        b.shadowColor = black
                        b.shadowOpacity = 1
                        b.shadowRadius = sigma * caRadiusPerSigma
                        b.shadowOffset = .zero
                        b.shadowPath = CGPath(roundedRect: b.bounds, cornerWidth: b.cornerRadius, cornerHeight: b.cornerRadius, transform: nil)
                    }
                    b.opacity = 0
                    b.add(Captions.discrete([0, 1, 0], [w.start, nextStart], total: total), forKey: "box")
                    b.add(pop(start: w.start, total: total), forKey: "pop")
                    pageLayer.addSublayer(b)
                }
            }

            // 3. the text on top
            if let t = picture({ ctx in drawWords(ctx, style.textColor.cgColor) }) { pageLayer.addSublayer(t) }
            if highlightText {
                for (k, p) in placed.enumerated() {
                    let w = words[p.index]
                    let nextStart = k + 1 < placed.count ? min(words[placed[k + 1].index].start, page.end) : page.end
                    guard nextStart > w.start, let hi = picture({ ctx in drawWords(ctx, style.activeColor.cgColor, only: p.index) }) else { continue }
                    hi.opacity = 0
                    hi.add(Captions.discrete([0, 1, 0], [w.start, nextStart], total: total), forKey: "hi")
                    pageLayer.addSublayer(hi)
                }
            }
            root.addSublayer(pageLayer)
        }
        return root
    }
}
