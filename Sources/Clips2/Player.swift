import Foundation
import AVFoundation
import AppKit
import SwiftUI
import QuartzCore

/// Plays edits straight from the camera files. Rebuilding an edit swaps the player item; nothing is rendered.
@MainActor
final class PlayerEngine: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published private(set) var itemVersion = 0
    @Published var renderSize = CGSize(width: 1920, height: 1080)
    private(set) var built: BuiltEdit?
    private(set) var captionLayer: CALayer?
    private var observer: Any?
    private var rateObs: NSKeyValueObservation?
    private var readyObs: NSKeyValueObservation?
    /// Where a freshly loaded item is headed. Until that seek lands the new item reports 0:00, and that
    /// must not overwrite the playhead (or every framing change would send it back to the start).
    private var loadTarget: Double?
    private var loadAt = Date.distantPast
    private var landing: Bool { loadTarget != nil && Date().timeIntervalSince(loadAt) < 3 }
    var onTick: ((Double) -> Void)?

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.skimming, !self.landing else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.onTick?(self.time)
            }
        }
        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    func load(_ b: BuiltEdit, mix: AVAudioMix, captions: CALayer?, at t: Double, play: Bool? = nil) {
        let wasPlaying = play ?? isPlaying
        let comp = b.composition.copy() as! AVComposition
        let item = AVPlayerItem(asset: comp)
        item.videoComposition = (b.videoComposition.copy() as! AVVideoComposition)
        item.audioMix = mix
        // no spatial audio: with AirPods macOS otherwise "spatializes" video playback, adding a virtual room (sounds echoey)
        item.allowedAudioSpatializationFormats = []
        item.seekingWaitsForVideoCompositionRendering = true
        built = b
        captionLayer = captions
        duration = b.duration
        renderSize = b.renderSize
        player.replaceCurrentItem(with: item)
        let target = max(0, min(t, max(0, b.duration - 0.05)))
        let itemID = ObjectIdentifier(item)
        loadTarget = target
        loadAt = Date()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor in
                guard let self, done, let cur = self.player.currentItem, ObjectIdentifier(cur) == itemID else { return }
                self.loadTarget = nil
            }
        }
        // a seek made before the item is ready can leave the viewer black until you press play:
        // seek again once it's ready, so the paused frame always shows
        readyObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self, let cur = self.player.currentItem, ObjectIdentifier(cur) == itemID else { return }
                self.readyObs = nil
                // the first seek may have been dropped while the item loaded: go there now (also while playing)
                if self.loadTarget != nil || (self.player.timeControlStatus == .paused && !self.skimming) {
                    let to = self.loadTarget ?? self.time
                    self.player.seek(to: CMTime(seconds: to, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, let cur = self.player.currentItem, ObjectIdentifier(cur) == itemID else { return }
                            self.loadTarget = nil
                        }
                    }
                }
            }
        }
        time = target
        itemVersion += 1
        if wasPlaying { player.play() }
    }

    func setMix(_ mix: AVAudioMix) { player.currentItem?.audioMix = mix }

    func seek(_ t: Double, exact: Bool = true) {
        skimming = false; pendingSeek = nil; loadTarget = nil
        let target = max(0, min(t, duration))
        let tol: CMTime = exact ? .zero : CMTime(value: 1, timescale: 10)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        time = target
    }

    // MARK: scrubbing & skimming

    /// true while the mouse skims the timeline: the viewer shows that moment, the playhead stays put.
    private(set) var skimming = false
    private var pendingSeek: Double? = nil
    private var seekBusy = false

    /// Dragging the playhead: moves it and shows each frame as fast as the decoder allows.
    func scrub(_ t: Double) {
        skimming = false; loadTarget = nil
        time = max(0, min(t, duration))
        queueSeek(time)
    }
    /// Hovering over the timeline with skimming on.
    func skim(_ t: Double) {
        guard !isPlaying, player.timeControlStatus == .paused else { return }
        skimming = true
        queueSeek(max(0, min(t, duration)))
    }
    /// Mouse left the timeline: back to the playhead.
    func endSkim() {
        guard skimming else { return }
        skimming = false
        pendingSeek = nil
        seek(time)
    }
    private func queueSeek(_ t: Double) { pendingSeek = t; pump() }
    private func pump() {
        guard !seekBusy, let t = pendingSeek else { return }
        pendingSeek = nil
        seekBusy = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seekBusy = false; self?.pump() }
        }
    }

    func toggle() {
        if skimming { skimming = false; pendingSeek = nil; seek(time) }
        if player.timeControlStatus == .paused {
            if time >= duration - 0.05 { seek(0) }
            player.play()
        } else { player.pause() }
    }
    func pause() { player.pause() }
    func play() { if skimming { endSkim() }; player.play() }

    func step(frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }
}

