import Foundation
import AppKit
import QuartzCore
import CoreText
import AVFoundation

struct CaptionWord {
    var text: String    // as drawn (uppercased if the style says so)
    var start: Double   // clip output time
    var end: Double
    var raw: String = ""        // as typed / transcribed
    var mStart: Double = 0      // master time
    var mEnd: Double = 0
}

struct CaptionPage {
    var start: Double
    var end: Double
    var lines: [[Int]]  // indexes into the word list
    var blockID: UUID? = nil    // a hand-edited caption (nil = automatic from the transcript)
    var positionY: Double? = nil  // height on screen when the camera showing has its own (nil = the style's)
    var wordIndexes: [Int] { lines.flatMap { $0 } }
}

/// Everything shown as captions in a clip: the words and how they're grouped on screen.
struct CaptionTrack {
    var words: [CaptionWord]
    var pages: [CaptionPage]
}

enum Captions {

    /// Master-time words placed in clip output time (words that were cut out are dropped).
    /// `lenient`: keep a word whose middle was cut out if its start or end is still in the clip (hand-edited captions).
    static func place(_ ws: [Word], clip: Clip, uppercase: Bool, lenient: Bool = false) -> [CaptionWord] {
        var out: [CaptionWord] = []
        for w in ws where w.end > clip.start && w.start < clip.end {
            let mid = (w.start + w.end) / 2
            let oMid = clip.outputTime(forMaster: mid)
                ?? (lenient ? (clip.outputTime(forMaster: w.start) ?? clip.outputTime(forMaster: w.end)) : nil)
            guard let o = oMid else { continue }
            let s = clip.outputTime(forMaster: max(w.start, clip.start)) ?? o
            let e = clip.outputTime(forMaster: min(w.end, clip.end)) ?? o
            let text = uppercase ? w.text.uppercased() : w.text
            out.append(CaptionWord(text: text, start: min(s, o), end: max(e, o), raw: w.text, mStart: w.start, mEnd: w.end))
        }
        return out
    }

    /// The clip's transcript words, in clip output time.
    static func words(for clip: Clip, project: Project, uppercase: Bool) -> [CaptionWord] {
        place(project.words.filter { !$0.isHidden }, clip: clip, uppercase: uppercase)
    }

