import Foundation
import AVFoundation
import CoreML

/// Word timing by forced alignment: a small speech model (wav2vec2, English) listens to the audio and
/// matches every letter of the transcript to the moment it's spoken. Apple's transcriber often gives
/// several words one shared time span; this puts each word where it actually is.
/// The model (≈180 MB) is downloaded once into Application Support and runs on this Mac.
enum Aligner {
    static let modelName = "WinnowAlign-en-1"
    static let downloadURL = URL(string: "https://github.com/hiasen99/winnow/releases/download/aligner-1/WinnowAlign-en-1.zip")!
    static let rate = 16_000.0
    /// Labels of the model's outputs (blank, word separator, letters, apostrophe).
    static let labels: [Character] = ["-", "|", "E", "T", "A", "O", "N", "I", "H", "S", "R", "D", "L", "U", "M", "W",
                                      "C", "F", "G", "Y", "P", "B", "V", "K", "'", "X", "J", "Q", "Z"]
    static let maxSegment = 15.0       // seconds of speech aligned in one go
    static let pauseSplit = 0.5        // a pause this long starts a new segment
    static let minConfidence: Float = -2.5
    static let startLead = 0.04        // the model hears a sound a touch after it starts

    struct Stats { var aligned = 0; var kept = 0; var segments = 0; var seconds = 0.0 }

