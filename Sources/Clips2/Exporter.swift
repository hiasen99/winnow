import Foundation
import AVFoundation
import QuartzCore

enum Exporter {
    /// Renders one finished clip (the only time anything is rendered).
    static func export(project p: Project, clip: Clip, auto: [AngleSegment], loaded: [LoadedAngle?],
                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try CompositionBuilder.build(project: p, clip: clip, auto: auto, loaded: loaded, format: clip.format)
        let vc = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
        if clip.captions {
            let style = p.captionStyle
            let track = Captions.track(for: clip, project: p, renderSize: built.renderSize)
            let captions = Captions.makeLayer(track, style: style, renderSize: built.renderSize, total: built.duration)
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: built.renderSize)
            let videoLayer = CALayer()
            videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            parent.addSublayer(Captions.container(captions, size: built.renderSize))
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        }
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ClipsError("Couldn't start the export.")
        }
        session.videoComposition = vc
        session.audioMix = CompositionBuilder.audioMix(built, mix: clip.audio, angles: p.angles, clip: clip)
        session.shouldOptimizeForNetworkUse = true
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let prog) = state { progress(prog.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
    }

    /// Just the clip's sound (cuts, sound changes and levels included).
    static func exportAudio(project p: Project, clip: Clip, auto: [AngleSegment], loaded: [LoadedAngle?],
                            to url: URL, wav: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try CompositionBuilder.build(project: p, clip: clip, auto: auto, loaded: loaded, format: clip.format)
        let mix = CompositionBuilder.audioMix(built, mix: clip.audio, angles: p.angles, clip: clip)
        try? FileManager.default.removeItem(at: url)
        let tracks = built.audioTracks.sorted { $0.key < $1.key }.map { $0.value }
        guard !tracks.isEmpty else { throw ClipsError("This clip has no sound to export.") }
        if !wav {
            guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw ClipsError("Couldn't start the audio export.")
            }
            session.audioMix = mix
            let watcher = Task {
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let prog) = state { progress(prog.fractionCompleted) }
                }
            }
            defer { watcher.cancel() }
            try await session.export(to: url, as: .m4a)
            progress(1)
            return
        }
        // WAV: read the mixed sound and write 48 kHz 24-bit stereo PCM
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        out.audioMix = mix
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? ClipsError("Couldn't write the WAV file.")
        }
        writer.startSession(atSourceTime: .zero)
        let total = max(0.001, built.duration)
        while let sb = out.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            input.append(sb)
            progress(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / total))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? ClipsError("Couldn't write the WAV file.") }
        if reader.status == .failed { throw reader.error ?? ClipsError("Couldn't read the clip's sound.") }
        progress(1)
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80)).isEmpty ? "Clip" : String(cleaned.prefix(80))
    }
}