// MARK: - View

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var syncLayer: AVSynchronizedLayer?
    var captionHost: CALayer?
    var renderSize = CGSize(width: 1920, height: 1080)
    var guides = false
    private let guideLayer = CAShapeLayer()
    // dragging / pinching the picture to frame it
    var canDrag: (() -> Bool)?
    var onDrag: ((CGFloat, CGFloat, CGFloat) -> Void)?   // dx, dy (points, y up), points per render pixel
    var onPinch: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDragBegin: (() -> Void)?
    private var lastDrag: NSPoint? = nil

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard videoRect.contains(p), canDrag?() == true else { lastDrag = nil; return }
        lastDrag = p
        onDragBegin?()
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with e: NSEvent) {
        guard let last = lastDrag else { return }
        let p = convert(e.locationInWindow, from: nil)
        onDrag?(p.x - last.x, p.y - last.y, videoRect.width / max(1, renderSize.width))
        lastDrag = p
    }
    override func mouseUp(with e: NSEvent) {
        if lastDrag != nil { onDragEnd?() }
        lastDrag = nil
        window?.invalidateCursorRects(for: self)
    }
    override func magnify(with e: NSEvent) {
        guard canDrag?() == true else { return }
        if e.phase == .began { onDragBegin?() }
        onPinch?(e.magnification)
        if e.phase == .ended || e.phase == .cancelled { onDragEnd?() }
    }
    override func resetCursorRects() {
        if canDrag?() == true { addCursorRect(videoRect, cursor: .openHand) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        guideLayer.strokeColor = NSColor.systemPink.withAlphaComponent(0.55).cgColor
        guideLayer.fillColor = nil
        guideLayer.lineDashPattern = [6, 5]
        guideLayer.lineWidth = 1
        layer?.addSublayer(guideLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    var videoRect: CGRect { AVMakeRect(aspectRatio: renderSize, insideRect: bounds) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        let r = videoRect
        if let s = syncLayer {
            s.frame = r
            if let host = captionHost {
                let k = r.width / max(1, renderSize.width)
                host.transform = CATransform3DMakeScale(k, k, 1)
                host.position = CGPoint(x: r.width / 2, y: r.height / 2)
            }
        }
        // social "safe zone" guides for vertical clips (top 14%, bottom 20%, sides 6%)
        if guides {
            let path = CGMutablePath()
            path.addRect(CGRect(x: r.minX + r.width * 0.06, y: r.minY + r.height * 0.20,
                                width: r.width * 0.88, height: r.height * 0.66))
            guideLayer.path = path
            guideLayer.isHidden = false
        } else { guideLayer.isHidden = true }
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    func attach(item: AVPlayerItem?, captions: CALayer?, renderSize: CGSize) {
        self.renderSize = renderSize
        syncLayer?.removeFromSuperlayer()
        syncLayer = nil; captionHost = nil
        if let item, let captions {
            let s = AVSynchronizedLayer(playerItem: item)
            let host = Captions.container(captions, size: renderSize)
            host.bounds = CGRect(origin: .zero, size: renderSize)
            host.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            s.addSublayer(host)
            layer?.insertSublayer(s, above: playerLayer)
            syncLayer = s; captionHost = host
        }
        needsLayout = true
    }
}

struct PlayerView: NSViewRepresentable {
    @ObservedObject var engine: PlayerEngine
    var guides: Bool
    var model: ProjectModel? = nil

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView(frame: .zero)
        v.playerLayer.player = engine.player
        return v
    }
    func updateNSView(_ v: PlayerNSView, context: Context) {
        if let m = model {
            v.canDrag = { [weak m] in m?.canDragFraming ?? false }
            v.onDragBegin = { [weak m] in m?.engine.pause(); m?.beginGesture() }
            v.onDrag = { [weak m] dx, dy, k in m?.dragFraming(dx: dx, dy: dy, k: k) }
            v.onPinch = { [weak m] g in m?.pinchFraming(g) }
            v.onDragEnd = { [weak m] in m?.endGesture() }
            v.window?.invalidateCursorRects(for: v)
        }
        if context.coordinator.version != engine.itemVersion || v.guides != guides {
            context.coordinator.version = engine.itemVersion
            v.guides = guides
            v.attach(item: engine.player.currentItem, captions: engine.captionLayer, renderSize: engine.renderSize)
        }
    }
    func makeCoordinator() -> Coord { Coord() }
    final class Coord { var version = -1 }
}