    static func supports(language: String) -> Bool { language.lowercased().hasPrefix("en") }

    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips 2/Models", isDirectory: true)
    }
    static var modelURL: URL { modelsDir.appendingPathComponent(modelName + ".mlmodelc", isDirectory: true) }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("coremldata.bin").path) }

    // MARK: - Model download

    static func ensureModel(status: @escaping @Sendable (String) -> Void,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        if isInstalled { return }
        let fm = FileManager.default
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        status("Downloading the word-timing model (one time, about 170 MB)…")
        Log.write("aligner: downloading \(downloadURL)")
        let zip = try await Downloader.fetch(downloadURL, progress: progress)
        defer { try? fm.removeItem(at: zip) }
        let tmp = modelsDir.appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ClipsError("Couldn't unpack the word-timing model.") }
        let found = tmp.appendingPathComponent(modelName + ".mlmodelc")
        guard fm.fileExists(atPath: found.appendingPathComponent("coremldata.bin").path) else {
            throw ClipsError("The word-timing model download was incomplete.")
        }
        try? fm.removeItem(at: modelURL)
        try fm.moveItem(at: found, to: modelURL)
        Log.write("aligner: model installed")
    }

    static func loadModel() throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndGPU     // the Neural Engine needs a long first-time compile for no real gain here
        return try MLModel(contentsOf: modelURL, configuration: cfg)
    }

    // MARK: - Aligning

    /// Re-times `words` against the 16 kHz mono recording at `audioFile` (master time).
    /// Words whose segment can't be matched confidently keep their old times. Text, speaker and
    /// hidden flags are never changed, and the count and order of words stay the same.
    static func align(words: [Word], audioFile url: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ([Word], Stats) {
        guard !words.isEmpty else { return (words, Stats()) }
        let loadStart = Date()
        let model = try loadModel()
        Log.write(String(format: "aligner: model loaded in %.1f s", Date().timeIntervalSince(loadStart)))
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard abs(fmt.sampleRate - rate) < 1, fmt.channelCount == 1 else {
            throw ClipsError("The aligner needs 16 kHz mono sound (got \(fmt.sampleRate) Hz, \(fmt.channelCount) ch).")
        }
        let total = Double(file.length) / rate
        let env = envelope(file)           // 100 frames/s, dB
        try? file.close()
        let floor = percentile(env, 0.1)
        let file2 = try AVAudioFile(forReading: url)

        var out = words
        var stats = Stats()
        let started = Date()
        let segs = segments(words)
        for (si, seg) in segs.enumerated() {
            if Task.isCancelled { break }
            progress(Double(si) / Double(segs.count))
            let first = words[seg.lowerBound], last = words[seg.upperBound - 1]
            let prevEnd = seg.lowerBound > 0 ? words[seg.lowerBound - 1].end : 0
            let nextStart = seg.upperBound < words.count ? words[seg.upperBound].start : total
            let padA = min(1.0, max(0.3, (first.start - prevEnd) / 2))
            let padB = min(1.0, max(0.3, (nextStart - last.end) / 2))
            let t0 = max(0, first.start - padA), t1 = min(total, last.end + padB)
            guard t1 - t0 >= 0.5, t1 - t0 <= 31 else { stats.kept += seg.count; continue }
            let x = read(file2, from: t0, to: t1)
            guard x.count >= 8000 else { stats.kept += seg.count; continue }
            stats.segments += 1
            let (lp, T) = try emissions(model, x)
            let V = labels.count
            // tokens: letters of each word, "|" between words, -1 = "any sound" for words with no letters (numbers…)
            var toks: [Int] = [], owner: [Int] = []
            for (j, wi) in seg.enumerated() {
                if j > 0 { toks.append(1); owner.append(-1) }
                var tk = tokens(words[wi].text)
                if tk.isEmpty { tk = [-1] }
                for k in tk { toks.append(k); owner.append(j) }
            }
            guard let path = viterbi(lp, T: T, V: V, toks: toks) else { stats.kept += seg.count; continue }
            var firstF = [Int](repeating: -1, count: seg.count), lastF = [Int](repeating: -1, count: seg.count)
            var confSum: Float = 0, confN = 0
            for t in 0..<T {
                let s = path[t]
                guard s % 2 == 1 else { continue }
                let k = s / 2
                if toks[k] >= 0 { confSum += lp[t * V + toks[k]]; confN += 1 }
                let j = owner[k]
                guard j >= 0 else { continue }
                if firstF[j] < 0 { firstF[j] = t }
                lastF[j] = t
            }
            let conf = confN > 0 ? confSum / Float(confN) : -99
            guard conf >= minConfidence else {
                stats.kept += seg.count
                Log.write(String(format: "aligner: kept %.1f–%.1f s (confidence %.2f)", first.start, last.end, conf))
                continue
            }
            let ratio = Double(x.count) / rate / Double(T)
            for (j, wi) in seg.enumerated() where firstF[j] >= 0 {
                out[wi].start = t0 + Double(firstF[j]) * ratio
                out[wi].end = t0 + Double(lastF[j] + 1) * ratio
            }
            stats.aligned += seg.count
        }
        try? file2.close()
        // tidy: a small lead, snap to a clear sound onset just before, keep everything in order
        for i in out.indices {
            let prevEnd = i > 0 ? out[i - 1].end : 0
            var s = max(prevEnd, out[i].start - startLead)
            if let rise = onset(env, floor: floor, before: out[i].start, from: prevEnd, wordEnd: out[i].end) {
                s = max(prevEnd, min(s, rise - 0.03))
            }
            out[i].start = s
            if out[i].end < out[i].start + 0.05 { out[i].end = out[i].start + 0.05 }
            if i > 0, out[i].start < out[i - 1].end { out[i - 1].end = max(out[i - 1].start + 0.02, out[i].start) }
        }
        stats.seconds = Date().timeIntervalSince(started)
        progress(1)
        Log.write(String(format: "aligner: %d words aligned, %d kept, %d segments, %.1f s", stats.aligned, stats.kept, stats.segments, stats.seconds))
        return (out, stats)
    }

    /// Consecutive words split at pauses (by the old times) and at `maxSegment` seconds.
    static func segments(_ words: [Word]) -> [Range<Int>] {
        var segs: [Range<Int>] = []
        var a = 0
        for i in words.indices.dropFirst() {
            if words[i].start - words[i - 1].end >= pauseSplit || words[i].end - words[a].start > maxSegment {
                segs.append(a..<i); a = i
            }
        }
        segs.append(a..<words.count)
        return segs
    }

    static func tokens(_ text: String) -> [Int] {
        let t = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .uppercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        var out: [Int] = []
        for c in t {
            if c == "-" || c == "|" { continue }
            if let k = labels.firstIndex(of: c) { out.append(k) }
        }
        return out
    }

    /// Log-probabilities from the model: T frames × labels, flattened.
    static func emissions(_ model: MLModel, _ x: [Float]) throws -> ([Float], Int) {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: x.count)], dataType: .float32)
        x.withUnsafeBufferPointer { src in
            arr.withUnsafeMutableBytes { dst, _ in
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: x.count * 4)
            }
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: arr)])
        let result = try model.prediction(from: input)
        guard let lp = result.featureValue(for: "logprobs")?.multiArrayValue else { throw ClipsError("The word-timing model gave no output.") }
        let shape = lp.shape.map { $0.intValue }, strides = lp.strides.map { $0.intValue }
        guard shape.count == 3, shape[2] == labels.count else { throw ClipsError("Unexpected word-timing model output \(shape).") }
        let T = shape[1], V = shape[2]
        var out = [Float](repeating: 0, count: T * V)
        switch lp.dataType {
        case .float32:
            lp.withUnsafeBufferPointer(ofType: Float.self) { p in
                for t in 0..<T { for k in 0..<V { out[t * V + k] = p[t * strides[1] + k * strides[2]] } }
            }
        #if arch(arm64)
        case .float16:
            lp.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for t in 0..<T { for k in 0..<V { out[t * V + k] = Float(p[t * strides[1] + k * strides[2]]) } }
            }
        #endif
        default:
            for t in 0..<T { for k in 0..<V { out[t * V + k] = lp[[0, NSNumber(value: t), NSNumber(value: k)]].floatValue } }
        }
        return (out, T)
    }

    /// CTC Viterbi: the best path through blank / token states. Returns the state for every frame
    /// (even = blank, odd = token (state-1)/2), or nil if there are more tokens than frames.
    static func viterbi(_ lp: [Float], T: Int, V: Int, toks: [Int]) -> [Int]? {
        let L = toks.count, S = 2 * L + 1
        guard T >= L, L > 0 else { return nil }
        var any = [Float](repeating: -1e30, count: T)      // best real letter, for "any sound" tokens
        for t in 0..<T { var m: Float = -1e30; for k in 2..<V { m = max(m, lp[t * V + k]) }; any[t] = m }
        @inline(__always) func em(_ s: Int, _ t: Int) -> Float {
            if s & 1 == 0 { return lp[t * V] }
            let k = toks[s >> 1]
            return k < 0 ? any[t] : lp[t * V + k]
        }
        let NEG: Float = -1e30
        var prev = [Float](repeating: NEG, count: S), cur = [Float](repeating: NEG, count: S)
        var back = [UInt8](repeating: 0, count: T * S)
        prev[0] = em(0, 0); if S > 1 { prev[1] = em(1, 0) }
        for t in 1..<T {
            let base = t * S
            for s in 0..<S {
                var best = prev[s], b: UInt8 = 0
                if s >= 1, prev[s - 1] > best { best = prev[s - 1]; b = 1 }
                if s >= 2, s & 1 == 1, toks[s >> 1] != toks[(s >> 1) - 1], prev[s - 2] > best { best = prev[s - 2]; b = 2 }
                if best > NEG / 2 { cur[s] = best + em(s, t); back[base + s] = b } else { cur[s] = NEG }
            }
            swap(&prev, &cur)
        }
        var s = prev[S - 1] >= prev[S - 2] ? S - 1 : S - 2
        guard prev[s] > NEG / 2 else { return nil }
        var path = [Int](repeating: 0, count: T)
        for t in stride(from: T - 1, through: 0, by: -1) {
            path[t] = s
            s -= Int(back[t * S + s])
        }
        return path
    }

    // MARK: - Sound helpers

    static func read(_ file: AVAudioFile, from t0: Double, to t1: Double) -> [Float] {
        let a = AVAudioFramePosition(t0 * rate), n = AVAudioFrameCount(max(0, (t1 - t0) * rate))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return [] }
        file.framePosition = a
        do { try file.read(into: buf, frameCount: n) } catch { return [] }
        guard let ch = buf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
    }

    /// Loudness in dB, 100 frames per second.
    static func envelope(_ file: AVAudioFile) -> [Float] {
        let hop = 160, block = hop * 1000
        let total = Int(file.length)
        var env: [Float] = []
        env.reserveCapacity(total / hop + 1)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)) else { return [] }
        var pos = 0
        while pos + hop <= total {
            let want = min(block, (total - pos) / hop * hop)
            file.framePosition = AVAudioFramePosition(pos)
            do { try file.read(into: buf, frameCount: AVAudioFrameCount(want)) } catch {
                Log.write("aligner: envelope read stopped at \(pos) of \(total): \(error)"); break
            }
            let n = Int(buf.frameLength)
            if n < hop { break }
            let ch = buf.floatChannelData![0]
            var i = 0
            while i + hop <= n {
                var s: Float = 0
                for k in i..<(i + hop) { s += ch[k] * ch[k] }
                env.append(10 * log10(s / Float(hop) + 1e-10))
                i += hop
            }
            pos += n / hop * hop
        }
        if env.count < total / hop - 1 { Log.write("aligner: envelope short (\(env.count) of \(total / hop))") }
        return env
    }

    static func percentile(_ v: [Float], _ q: Double) -> Float {
        guard !v.isEmpty else { return -100 }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }

    /// A quiet-to-loud rise (after ≥80 ms of quiet) in the 0.3 s before `before`, not earlier than `from`.
    static func onset(_ env: [Float], floor: Float, before: Double, from: Double, wordEnd: Double) -> Double? {
        let f1 = min(env.count, Int((before + 0.05) * 100)), f0 = max(0, max(Int(from * 100), Int((before - 0.3) * 100)))
        guard f1 - f0 > 5 else { return nil }
        let p0 = max(0, min(env.count - 1, Int(before * 100))), p1 = max(p0 + 1, min(env.count, Int(wordEnd * 100) + 1))
        let peak = env[p0..<p1].max() ?? env[f0..<f1].max()!
        let thr = max(floor + 12, peak - 30)
        var run = 0, rise: Int? = nil
        for k in f0..<f1 {
            if env[k] < thr { run += 1 } else {
                if run >= 8 { rise = k }
                run = 0
            }
        }
        return rise.map { Double($0) / 100 }
    }
}

/// One file download with progress, into a temporary file.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var cont: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Double) -> Void

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.cont = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            cont?.resume(throwing: ClipsError("Couldn't download the word-timing model (HTTP \(http.statusCode)).")); cont = nil
            return
        }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-dl-\(UUID().uuidString).zip")
        do { try FileManager.default.moveItem(at: location, to: keep); cont?.resume(returning: keep) }
        catch { cont?.resume(throwing: error) }
        cont = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { cont?.resume(throwing: e); cont = nil }
    }
}
