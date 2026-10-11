import Foundation
import AVFoundation
import Accelerate

struct ClipsError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Analysis results for one angle, kept in the project's cache folder.
struct AngleAudio {
    var envelope: [Float]       // 100 frames per second, dB
    var rawURL: URL             // 16 kHz mono Float32 samples (headerless)
    var sampleCount: Int
}

enum AudioAnalysis {
    static let rawRate: Double = 16_000
    static let envRate: Double = 100
    static let hop = 160

    // MARK: Reading

    /// Streams the first audio track of `url` as mono Float32 at `rate` Hz.
    static func readMono(url: URL, rate: Double,
                         progress: ((Double) -> Void)? = nil,
                         chunk: ([Float]) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ClipsError("\(url.lastPathComponent) has no sound.") }
        let duration = max(0.1, try await asset.load(.duration).seconds)
        let reader = try AVAssetReader(asset: asset)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw ClipsError("Can't read the sound in \(url.lastPathComponent).") }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? ClipsError("Can't read \(url.lastPathComponent).") }
        var produced = 0
        var lastReport = 0.0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            if len == 0 { continue }
            var arr = [Float](repeating: 0, count: len / 4)
            arr.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
            }
            try chunk(arr)
            produced += arr.count
            let p = Double(produced) / rate / duration
            if p - lastReport > 0.01 { lastReport = p; progress?(min(1, p)) }
            try Task.checkCancellation()
        }
        if reader.status == .failed { throw reader.error ?? ClipsError("Reading sound failed.") }
    }

    /// Decodes one angle: writes raw 16 kHz samples to `rawOut` and returns a 100 fps dB envelope.
    static func analyze(url: URL, rawOut: URL, progress: ((Double) -> Void)? = nil) async throws -> AngleAudio {
        FileManager.default.createFile(atPath: rawOut.path, contents: nil)
        let fh = try FileHandle(forWritingTo: rawOut)
        defer { try? fh.close() }
        var env: [Float] = []
        env.reserveCapacity(400_000)
        var carry: [Float] = []
        var count = 0
        try await readMono(url: url, rate: rawRate, progress: progress) { samples in
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            fh.write(data)
            count += samples.count
            carry.append(contentsOf: samples)
            var i = 0
            while i + hop <= carry.count {
                var ms: Float = 0
                carry.withUnsafeBufferPointer { p in
                    vDSP_measqv(p.baseAddress! + i, 1, &ms, vDSP_Length(hop))
                }
                env.append(10 * log10f(ms + 1e-10))
                i += hop
            }
            carry.removeFirst(i)
        }
        return AngleAudio(envelope: env, rawURL: rawOut, sampleCount: count)
    }

    static func loadRaw(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: .alwaysMapped)
    }

    static func samples(_ data: Data, from start: Int, count: Int) -> [Float] {
        let total = data.count / 4
        var out = [Float](repeating: 0, count: max(0, count))
        guard count > 0 else { return out }
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                let j = start + i
                if j >= 0 && j < total { out[i] = p[j] }
            }
        }
        return out
    }

    // MARK: Cross-correlation

    /// r[k] = sum_n x[n+k] * y[n]  (circular, zero padded). Returns (r, n).
    static func xcorr(_ x: [Float], _ y: [Float], phat: Bool) -> ([Float], Int) {
        let need = x.count + y.count
        var n = 16
        while n < need { n <<= 1 }
        guard let fwd = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self),
              let inv = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        else { return ([], n) }
        let zeros = [Float](repeating: 0, count: n)
        var xr = zeros, yr = zeros
        xr.replaceSubrange(0..<x.count, with: x)
        yr.replaceSubrange(0..<y.count, with: y)
        var Xr = zeros, Xi = zeros, Yr = zeros, Yi = zeros
        fwd.transform(inputReal: xr, inputImaginary: zeros, outputReal: &Xr, outputImaginary: &Xi)
        fwd.transform(inputReal: yr, inputImaginary: zeros, outputReal: &Yr, outputImaginary: &Yi)
        var Rr = zeros, Ri = zeros
        for i in 0..<n {
            var re = Xr[i] * Yr[i] + Xi[i] * Yi[i]
            var im = Xi[i] * Yr[i] - Xr[i] * Yi[i]
            if phat {
                let m = sqrtf(re * re + im * im) + 1e-9
                re /= m; im /= m
            }
            Rr[i] = re; Ri[i] = im
        }
        var rr = zeros, ri = zeros
        inv.transform(inputReal: Rr, inputImaginary: Ri, outputReal: &rr, outputImaginary: &ri)
        return (rr, n)
    }

    /// Onset-strength feature from a dB envelope (robust to different mic gains).
    static func onsets(_ env: [Float]) -> [Float] {
        guard env.count > 1 else { return env }
        var out = [Float](repeating: 0, count: env.count)
        for i in 1..<env.count {
            let a = max(env[i - 1], -60), b = max(env[i], -60)
            out[i] = max(0, b - a)
        }
        let mean = out.reduce(0, +) / Float(out.count)
        return out.map { $0 - mean }
    }

    struct PairSync { var offset: Double; var confidence: Double }

    /// Coarse match of two 100 fps envelopes. offset: sourceB = sourceA + offset.
    /// confidence = best peak ÷ best peak more than 1 s away (≈1 means no real match).
    static func coarse(_ envA: [Float], _ envB: [Float]) -> PairSync? {
        let fa = onsets(envA), fb = onsets(envB)
        let (r, n) = xcorr(fa, fb, phat: false)
        guard !r.isEmpty else { return nil }
        var best = 0, bestV = -Float.infinity
        for k in 0..<n where r[k] > bestV { bestV = r[k]; best = k }
        let lag = best > n / 2 ? best - n : best        // x[n+lag] ~ y[n]
        var second = -Float.infinity
        for k in 0..<n {
            let l = k > n / 2 ? k - n : k
            if abs(l - lag) > 100 && r[k] > second { second = r[k] }
        }
        return PairSync(offset: -Double(lag) / envRate, confidence: Double(bestV / max(second, 1e-6)))
    }

    /// Sample-accurate refinement around a coarse offset, using 20 s where both files have sound.
    static func fine(a: AngleAudio, b: AngleAudio, coarse offB0: Double) throws -> Double {
        var offB = offB0
        let dataA = try loadRaw(a.rawURL), dataB = try loadRaw(b.rawURL)
        let win = 20.0, margin = 0.1
        let durA = Double(a.sampleCount) / rawRate, durB = Double(b.sampleCount) / rawRate
        let ovStart = max(0, -offB), ovEnd = min(durA, durB - offB)
        guard ovEnd - ovStart > win + 2 * margin else { return offB }
        // the window where BOTH are loudest (isolated tracks may be silent while the other talks)
        var bestStart = ovStart, bestE = -Float.infinity
        var t = ovStart
        func mean(_ e: [Float], _ from: Double, _ to: Double) -> Float {
            let i0 = max(0, Int(from * envRate)), i1 = min(e.count, Int(to * envRate))
            guard i1 > i0 else { return -120 }
            return e[i0..<i1].reduce(0, +) / Float(i1 - i0)
        }
        while t + win < ovEnd {
            let e = min(mean(a.envelope, t, t + win), mean(b.envelope, t + offB, t + offB + win))
            if e > bestE { bestE = e; bestStart = t }
            t += win / 2
        }
        let m0 = bestStart
        let xa = samples(dataA, from: Int(m0 * rawRate), count: Int(win * rawRate))
        let bStartIdx = Int(((m0 + offB - margin) * rawRate).rounded())
        let yb = samples(dataB, from: bStartIdx, count: Int((win + 2 * margin) * rawRate))
        let (r2, n2) = xcorr(xa, yb, phat: true)
        guard !r2.isEmpty else { return offB }
        let expected = -Int(margin * rawRate)
        let search = Int(0.06 * rawRate)
        var bk = expected, bv = -Float.infinity
        for k in (expected - search)...(expected + search) {
            let idx = ((k % n2) + n2) % n2
            if r2[idx] > bv { bv = r2[idx]; bk = k }
        }
        offB = Double(bStartIdx) / rawRate - m0 - Double(bk) / rawRate
        return offB
    }

    /// Checks the match in several parts of the recording. Returns the largest disagreement (s)
    /// from the overall offset — big numbers mean one file was edited or drifts.
    static func drift(_ envA: [Float], _ envB: [Float], offset: Double) -> Double {
        let lagF = Int((offset * envRate).rounded())     // envB[i + lagF] ~ envA[i]
        let fa = onsets(envA), fb = onsets(envB)
        let start = max(0, -lagF), end = min(fa.count, fb.count - lagF)
        guard end - start > 6000 else { return 0 }
        let parts = 4, len = (end - start) / parts, search = 300
        var worst = 0.0
        for p in 0..<parts {
            let s0 = start + p * len + search, s1 = start + (p + 1) * len - search
            guard s1 > s0 + 1000 else { continue }
            var bestK = 0, bestV = -Float.infinity
            for k in -search...search {
                var acc: Float = 0
                var i = s0
                while i < s1 {
                    let j = i + lagF + k
                    if j >= 0 && j < fb.count { acc += fa[i] * fb[j] }
                    i += 1
                }
                if acc > bestV { bestV = acc; bestK = k }
            }
            worst = max(worst, abs(Double(bestK) / envRate))
        }
        return worst
    }

    /// Kept for the add-one-file path: coarse + fine against one partner.
    static func findOffset(a: AngleAudio, b: AngleAudio) throws -> (offset: Double, confidence: Double) {
        guard let c = coarse(a.envelope, b.envelope) else { throw ClipsError("Sync failed.") }
        return (try fine(a: a, b: b, coarse: c.offset), c.confidence)
    }

    struct SyncPlan {
        var offsets: [Double?]       // per source; nil = couldn't be placed
        var confidence: [Double?]
        var partner: [Int?]
        var drift: [Double?]
        var order: [Int] = []        // placement order (each one's partner comes before it)
    }

    /// Lines up every source using whichever pairs share sound best (a spanning tree over all pairs),
    /// so isolated tracks (each person's own camera/mic) connect through a shared or combined file.
    /// `fixed` sources keep their offsets; everything else is placed relative to them.
    static func solve(envelopes: [[Float]?], root: Int, fixed: [Int: Double] = [:],
                      minConfidence: Double = 1.15) -> SyncPlan {
        let n = envelopes.count
        var plan = SyncPlan(offsets: Array(repeating: nil, count: n), confidence: Array(repeating: nil, count: n),
                            partner: Array(repeating: nil, count: n), drift: Array(repeating: nil, count: n))
        var placed = Set<Int>()
        if fixed.isEmpty {
            plan.offsets[root] = 0; placed.insert(root)
        } else {
            for (k, v) in fixed where envelopes[k] != nil { plan.offsets[k] = v; placed.insert(k) }
        }
        let live = (0..<n).filter { envelopes[$0] != nil }
        var cache: [String: PairSync] = [:]
        func pair(_ i: Int, _ j: Int) -> PairSync? {
            let key = "\(i)-\(j)"
            if let c = cache[key] { return c }
            guard let a = envelopes[i], let b = envelopes[j], let c = coarse(a, b) else { return nil }
            cache[key] = c
            return c
        }
        while true {
            var best: (i: Int, j: Int, s: PairSync)? = nil
            for i in placed {
                for j in live where !placed.contains(j) {
                    if let s = pair(i, j), s.confidence > (best?.s.confidence ?? 0) { best = (i, j, s) }
                }
            }
            guard let b = best, b.s.confidence >= minConfidence else { break }
            plan.offsets[b.j] = plan.offsets[b.i]! + b.s.offset
            plan.confidence[b.j] = b.s.confidence
            plan.partner[b.j] = b.i
            plan.order.append(b.j)
            placed.insert(b.j)
        }
        return plan
    }

    // MARK: Levels

    static func percentile(_ v: [Float], _ p: Double) -> Float {
        guard !v.isEmpty else { return -60 }
        let s = v.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
    }

    /// Gain (dB) to bring an angle's speech level to about -20 dBFS.
    static func levelMatchGain(_ env: [Float]) -> Double {
        let p = percentile(env.filter { $0 > -70 }, 0.9)
        return Double(max(-12, min(18, -20 - p)))
    }

    // MARK: Mixed audio for transcription

    /// Writes a mono 16 kHz WAV of all angles' audio, aligned on the master timeline.
    static func writeMix(angles: [AngleSource], audio: [AngleAudio?], total totalSeconds: Double, to url: URL,
                         progress: ((Double) -> Void)? = nil) throws {
        let total = Int(totalSeconds * rawRate)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rawRate, channels: 1, interleaved: false)!
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var sources: [(Data, Int, Float)] = []    // data, offset samples, linear gain
        let live = audio.compactMap { $0 }.count
        for (i, a) in angles.enumerated() {
            guard let aa = audio[i] else { continue }
            let g = powf(10, Float(levelMatchGain(aa.envelope)) / 20) / Float(max(1, live))
            sources.append((try loadRaw(aa.rawURL), Int((a.offset * rawRate).rounded()), g))
        }
        let block = Int(rawRate) * 10
        var pos = 0
        while pos < total {
            let n = min(block, total - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let out = buf.floatChannelData![0]
            for i in 0..<n { out[i] = 0 }
            for (data, off, g) in sources {
                let s = samples(data, from: pos + off, count: n)
                for i in 0..<n { out[i] += s[i] * g }
            }
            for i in 0..<n { out[i] = max(-1, min(1, out[i])) }
            try file.write(from: buf)
            pos += n
            progress?(Double(pos) / Double(max(1, total)))
        }
    }

    // MARK: Speakers

    /// Mean level (dB) of an angle over a master-time span.
    static func level(_ env: [Float], angle: AngleSource, from a: Double, to b: Double) -> Float {
        let i0 = Int(((a + angle.offset) * envRate).rounded(.down))
        let i1 = max(i0 + 1, Int(((b + angle.offset) * envRate).rounded(.up)))
        var sum: Float = 0, n: Float = 0
        for i in i0..<i1 where i >= 0 && i < env.count {
            sum += powf(10, env[i] / 10); n += 1
        }
        guard n > 0 else { return -100 }
        return 10 * log10f(sum / n + 1e-10)
    }

    /// Combined loudness (loudest mic) at a master-time frame.
    static func combined(_ envs: [[Float]?], angles: [AngleSource], frame f: Int) -> Float {
        var best: Float = -120
        for (i, e) in envs.enumerated() {
            guard let e, i < angles.count else { continue }
            let j = f + Int((angles[i].offset * envRate).rounded())
            if j >= 0 && j < e.count { best = max(best, e[j]) }
        }
        return best
    }

    /// Speech recognisers often stretch a word over the silence before it. Trim each word's
    /// start/end to where there is actually sound, so clips and captions land on the voice.
    static func tighten(words: inout [Word], angles: [AngleSource], envelopes: [[Float]?]) {
        guard envelopes.contains(where: { $0 != nil }) else { return }
        // noise floor: 10th percentile of the combined level
        var sample: [Float] = []
        let total = Int((angles.map { $0.masterEnd }.max() ?? 0) * envRate)
        var f = 0
        while f < total { sample.append(combined(envelopes, angles: angles, frame: f)); f += 7 }
        let floor = percentile(sample, 0.1)
        var thrs = [Float](repeating: floor + 8, count: words.count)
        for i in words.indices {
            let a = Int((words[i].start * envRate).rounded(.down)), b = Int((words[i].end * envRate).rounded(.up))
            guard b > a + 2 else { continue }
            var levels: [Float] = []
            for k in a..<b { levels.append(combined(envelopes, angles: angles, frame: k)) }
            let peak = levels.max() ?? -120
            let thr = max(peak - 22, floor + 8)
            thrs[i] = thr
            guard peak > floor + 10 else { continue }
            // start after the last real pause inside the span (sound before it belongs to the previous word)
            var startIdx = levels.firstIndex(where: { $0 >= thr }) ?? 0
            var run = 0
            for k in levels.indices {
                if levels[k] < thr { run += 1 } else {
                    if run >= 15, k > 0 { startIdx = k }
                    run = 0
                }
            }
            if startIdx > 2 { words[i].start = Double(a + startIdx) / envRate - 0.04 }
            if let last = levels.lastIndex(where: { $0 >= thr }), last < levels.count - 4, last > startIdx {
                words[i].end = Double(a + last + 1) / envRate + 0.06
            }
            if words[i].end < words[i].start + 0.05 { words[i].end = words[i].start + 0.05 }
        }
        // a word cut short before a pause: extend it while its sound continues
        for i in words.indices.dropLast() {
            var f = Int((words[i].end * envRate).rounded())
            let limit = Int((words[i + 1].start * envRate).rounded()) - 2
            var moved = false
            while f < limit && combined(envelopes, angles: angles, frame: f) >= thrs[i] { f += 1; moved = true }
            if moved { words[i].end = Double(f) / envRate + 0.04 }
        }
    }

    /// Labels each word with who said it, judged by which camera's mic hears it loudest.
    /// Returns the number of speakers found.
    static func assignSpeakers(words: inout [Word], angles: [AngleSource], envelopes: [[Float]?]) -> Int {
        let live = angles.indices.filter { envelopes[$0] != nil && angles[$0].hasAudio }
        guard live.count >= 2, !words.isEmpty else {
            for i in words.indices { words[i].speaker = 0 }
            return 1
        }
        if live.count == 2 {
            let a = live[0], b = live[1]
            var diffs = words.map { w -> Float in
                level(envelopes[a]!, angle: angles[a], from: w.start, to: w.end)
                    - level(envelopes[b]!, angle: angles[b], from: w.start, to: w.end)
            }
            // smooth with a 5-word median
            let raw = diffs
            for i in diffs.indices {
                let lo = max(0, i - 2), hi = min(raw.count - 1, i + 2)
                let s = raw[lo...hi].sorted()
                diffs[i] = s[s.count / 2]
            }
            // 2-means
            var c0 = percentile(diffs, 0.75), c1 = percentile(diffs, 0.25)
            for _ in 0..<30 {
                var s0: Float = 0, n0: Float = 0, s1: Float = 0, n1: Float = 0
                for d in diffs {
                    if abs(d - c0) < abs(d - c1) { s0 += d; n0 += 1 } else { s1 += d; n1 += 1 }
                }
                if n0 > 0 { c0 = s0 / n0 }
                if n1 > 0 { c1 = s1 / n1 }
            }
            if abs(c0 - c1) < 4 {
                for i in words.indices { words[i].speaker = 0 }
                return 1
            }
            let hi = max(c0, c1), lo = min(c0, c1)
            let mid = (hi + lo) / 2, band = (hi - lo) * 0.15
            let strong = (hi - lo) * 0.3
            var current = diffs.first.map { $0 > mid ? 0 : 1 } ?? 0
            for i in words.indices {
                // a clear reading of the word itself wins; otherwise use the smoothed value
                let d = abs(raw[i] - mid) > strong ? raw[i] : diffs[i]
                if d > mid + band { current = 0 } else if d < mid - band { current = 1 }
                words[i].speaker = current
            }
            return 2
        }
        // 3+ mics: loudest relative to its own usual speech level
        let refs = live.map { percentile(envelopes[$0]!.filter { $0 > -70 }, 0.9) }
        var current = 0
        for i in words.indices {
            let w = words[i]
            var scores: [(Int, Float)] = []
            for (k, ai) in live.enumerated() {
                scores.append((k, level(envelopes[ai]!, angle: angles[ai], from: w.start, to: w.end) - refs[k]))
            }
            scores.sort { $0.1 > $1.1 }
            if scores.count > 1, scores[0].1 - scores[1].1 > 3 { current = scores[0].0 }
            words[i].speaker = current
        }
        return live.count
    }
}
