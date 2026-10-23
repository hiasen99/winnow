import Foundation
import CoreGraphics

/// The box behind the spoken word glides to each new word on a damped spring: about 170 ms to settle,
/// with a small (~7 %) overshoot of position and width before it settles around the word.
/// It's simulated (not CASpringAnimation) so a word that starts mid-move carries the box's speed on
/// without a jump, and the viewer, export and render_frame all show exactly the same thing.
enum WordBoxMotion {
    static let damping = 0.65        // ζ: 0.65 ≈ 7 % overshoot
    static let omega = 34.0          // rad/s: ≈ 170 ms to settle within 2 %
    static let sampleRate = 120.0    // key frames per second while moving
    static let appearScale = 0.86    // the first word of a caption: the box springs up from this size

    /// Key frames (clip output time, rect) for a box that heads for `targets[i].rect` from `targets[i].time`
    /// (sorted by time) and is shown until `end`.
    static func keyframes(_ targets: [(time: Double, rect: CGRect)], end: Double) -> (times: [Double], rects: [CGRect]) {
        guard let first = targets.first else { return ([], []) }
        func vec(_ r: CGRect) -> [Double] { [Double(r.midX), Double(r.midY), Double(r.width), Double(r.height)] }
        func rect(_ v: [Double]) -> CGRect { CGRect(x: v[0] - v[2] / 2, y: v[1] - v[3] / 2, width: v[2], height: v[3]) }
        var x = vec(first.rect)
        x[2] *= appearScale; x[3] *= appearScale
        var v = [0.0, 0, 0, 0]
        var times = [first.time], rects = [rect(x)]
        let frame = 1 / sampleRate, dt = frame / 16
        let k = omega * omega, c = 2 * damping * omega
        for (i, tg) in targets.enumerated() {
            let goal = vec(tg.rect)
            let stop = max(tg.time, i + 1 < targets.count ? targets[i + 1].time : end)
            var t = tg.time
            if t > times[times.count - 1] + 1e-9 { times.append(t); rects.append(rect(x)) }   // held still until now
            var nextSample = t + frame
            while t < stop - 1e-9 {
                let h = min(dt, stop - t)
                for j in 0..<4 {
                    v[j] += (-k * (x[j] - goal[j]) - c * v[j]) * h
                    x[j] += v[j] * h
                }
                t += h
                if (0..<4).allSatisfy({ abs(x[$0] - goal[$0]) < 0.2 && abs(v[$0]) < 3 }) {
                    x = goal; v = [0, 0, 0, 0]
                    times.append(t); rects.append(rect(x))
                    break
                }
                if t >= nextSample - 1e-9 || t >= stop - 1e-9 {
                    times.append(t); rects.append(rect(x)); nextSample += frame
                }
            }
        }
        return (times, rects)
    }
}