    /// The clip's captions: hand-edited ones where there are any, automatic ones from the transcript everywhere else.
    static func track(for clip: Clip, project: Project, renderSize: CGSize? = nil) -> CaptionTrack {
        let style = project.captionStyle
        let size = renderSize ?? clip.format.renderSize
        let total = clip.outputDuration
        guard let blocks0 = clip.captionBlocks, !blocks0.isEmpty else {
            let w = words(for: clip, project: project, uppercase: style.uppercase)
            return placedByCamera(CaptionTrack(words: w, pages: pages(w, style: style, renderSize: size, total: total)),
                                  clip: clip, project: project)
        }
        let blocks = blocks0.sorted { $0.start < $1.start }
        // each page with its own words; joined into one list (in time order) at the end
        var parts: [(page: CaptionPage, words: [CaptionWord])] = []
        var handSpans: [(Double, Double)] = []   // output time
        for b in blocks {
            let bs = clip.outputTimeClamped(forMaster: b.start), be = clip.outputTimeClamped(forMaster: b.end)
            guard be - bs > 0.01 else { continue }       // cut out of the clip entirely
            var ws = place(b.words, clip: clip, uppercase: style.uppercase, lenient: true)
            for k in ws.indices {
                ws[k].start = min(max(ws[k].start, bs), be)
                ws[k].end = min(max(ws[k].end, ws[k].start), be)
            }
            let lines = wrap(ws, style: style, renderSize: size)
            parts.append((CaptionPage(start: bs, end: be, lines: lines, blockID: b.id), ws))
            handSpans.append((bs, be))
        }
        // transcript words that no hand-edited caption covers get automatic captions, kept out of the hand-made ones
        let free = project.words.filter { w in !w.isHidden && !blocks.contains { $0.owns(w) } }
        let fw = place(free, clip: clip, uppercase: style.uppercase)
        var run: [CaptionWord] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            for var pg in pages(run, style: style, renderSize: size, total: total) {
                if let next = handSpans.map({ $0.0 }).filter({ $0 >= pg.start - 0.001 }).min() { pg.end = min(pg.end, next) }
                let idx = pg.wordIndexes
                let ws = idx.map { run[$0] }
                var k = 0
                pg.lines = pg.lines.map { line in line.map { _ in defer { k += 1 }; return k } }
                parts.append((pg, ws))
            }
            run = []
        }
        for w in fw {
            // a hand-made caption between this word and the last one starts a new run
            if let last = run.last, handSpans.contains(where: { $0.0 >= last.end - 0.001 && $0.0 <= w.start + 0.001 }) { flushRun() }
            run.append(w)
        }
        flushRun()
        parts.sort { $0.page.start < $1.page.start }
        var allWords: [CaptionWord] = []
        var allPages: [CaptionPage] = []
        for (pg, ws) in parts {
            var p = pg
            let base = allWords.count
            p.lines = pg.lines.map { $0.map { $0 + base } }
            allWords.append(contentsOf: ws)
            allPages.append(p)
        }
        return placedByCamera(CaptionTrack(words: allWords, pages: allPages), clip: clip, project: project)
    }

    /// Cameras with their own caption height: each caption takes the height of the camera that's on screen
    /// for most of the time it's shown.
    static func placedByCamera(_ track: CaptionTrack, clip: Clip, project: Project) -> CaptionTrack {
        guard clip.framing.contains(where: { $0.captionY != nil }) else { return track }
        let pieces = Schedule.pieces(project: project, clip: clip, auto: Schedule.auto(project: project))
        guard !pieces.isEmpty else { return track }
        var t = track
        for k in t.pages.indices {
            let pg = t.pages[k]
            var best: (angle: Int, overlap: Double)? = nil
            var overlapBy: [Int: Double] = [:]
            for pc in pieces {
                let o = min(pg.end, pc.outStart + pc.duration) - max(pg.start, pc.outStart)
                if o > 0 { overlapBy[pc.angle, default: 0] += o }
            }
            for (a, o) in overlapBy.sorted(by: { $0.key < $1.key }) where best == nil || o > best!.overlap { best = (a, o) }
            // a caption that shows for no time at all: the camera at its start
            let angle = best?.angle ?? pieces.last(where: { $0.outStart <= pg.start + 1e-4 })?.angle ?? pieces[0].angle
            t.pages[k].positionY = clip.framing(for: angle).captionY
        }
        return t
    }

    /// Breaks one caption's words into lines (as many as it needs).
    static func wrap(_ ws: [CaptionWord], style: CaptionStyle, renderSize: CGSize) -> [[Int]] {
        guard !ws.isEmpty else { return [] }
        let f = font(style, width: renderSize.width)
        let maxW = renderSize.width * (1 - 2 * style.sideMargin)
        let space = measure(" ", font: f)
        var lines: [[Int]] = [[]]
        var lineW: CGFloat = 0, lineChars = 0
        for (i, w) in ws.enumerated() {
            let ww = measure(w.text, font: f)
            let has = !(lines.last?.isEmpty ?? true)
            if has && (lineChars + 1 + w.text.count > style.maxCharsPerLine || lineW + space + ww > maxW) {
                lines.append([]); lineW = 0; lineChars = 0
            }
            let has2 = !(lines.last?.isEmpty ?? true)
            lines[lines.count - 1].append(i)
            lineW += (has2 ? space : 0) + ww
            lineChars += (has2 ? 1 : 0) + w.text.count
        }
        return lines
    }

    static func font(_ style: CaptionStyle, width: Double) -> NSFont {
        let size = CGFloat(style.fontSize * width)
        return FontCatalog.font(style.fontName, size: size, weight: style.fontWeight) ?? NSFont.systemFont(ofSize: size, weight: .heavy)
    }

    static func measure(_ s: String, font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    /// Groups words into on-screen captions.
    static func pages(_ words: [CaptionWord], style: CaptionStyle, renderSize: CGSize, total: Double) -> [CaptionPage] {
        guard !words.isEmpty else { return [] }
        let f = font(style, width: renderSize.width)
        let maxW = renderSize.width * (1 - 2 * style.sideMargin)
        let space = measure(" ", font: f)
        var pages: [CaptionPage] = []
        var lines: [[Int]] = [[]]
        var lineW: CGFloat = 0
        var lineChars = 0

        func flush(_ nextStart: Double?) {
            let idx = lines.flatMap { $0 }
            guard let first = idx.first, let last = idx.last else { return }
            let s = words[first].start
            var e = words[last].end + 0.35
            if let n = nextStart { e = min(e, n) }
            pages.append(CaptionPage(start: s, end: max(e, words[last].end), lines: lines.filter { !$0.isEmpty }))
            lines = [[]]; lineW = 0; lineChars = 0
        }

        for i in words.indices {
            let w = words[i]
            let ww = measure(w.text, font: f)
            let hasContent = !(lines.last?.isEmpty ?? true)
            // new caption after a pause or after a sentence ends on a full-ish caption
            if hasContent, i > 0 {
                let gap = w.start - words[i - 1].end
                let prev = words[i - 1].text
                let sentenceEnd = prev.hasSuffix(".") || prev.hasSuffix("?") || prev.hasSuffix("!")
                if gap > style.pauseBreak || (sentenceEnd && lines.count == style.maxLines && lineChars > style.maxCharsPerLine / 2) {
                    flush(w.start)
                }
            }
            let nowHas = !(lines.last?.isEmpty ?? true)
            let fitsChars = lineChars + (nowHas ? 1 : 0) + w.text.count <= style.maxCharsPerLine
            let fitsWidth = lineW + (nowHas ? space : 0) + ww <= maxW
            if nowHas && !(fitsChars && fitsWidth) {
                if lines.count >= style.maxLines { flush(w.start) } else { lines.append([]); lineW = 0; lineChars = 0 }
            }
            let has2 = !(lines.last?.isEmpty ?? true)
            lines[lines.count - 1].append(i)
            lineW += (has2 ? space : 0) + ww
            lineChars += (has2 ? 1 : 0) + w.text.count
        }
        flush(nil)
        // make each caption last until the next one starts if the gap is short
        for i in pages.indices.dropLast() {
            let gap = pages[i + 1].start - pages[i].end
            if gap > 0 && gap < 0.4 { pages[i].end = pages[i + 1].start }
        }
        if var last = pages.last { last.end = min(max(last.end, last.start + 0.3), max(total, last.end)); pages[pages.count - 1] = last }
        return pages
    }

    // MARK: - Layers

    private static func discrete(_ values: [Float], _ times: [Double], total: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.calculationMode = .discrete
        a.values = values
        var kt: [NSNumber] = [0]
        var last = 0.0
        for t in times {
            let v = min(1, max(last, t / max(total, 0.001)))
            kt.append(NSNumber(value: v)); last = v
        }
        kt.append(1)
        a.keyTimes = kt
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.duration = max(total, 0.001)
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        return a
    }

    /// Key frames that follow `values` at `times` (clip output time) along the whole clip.
    private static func moving(_ keyPath: String, _ values: [Any], _ times: [Double], total: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        let T = max(total, 0.001)
        var vals = values
        var kt = times.map { NSNumber(value: min(1, max(0, $0 / T))) }
        // linear key frames have to run from 0 to 1
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

    /// One box behind the spoken word for a whole caption, gliding from word to word (see `WordBoxMotion`).
    private static func glidingWordBox(_ targets: [(time: Double, rect: CGRect)], until end: Double, style: CaptionStyle, total: Double) -> CALayer {
        let wb = CALayer()
        let sorted = targets.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map { $0.element }
        guard let first = sorted.first else { return wb }
        let kf = WordBoxMotion.keyframes(sorted, end: end)
        let round = CGFloat(style.wordBoxRoundness)
        wb.frame = kf.rects.last ?? first.rect
        wb.backgroundColor = style.wordBoxRGBA.cgColor
        wb.cornerRadius = wb.frame.height / 2 * round
        wb.opacity = 0
        wb.add(discrete([0, 1, 0], [first.time, max(end, first.time + 0.05)], total: total), forKey: "wordbox")
        guard kf.times.count > 1 else { return wb }
        wb.add(moving("position", kf.rects.map { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) }, kf.times, total: total), forKey: "glide.position")
        wb.add(moving("bounds", kf.rects.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) }, kf.times, total: total), forKey: "glide.bounds")
        wb.add(moving("cornerRadius", kf.rects.map { NSNumber(value: Double($0.height / 2 * round)) }, kf.times, total: total), forKey: "glide.corner")
        return wb
    }

    /// One word drawn into a bitmap (CATextLayer doesn't render reliably during export).
    /// The outline is drawn first with round corners (no spikes on sharp letters) and the letter fill on top,
    /// so the outline only shows outside the letters.
    private static func textLayer(_ text: String, font: NSFont, color: RGBA, style: CaptionStyle, shadow: Bool, at origin: CGPoint) -> CALayer {
        let pad = ceil(font.pointSize * 0.3)
        let ctKey = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let a = NSAttributedString(string: text, attributes: [.font: font, ctKey: true])
        let size = a.size()
        let w = Int(ceil(size.width + 2 * pad)), h = Int(ceil(size.height + 2 * pad))
        let layer = CALayer()
        layer.frame = CGRect(x: origin.x - pad, y: origin.y - pad, width: CGFloat(w), height: CGFloat(h))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return layer }
        let line = CTLineCreateWithAttributedString(a)
        let baseline = CGPoint(x: pad, y: pad - font.descender)
        let stroke = style.strokeWidth > 0
        func setShadow() {
            ctx.setShadow(offset: CGSize(width: 0, height: -font.pointSize * 0.05), blur: font.pointSize * 0.12,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        }
        if stroke {
            ctx.saveGState()
            if shadow { setShadow() }
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.setLineWidth(CGFloat(style.strokeWidth) * font.pointSize)
            ctx.setStrokeColor(style.strokeColor.cgColor)
            ctx.setFillColor(style.strokeColor.cgColor)
            ctx.setTextDrawingMode(.fillStroke)
            ctx.textPosition = baseline
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.saveGState()
        if shadow && !stroke { setShadow() }
        ctx.setFillColor(color.cgColor)
        ctx.setTextDrawingMode(.fill)
        ctx.textPosition = baseline
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        layer.contents = ctx.makeImage()
        layer.contentsGravity = .resize
        return layer
    }

    /// Builds the caption overlay. The returned layer uses top-left coordinates: put it inside a
    /// container whose `isGeometryFlipped` is true (see `container`).
    static func makeLayer(words: [CaptionWord], style: CaptionStyle, renderSize: CGSize, total: Double) -> CALayer {
        makeLayer(CaptionTrack(words: words, pages: pages(words, style: style, renderSize: renderSize, total: total)),
                  style: style, renderSize: renderSize, total: total)
    }

    static func makeLayer(_ track: CaptionTrack, style: CaptionStyle, renderSize: CGSize, total: Double) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        let words = track.words
        let pages = track.pages.filter { !$0.lines.isEmpty }
        let f = font(style, width: renderSize.width)
        let space = measure(" ", font: f)
        let lineH = f.ascender - f.descender + f.leading
        let step = lineH * CGFloat(style.lineSpacing)

        for (pi, page) in pages.enumerated() {
            let pageLayer = CALayer()
            pageLayer.frame = root.bounds
            pageLayer.opacity = 0
            pageLayer.add(discrete([0, 1, 0], [page.start, page.end], total: total), forKey: "show")
            let blockH = step * CGFloat(page.lines.count - 1) + lineH
            // all boxes go under all of the caption's text
            var under: [CALayer] = [], over: [CALayer] = []
            var glide: [(time: Double, rect: CGRect)] = []
            var y = CGFloat(page.positionY ?? style.positionY) * renderSize.height - blockH / 2
            for (li, line) in page.lines.enumerated() {
                let widths = line.map { measure(words[$0].text, font: f) }
                let lineW = widths.reduce(0, +) + space * CGFloat(max(0, line.count - 1))
                var x = (renderSize.width - lineW) / 2
                if style.box {
                    let pad = f.pointSize * 0.25
                    let box = CALayer()
                    box.frame = CGRect(x: x - pad, y: y - pad * 0.4, width: lineW + 2 * pad, height: lineH + pad * 0.8)
                    box.backgroundColor = style.boxColor.cgColor
                    box.cornerRadius = pad
                    if style.mode == .reveal || style.mode == .revealHighlight {
                        // the box appears with the line's first word
                        box.opacity = 0
                        box.add(discrete([0, 1], [words[line[0]].start], total: total), forKey: "box")
                    }
                    under.append(box)
                }
                // boxes behind the spoken word
                if style.wordBoxOn {
                    var bx = x
                    for (k, wi) in line.enumerated() {
                        let w = words[wi]
                        let nextStart = (wi + 1 < words.count) ? min(words[wi + 1].start, page.end) : page.end
                        let padX = f.pointSize * 0.16, padY = f.pointSize * 0.06
                        let r = CGRect(x: bx - padX, y: y - padY - f.pointSize * 0.04, width: widths[k] + 2 * padX, height: lineH * 0.95 + 2 * padY)
                        if style.wordBoxGlides {
                            glide.append((w.start, r))
                            bx += widths[k] + space
                            continue
                        }
                        let wb = CALayer()
                        wb.frame = r
                        wb.backgroundColor = style.wordBoxRGBA.cgColor
                        wb.cornerRadius = r.height / 2 * CGFloat(style.wordBoxRoundness)
                        wb.opacity = 0
                        wb.add(discrete([0, 1, 0], [w.start, max(nextStart, w.start + 0.05)], total: total), forKey: "wordbox")
                        under.append(wb)
                        bx += widths[k] + space
                    }
                }
                for (k, wi) in line.enumerated() {
                    let w = words[wi]
                    let frame = CGRect(x: x, y: y, width: widths[k] + 4, height: lineH + 2)
                    let nextStart = (wi + 1 < words.count) ? min(words[wi + 1].start, page.end) : page.end
                    let base = textLayer(w.text, font: f, color: style.textColor, style: style, shadow: style.shadow, at: frame.origin)
                    switch style.mode {
                    case .reveal, .revealHighlight:
                        base.opacity = 0
                        base.add(discrete([0, 1], [w.start], total: total), forKey: "reveal")
                    case .highlight, .line:
                        break
                    }
                    over.append(base)
                    if style.mode == .highlight || style.mode == .revealHighlight {
                        let hi = textLayer(w.text, font: f, color: style.activeColor, style: style, shadow: false, at: frame.origin)
                        hi.opacity = 0
                        hi.add(discrete([0, 1, 0], [w.start, max(nextStart, w.start + 0.05)], total: total), forKey: "hi")
                        over.append(hi)
                    }
                    x += widths[k] + space
                }
                y += step
                _ = li
            }
            under.forEach { pageLayer.addSublayer($0) }
            if !glide.isEmpty { pageLayer.addSublayer(glidingWordBox(glide, until: page.end, style: style, total: total)) }
            over.forEach { pageLayer.addSublayer($0) }
            root.addSublayer(pageLayer)
            _ = pi
        }
        return root
    }

    /// Wraps a top-left caption layer in a flipped container of the given size.
    static func container(_ layer: CALayer, size: CGSize) -> CALayer {
        let c = CALayer()
        c.frame = CGRect(origin: .zero, size: size)
        c.isGeometryFlipped = true
        c.addSublayer(layer)
        return c
    }

    // MARK: - SRT

    static func srt(words: [CaptionWord], style: CaptionStyle, renderSize: CGSize, total: Double) -> String {
        srt(CaptionTrack(words: words, pages: pages(words, style: style, renderSize: renderSize, total: total)))
    }

    static func srt(_ track: CaptionTrack) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        let words = track.words
        for (i, p) in track.pages.filter({ !$0.lines.isEmpty }).enumerated() {
            let text = p.lines.map { $0.map { words[$0].text }.joined(separator: " ") }.joined(separator: "\n")
            out += "\(i + 1)\n\(ts(p.start)) --> \(ts(p.end))\n\(text)\n\n"
        }
        return out
    }
}
