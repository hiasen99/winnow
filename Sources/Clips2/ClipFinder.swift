import Foundation

struct ClipIdea: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var start: Double
    var end: Double
    var why: String = ""
    var score: Double? = nil
}

enum ClipFinder {

    static let models: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (best picks, ~5–10¢ an episode)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (cheaper)"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (cheapest)"),
        ("claude-fable-5-1", "Claude Fable 5.1 (top end, pricier)"),
    ]

    // MARK: Transcript text

    /// Lines of the transcript with start–end seconds and speaker, broken at sentences and pauses.
    static func transcriptLines(_ p: Project, from: Double = 0, to: Double = .infinity) -> String {
        var out = ""
        var line: [Word] = []
        func flush() {
            guard let f = line.first, let l = line.last else { return }
            let who = p.speakers.indices.contains(f.speaker) ? p.speakers[f.speaker].name : "Speaker \(f.speaker + 1)"
            out += String(format: "[%.1f–%.1f] ", f.start, l.end) + "\(who): " + line.map { $0.text }.joined(separator: " ") + "\n"
            line = []
        }
        let words = p.words.filter { !$0.isHidden && $0.start >= from && $0.end <= to }
        for (i, w) in words.enumerated() {
            if let last = line.last {
                let pause = w.start - last.end
                let sentence = last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")
                if w.speaker != last.speaker || pause > 0.8 || (sentence && line.count > 6) || line.count >= 30 { flush() }
            }
            line.append(w)
            if i == words.count - 1 { flush() }
        }
        return out
    }

    static func prompt(_ p: Project, count: Int, minLen: Int, maxLen: Int, guidance: String) -> String {
        let speakers = p.speakers.map { $0.name }.joined(separator: ", ")
        return """
        You are an expert short-form video editor. Below is a timestamped transcript of a recorded conversation \
        (\(p.videoIndices.count) camera\(p.videoIndices.count == 1 ? "" : "s"); speakers: \(speakers.isEmpty ? "unknown" : speakers)). \
        Each line is [start–end seconds] Speaker: words.

        Find the \(count) best standalone clips for social video (Reels, Shorts, TikTok).
        Each clip must:
        - grab attention in its first 3 seconds (never start mid-thought or on "so", "and", "but", "um")
        - hold one complete idea that makes sense with no earlier context
        - end on a clean, satisfying full stop, not trailing off
        - run \(minLen)–\(maxLen) seconds
        Favour insight, strong conviction, a story, emotion, humour or a quotable line. Don't overlap clips.
        \(guidance.isEmpty ? "" : "\nWhat I'm looking for: \(guidance)\n")
        Reply with ONLY this JSON, nothing before or after it:
        {"clips":[{"title":"short punchy title, max 8 words","start":123.4,"end":178.9,"why":"one sentence on why it works","score":8}]}
        "start" is the start time of the clip's first word and "end" the END time of its last word, in seconds, \
        taken from the transcript's timestamps. "score" is 1–10.

        TRANSCRIPT
        \(transcriptLines(p))
        """
    }

    // MARK: Parsing (JSON or plain "mm:ss - mm:ss Title" lines)

    static func parse(_ text: String) -> [ClipIdea] {
        if let ideas = parseJSON(text), !ideas.isEmpty { return ideas }
        return parseLines(text)
    }

    static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return parseTime(s) }
        return nil
    }

    static func parseJSON(_ text: String) -> [ClipIdea]? {
        guard let s = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let e = text.lastIndex(where: { $0 == "}" || $0 == "]" }), s < e else { return nil }
        let body = String(text[s...e])
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var list: [[String: Any]] = []
        if let d = obj as? [String: Any] {
            list = (d["clips"] as? [[String: Any]]) ?? (d["moments"] as? [[String: Any]]) ?? []
        } else if let a = obj as? [[String: Any]] { list = a }
        return list.compactMap { c in
            guard let st = number(c["start"] ?? c["start_time"] ?? c["in"]),
                  let en = number(c["end"] ?? c["end_time"] ?? c["out"]), en > st else { return nil }
            let title = (c["title"] as? String) ?? (c["hook"] as? String) ?? "Clip"
            return ClipIdea(title: title, start: st, end: en,
                            why: (c["why"] as? String) ?? (c["reason"] as? String) ?? "",
                            score: number(c["score"]))
        }
    }

    static func parseLines(_ text: String) -> [ClipIdea] {
        let tp = #"(\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?|\d+(?:\.\d+)?)"#
        let pattern = tp + #"\s*(?:-|–|—|to|→)\s*"# + tp + #"(.*)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [ClipIdea] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            guard let a = parseTime(ns.substring(with: m.range(at: 1))),
                  let b = parseTime(ns.substring(with: m.range(at: 2))), b > a else { continue }
            var title = ns.substring(with: m.range(at: 3))
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|*\"'\t"))
            out.append(ClipIdea(title: title.isEmpty ? "Clip \(out.count + 1)" : title, start: a, end: b))
        }
        return out
    }

    /// Moves rough times onto word boundaries, preferring the start/end of a sentence or turn
    /// when one is close (timestamps are often only accurate to the second).
    static func snap(_ idea: ClipIdea, words: [Word]) -> (Double, Double) {
        guard !words.isEmpty else { return (idea.start, idea.end) }
        func isStart(_ i: Int) -> Bool {
            if i == 0 { return true }
            let p = words[i - 1]
            return p.speaker != words[i].speaker || words[i].start - p.end > 0.45
                || p.text.hasSuffix(".") || p.text.hasSuffix("?") || p.text.hasSuffix("!")
        }
        func isEnd(_ i: Int) -> Bool { i == words.count - 1 || isStart(i + 1) }
        let window = 1.6
        // start
        var first = words.firstIndex { ($0.start + $0.end) / 2 > idea.start } ?? 0
        let startCands = words.indices.filter { abs(words[$0].start - idea.start) <= window && isStart($0) }
        if let best = startCands.min(by: { abs(words[$0].start - idea.start) < abs(words[$1].start - idea.start) }) { first = best }
        // end
        var last = words.lastIndex { ($0.start + $0.end) / 2 < idea.end } ?? (words.count - 1)
        let endCands = words.indices.filter { abs(words[$0].end - idea.end) <= window && isEnd($0) && $0 >= first }
        if let best = endCands.min(by: { abs(words[$0].end - idea.end) < abs(words[$1].end - idea.end) }) { last = best }
        guard last >= first else { return (idea.start, idea.end) }
        let prevEnd = first > 0 ? words[first - 1].end : 0
        let nextStart = last + 1 < words.count ? words[last + 1].start : words[last].end + 1
        let s = max(prevEnd, words[first].start - 0.12)
        let e = min(nextStart, words[last].end + 0.25)
        return (max(0, s), e)
    }

    // MARK: Claude API

    static var keyURL: URL { Store.supportDir.appendingPathComponent("anthropic-key") }

    static func loadKey() -> String {
        (try? String(contentsOf: keyURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func saveKey(_ k: String) {
        let trimmed = k.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try? FileManager.default.removeItem(at: keyURL); return }
        try? trimmed.write(to: keyURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    static func askClaude(prompt: String, model: String) async throws -> String {
        let key = loadKey()
        guard !key.isEmpty else { throw ClipsError("Add your Claude API key in Settings first.") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "HTTP \(code)"
            throw ClipsError("Claude API: \(msg)")
        }
        let blocks = (obj?["content"] as? [[String: Any]]) ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        if text.isEmpty { throw ClipsError("Claude API returned no text.") }
        return text
    }
}
