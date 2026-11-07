import Foundation
import AVFoundation

/// Clips2 --composetest <project folder COPY> [tries per clip]: builds every clip's export composition, with its
/// edit points nudged by sub-millisecond amounts, and checks AVFoundation accepts it (the same check an export
/// does before it renders: "The video could not be composed." when it fails).
@MainActor
enum ComposeTest {
    final class Notes: NSObject, AVVideoCompositionValidationHandling {
        var list: [String] = []
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
            list.append("invalid value \(key)"); return true
        }
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
            list.append("uncovered \(timeRange.start.value)-\(timeRange.end.value)"); return true
        }
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction: any AVVideoCompositionInstructionProtocol) -> Bool {
            list.append("bad instruction \(instruction.timeRange.start.value)-\(instruction.timeRange.end.value)"); return true
        }
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction: any AVVideoCompositionInstructionProtocol,
                              layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
            list.append("bad track id"); return true
        }
    }

    static func run(folder: URL, tries: Int) async -> Int32 {
        do {
            let m = try ProjectModel(folder: folder)
            await m.open()
            let p = m.project
            print("project \(p.name): \(p.clips.count) clips, \(m.sources.compactMap { $0 }.count) sources loaded")
            var bad = 0, total = 0
            for clip in p.clips {
                var clipBad = 0
                for k in 0..<max(1, tries) {
                    var c = clip
                    if k > 0 {
                        c.ranges = clip.ranges.map { TimeRange(start: $0.start + Double.random(in: -0.003...0.003),
                                                               end: $0.end + Double.random(in: -0.003...0.003)) }
                    }
                    total += 1
                    if let problem = await check(project: p, clip: c, auto: m.auto, loaded: m.sources) {
                        clipBad += 1
                        if clipBad <= 2 {
                            print("  \(clip.title) try \(k): \(problem)")
                            print("    ranges \(c.ranges.map { String(format: "%.9f-%.9f", $0.start, $0.end) })")
                        }
                    }
                }
                bad += clipBad
                print("\(clip.title): \(clipBad)/\(max(1, tries)) rejected")
            }
            print("TOTAL rejected \(bad)/\(total)")
            return 0
        } catch { print("FAILED \(error)"); return 1 }
    }

    /// nil = AVFoundation accepts this clip's export composition.
    static func check(project p: Project, clip c: Clip, auto: [AngleSegment], loaded: [LoadedAngle?]) async -> String? {
        do {
            let b = try CompositionBuilder.build(project: p, clip: c, auto: auto, loaded: loaded, format: c.format)
            var notes: [String] = []
            let n = Notes()
            let dur = b.composition.duration
            let ok = try await b.videoComposition.isValid(for: b.composition, timeRange: CMTimeRange(start: .zero, duration: dur), validationDelegate: n)
            if !ok { notes.append("invalid: " + n.list.joined(separator: "; ")) }
            let insEnd = b.videoComposition.instructions.last?.timeRange.end ?? .zero
            if dur > insEnd {
                let ends = b.composition.tracks.map { "\($0.mediaType == .video ? "v" : "a")\($0.timeRange.end.value)" }
                notes.append("composition ends \(dur.value) after instructions \(insEnd.value) [\(ends.joined(separator: " "))]")
            }
            return notes.isEmpty ? nil : notes.joined(separator: " | ")
        } catch { return "threw \(error)" }
    }
}
