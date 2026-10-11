import Foundation
import AVFoundation
import Speech
import CoreMedia

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26). Nothing leaves the Mac.
enum Transcriber {

    static func transcribe(audioFile url: URL, language: String,
                           progress: @escaping @Sendable (Double) -> Void,
                           status: @escaping @Sendable (String) -> Void) async throws -> [Word] {
        let wanted = Locale(identifier: language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw ClipsError("Speech recognition doesn't support \(language) on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Downloading Apple's speech model (one time)…")
            try await request.downloadAndInstall()
        }
        status("Transcribing…")
        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / file.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    let piece = String(text[run.range].characters)
                    guard let tr = run.audioTimeRange else {
                        // punctuation without timing: glue onto the previous word
                        let t = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty, !words.isEmpty { words[words.count - 1].text += t }
                        continue
                    }
                    let start = tr.start.seconds, end = (tr.start + tr.duration).seconds
                    // a run can hold more than one word; split evenly by characters if so
                    let parts = piece.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
                    if parts.isEmpty { continue }
                    if parts.count == 1 {
                        if isPunctuation(parts[0]), !words.isEmpty {
                            words[words.count - 1].text += parts[0]
                        } else {
                            words.append(Word(text: parts[0], start: start, end: max(end, start + 0.05)))
                        }
                    } else {
                        let chars = Double(parts.reduce(0) { $0 + $1.count })
                        var t = start
                        for p in parts {
                            let d = (end - start) * Double(p.count) / max(1, chars)
                            words.append(Word(text: p, start: t, end: t + max(0.05, d)))
                            t += d
                        }
                    }
                }
                let reached = (result.range.start + result.range.duration).seconds
                if total > 0 { progress(min(1, reached / total)) }
            }
            return words
        }

        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        var words = try await collector.value
        words.sort { $0.start < $1.start }
        // keep times monotonic
        for i in words.indices.dropFirst() where words[i].start < words[i - 1].end {
            words[i - 1].end = max(words[i - 1].start + 0.02, words[i].start)
        }
        return words
    }

    static func isPunctuation(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
