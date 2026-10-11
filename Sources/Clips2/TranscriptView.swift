import SwiftUI
import AppKit

let speakerColors: [NSColor] = [.systemBlue, .systemOrange, .systemPink, .systemPurple]
let angleColors: [Color] = [Color(nsColor: .systemBlue), Color(nsColor: .systemOrange), Color(nsColor: .systemPink), Color(nsColor: .systemPurple)]

extension NSAttributedString.Key {
    static let wordIndex = NSAttributedString.Key("clipsWordIndex")
    static let paraStart = NSAttributedString.Key("clipsParaStart")
}

final class TranscriptTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?
    var onDoubleClick: (() -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if let h = onKey, h(event) { return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)      // tracks the drag / selection until the mouse goes up
        if event.clickCount == 2 { onDoubleClick?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return onMenu?(characterIndexForInsertion(at: p)) ?? super.menu(for: event)
    }
    override var acceptsFirstResponder: Bool { true }
}

struct TranscriptView: NSViewRepresentable {
    @ObservedObject var model: ProjectModel
    var fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        let tv = TranscriptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 18, height: 16)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        tv.onKey = { [weak coordinator = context.coordinator] e in coordinator?.key(e) ?? false }
        tv.onDoubleClick = { [weak coordinator = context.coordinator] in coordinator?.doubleClicked() }
        tv.onMenu = { [weak coordinator = context.coordinator] loc in coordinator?.menu(atChar: loc) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = tv
        scroll.drawsBackground = false
        context.coordinator.textView = tv
        context.coordinator.rebuildText(fontSize: fontSize)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.model = model
        let sig = "\(model.transcriptVersion)|\(model.project.words.count)|\(model.project.speakers.map { $0.name }.joined())|\(fontSize)|\(model.showHiddenWords)"
        if sig != c.textSignature { c.rebuildText(fontSize: fontSize) }
        c.applyClipStyling()
        c.highlight(model.currentWord, follow: model.engine.isPlaying)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ProjectModel
        weak var textView: TranscriptTextView?
        var wordRanges: [NSRange] = []
        var textSignature = ""
        var clipSignature = ""
        var highlighted: Int? = nil
        var settingSelection = false

        init(model: ProjectModel) { self.model = model }

        func rebuildText(fontSize: CGFloat) {
            guard let tv = textView else { return }
            let p = model.project
            textSignature = "\(model.transcriptVersion)|\(p.words.count)|\(p.speakers.map { $0.name }.joined())|\(fontSize)|\(model.showHiddenWords)"
            let showHidden = model.showHiddenWords
            let out = NSMutableAttributedString()
            let body = NSFont.systemFont(ofSize: fontSize)
            let label = NSFont.systemFont(ofSize: fontSize * 0.78, weight: .semibold)
            let para = NSMutableParagraphStyle()
            para.lineSpacing = fontSize * 0.35
            para.paragraphSpacing = fontSize * 0.9
            let labelPara = NSMutableParagraphStyle()
            labelPara.paragraphSpacing = fontSize * 0.2
            wordRanges = Array(repeating: NSRange(location: 0, length: 0), count: p.words.count)
            var prev: Word? = nil
            for (i, w) in p.words.enumerated() {
                if w.isHidden && !showHidden {
                    // left out of the text; an empty range keeps the index lookup working
                    wordRanges[i] = NSRange(location: out.length, length: 0)
                    continue
                }
                let newPara = prev == nil || prev!.speaker != w.speaker || w.start - prev!.end > 2.5
                if newPara {
                    if prev != nil { out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: para])) }
                    let name = p.speakers.indices.contains(w.speaker) ? p.speakers[w.speaker].name : "Speaker \(w.speaker + 1)"
                    let color = speakerColors[w.speaker % speakerColors.count]
                    out.append(NSAttributedString(string: "\(name.uppercased())   \(fmtTime(w.start))\n", attributes: [
                        .font: label, .foregroundColor: color, .paragraphStyle: labelPara, .paraStart: i,
                    ]))
                } else {
                    out.append(NSAttributedString(string: " ", attributes: [.font: body, .paragraphStyle: para]))
                }
                let r = NSRange(location: out.length, length: (w.text as NSString).length)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: body, .foregroundColor: NSColor.textColor, .paragraphStyle: para, .wordIndex: i,
                ]
                if w.isHidden {
                    // hidden: faded with a dotted line through it
                    attrs[.foregroundColor] = NSColor.tertiaryLabelColor
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    attrs[.strikethroughColor] = NSColor.secondaryLabelColor
                }
                out.append(NSAttributedString(string: w.text, attributes: attrs))
                wordRanges[i] = r
                prev = w
            }
            if p.words.isEmpty {
                out.append(NSAttributedString(string: model.isReady ? "No speech was found." : "The transcript will appear here.",
                                              attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            settingSelection = true
            tv.textStorage?.setAttributedString(out)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            settingSelection = false
            clipSignature = ""
            highlighted = nil
        }

        /// Dim words outside the clip and strike through words cut out of it.
        func applyClipStyling() {
            guard let tv = textView, let lm = tv.layoutManager else { return }
            let clip = model.selectedClip
            let sig = clip.map { "\($0.id)|\($0.ranges)" } ?? "none"
            if sig == clipSignature { return }
            let firstTime = clipSignature == ""
            clipSignature = sig
            let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.strikethroughStyle, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            guard let clip else { return }
            let ws = model.project.words
            var firstIn: Int? = nil
            for (i, w) in ws.enumerated() {
                let r = wordRanges[i]
                let mid = (w.start + w.end) / 2
                if mid < clip.start || mid > clip.end {
                    lm.addTemporaryAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, forCharacterRange: r)
                } else if clip.outputTime(forMaster: mid) == nil {
                    lm.addTemporaryAttribute(.foregroundColor, value: NSColor.systemRed.withAlphaComponent(0.7), forCharacterRange: r)
                    lm.addTemporaryAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: r)
                } else if firstIn == nil { firstIn = i }
            }
            _ = firstTime
            if let f = firstIn, f < wordRanges.count {
                // bring the clip into view
                let r = wordRanges[f]
                tv.scrollRangeToVisible(NSRange(location: r.location, length: 0))
            }
        }

        func highlight(_ idx: Int?, follow: Bool) {
            guard let tv = textView, let lm = tv.layoutManager, idx != highlighted else { return }
            if let h = highlighted, h < wordRanges.count {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: wordRanges[h])
            }
            highlighted = idx
            if let i = idx, i < wordRanges.count, wordRanges[i].length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), forCharacterRange: wordRanges[i])
                if follow {
                    let visible = tv.visibleRect
                    let glyphs = lm.glyphRange(forCharacterRange: wordRanges[i], actualCharacterRange: nil)
                    var rect = lm.boundingRect(forGlyphRange: glyphs, in: tv.textContainer!)
                    rect.origin.y += tv.textContainerInset.height
                    if !visible.insetBy(dx: 0, dy: 40).contains(rect) {
                        tv.scroll(NSPoint(x: 0, y: max(0, rect.midY - visible.height * 0.35)))
                    }
                }
            }
        }

        func word(atChar loc: Int) -> Int? {
            guard let ts = textView?.textStorage, ts.length > 0 else { return nil }
            for l in [loc, loc - 1] where l >= 0 && l < ts.length {
                if let i = ts.attribute(.wordIndex, at: l, effectiveRange: nil) as? Int { return i }
                if let i = ts.attribute(.paraStart, at: l, effectiveRange: nil) as? Int { return i }
            }
            return nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !settingSelection, let tv = textView else { return }
            let r = tv.selectedRange()
            if r.length == 0 {
                // only a real click should move the playhead
                guard let ev = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(ev.type) else { return }
                if let w = word(atChar: r.location) {
                    model.selection = nil
                    model.seekMaster(model.project.words[w].start)
                }
                return
            }
            // snap to whole words
            var first: Int? = nil, last: Int? = nil
            for i in wordRanges.indices {
                let wr = wordRanges[i]
                if wr.length == 0 { continue }          // a hidden word that isn't shown
                if NSIntersectionRange(wr, r).length > 0 {
                    if first == nil { first = i }
                    last = i
                } else if first != nil { break }
            }
            if let f = first, let l = last { model.selection = f...l } else { model.selection = nil }
        }

        func key(_ e: NSEvent) -> Bool { handleKey(model, e) }

        func doubleClicked() {
            if model.selection != nil { model.beginEditingText() }
        }

        /// Right-click: act on the selection if the click is inside it, else on the word clicked.
        func menu(atChar loc: Int) -> NSMenu? {
            guard let w = word(atChar: loc), w < model.project.words.count else { return nil }
            if !(model.selection?.contains(w) ?? false) {
                model.selection = w...w
                settingSelection = true
                textView?.setSelectedRange(wordRanges[w])
                settingSelection = false
            }
            guard let sel = model.selection else { return nil }
            let m = ClosureMenu()
            let txt = model.text(of: sel)
            m.add("Fix Text “\(txt.count > 30 ? String(txt.prefix(30)) + "…" : txt)”…  (E)") { [weak self] in self?.model.beginEditingText() }
            let isHidden = model.allHidden(sel)
            m.add(isHidden ? "Show in Transcript & Captions  (H)" : "Hide from Transcript & Captions  (H)") { [weak self] in
                self?.model.setHidden(sel, !isHidden)
            }
            let places = model.occurrences(of: sel).count
            if places > 1 {
                let short = txt.count > 20 ? String(txt.prefix(20)) + "…" : txt
                m.add(isHidden ? "Show “\(short)” Everywhere (\(places) places)" : "Hide “\(short)” Everywhere (\(places) places)") { [weak self] in
                    self?.model.setHidden(sel, !isHidden, everywhere: true)
                }
            }
            m.addSeparator()
            m.add("Make Clip  (C)") { [weak self] in self?.model.makeClipFromSelection() }
            if model.selectedClip != nil {
                m.add("Remove from Clip  (Delete)") { [weak self] in self?.model.cutSelection() }
                m.add("Restore  (R)") { [weak self] in self?.model.restoreSelection() }
                m.add("Clip Starts Here  ([)") { [weak self] in self?.model.setStart(toWord: sel.lowerBound) }
                m.add("Clip Ends Here  (])") { [weak self] in self?.model.setEnd(toWord: sel.upperBound) }
            }
            return m
        }
    }
}
