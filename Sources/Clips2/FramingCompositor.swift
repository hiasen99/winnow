import Foundation
import AVFoundation
import CoreImage

/// One shot for `FramingCompositor`: which camera track to draw, where, and whether a blurred copy
/// of the same picture fills the frame behind it (when the shot is zoomed out below 1×).
final class FramedInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    let enablePostProcessing = true        // lets the captions (Core Animation) draw on top in exports
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    /// kCMPersistentTrackID_Invalid = a black gap
    let trackID: CMPersistentTrackID
    /// source pixels (as stored, y down) → render pixels (y down), the same transform a layer instruction would get
    let transform: CGAffineTransform
    /// the picture scaled to fill the frame, for the blurred background; nil = black behind
    let background: CGAffineTransform?
    let renderSize: CGSize

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform,
         background: CGAffineTransform?, renderSize: CGSize) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        self.background = background
        self.renderSize = renderSize
        self.requiredSourceTrackIDs = trackID == kCMPersistentTrackID_Invalid ? [] : [NSNumber(value: trackID)]
    }

    static func black(_ r: CMTimeRange, renderSize: CGSize) -> FramedInstruction {
        FramedInstruction(timeRange: r, trackID: kCMPersistentTrackID_Invalid, transform: .identity, background: nil, renderSize: renderSize)
    }
}

/// Draws each frame with Core Image: used only when some shot is zoomed out (the built-in compositor can't blur).
/// The same path runs in the viewer, the export and render_frame.
final class FramingCompositor: NSObject, AVVideoCompositing {
    /// How soft the background is: blur radius as a fraction of the frame's long side.
    static let blurFraction: CGFloat = 0.045
    /// The background is dimmed a little so the picture in front stands out.
    static let backgroundLevel: CGFloat = 0.82

    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),      // pass colours straight through, like the built-in compositor
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])
    private let queue = DispatchQueue(label: "winnow.framing-compositor", qos: .userInteractive)

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                do {
                    request.finish(withComposedVideoFrame: try Self.render(request))
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private static func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        let rc = request.renderContext
        guard let out = rc.newPixelBuffer() else { throw ClipsError("No frame buffer for the picture.") }
        let size = rc.size
        let bounds = CGRect(origin: .zero, size: size)
        var image = CIImage(color: .black).cropped(to: bounds)

        if let ins = request.videoCompositionInstruction as? FramedInstruction,
           ins.trackID != kCMPersistentTrackID_Invalid,
           let src = request.sourceFrame(byTrackID: ins.trackID) {
            let raw = CGSize(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            let picture = CIImage(cvPixelBuffer: src)
            // the viewer may ask for a smaller frame than the composition's render size
            let k = CGAffineTransform(scaleX: size.width / max(1, ins.renderSize.width),
                                      y: size.height / max(1, ins.renderSize.height))
            if let bg = ins.background {
                let radius = blurFraction * max(size.width, size.height)
                let back = picture.transformed(by: ciTransform(bg.concatenating(k), raw: raw, renderHeight: size.height))
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(radius))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: backgroundLevel, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: backgroundLevel, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: backgroundLevel, w: 0),
                    ])
                    .cropped(to: bounds)
                image = back.composited(over: image)
            }
            let front = picture.transformed(by: ciTransform(ins.transform.concatenating(k), raw: raw, renderHeight: size.height))
            image = front.composited(over: image).cropped(to: bounds)
            CVBufferPropagateAttachments(src, out)
        }
        context.render(image, to: out, bounds: bounds, colorSpace: nil)
        return out
    }

    /// AVFoundation transforms work with y pointing down; Core Image's y points up. Flip in and out.
    static func ciTransform(_ t: CGAffineTransform, raw: CGSize, renderHeight: CGFloat) -> CGAffineTransform {
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: raw.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderHeight)
        return flipIn.concatenating(t).concatenating(flipOut)
    }
}
