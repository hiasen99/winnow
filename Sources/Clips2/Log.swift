import Foundation

/// Plain-text log at ~/Library/Logs/Clips 2/clips2.log (handy when something goes wrong).
enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Clips 2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clips2.log")
    }()
    private static let q = DispatchQueue(label: "clips2.log")
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
