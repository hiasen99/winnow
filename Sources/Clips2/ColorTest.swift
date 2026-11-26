import Foundation
import AVFoundation
import QuartzCore

/// `--colortest <video> <outdir>`: exports the first 2 s of a video through the Core Animation pass
/// (what burning in captions uses) with different colour settings on the video composition, so the one that
/// leaves the picture unchanged can be picked. Writes <outdir>/ct-<variant>.mp4.
enum ColorTest {
    static func run(video: URL, out: URL) async -> Int32 {
        let asset = AVURLAsset(url: video)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let variants: [(String, String?, String?, String?)] = [
            ("none", nil, nil, nil),
            ("709", AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2),
            ("srgb", AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_IEC_sRGB, AVVideoYCbCrMatrix_ITU_R_709_2),
            ("linear", AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunction_Linear, AVVideoYCbCrMatrix_ITU_R_709_2),
        ]
        for (name, prim, tf, mx) in variants {
            for useTool in [true, false] {
                do {
                    let vc = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
                    vc.colorPrimaries = prim
                    vc.colorTransferFunction = tf
                    vc.colorYCbCrMatrix = mx
                    if useTool {
                        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: vc.renderSize)
                        let videoLayer = CALayer(); videoLayer.frame = parent.frame
                        parent.addSublayer(videoLayer)
                        let dot = CALayer(); dot.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
                        dot.backgroundColor = CGColor(srgbRed: 0xAF / 255.0, green: 0x8D / 255.0, blue: 0x68 / 255.0, alpha: 1)
                        parent.addSublayer(dot)
                        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
                    }
                    let url = out.appendingPathComponent("ct-\(name)\(useTool ? "" : "-notool").mp4")
                    try? FileManager.default.removeItem(at: url)
                    guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { continue }
                    s.videoComposition = vc
                    s.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
                    try await s.export(to: url, as: .mp4)
                    print("colortest \(name) tool=\(useTool): ok")
                } catch {
                    print("colortest \(name) tool=\(useTool): \(error.localizedDescription)")
                }
            }
        }
        return 0
    }
}
